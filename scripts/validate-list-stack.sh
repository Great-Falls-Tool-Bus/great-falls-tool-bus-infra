#!/usr/bin/env bash
set -euo pipefail

# Offline validation of the GFTB Mailman 3 list stack (TIN-2380). Asserts the
# load-bearing invariants of the blahaj tenant-list-engine SMTP relay contract
# v0 so a regression in the manifests fails CI before any apply. Never contacts
# a cluster; never needs a secret.

dir="${1:?usage: validate-list-stack.sh <manifest-dir>}"
account_file="${dir}/mailaccount-lists-bounces.yaml"
core_svc_file="${dir}/service-mailman-core.yaml"
cfg_file="${dir}/configmap-mailman.yaml"
pvcs_file="${dir}/pvcs.yaml"
kustomization_file="${dir}/kustomization.yaml"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_file() {
  test -f "$1" || fail "missing $1"
}

field() {
  yq -r "$1" "$2"
}

assert_eq() {
  if [ "$1" != "$2" ]; then
    fail "$3: got '$1', want '$2'"
  fi
}

command -v yq >/dev/null 2>&1 || fail "yq is required"
command -v kubectl >/dev/null 2>&1 || fail "kubectl is required for kubectl kustomize"

require_file "${account_file}"
require_file "${core_svc_file}"
require_file "${cfg_file}"
require_file "${pvcs_file}"
require_file "${kustomization_file}"

# --- Submission identity (contract capability #2) --------------------------
assert_eq "$(field '.apiVersion' "${account_file}")" "mail.tinyland.dev/v1alpha1" "MailAccount apiVersion"
assert_eq "$(field '.kind' "${account_file}")" "MailAccount" "MailAccount kind"
assert_eq "$(field '.metadata.name' "${account_file}")" "lists-bounces" "MailAccount metadata.name"
assert_eq "$(field '.metadata.namespace' "${account_file}")" "latoolb-us-production" "MailAccount metadata.namespace"
assert_eq "$(field '.spec.email' "${account_file}")" "lists-bounces@latoolb.us" "MailAccount spec.email"
assert_eq "$(field '.spec.domainRef' "${account_file}")" "latoolb-us" "MailAccount spec.domainRef"
assert_eq "$(field '.spec.enabled' "${account_file}")" "true" "MailAccount spec.enabled"
assert_eq "$(field '.spec.submission.envelopeSenderAliases | length' "${account_file}")" "1" "MailAccount envelope sender alias count"
assert_eq "$(field '.spec.submission.envelopeSenderAliases[0]' "${account_file}")" "root@lists.latoolb.us" "Mailman observed envelope sender alias"
if [ "$(field '.spec.passwordSecretRef // ""' "${account_file}")" != "" ]; then
  fail "MailAccount must not declare passwordSecretRef; the controller generates the credential (overlay doctrine)"
fi

# --- Incoming LMTP target (contract capability #4) -------------------------
# The substrate transport map routes list mail to this exact service:port.
assert_eq "$(field '.kind' "${core_svc_file}")" "Service" "core Service kind"
assert_eq "$(field '.metadata.name' "${core_svc_file}")" "mailman-core" "core Service name (contract-named LMTP target)"
lmtp_port="$(field '.spec.ports[] | select(.name == "lmtp") | .port' "${core_svc_file}")"
assert_eq "${lmtp_port}" "8024" "core Service LMTP port (contract upstream default)"

# --- Outgoing submission endpoint (contract capabilities #1/#2) ------------
smtp_host="$(yq -r 'select(.metadata.name == "mailman-env") | .data.SMTP_HOST' "${cfg_file}")"
smtp_port="$(yq -r 'select(.metadata.name == "mailman-env") | .data.SMTP_PORT' "${cfg_file}")"
assert_eq "${smtp_host}" "postfix.tinyland-dev-production.svc.cluster.local" "outgoing SMTP host (substrate submission endpoint)"
assert_eq "${smtp_port}" "587" "outgoing SMTP port (submission, not port-25 CIDR trust)"

# docker-mailman uses MAILMAN_HOSTNAME as the internal core host during web
# settings import. The public list identity belongs in SERVE_FROM_DOMAIN.
mailman_hostname="$(yq -r 'select(.metadata.name == "mailman-env") | .data.MAILMAN_HOSTNAME' "${cfg_file}")"
serve_from_domain="$(yq -r 'select(.metadata.name == "mailman-env") | .data.SERVE_FROM_DOMAIN' "${cfg_file}")"
assert_eq "${mailman_hostname}" "mailman-core" "Mailman internal hostname"
assert_eq "${serve_from_domain}" "lists.latoolb.us" "public list domain"

# The [mta] template must require STARTTLS and must not weaken to port 25.
mta_tmpl="$(yq -r 'select(.metadata.name == "mailman-core-mta-template") | .data["mailman-extra.cfg"]' "${cfg_file}")"
echo "${mta_tmpl}" | grep -q "smtp_secure_mode: starttls" || fail "[mta] must set smtp_secure_mode: starttls"
echo "${mta_tmpl}" | grep -q "smtp_port: 587" || fail "[mta] must submit on port 587"
echo "${mta_tmpl}" | grep -q "lmtp_port: 8024" || fail "[mta] must host LMTP on 8024"
echo "${mta_tmpl}" | grep -q "lmtp_host: 0.0.0.0" || fail "[mta] lmtp_host must be 0.0.0.0 so the Service can reach the listener"
if echo "${mta_tmpl}" | grep -Eq "smtp_pass:[[:space:]]*[^[:space:]]"; then
  fail "no smtp_pass literal may live in the config template; it is appended from the Secret at runtime"
fi

# --- No secret material committed ------------------------------------------
if grep -REn "^\s*(password|smtp_pass|POSTGRES_PASSWORD|SECRET_KEY|HYPERKITTY_API_KEY|DATABASE_URL)\s*:\s*['\"]?[A-Za-z0-9+/=]{6,}" "${dir}" \
    | grep -v "secretKeyRef" | grep -v "valueFrom" >/dev/null 2>&1; then
  fail "possible committed secret value under ${dir}; secrets must be referenced by name only"
fi

# --- Images pinned ----------------------------------------------------------
if grep -REn "image:\s*\S*:latest" "${dir}" >/dev/null 2>&1; then
  fail "images must be pinned to a tag/digest, not :latest"
fi
if ! grep -REq "image:\s*\S+" "${dir}"; then
  fail "no container images found; expected mailman-core, mailman-web, postgres"
fi
while IFS= read -r line; do
  case "${line}" in
  *"@sha256:"*) : ;;
  *) fail "image not pinned by immutable digest: ${line}" ;;
  esac
done < <(grep -REh "^\s*image:\s*\S+" "${dir}")

# --- Storage class must be explicit -----------------------------------------
# Honey has no default StorageClass. A missing storageClassName passed offline
# validation once but left all Mailman pods Pending after apply.
# Multi-doc-safe check: the earlier `yq select(...)` form only read the first
# YAML document under some yq builds, so PVCs 2 and 3 falsely validated as
# empty. Assert by count instead: all three PVCs must exist and each must pin
# local-path-retain.
pvc_count="$(grep -cE '^  name: mailman-(postgres|core|web)-data$' "${pvcs_file}")"
sc_count="$(grep -cE '^  storageClassName: local-path-retain$' "${pvcs_file}")"
assert_eq "${pvc_count}" "3" "mailman PVC count"
assert_eq "${sc_count}" "3" "mailman PVC storageClassName local-path-retain pins"

# --- Core first-start memory floor ------------------------------------------
# Mailman core OOMKilled under a 768Mi cap before opening LMTP/REST on the
# first live bring-up. Keep a conservative floor in CI unless the image changes
# and a lower cap is proven.
core_memory_limit="$(yq -r 'select(.metadata.name == "mailman-core") | .spec.template.spec.containers[] | select(.name == "mailman-core") | .resources.limits.memory' "${dir}/deployment-mailman-core.yaml")"
assert_eq "${core_memory_limit}" "2Gi" "mailman-core memory limit"

# --- Web tier co-located with core (TIN-2493) --------------------------------
# The HyperKitty archiver trusts only the source IP in MAILMAN_ARCHIVER_FROM,
# which the web tier's settings.py derives from MAILMAN_HOST_IP. In the earlier
# two-Deployment shape the archive POST arrived from the dynamic core POD IP and
# HyperKitty answered 403. The fix co-locates mailman-web as a second container
# in the mailman-core pod so the POST travels over loopback (127.0.0.1:8000) and
# the trusted source matches. Assert that co-located shape holds.
core_deploy="${dir}/deployment-mailman-core.yaml"

# The standalone web Deployment must be gone (folded into the core pod).
if [ -f "${dir}/deployment-mailman-web.yaml" ]; then
  fail "deployment-mailman-web.yaml must be removed; mailman-web is co-located inside deployment-mailman-core.yaml (TIN-2493)"
fi

# docker-mailman mailman-web:0.5 listens for HTTP on uwsgi.ini's http-socket
# 8000. Port 8080 is not HTTP and returns EOF to probes. The web container now
# lives inside the mailman-core Deployment.
web_http_port="$(yq -r 'select(.metadata.name == "mailman-core") | .spec.template.spec.containers[] | select(.name == "mailman-web") | .ports[] | select(.name == "http") | .containerPort' "${core_deploy}")"
assert_eq "${web_http_port}" "8000" "co-located mailman-web HTTP container port (inside mailman-core Deployment)"

# MAILMAN_HOST_IP on the web container drives MAILMAN_ARCHIVER_FROM; it must be
# 127.0.0.1 so the same-pod loopback archive POST is trusted.
web_host_ip="$(yq -r 'select(.metadata.name == "mailman-core") | .spec.template.spec.containers[] | select(.name == "mailman-web") | .env[] | select(.name == "MAILMAN_HOST_IP") | .value' "${core_deploy}")"
assert_eq "${web_host_ip}" "127.0.0.1" "co-located mailman-web MAILMAN_HOST_IP (drives MAILMAN_ARCHIVER_FROM loopback trust)"

# Core POSTs the archive over loopback to the same-pod web tier, not the Service.
hyperkitty_url="$(yq -r 'select(.metadata.name == "mailman-env") | .data.HYPERKITTY_URL' "${cfg_file}")"
assert_eq "${hyperkitty_url}" "http://127.0.0.1:8000/hyperkitty" "HYPERKITTY_URL must POST over same-pod loopback (co-located archive trust)"

# The web HTTP ingress (8000) is folded into the mailman-core NetworkPolicy; the
# standalone mailman-web policy would select no pods after co-location and must
# be gone (a policy selecting nothing is a silent no-op footgun).
if yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "mailman-web") | .metadata.name' "${dir}/networkpolicy.yaml" | grep -q "mailman-web"; then
  fail "the standalone mailman-web NetworkPolicy must be removed; it selects no pods after co-location (TIN-2493)"
fi
web_np_port="$(yq -r 'select(.metadata.name == "mailman-core") | .spec.ingress[].ports[] | select(.port == 8000) | .port' "${dir}/networkpolicy.yaml")"
assert_eq "${web_np_port}" "8000" "web HTTP ingress (8000) folded into the mailman-core NetworkPolicy"
if grep -q "namespaceSelector: {}" "${dir}/networkpolicy.yaml"; then
  fail "mailman web ingress must not admit every namespace; scope it to the explicit discuss-reader namespaceSelectors (arc-runners, greatfallstoolbus-org-production)"
fi
# The archive PoW gate is now network-enforced (PR #77 follow-through): the
# house cloudflared namespace must NOT be admitted directly to the mailman-core
# web tier on :8000. The only public path is
#   lists.latoolb.us -> anubis-archive:8081 -> mailman-core:8000
# and that final leg is admitted by the SEPARATE additive
# mailman-core-archive-ingress policy in the archive stack, not by this rule.
# Forbid a cloudflared peer reappearing on THIS :8000 rule. Scope to that rule
# only: cloudflared may legitimately appear on other rules or in other stacks.
web_np_8000_ns_peers="$(yq -r 'select(.metadata.name == "mailman-core") | .spec.ingress[] | select(.ports[].port == 8000) | .from[].namespaceSelector.matchLabels["kubernetes.io/metadata.name"] | select(. != null)' "${dir}/networkpolicy.yaml")"
if echo "${web_np_8000_ns_peers}" | grep -qx "cloudflared"; then
  fail "cloudflared must not be admitted to the mailman-core web tier :8000 rule; the archive PoW gate is network-enforced (PR #77). The only public path is lists.latoolb.us -> anubis-archive:8081 -> mailman-core:8000 via the mailman-core-archive-ingress policy."
fi

# The mailman-web Service must still front the web container, now by selecting
# the combined mailman-core pod on targetPort 8000 (external 8080 unchanged).
web_svc_selector="$(yq -r '.spec.selector["app.kubernetes.io/name"]' "${dir}/service-mailman-web.yaml")"
web_svc_target="$(yq -r '.spec.ports[] | select(.name == "http") | .targetPort' "${dir}/service-mailman-web.yaml")"
assert_eq "${web_svc_selector}" "mailman-core" "mailman-web Service selector (co-located pod)"
assert_eq "${web_svc_target}" "8000" "mailman-web Service targetPort (web container HTTP socket)"

# --- Verified outbound TLS to the substrate postfix (#74) -------------------
# Operator ruling 2026-07-07 (Option A): endpoint identity is authenticated,
# not merely encrypted; NetworkPolicy-acceptance of an unverified context was
# rejected. Guard the two clients so the CERT_NONE / SMTP_VERIFY_*=False
# workaround cannot silently return. Both depend on a substrate pre-apply gate
# (postfix presents a cert whose SAN covers the dialed service name, signed by
# a CA delivered in the mail-substrate-ca Secret) — see the bring-up runbook.
core_verify_hostname="$(yq -r 'select(.metadata.name == "mailman-core") | .spec.template.spec.containers[] | select(.name == "mailman-core") | .env[] | select(.name == "SMTP_VERIFY_HOSTNAME") | .value' "${core_deploy}")"
core_verify_cert="$(yq -r 'select(.metadata.name == "mailman-core") | .spec.template.spec.containers[] | select(.name == "mailman-core") | .env[] | select(.name == "SMTP_VERIFY_CERT") | .value' "${core_deploy}")"
assert_eq "${core_verify_hostname}" "True" "mailman-core SMTP_VERIFY_HOSTNAME must be True (endpoint auth on, #74)"
assert_eq "${core_verify_cert}" "True" "mailman-core SMTP_VERIFY_CERT must be True (endpoint auth on, #74)"

# Both containers must trust the substrate mail CA via SSL_CERT_FILE + mount,
# AND via the env-independent /etc/ssl/cert.pem subPath overlay: the mailman
# delivery runner does not inherit SSL_CERT_FILE (proven live 2026-07-09), so
# the default-cafile mount is the trust anchor that actually reaches delivery.
for c in mailman-core mailman-web; do
  ssl_cert_file="$(yq -r "select(.metadata.name == \"mailman-core\") | .spec.template.spec.containers[] | select(.name == \"${c}\") | .env[] | select(.name == \"SSL_CERT_FILE\") | .value" "${core_deploy}")"
  assert_eq "${ssl_cert_file}" "/etc/ssl/mail-substrate-ca/ca.crt" "${c} SSL_CERT_FILE must point at the mounted substrate mail CA (#74)"
  ca_dir_mount="$(yq -r "select(.metadata.name == \"mailman-core\") | .spec.template.spec.containers[] | select(.name == \"${c}\") | .volumeMounts[] | select(.name == \"mail-substrate-ca\" and .mountPath == \"/etc/ssl/mail-substrate-ca\") | .mountPath" "${core_deploy}")"
  assert_eq "${ca_dir_mount}" "/etc/ssl/mail-substrate-ca" "${c} must mount the mail-substrate-ca CA dir (#74)"
  ca_pem_subpath="$(yq -r "select(.metadata.name == \"mailman-core\") | .spec.template.spec.containers[] | select(.name == \"${c}\") | .volumeMounts[] | select(.name == \"mail-substrate-ca\" and .mountPath == \"/etc/ssl/cert.pem\") | .subPath" "${core_deploy}")"
  assert_eq "${ca_pem_subpath}" "ca.crt" "${c} must overlay the default OpenSSL cafile with the substrate CA (env-independent runner trust, #74)"
done

# The CA volume must be sourced from a named Secret (no committed cert material).
ca_vol_secret="$(yq -r 'select(.metadata.name == "mailman-core") | .spec.template.spec.volumes[] | select(.name == "mail-substrate-ca") | .secret.secretName' "${core_deploy}")"
assert_eq "${ca_vol_secret}" "mail-substrate-ca" "mail-substrate-ca volume must reference the operator-owned Secret by name (#74)"

# The web branding ConfigMap must NOT reintroduce the unverified TLS backend.
# Match code-shaped constructs (an assignment/class/definition), not the prose
# that documents what was removed, so the guard survives explanatory comments.
branding_file="${dir}/configmap-mailman-web-branding.yaml"
require_file "${branding_file}"
if grep -Eq "class[[:space:]]+InsecureTLSEmailBackend|verify_mode[[:space:]]*=[[:space:]]*ssl\.CERT_NONE|check_hostname[[:space:]]*=[[:space:]]*False|EMAIL_BACKEND[[:space:]]*=[[:space:]]*[\"'][^\"']*Insecure" "${branding_file}"; then
  fail "mailman-web branding must not reintroduce the unverified TLS email backend (#74): no InsecureTLSEmailBackend class / verify_mode=ssl.CERT_NONE / check_hostname=False / EMAIL_BACKEND override to an insecure backend"
fi

# --- Full render must succeed ----------------------------------------------
kubectl kustomize "${dir}" >/dev/null

echo "list stack validation passed: mailman-core LMTP :8024, submission 587+STARTTLS VERIFIED (substrate mail CA), lists-bounces@latoolb.us, image digests pinned, no committed secrets"
