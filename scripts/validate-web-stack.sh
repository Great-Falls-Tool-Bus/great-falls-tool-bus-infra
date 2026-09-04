#!/usr/bin/env bash
set -euo pipefail

# yq NOTE: hosted validation is standardized on mikefarah yq-go v4
# in both this repository and GF-core. Container selection binds through
# the exported app variable plus strenv(app); the version preflight below
# rejects kislyuk/python-yq before any predicate can be skipped.

# Declaration validator for the GFTB on-cluster web workload (TIN-2543,
# ADR 0010; posture updated by TIN-3899). Asserts the invariants so a
# regression that would change the declared production shape fails CI. Never
# contacts a cluster and never needs a secret.
#
# ADR 0010 flips this stack to the executing-cutover shape: like the form stack
# it now asserts a digest-pinned image and the running replica count (2). The
# declaration contains NO Namespace object and NO Secret. Edge routing is live
# state owned by the edge stack, not a parked placeholder in this tree.
#
# TIN-3899 retired the dispatch carrier and this change removes its dead manual
# adapter-node tail. The separate web-release-* transaction is the only current
# mutation path and remains attended until the shared v4 owner-overlay path
# proves a complete takeover.
#
# Image admission is bound to the target namespace. The production namespace
# admits only the gftb-site repository, and an unknown namespace fails closed.

dir="${1:?usage: validate-web-stack.sh <manifest-dir>}"
deploy="${dir}/deployment.yaml"
svc="${dir}/service.yaml"
netpol="${dir}/networkpolicy.yaml"
kustomization="${dir}/kustomization.yaml"
rbac="${dir}/web-apply-rbac.yaml"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}
require_file() { test -f "$1" || fail "missing $1"; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: got '$1', want '$2'"; }

command -v yq >/dev/null 2>&1 || fail "yq is required"
yq_version="$(yq --version 2>&1 || true)"
if ! printf "%s" "${yq_version}" | grep -qi "mikefarah" || ! printf "%s" "${yq_version}" | grep -Eqi "version v?4\."; then fail "mikefarah yq-go v4 is required; got: ${yq_version:-unavailable}"; fi
command -v jq >/dev/null 2>&1 || fail "jq is required (JSON shape assertions)"
command -v kubectl >/dev/null 2>&1 || fail "kubectl is required for kubectl kustomize"

for f in "${deploy}" "${svc}" "${netpol}" "${kustomization}" "${rbac}"; do
  require_file "${f}"
done

# --- stack identity: namespace -> admitted workload + admitted image repo -----
# Every per-container assertion below binds to "${app}", and the image admission
# binds to "${admitted_image_repo}", so a stack can neither rename its container
# out from under the probe/hardening checks nor borrow another stack's registry
# admission.
stack_ns="$(yq -r 'select(.kind == "Deployment") | .metadata.namespace' "${deploy}")"
case "${stack_ns}" in
greatfallstoolbus-org-production)
  app="greatfallstoolbus-org"
  admitted_image_repo="ghcr.io/great-falls-tool-bus/gftb-site"
  ;;
*)
  fail "unknown web stack namespace '${stack_ns}'; the only admitted GFTB web stack is greatfallstoolbus-org-production"
  ;;
esac
export app
deploy_name="$(yq -r 'select(.kind == "Deployment") | .metadata.name' "${deploy}")"
assert_eq "${deploy_name}" "${app}" "Deployment name admitted in namespace ${stack_ns}"

# --- axis 1: replicas MUST be the ADR 0010 cutover shape (2) ------------------
# ADR 0010 §5 step 3 flips 0 -> 2. Merging this declaration does not apply it.
replicas="$(yq -r 'select(.kind == "Deployment") | .spec.replicas' "${deploy}")"
assert_eq "${replicas}" "2" "Deployment replicas (ADR 0010 cutover shape)"

# --- axis 2: web image is a digest-pinned production reference ----------------
# ADR 0010 makes on-prem the host; the manifest carries the real digest-pinned
# image as the declarative record of what is actually served (updated by an
# operator at each web-release-* ceremony's pin step, not auto-reconciled).
# Require THIS STACK's admitted GHCR repository pinned by a full 64-hex
# @sha256: digest, and forbid the retired declare-only PLACEHOLDER marker.
# Nothing else passes: no tag, no truncated or uppercase digest, no other
# registry/owner/repository, and no sibling stack's repository.
web_image="$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == strenv(app)) | .image' "${deploy}")"
case "${web_image}" in
*PLACEHOLDER*) fail "web image must be a real digest-pinned reference, not the retired PLACEHOLDER: '${web_image}'" ;;
esac
if [[ ! "${web_image}" =~ ^"${admitted_image_repo}"@sha256:[0-9a-f]{64}$ ]]; then
  fail "web image in ${stack_ns} must be ${admitted_image_repo} pinned by @sha256:<64 lowercase hex>; got '${web_image}'"
fi

# --- FAIL-CLOSED axis 3: this stack creates NO Namespace ---------------------
if grep -REn "^kind:\s*Namespace" "${dir}" >/dev/null 2>&1; then
  fail "declare-only stack must NOT create the target namespace"
fi

# --- tracked authority source: exact, namespace-scoped, never self-applied -----
# These are desired source bytes, not a claim about live equality. A protected
# read-only live census remains mandatory before the permanent carrier may
# issue its one-use credential. The workload kustomization has an exact finite
# surface and cannot bootstrap or widen this Role.
kustomization_json="$(yq eval -o=json -I=0 '.' "${kustomization}")"
jq -e '
  (. | keys | sort) == ["apiVersion","kind","labels","namespace","resources"]
  and .resources == ["deployment.yaml","service.yaml","networkpolicy.yaml"]
' <<<"${kustomization_json}" >/dev/null ||
  fail "workload kustomization must remain the exact three-file surface with no patches, generators, or components"

rbac_docs_json="$(yq eval-all -o=json -I=0 '.' "${rbac}")"
jq --slurp -e '
  length == 3
  and ([.[] | .kind] | sort) == ["Role","RoleBinding","ServiceAccount"]
  and (([.[] | select(.kind == "ServiceAccount")] | length) == 1)
  and (([.[] | select(.kind == "Role")] | length) == 1)
  and (([.[] | select(.kind == "RoleBinding")] | length) == 1)
  and ((.[] | select(.kind == "ServiceAccount")) == {
    "apiVersion":"v1",
    "kind":"ServiceAccount",
    "metadata":{
      "name":"web-apply",
      "namespace":"greatfallstoolbus-org-production",
      "labels":{
        "app.kubernetes.io/managed-by":"great-falls-tool-bus-infra",
        "app.kubernetes.io/part-of":"great-falls-tool-bus"
      }
    },
    "automountServiceAccountToken":false
  })
  and ((.[] | select(.kind == "Role")) == {
    "apiVersion":"rbac.authorization.k8s.io/v1",
    "kind":"Role",
    "metadata":{
      "name":"web-apply",
      "namespace":"greatfallstoolbus-org-production",
      "labels":{
        "app.kubernetes.io/managed-by":"great-falls-tool-bus-infra",
        "app.kubernetes.io/part-of":"great-falls-tool-bus"
      }
    },
    "rules":[
      {"apiGroups":["apps"],"resources":["deployments"],"resourceNames":["greatfallstoolbus-org"],"verbs":["get","update","patch"]},
      {"apiGroups":["apps"],"resources":["deployments"],"verbs":["list","watch","create"]},
      {"apiGroups":["apps"],"resources":["replicasets"],"verbs":["list"]},
      {"apiGroups":[""],"resources":["pods"],"verbs":["list"]},
      {"apiGroups":[""],"resources":["services"],"resourceNames":["greatfallstoolbus-org"],"verbs":["get","update","patch"]},
      {"apiGroups":[""],"resources":["services"],"verbs":["create"]},
      {"apiGroups":["networking.k8s.io"],"resources":["networkpolicies"],"resourceNames":["default-deny-ingress","allow-cloudflared-tunnel-ingress","allow-prometheus-scrape","default-deny-egress"],"verbs":["get","update","patch"]},
      {"apiGroups":["networking.k8s.io"],"resources":["networkpolicies"],"verbs":["list","create"]},
      {"apiGroups":["discovery.k8s.io"],"resources":["endpointslices"],"verbs":["list"]}
    ]
  })
  and ((.[] | select(.kind == "RoleBinding")) == {
    "apiVersion":"rbac.authorization.k8s.io/v1",
    "kind":"RoleBinding",
    "metadata":{
      "name":"web-apply",
      "namespace":"greatfallstoolbus-org-production",
      "labels":{
        "app.kubernetes.io/managed-by":"great-falls-tool-bus-infra",
        "app.kubernetes.io/part-of":"great-falls-tool-bus"
      }
    },
    "roleRef":{"apiGroup":"rbac.authorization.k8s.io","kind":"Role","name":"web-apply"},
    "subjects":[{"kind":"ServiceAccount","name":"web-apply","namespace":"greatfallstoolbus-org-production"}]
  })
' <<<"${rbac_docs_json}" >/dev/null ||
  fail "web-apply RBAC must be exactly one closed ServiceAccount/Role/RoleBinding document set"

# --- gftb-site serving shape: containerPort 3000 + /health probes -----------
port="$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == strenv(app)) | .ports[] | select(.name == "http") | .containerPort' "${deploy}")"
assert_eq "${port}" "3000" "web containerPort (gftb-site static Caddy origin)"
live_path="$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == strenv(app)) | .livenessProbe.httpGet.path' "${deploy}")"
ready_path="$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == strenv(app)) | .readinessProbe.httpGet.path' "${deploy}")"
assert_eq "${live_path}" "/health" "liveness probe path"
assert_eq "${ready_path}" "/health" "readiness probe path"

# --- runAsNonRoot + hardening ------------------------------------------------
nonroot="$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.securityContext.runAsNonRoot' "${deploy}")"
assert_eq "${nonroot}" "true" "web runAsNonRoot"
rorootfs="$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == strenv(app)) | .securityContext.readOnlyRootFilesystem' "${deploy}")"
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
# default-deny-egress is COMMITTED tree truth since TIN-4254 (W13): the static
# origin gets no egress at all, so the policy must be present with an empty
# egress rule list, exactly as the release ceremony has always applied it.
egress_deny_json="$(yq eval -o=json -I=0 'select(.kind == "NetworkPolicy" and .metadata.name == "default-deny-egress")' "${netpol}")"
jq -e '
  .metadata.namespace == "greatfallstoolbus-org-production"
  and .spec.policyTypes == ["Egress"]
  and .spec.egress == []
  and .spec.podSelector == {"matchLabels":{"app.kubernetes.io/name":"greatfallstoolbus-org","app.kubernetes.io/component":"web"}}
' <<<"${egress_deny_json}" >/dev/null ||
  fail "default-deny-egress NetworkPolicy must be committed with policyTypes [Egress] and an empty egress rule list"

# --- No committed secret material anywhere in the web stack ------------------
if grep -REn "kind:\s*Secret" "${dir}" >/dev/null 2>&1; then
  fail "the declare-only web stack must not ship a Secret object"
fi
if grep -REn "AGE-SECRET-KEY-1|BEGIN [A-Z ]*PRIVATE KEY|cfat_[A-Za-z0-9_-]{8,}" "${dir}" >/dev/null 2>&1; then
  fail "possible committed key material under ${web_root}; this stack carries none"
fi

# --- Full render must succeed (parse-only; never applies) --------------------
# guard-no-remote-kustomize-resources.sh (round 4, adversarial review PR #127
# comments 5380010266 + 5380172269): kubectl kustomize fetches remote
# references over the network with no flag required, in more forms and more
# fields than a denylist can enumerate -- it is an ALLOWLIST (see the script
# header): every reference-carrying field is accepted only if it resolves to
# a real, contained local path. Refuse before this render, and before
# web-stack-render's own separate render, ever runs.
bash scripts/guard-no-remote-kustomize-resources.sh "${dir}"
rendered_json_stream="$(kubectl kustomize "${dir}" | yq eval-all -o=json -I=0 '.' -)"
jq --slurp -e '
  length == 6
  and ([.[] | "\(.kind)/\(.metadata.name)"] | sort) == [
    "Deployment/greatfallstoolbus-org",
    "NetworkPolicy/allow-cloudflared-tunnel-ingress",
    "NetworkPolicy/allow-prometheus-scrape",
    "NetworkPolicy/default-deny-egress",
    "NetworkPolicy/default-deny-ingress",
    "Service/greatfallstoolbus-org"
  ]
  and ([.[] | select(
    .kind == "ServiceAccount"
    or .kind == "Role"
    or .kind == "RoleBinding"
    or .kind == "ClusterRole"
    or .kind == "ClusterRoleBinding"
  )] | length) == 0
' <<<"${rendered_json_stream}" >/dev/null ||
  fail "workload render must contain exactly Deployment/Service/four NetworkPolicies and no RBAC authority"

echo "web stack validation passed for ${app} in ${stack_ns}: declaration-only (replicas 2, image pinned to ${admitted_image_repo}@sha256:<64 hex>, no namespace, tracked exact web-apply RBAC excluded from workload kustomization, no workflow mutation path), gftb-site static-origin ClusterIP 80->3000 with /health probes, default-deny ingress + committed default-deny-egress (empty egress) + cloudflared-only public ingress, no committed secrets"
