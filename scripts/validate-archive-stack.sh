#!/usr/bin/env bash
set -euo pipefail

# Offline validation of the GFTB public discuss@ archive stack (TIN-2528).
# Faithful mirror of scripts/validate-form-stack.sh in approach and rigor:
# asserts the load-bearing invariants of the SECOND Anubis PoW gate
# (anubis-archive) that fronts the HyperKitty web tier, so a regression in the
# manifests fails CI before any apply. Where the archive stack differs from the
# forms stack, the assertions differ with it: the archive route is a PURE
# BROWSING surface (no form-handler tier, no LMTP, no server.py, and no
# /api/contact ALLOW carve-out), and it adds an anti-bulk-export CHALLENGE on
# HyperKitty's mbox /export/ path. Never contacts a cluster; never needs a secret.

dir="${1:?usage: validate-archive-stack.sh <manifest-dir>}"
anubis_deploy="${dir}/deployment-anubis-archive.yaml"
anubis_svc="${dir}/service-anubis-archive.yaml"
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

assert_eq() {
  if [ "$1" != "$2" ]; then
    fail "$3: got '$1', want '$2'"
  fi
}

command -v yq >/dev/null 2>&1 || fail "yq is required"
command -v kubectl >/dev/null 2>&1 || fail "kubectl is required for kubectl kustomize"
command -v jq >/dev/null 2>&1 || fail "jq is required (bot policy JSON assertions)"

for f in "${anubis_deploy}" "${anubis_svc}" "${anubis_policy_cm}" "${netpol}" \
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

anubis_image="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "anubis-archive") | .spec.template.spec.containers[] | select(.name == "anubis") | .image' "${anubis_deploy}")"
case "${anubis_image}" in
ghcr.io/techarohq/anubis:*@sha256:*) : ;;
*) fail "anubis-archive image must be ghcr.io/techarohq/anubis pinned by digest; got '${anubis_image}'" ;;
esac

# --- Anubis fronts the HyperKitty web tier (the PoW gate is not bypassable) ---
anubis_target="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "anubis-archive") | .spec.template.spec.containers[] | select(.name == "anubis") | .env[] | select(.name == "TARGET") | .value' "${anubis_deploy}")"
assert_eq "${anubis_target}" "http://mailman-web:8080" "anubis-archive TARGET (must proxy the HyperKitty web tier)"
anubis_bind="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "anubis-archive") | .spec.template.spec.containers[] | select(.name == "anubis") | .env[] | select(.name == "BIND") | .value' "${anubis_deploy}")"
assert_eq "${anubis_bind}" ":8081" "anubis-archive BIND (tunnel target port)"
anubis_svc_port="$(yq -r '.spec.ports[] | select(.name == "http") | .port' "${anubis_svc}")"
assert_eq "${anubis_svc_port}" "8081" "anubis-archive Service port (tunnel target)"

# --- Bot policy: pure browsing surface, anti-bulk-export, NO /api ALLOW -------
# v1.13.0 parses the policy as JSON, so we assert the mounted ConfigMap's JSON
# shape directly (same posture as the forms gate).
assert_eq "$(yq -r '.kind' "${anubis_policy_cm}")" "ConfigMap" "anubis policy object kind"
assert_eq "$(yq -r '.metadata.name' "${anubis_policy_cm}")" "anubis-archive-policy" "anubis policy ConfigMap name (renamed so it never collides with the forms gate)"

# Anubis must be pointed at the mounted policy (POLICY_FNAME) and mount it.
anubis_policy_fname="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "anubis-archive") | .spec.template.spec.containers[] | select(.name == "anubis") | .env[] | select(.name == "POLICY_FNAME") | .value' "${anubis_deploy}")"
assert_eq "${anubis_policy_fname}" "/etc/anubis/botPolicies.json" "anubis-archive POLICY_FNAME (mounted policy path)"
anubis_policy_vol="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "anubis-archive") | .spec.template.spec.volumes[] | select(.configMap.name == "anubis-archive-policy") | .name' "${anubis_deploy}")"
test -n "${anubis_policy_vol}" || fail "anubis-archive Deployment must mount a volume from the anubis-archive-policy ConfigMap"
anubis_policy_mount="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "anubis-archive") | .spec.template.spec.containers[] | select(.name == "anubis") | .volumeMounts[] | select(.name == "'"${anubis_policy_vol}"'") | .mountPath' "${anubis_deploy}")"
assert_eq "${anubis_policy_mount}" "/etc/anubis" "anubis-archive policy volumeMount path (must yield POLICY_FNAME)"

# The policy body must be valid JSON (v1.13.0 decodes with encoding/json).
policy_json="$(yq -r '.data["botPolicies.json"]' "${anubis_policy_cm}")"
echo "${policy_json}" | jq -e . >/dev/null 2>&1 || fail "botPolicies.json is not valid JSON (v1.13.0 parses JSON only)"

# The archive is a PURE BROWSING surface: unlike the forms gate it must carry NO
# ALLOW carve-out for /api/contact (the forms carve-out exists only because a
# cross-origin fetch() cannot solve a PoW; there is no API on this route). This
# is the archive-specific inversion of the forms script's positive ALLOW check.
api_allow_matches="$(echo "${policy_json}" | jq -r '[.bots[] | select(.action == "ALLOW" and .path_regex != null and (.path_regex as $p | "/api/contact" | test($p)))] | length')"
test "${api_allow_matches}" -eq 0 || fail "archive policy must NOT ALLOW /api/contact (the forms carve-out must not leak onto the browsing-only archive)"

# The default browser challenge must gate the browsing surface (founding row f).
challenge_present="$(echo "${policy_json}" | jq -r '[.bots[] | select(.action == "CHALLENGE" and .user_agent_regex != null and (.user_agent_regex as $u | "Mozilla/5.0" | test($u)))] | length')"
test "${challenge_present}" -ge 1 || fail "policy must keep a CHALLENGE rule for browser user agents (default browsing-surface gate)"

# Anti-bulk-export: HyperKitty's per-list gzipped-mbox export is the main abuse
# vector on an open archive. The policy must CHALLENGE the /export/*.mbox[.gz]
# path, and that CHALLENGE must be ordered BEFORE the crawler ALLOWs so even an
# allowlisted crawler must solve a PoW to bulk-export (which a headless crawler
# cannot). Rules evaluate top-to-bottom, first terminal match wins.
export_probe="/archives/list/discuss@latoolb.us/export/discuss.mbox.gz"
export_challenge_matches="$(echo "${policy_json}" | jq -r --arg p "${export_probe}" '[.bots[] | select(.action == "CHALLENGE" and .path_regex != null and (.path_regex as $r | $p | test($r)))] | length')"
test "${export_challenge_matches}" -ge 1 || fail "policy must CHALLENGE the HyperKitty mbox export path (/export/*.mbox[.gz]) to block anonymous bulk export"
export_idx="$(echo "${policy_json}" | jq -r --arg p "${export_probe}" 'first(.bots | to_entries[] | select(.value.action == "CHALLENGE" and .value.path_regex != null and (.value.path_regex as $r | $p | test($r))) | .key)')"
crawler_allow_idx="$(echo "${policy_json}" | jq -r 'first(.bots | to_entries[] | select(.value.action == "ALLOW" and .value.user_agent_regex != null) | .key)')"
test -n "${crawler_allow_idx}" || fail "policy must ALLOW at least one search-engine crawler (the discuss@ archive is intentionally indexable)"
test "${export_idx}" -lt "${crawler_allow_idx}" || fail "the mbox export CHALLENGE must be ordered before the crawler ALLOW rules (else an allowlisted crawler bypasses the export gate)"

# --- NetworkPolicy doctrine: gate not bypassable, egress least-privilege -----
# Anubis ingress is from the cloudflared tunnel namespace on 8081.
anubis_ns_src="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "anubis-archive") | .spec.ingress[].from[].namespaceSelector.matchLabels["kubernetes.io/metadata.name"]' "${netpol}")"
assert_eq "${anubis_ns_src}" "cloudflared" "anubis-archive ingress source (cloudflared tunnel namespace)"
anubis_ingress_port="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "anubis-archive") | .spec.ingress[].ports[].port' "${netpol}")"
assert_eq "${anubis_ingress_port}" "8081" "anubis-archive ingress port (PoW gate)"
# Egress to the HyperKitty web tier is the POST-DNAT pod port 8000 on the
# mailman-core pod (the mailman-web Service is 8080 -> targetPort 8000, and
# NetworkPolicy evaluates the post-DNAT destination), NOT the Service's 8080.
anubis_egress_web="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "anubis-archive") | .spec.egress[] | select(.to[].podSelector.matchLabels["app.kubernetes.io/name"] == "mailman-core") | .ports[].port' "${netpol}")"
assert_eq "${anubis_egress_web}" "8000" "anubis-archive egress target port (HyperKitty web tier, post-DNAT pod port)"
if yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "anubis-archive") | .spec.egress[].to[] | select(has("ipBlock")) | .ipBlock.cidr' "${netpol}" | grep -q "0.0.0.0/0"; then
  fail "anubis-archive egress must not include 0.0.0.0/0"
fi
# Reciprocal admission on the web tier: ONLY anubis-archive may reach it on 8000.
web_ingress_src="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "mailman-core-archive-ingress") | .spec.ingress[].from[].podSelector.matchLabels["app.kubernetes.io/name"]' "${netpol}")"
assert_eq "${web_ingress_src}" "anubis-archive" "mailman-core archive-ingress source (anubis-archive pod ONLY)"
web_ingress_port="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "mailman-core-archive-ingress") | .spec.ingress[].ports[].port' "${netpol}")"
assert_eq "${web_ingress_port}" "8000" "mailman-core archive-ingress port (HyperKitty web tier)"

# --- runAsNonRoot on the gate workload ---------------------------------------
anubis_nonroot="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "anubis-archive") | .spec.template.spec.securityContext.runAsNonRoot' "${anubis_deploy}")"
assert_eq "${anubis_nonroot}" "true" "anubis-archive runAsNonRoot"

# --- No secret material committed --------------------------------------------
if grep -REn "kind:\s*Secret" "${dir}" >/dev/null 2>&1; then
  fail "this stack must not ship a Secret (the archive gate needs no credential)"
fi
if grep -REn "^\s*(password|smtp_pass|SECRET_KEY|token)\s*:\s*['\"]?[A-Za-z0-9+/=]{8,}" "${dir}" \
  | grep -v "secretKeyRef" | grep -v "valueFrom" >/dev/null 2>&1; then
  fail "possible committed secret value under ${dir}; this stack carries none"
fi

# --- Full render must succeed AND produce exactly the declared 5 resources ----
render="$(kubectl kustomize "${dir}")"
rendered_ids="$(echo "${render}" | yq -r '[.kind, .metadata.name] | join("/")' | sort)"
expected_ids="$(printf '%s\n' \
  "ConfigMap/anubis-archive-policy" \
  "Deployment/anubis-archive" \
  "NetworkPolicy/anubis-archive" \
  "NetworkPolicy/mailman-core-archive-ingress" \
  "Service/anubis-archive" | sort)"
if [ "${rendered_ids}" != "${expected_ids}" ]; then
  echo "ERROR: rendered resource set mismatch" >&2
  echo "got:" >&2
  echo "${rendered_ids}" >&2
  echo "want:" >&2
  echo "${expected_ids}" >&2
  exit 1
fi
# Every rendered resource must land in the target namespace.
while IFS= read -r ns; do
  assert_eq "${ns}" "latoolb-us-production" "rendered resource namespace"
done < <(echo "${render}" | yq -r '.metadata.namespace')

echo "archive stack validation passed: Anubis PoW gate (CHALLENGE browsing surface + mbox /export before crawler ALLOWs, NO /api ALLOW) -> HyperKitty web tier http://mailman-web:8080 (egress pod :8000), Service :8081, digests pinned, 5 resources in latoolb-us-production, no committed secrets"
