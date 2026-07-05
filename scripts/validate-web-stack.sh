#!/usr/bin/env bash
set -euo pipefail

# DECLARE-ONLY guard for the GFTB on-cluster web serving skeleton (TIN-2541).
# Asserts the FAIL-CLOSED invariants so a regression that would make the
# skeleton accidentally applyable/serving fails CI before any apply. Never
# contacts a cluster; never needs a secret.
#
# Mirrors the shape of scripts/validate-form-stack.sh, but where the form stack
# is a LIVE workload (asserts digest pins), this stack is DECLARE-ONLY and
# asserts the opposite: replicas 0, a NON-digest placeholder image, no
# Namespace, no Secret, no live tunnel route.

dir="${1:?usage: validate-web-stack.sh <manifest-dir>}"
web_root="$(cd "${dir}/.." && pwd)"
deploy="${dir}/deployment.yaml"
svc="${dir}/service.yaml"
netpol="${dir}/networkpolicy.yaml"
kustomization="${dir}/kustomization.yaml"
route_intent="${web_root}/../../tofu/intent/great-falls-tool-bus/web-oncluster-route.json"
prenv_schema="${web_root}/../../tofu/intent/great-falls-tool-bus/pr-env-lanes.schema.json"
secrets_contract="${web_root}/secrets.contract.yaml"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}
require_file() { test -f "$1" || fail "missing $1"; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: got '$1', want '$2'"; }

command -v yq >/dev/null 2>&1 || fail "yq is required"
command -v jq >/dev/null 2>&1 || fail "jq is required (JSON intent assertions)"
command -v kubectl >/dev/null 2>&1 || fail "kubectl is required for kubectl kustomize"

for f in "${deploy}" "${svc}" "${netpol}" "${kustomization}" \
  "${route_intent}" "${prenv_schema}" "${secrets_contract}"; do
  require_file "${f}"
done

# --- FAIL-CLOSED axis 1: replicas MUST be 0 ----------------------------------
replicas="$(yq -r 'select(.kind == "Deployment") | .spec.replicas' "${deploy}")"
assert_eq "${replicas}" "0" "Deployment replicas (declare-only fail-closed)"

# --- FAIL-CLOSED axis 2: image is a NON-digest PLACEHOLDER --------------------
# The opposite of the form stack: a real, resolvable, digest-pinned image in
# this tree would mean the skeleton became applyable. Forbid @sha256: digests on
# any actual `image:` line (comments explaining the guard are exempt) and require
# the explicit PLACEHOLDER marker.
while IFS= read -r line; do
  case "${line}" in
  *"@sha256:"*) fail "declare-only stack must NOT carry a digest-pinned (@sha256:) image; the real pin is an operator-gated private-overlay bump at cutover: ${line}" ;;
  esac
done < <(grep -REh "^\s*image:\s*\S+" "${dir}")
web_image="$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "greatfallstoolbus-org") | .image' "${deploy}")"
case "${web_image}" in
*PLACEHOLDER*NOT-APPLIED*) : ;;
*) fail "web image must be the declare-only PLACEHOLDER (…PLACEHOLDER-DECLARE-ONLY-NOT-APPLIED); got '${web_image}'" ;;
esac

# --- FAIL-CLOSED axis 3: this stack creates NO Namespace ---------------------
if grep -REn "^kind:\s*Namespace" "${dir}" >/dev/null 2>&1; then
  fail "declare-only stack must NOT create the target namespace"
fi

# --- adapter-node serving shape: containerPort 3000 + /health probes ---------
port="$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "greatfallstoolbus-org") | .ports[] | select(.name == "http") | .containerPort' "${deploy}")"
assert_eq "${port}" "3000" "web containerPort (adapter-node)"
live_path="$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "greatfallstoolbus-org") | .livenessProbe.httpGet.path' "${deploy}")"
ready_path="$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "greatfallstoolbus-org") | .readinessProbe.httpGet.path' "${deploy}")"
assert_eq "${live_path}" "/health" "liveness probe path"
assert_eq "${ready_path}" "/health" "readiness probe path"

# --- runAsNonRoot + hardening ------------------------------------------------
nonroot="$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.securityContext.runAsNonRoot' "${deploy}")"
assert_eq "${nonroot}" "true" "web runAsNonRoot"
rorootfs="$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "greatfallstoolbus-org") | .securityContext.readOnlyRootFilesystem' "${deploy}")"
assert_eq "${rorootfs}" "true" "web readOnlyRootFilesystem"

# --- Service: ClusterIP 80 -> 3000 -------------------------------------------
svc_type="$(yq -r 'select(.kind == "Service") | .spec.type' "${svc}")"
svc_port="$(yq -r 'select(.kind == "Service") | .spec.ports[] | select(.name == "http") | .port' "${svc}")"
svc_target="$(yq -r 'select(.kind == "Service") | .spec.ports[] | select(.name == "http") | .targetPort' "${svc}")"
assert_eq "${svc_type}" "ClusterIP" "Service type"
assert_eq "${svc_port}" "80" "Service port"
assert_eq "${svc_target}" "http" "Service targetPort (named -> 3000)"

# --- NetworkPolicy doctrine: default-deny + cloudflared-only public ingress ---
deny_present="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "default-deny-ingress") | .metadata.name' "${netpol}")"
assert_eq "${deny_present}" "default-deny-ingress" "default-deny-ingress NetworkPolicy present"
tunnel_ns="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-cloudflared-tunnel-ingress") | .spec.ingress[].from[].namespaceSelector.matchLabels["kubernetes.io/metadata.name"]' "${netpol}")"
assert_eq "${tunnel_ns}" "cloudflared" "public ingress source (cloudflared tunnel namespace)"
tunnel_port="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-cloudflared-tunnel-ingress") | .spec.ingress[].ports[].port' "${netpol}")"
assert_eq "${tunnel_port}" "3000" "public ingress port"
if yq -r 'select(.kind == "NetworkPolicy") | .spec.egress[]?.to[]? | select(has("ipBlock")) | .ipBlock.cidr' "${netpol}" | grep -q "0.0.0.0/0"; then
  fail "web egress must not include 0.0.0.0/0"
fi

# --- FAIL-CLOSED route intent: applied/dns/route all false -------------------
assert_eq "$(jq -r '.applied' "${route_intent}")" "false" "route intent applied"
assert_eq "$(jq -r '.dns_enabled' "${route_intent}")" "false" "route intent dns_enabled"
assert_eq "$(jq -r '.route_enabled' "${route_intent}")" "false" "route intent route_enabled"
assert_eq "$(jq -r '.planned_route.dns_record.enabled' "${route_intent}")" "false" "route intent dns_record.enabled"
# No live cfargotunnel UUID inlined (placeholder only).
if jq -r '.. | strings' "${route_intent}" | grep -Eq "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.cfargotunnel\.com"; then
  fail "route intent must NOT inline a live <uuid>.cfargotunnel.com target (dashboard/token-managed)"
fi

# --- FAIL-CLOSED reaper lane: enabled=false ----------------------------------
assert_eq "$(jq -r '.enabled' "${prenv_schema}")" "false" "pr-env reaper lane enabled"
assert_eq "$(jq -r '.teardown_model.leg_2_ttl_reaper_workflow.toggle_default' "${prenv_schema}")" "false" "reaper workflow toggle default"
assert_eq "$(jq -r '.teardown_model.leg_3_incluster_backstop_cronjob.suspend_default' "${prenv_schema}")" "true" "backstop CronJob suspend default"

# --- No committed secret material anywhere in the web stack ------------------
if grep -REn "kind:\s*Secret" "${dir}" "${secrets_contract}" >/dev/null 2>&1; then
  fail "the declare-only web stack must not ship a Secret object"
fi
if grep -REn "AGE-SECRET-KEY-1|BEGIN [A-Z ]*PRIVATE KEY|cfat_[A-Za-z0-9_-]{8,}" "${web_root}" >/dev/null 2>&1; then
  fail "possible committed key material under ${web_root}; this stack carries none"
fi

# --- Full render must succeed (parse-only; never applies) --------------------
kubectl kustomize "${dir}" >/dev/null

echo "web stack validation passed: DECLARE-ONLY (replicas 0, placeholder image, no namespace), adapter-node ClusterIP 80->3000 with /health probes, default-deny + cloudflared-only public ingress, route+reaper fail-closed, no committed secrets"
