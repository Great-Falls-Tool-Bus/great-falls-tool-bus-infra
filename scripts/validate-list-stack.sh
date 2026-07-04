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

# --- Storage class must be explicit -----------------------------------------
# Honey has no default StorageClass. A missing storageClassName passed offline
# validation once but left all Mailman pods Pending after apply.
for pvc in mailman-postgres-data mailman-core-data mailman-web-data; do
  sc="$(yq -r "select(.metadata.name == \"${pvc}\") | .spec.storageClassName // \"\"" "${pvcs_file}")"
  assert_eq "${sc}" "local-path-retain" "${pvc} storageClassName"
done

# --- Core first-start memory floor ------------------------------------------
# Mailman core OOMKilled under a 768Mi cap before opening LMTP/REST on the
# first live bring-up. Keep a conservative floor in CI unless the image changes
# and a lower cap is proven.
core_memory_limit="$(yq -r 'select(.metadata.name == "mailman-core") | .spec.template.spec.containers[] | select(.name == "mailman-core") | .resources.limits.memory' "${dir}/deployment-mailman-core.yaml")"
assert_eq "${core_memory_limit}" "2Gi" "mailman-core memory limit"

# --- Web HTTP socket ---------------------------------------------------------
# docker-mailman mailman-web:0.5 listens for HTTP on uwsgi.ini's http-socket
# 8000. Port 8080 is not HTTP and returns EOF to probes.
web_http_port="$(yq -r 'select(.metadata.name == "mailman-web") | .spec.template.spec.containers[] | select(.name == "mailman-web") | .ports[] | select(.name == "http") | .containerPort' "${dir}/deployment-mailman-web.yaml")"
web_np_port="$(yq -r 'select(.metadata.name == "mailman-web") | .spec.ingress[].ports[] | select(.protocol == "TCP") | .port' "${dir}/networkpolicy.yaml")"
assert_eq "${web_http_port}" "8000" "mailman-web HTTP container port"
assert_eq "${web_np_port}" "8000" "mailman-web NetworkPolicy HTTP port"

# --- Full render must succeed ----------------------------------------------
kubectl kustomize "${dir}" >/dev/null

echo "list stack validation passed: mailman-core LMTP :8024, submission 587+STARTTLS, lists-bounces@latoolb.us, no committed secrets"
