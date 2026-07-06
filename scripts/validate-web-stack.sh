#!/usr/bin/env bash
set -euo pipefail

# DISPATCH-GATED declare-only guard for the GFTB on-cluster web workload
# (TIN-2543, ADR 0010). Asserts the invariants so a regression that would open
# the public path or auto-apply on merge fails CI before any apply. Never
# contacts a cluster; never needs a secret.
#
# ADR 0010 flips this stack to the executing-cutover shape: like the form stack
# it now asserts a digest-pinned image and the running replica count (2). The
# declare-only guarantee moves to the still-closed axes — NO Namespace object, NO
# Secret, and a fail-closed tunnel route + reaper intent — so merging applies
# nothing and routes no public traffic (the only apply is the dispatch-gated
# web-stack.yml).

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

# --- axis 1: replicas MUST be the ADR 0010 cutover shape (2) ------------------
# ADR 0010 §5 step 3 flips 0 -> 2. Merging still applies nothing (web-crs.yml is
# validate-only; the only apply is the dispatch-gated web-stack.yml).
replicas="$(yq -r 'select(.kind == "Deployment") | .spec.replicas' "${deploy}")"
assert_eq "${replicas}" "2" "Deployment replicas (ADR 0010 cutover shape)"

# --- axis 2: web image is a digest-pinned production reference ----------------
# ADR 0010 makes on-prem the host; the manifest carries the real digest-pinned
# image as the declarative record (web-stack.yml overrides it with the operator-
# resolved digest at dispatch). Require the org GHCR repo pinned by @sha256: and
# forbid the retired declare-only PLACEHOLDER marker.
web_image="$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "greatfallstoolbus-org") | .image' "${deploy}")"
case "${web_image}" in
*PLACEHOLDER*) fail "web image must be a real digest-pinned reference, not the retired PLACEHOLDER: '${web_image}'" ;;
esac
case "${web_image}" in
ghcr.io/great-falls-tool-bus/greatfallstoolbus.org@sha256:*) : ;;
*) fail "web image must be ghcr.io/great-falls-tool-bus/greatfallstoolbus.org pinned by @sha256:<digest>; got '${web_image}'" ;;
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

echo "web stack validation passed: DISPATCH-GATED declare-only (replicas 2, digest-pinned image, no namespace, apply is dispatch-only), adapter-node ClusterIP 80->3000 with /health probes, default-deny + cloudflared-only public ingress, route+reaper fail-closed, no committed secrets"
