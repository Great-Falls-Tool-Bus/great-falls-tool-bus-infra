#!/usr/bin/env bash
set -euo pipefail

dir="${1:?usage: validate-platform-stack.sh <manifest-dir>}"
platform_root="$(cd "${dir}/.." && pwd)"
route_intent="${platform_root}/../../tofu/intent/great-falls-tool-bus/staging-platform-route.json"
secrets_contract="${platform_root}/secrets.contract.yaml"
runtime_dsn_secret="gftb-member-db-runtime-dsn"
migrator_dsn_secret="gftb-member-db-migrator-dsn"
stripe_secret="gftb-platform-stripe-testmode"
tenant_sentinel="PLACEHOLDER-GFTB-TENANT-ID"
expected_image="ghcr.io/great-falls-tool-bus/greatfallstoolbus.org@sha256:10f853938dc6823afe8c9bdc54943587f963d22117aafd17247350b2b5712b35"
stack_ns="members-greatfallstoolbus-org-production"

fail() { echo "ERROR: $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: got '$1', want '$2'"; }
require_file() { test -f "$1" || fail "missing $1"; }

command -v yq >/dev/null 2>&1 || fail "yq is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v kubectl >/dev/null 2>&1 || fail "kubectl is required for kubectl kustomize"
yq_version="$(yq --version 2>&1 || true)"
printf '%s' "${yq_version}" | grep -qi mikefarah &&
  printf '%s' "${yq_version}" | grep -Eqi 'version v?4\.' ||
  fail "mikefarah yq-go v4 is required; got: ${yq_version:-unavailable}"

for name in deployment-web.yaml deployment-worker.yaml service-web.yaml networkpolicy.yaml kustomization.yaml; do
  require_file "${dir}/${name}"
done
require_file "${route_intent}"
require_file "${secrets_contract}"

rendered_yaml="$(mktemp)"
rendered_json="$(mktemp)"
trap 'rm -f "${rendered_yaml}" "${rendered_json}"' EXIT
kubectl kustomize "${dir}" > "${rendered_yaml}"
test -s "${rendered_yaml}" || fail "kubectl kustomize produced no manifest"
yq eval-all -o=json -I=0 '.' "${rendered_yaml}" | jq --slurp '.' > "${rendered_json}"
jq -e 'type == "array" and length > 0 and all(.[]; type == "object")' "${rendered_json}" >/dev/null ||
  fail "rendered YAML did not decode into a non-empty JSON object array"

expected_inventory="$(cat <<'EOF'
Deployment/gftb-platform-web
Deployment/gftb-platform-worker
NetworkPolicy/allow-cloudflared-tunnel-ingress
NetworkPolicy/allow-egress-dns
NetworkPolicy/allow-egress-member-db
NetworkPolicy/allow-prometheus-scrape
NetworkPolicy/default-deny-egress
NetworkPolicy/default-deny-ingress
Service/gftb-platform-web
EOF
)"
actual_inventory="$(jq -r '.[] | "\(.kind)/\(.metadata.name)"' "${rendered_json}" | LC_ALL=C sort)"
assert_eq "${actual_inventory}" "${expected_inventory}" "exact rendered inventory"
bad_ns="$(jq -r --arg ns "${stack_ns}" '.[] | select((.metadata.namespace // "") != $ns) | "\(.kind)/\(.metadata.name)"' "${rendered_json}")"
[ -z "${bad_ns}" ] || fail "rendered object(s) outside ${stack_ns}: ${bad_ns}"

jq -e --arg image "${expected_image}" --arg tenant "${tenant_sentinel}" '
  def object($kind; $name):
    [.[] | select(.kind == $kind and .metadata.name == $name)] as $found
    | if ($found | length) == 1 then $found[0] else error("object identity is not exact") end;
  object("Deployment"; "gftb-platform-web") as $web
  | object("Deployment"; "gftb-platform-worker") as $worker
  | $web.spec.template.spec.containers as $wc
  | $worker.spec.template.spec.containers as $kc
  | ($wc | length) == 1 and ($kc | length) == 1
  and $wc[0].name == "gftb-platform-web"
  and $kc[0].name == "gftb-platform-worker"
  and $wc[0].image == $image and $kc[0].image == $image
  and ($wc[0] | has("command") | not) and ($wc[0] | has("args") | not)
  and ($kc[0] | has("command") | not) and $kc[0].args == ["worker"]
  and $web.spec.replicas == 2
  and $web.spec.strategy.type == "RollingUpdate"
  and $web.spec.strategy.rollingUpdate.maxUnavailable == 0
  and $web.spec.strategy.rollingUpdate.maxSurge == 1
  and $worker.spec.replicas == 1
  and $worker.spec.strategy == {"type":"Recreate"}
  and $web.spec.template.metadata.labels["app.kubernetes.io/part-of"] == "gftb-platform"
  and $worker.spec.template.metadata.labels["app.kubernetes.io/part-of"] == "gftb-platform"
  and $web.spec.template.metadata.labels["app.kubernetes.io/component"] == "web"
  and $worker.spec.template.metadata.labels["app.kubernetes.io/component"] == "worker"
  and $wc[0].ports == [{"name":"http","containerPort":3000,"protocol":"TCP"}]
  and $wc[0].livenessProbe.httpGet == {"path":"/health","port":"http"}
  and $wc[0].readinessProbe.httpGet == {"path":"/health","port":"http"}
  and (($kc[0].ports // []) | length) == 0
  and $web.spec.template.spec.automountServiceAccountToken == false
  and $worker.spec.template.spec.automountServiceAccountToken == false
  and $web.spec.template.spec.securityContext.runAsNonRoot == true
  and $worker.spec.template.spec.securityContext.runAsNonRoot == true
  and $wc[0].securityContext.readOnlyRootFilesystem == true
  and $kc[0].securityContext.readOnlyRootFilesystem == true
  and ([$wc[0].env[] | select(.name == "GFTB_TENANT_ID") | .value] == [$tenant])
  and ([$kc[0].env[] | select(.name == "GFTB_TENANT_ID") | .value] == [$tenant])
' "${rendered_json}" >/dev/null || fail "rendered Deployment image/entrypoint/tenant/strategy/replica contract mismatch"

jq -e --arg runtime "${runtime_dsn_secret}" --arg stripe "${stripe_secret}" '
  [.[] | select(.kind == "Deployment") | .spec.template.spec.containers[]] as $containers
  | ($containers | length) == 2
  and all($containers[];
    ([.env[] | select(.name == "DATABASE_URL") | .valueFrom.secretKeyRef] == [{"name":$runtime,"key":"dsn"}])
    and all(.env[] | select(.name | startswith("STRIPE_"));
      .valueFrom.secretKeyRef.name == $stripe and .valueFrom.secretKeyRef.optional == true))
  and ([.[] | select(.kind == "Deployment" and .metadata.name == "gftb-platform-worker")
        | .spec.template.spec.containers[0].env[] | select(.name == "GFTB_WORKER_ID")
        | .valueFrom.fieldRef.fieldPath] == ["metadata.name"])
' "${rendered_json}" >/dev/null || fail "runtime DSN / worker identity / optional Stripe contract mismatch"

jq -e '
  def object($kind; $name):
    [.[] | select(.kind == $kind and .metadata.name == $name)] as $found
    | if ($found | length) == 1 then $found[0] else error("object identity is not exact") end;
  object("Service"; "gftb-platform-web") as $svc
  | $svc.spec.type == "ClusterIP"
  and $svc.spec.selector["app.kubernetes.io/component"] == "web"
  and $svc.spec.ports == [{"name":"http","port":80,"protocol":"TCP","targetPort":"http"}]
' "${rendered_json}" >/dev/null || fail "rendered Service contract mismatch"

jq -e '
  def policy($name):
    [.[] | select(.kind == "NetworkPolicy" and .metadata.name == $name)] as $found
    | if ($found | length) == 1 then $found[0] else error("policy identity is not exact") end;
  (policy("default-deny-ingress").spec.podSelector == {})
  and (policy("default-deny-egress").spec.podSelector == {})
  and (policy("allow-cloudflared-tunnel-ingress").spec.podSelector.matchLabels["app.kubernetes.io/component"] == "web")
  and (policy("allow-cloudflared-tunnel-ingress").spec.ingress[0].from[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == "cloudflared")
  and (policy("allow-cloudflared-tunnel-ingress").spec.ingress[0].ports[0].port == 3000)
  and (policy("allow-egress-dns").spec.egress[0].to[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == "kube-system")
  and (policy("allow-egress-dns").spec.egress[0].to[0].podSelector.matchLabels["k8s-app"] == "kube-dns")
  and (policy("allow-egress-member-db").spec.egress[0].to[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == "members-greatfallstoolbus-org-db-production")
  and (policy("allow-egress-member-db").spec.egress[0].to[0].podSelector.matchLabels["cnpg.io/cluster"] == "gftb-member-db")
  and (policy("allow-egress-member-db").spec.egress[0].ports[0].port == 5432)
  and ([policy("allow-egress-member-db").spec.podSelector.matchExpressions[]
        | select(.key == "app.kubernetes.io/component") | .values] == [["web","worker","migrator"]])
  and ([.[] | select(.kind == "NetworkPolicy") | .spec.egress[]?.to[]?
        | select(has("ipBlock"))] | length == 0)
  and ([.[] | select(.kind == "NetworkPolicy") | .metadata.name as $name
        | .spec.egress[]? | select(((.to // []) | length) == 0) | $name] | length == 0)
' "${rendered_json}" >/dev/null || fail "NetworkPolicy contract mismatch, ipBlock present, or empty egress to"

if grep -REn "${migrator_dsn_secret}" "${dir}" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' >/dev/null; then
  fail "owner/DDL DSN is executable in serving stack"
fi
if grep -REn '^kind:[[:space:]]*(Namespace|Secret)[[:space:]]*$' "${dir}" "${secrets_contract}" >/dev/null 2>&1; then
  fail "platform carrier must create neither Namespace nor Secret"
fi
if grep -REn 'AGE-SECRET-KEY-1|BEGIN [A-Z ]*PRIVATE KEY|cfat_[A-Za-z0-9_-]{8,}|sk_live_|sk_test_[A-Za-z0-9]|pk_test_[A-Za-z0-9]|whsec_[A-Za-z0-9]' "${platform_root}" >/dev/null 2>&1; then
  fail "possible committed key material under ${platform_root}"
fi
jq -e '
  .applied == false and .dns_enabled == false and .route_enabled == false
  and .planned_route.dns_record.enabled == false
  and .planned_route.hostname == "staging.greatfallstoolbus.org"
  and ([.. | strings | select(test("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.cfargotunnel\.com"))] | length == 0)
' "${route_intent}" >/dev/null || fail "staging route intent must remain exact and fail-closed"

echo "platform stack validation passed: exact Git-owned image; web inherits OCI command/args; worker args=[worker]; tenant sole input; exact inventory/budget; runtime DSN; no egress ipBlock; route fail-closed"
