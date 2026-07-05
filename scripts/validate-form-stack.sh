#!/usr/bin/env bash
set -euo pipefail

# Offline validation of the GFTB contact-intake stack (TIN-2420 Path B). Asserts
# the load-bearing invariants of the Anubis-gated LMTP intake so a regression in
# the manifests fails CI before any apply. Never contacts a cluster; never needs
# a secret.

dir="${1:?usage: validate-form-stack.sh <manifest-dir>}"
handler_deploy="${dir}/deployment-form-handler.yaml"
handler_svc="${dir}/service-form-handler.yaml"
handler_cm="${dir}/configmap-form-handler.yaml"
anubis_deploy="${dir}/deployment-anubis.yaml"
anubis_svc="${dir}/service-anubis.yaml"
anubis_policy_cm="${dir}/configmap-anubis-policy.yaml"
netpol="${dir}/networkpolicy.yaml"
kustomization="${dir}/kustomization.yaml"

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

command -v jq >/dev/null 2>&1 || fail "jq is required (bot policy JSON assertions)"

for f in "${handler_deploy}" "${handler_svc}" "${handler_cm}" \
  "${anubis_deploy}" "${anubis_svc}" "${anubis_policy_cm}" "${netpol}" \
  "${kustomization}"; do
  require_file "${f}"
done

# --- Images pinned by DIGEST (not tag, not :latest) --------------------------
if grep -REn "image:\s*\S*:latest" "${dir}" >/dev/null 2>&1; then
  fail "images must be pinned by digest, not :latest"
fi
# Every image line in this stack must carry an @sha256: digest.
while IFS= read -r line; do
  case "${line}" in
  *"@sha256:"*) : ;;
  *) fail "image not pinned by digest: ${line}" ;;
  esac
done < <(grep -REh "^\s*image:\s*\S+" "${dir}")

handler_image="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "form-handler") | .spec.template.spec.containers[] | select(.name == "form-handler") | .image' "${handler_deploy}")"
anubis_image="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "anubis") | .spec.template.spec.containers[] | select(.name == "anubis") | .image' "${anubis_deploy}")"
case "${handler_image}" in
python:3.12-alpine@sha256:*) : ;;
*) fail "form-handler image must be python:3.12-alpine pinned by digest; got '${handler_image}'" ;;
esac
case "${anubis_image}" in
ghcr.io/techarohq/anubis:*@sha256:*) : ;;
*) fail "anubis image must be ghcr.io/techarohq/anubis pinned by digest; got '${anubis_image}'" ;;
esac

# --- Anubis fronts the handler (the PoW gate is not bypassable) --------------
anubis_target="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "anubis") | .spec.template.spec.containers[] | select(.name == "anubis") | .env[] | select(.name == "TARGET") | .value' "${anubis_deploy}")"
assert_eq "${anubis_target}" "http://form-handler:8080" "Anubis TARGET (must proxy the handler)"
anubis_bind="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "anubis") | .spec.template.spec.containers[] | select(.name == "anubis") | .env[] | select(.name == "BIND") | .value' "${anubis_deploy}")"
assert_eq "${anubis_bind}" ":8081" "Anubis BIND (tunnel target port)"
anubis_svc_port="$(yq -r '.spec.ports[] | select(.name == "http") | .port' "${anubis_svc}")"
assert_eq "${anubis_svc_port}" "8081" "Anubis Service port (tunnel target)"

# --- Bot policy: JSON API route ALLOWed, browsing surface still CHALLENGEd -----
# The site's cross-origin fetch() POST to /api/contact cannot solve Anubis's
# browser PoW challenge, so the policy must ALLOW that path while keeping the
# default browser challenge for everything else (founding row f). v1.13.0 parses
# the policy as JSON, so we assert the mounted ConfigMap's JSON shape directly.
assert_eq "$(yq -r '.kind' "${anubis_policy_cm}")" "ConfigMap" "anubis policy object kind"
assert_eq "$(yq -r '.metadata.name' "${anubis_policy_cm}")" "anubis-policy" "anubis policy ConfigMap name"

# Anubis must be pointed at the mounted policy (POLICY_FNAME) and mount it.
anubis_policy_fname="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "anubis") | .spec.template.spec.containers[] | select(.name == "anubis") | .env[] | select(.name == "POLICY_FNAME") | .value' "${anubis_deploy}")"
assert_eq "${anubis_policy_fname}" "/etc/anubis/botPolicies.json" "Anubis POLICY_FNAME (mounted policy path)"
anubis_policy_vol="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "anubis") | .spec.template.spec.volumes[] | select(.configMap.name == "anubis-policy") | .name' "${anubis_deploy}")"
test -n "${anubis_policy_vol}" || fail "Anubis Deployment must mount a volume from the anubis-policy ConfigMap"
anubis_policy_mount="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "anubis") | .spec.template.spec.containers[] | select(.name == "anubis") | .volumeMounts[] | select(.name == "'"${anubis_policy_vol}"'") | .mountPath' "${anubis_deploy}")"
assert_eq "${anubis_policy_mount}" "/etc/anubis" "Anubis policy volumeMount path (must yield POLICY_FNAME)"

# The policy body must be valid JSON (v1.13.0 decodes with encoding/json).
policy_json="$(yq -r '.data["botPolicies.json"]' "${anubis_policy_cm}")"
echo "${policy_json}" | jq -e . >/dev/null 2>&1 || fail "botPolicies.json is not valid JSON (v1.13.0 parses JSON only)"

# There must be an ALLOW rule that matches POST /api/contact. Assert against the
# real regex, not just its presence, so a typo in the pattern fails CI. The
# regex is bound to $p first because test()'s input becomes the probe string.
allow_matches="$(echo "${policy_json}" | jq -r '[.bots[] | select(.action == "ALLOW" and .path_regex != null and (.path_regex as $p | "/api/contact" | test($p)))] | length')"
test "${allow_matches}" -ge 1 || fail "policy must ALLOW /api/contact (a path_regex ALLOW rule that matches the endpoint)"

# The default browser challenge must remain intact (row f: browsing surface gated).
challenge_present="$(echo "${policy_json}" | jq -r '[.bots[] | select(.action == "CHALLENGE" and .user_agent_regex != null and (.user_agent_regex as $u | "Mozilla/5.0" | test($u)))] | length')"
test "${challenge_present}" -ge 1 || fail "policy must keep a CHALLENGE rule for browser user agents (default browsing-surface gate)"

# Order matters: the /api/contact ALLOW must precede the browser CHALLENGE so a
# real browser's fetch (Mozilla UA) hits ALLOW first, not the challenge.
allow_idx="$(echo "${policy_json}" | jq -r 'first(.bots | to_entries[] | select(.value.action == "ALLOW" and .value.path_regex != null and (.value.path_regex as $p | "/api/contact" | test($p))) | .key)')"
challenge_idx="$(echo "${policy_json}" | jq -r 'first(.bots | to_entries[] | select(.value.action == "CHALLENGE" and .value.user_agent_regex != null and (.value.user_agent_regex as $u | "Mozilla/5.0" | test($u))) | .key)')"
test "${allow_idx}" -lt "${challenge_idx}" || fail "the /api/contact ALLOW rule must be ordered before the browser CHALLENGE rule"

# --- LMTP target (contract: keyholders list, port 8024) ----------------------
lmtp_host="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "form-handler") | .spec.template.spec.containers[] | select(.name == "form-handler") | .env[] | select(.name == "LMTP_HOST") | .value' "${handler_deploy}")"
lmtp_port="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "form-handler") | .spec.template.spec.containers[] | select(.name == "form-handler") | .env[] | select(.name == "LMTP_PORT") | .value' "${handler_deploy}")"
assert_eq "${lmtp_host}" "mailman-core.latoolb-us-production.svc.cluster.local" "handler LMTP host (list-engine listener)"
assert_eq "${lmtp_port}" "8024" "handler LMTP port (contract listener)"
mail_to="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "form-handler") | .spec.template.spec.containers[] | select(.name == "form-handler") | .env[] | select(.name == "FORM_MAIL_TO") | .value' "${handler_deploy}")"
assert_eq "${mail_to}" "keyholders@latoolb.us" "handler delivery target (keyholders list)"
mail_from="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "form-handler") | .spec.template.spec.containers[] | select(.name == "form-handler") | .env[] | select(.name == "FORM_MAIL_FROM") | .value' "${handler_deploy}")"
assert_eq "${mail_from}" "form-intake@latoolb.us" "handler From identity (DMARC-safe, latoolb.us aligned)"

# --- CORS locked to the static site origin (asserted in BOTH env and code) ---
cors_env="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "form-handler") | .spec.template.spec.containers[] | select(.name == "form-handler") | .env[] | select(.name == "FORM_ALLOWED_ORIGIN") | .value' "${handler_deploy}")"
assert_eq "${cors_env}" "https://greatfallstoolbus.org" "CORS allowed origin (static site only)"
server_src="$(yq -r '.data["server.py"]' "${handler_cm}")"
echo "${server_src}" | grep -q "https://greatfallstoolbus.org" || fail "server.py must default the CORS origin to https://greatfallstoolbus.org"
echo "${server_src}" | grep -q "Access-Control-Allow-Origin" || fail "server.py must emit CORS Access-Control-Allow-Origin"
echo "${server_src}" | grep -q "do_OPTIONS" || fail "server.py must handle the CORS preflight (OPTIONS)"

# --- Honeypot + rate limit + LMTP present in the handler code ----------------
echo "${server_src}" | grep -q "website" || fail "server.py must read the 'website' honeypot field"
echo "${server_src}" | grep -q "honeypot" || fail "server.py must implement the honeypot path"
echo "${server_src}" | grep -q "TokenBucket" || fail "server.py must implement the per-client token bucket"
echo "${server_src}" | grep -q "smtplib.LMTP" || fail "server.py must deliver via smtplib.LMTP (no SMTP credential)"
echo "${server_src}" | grep -q "/healthz" || fail "server.py must serve GET /healthz for probes"
echo "${server_src}" | grep -q "X-GFTB-Form" || fail "server.py must set the X-GFTB-Form header"
# The handler must NOT open an SMTP submission with credentials.
if echo "${server_src}" | grep -Eq "smtplib\.SMTP\b|\.login\("; then
  fail "server.py must inject via LMTP, not authenticated SMTP submission"
fi

# --- The handler must byte-compile (catch a syntax slip before apply) --------
tmp_src="$(mktemp -t gftb-form-server.XXXXXX.py)"
trap 'rm -f "${tmp_src}"' EXIT
yq -r '.data["server.py"]' "${handler_cm}" >"${tmp_src}"
python3 -m py_compile "${tmp_src}" || fail "server.py does not byte-compile"

# --- NetworkPolicy doctrine: gate not bypassable, egress least-privilege -----
# Handler ingress is ONLY from the anubis pod.
handler_ingress_from="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "form-handler") | .spec.ingress[].from[].podSelector.matchLabels["app.kubernetes.io/name"]' "${netpol}")"
assert_eq "${handler_ingress_from}" "anubis" "form-handler ingress source (anubis pod ONLY)"
# Handler egress must reach mailman-core on 8024 and must NOT egress to the world.
handler_egress_lmtp="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "form-handler") | .spec.egress[] | select(.to[].podSelector.matchLabels["app.kubernetes.io/name"] == "mailman-core") | .ports[].port' "${netpol}")"
assert_eq "${handler_egress_lmtp}" "8024" "form-handler egress LMTP target port"
if yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "form-handler") | .spec.egress[].to[] | select(has("ipBlock")) | .ipBlock.cidr' "${netpol}" | grep -q "0.0.0.0/0"; then
  fail "form-handler egress must not include 0.0.0.0/0"
fi
# Anubis ingress is from the cloudflared tunnel namespace on 8081.
anubis_ns_src="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "anubis") | .spec.ingress[].from[].namespaceSelector.matchLabels["kubernetes.io/metadata.name"]' "${netpol}")"
assert_eq "${anubis_ns_src}" "cloudflared" "anubis ingress source (cloudflared tunnel namespace)"
anubis_ingress_port="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "anubis") | .spec.ingress[].ports[].port' "${netpol}")"
assert_eq "${anubis_ingress_port}" "8081" "anubis ingress port (PoW gate)"
# Anubis egress is ONLY to the handler on 8080.
anubis_egress_handler="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "anubis") | .spec.egress[] | select(.to[].podSelector.matchLabels["app.kubernetes.io/name"] == "form-handler") | .ports[].port' "${netpol}")"
assert_eq "${anubis_egress_handler}" "8080" "anubis egress target port (handler)"

# --- runAsNonRoot on both workloads -----------------------------------------
handler_nonroot="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "form-handler") | .spec.template.spec.securityContext.runAsNonRoot' "${handler_deploy}")"
anubis_nonroot="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "anubis") | .spec.template.spec.securityContext.runAsNonRoot' "${anubis_deploy}")"
assert_eq "${handler_nonroot}" "true" "form-handler runAsNonRoot"
assert_eq "${anubis_nonroot}" "true" "anubis runAsNonRoot"

# --- No secret material committed --------------------------------------------
if grep -REn "kind:\s*Secret" "${dir}" >/dev/null 2>&1; then
  fail "this stack must not ship a Secret (LMTP injection needs no credential)"
fi
if grep -REn "^\s*(password|smtp_pass|SECRET_KEY|token)\s*:\s*['\"]?[A-Za-z0-9+/=]{8,}" "${dir}" \
  | grep -v "secretKeyRef" | grep -v "valueFrom" >/dev/null 2>&1; then
  fail "possible committed secret value under ${dir}; this stack carries none"
fi

# --- Full render must succeed ------------------------------------------------
kubectl kustomize "${dir}" >/dev/null

echo "form stack validation passed: Anubis PoW gate (ALLOW /api/contact, CHALLENGE browsing surface) -> form-handler -> LMTP :8024 keyholders@latoolb.us, CORS greatfallstoolbus.org only, digests pinned, no committed secrets"
