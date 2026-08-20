#!/usr/bin/env bash
# shellcheck disable=SC2016
# SC2016 is intentional throughout: `$app` inside single-quoted yq programs is
# a jq variable bound by `--arg app`, not a shell expansion — the same
# injection posture as validate-web-stack.sh.
set -euo pipefail

# DECLARE-ONLY guard for the GFTB platform staging serving stack (TIN-3815 /
# TIN-3817). Asserts the invariants so a regression that would open the public
# path, smuggle a real image or tenant id into the tree, or cross the two
# database credentials fails CI before any apply. Never contacts a cluster;
# never needs a secret.
#
# THE COMMITTED BYTES ARE SENTINELED, NOT PINNED. Unlike the legacy web stack
# (validate-web-stack.sh requires a real digest pin there), no three-entrypoint
# platform image exists until the S0-S3 app stack lands, so this stack follows
# the member-db migrator-Job template precedent: the committed Deployments MUST
# carry PLACEHOLDER-PLATFORM-IMAGE and PLACEHOLDER-GFTB-TENANT-ID, and the
# real values arrive only through the attended platform-release chain, whose
# input guards hold the image to
# ghcr.io/great-falls-tool-bus/{greatfallstoolbus.org,gftb-platform}@sha256:<64 hex>
# (pre-/post-TIN-3815-rename identities) and the tenant to a UUID. A real
# digest or UUID committed here FAILS, so nothing can bypass those guards.
#
# THE CREDENTIAL BOUNDARY IS ENFORCED HERE. web and worker consume ONLY
# gftb-member-db-runtime-dsn (DML-only gftb_app); the owner DSN
# gftb-member-db-migrator-dsn belongs to the pre-rollout migration Job
# (k8s/member-db, PR #118) and its NAME may not appear anywhere in this stack.

dir="${1:?usage: validate-platform-stack.sh <manifest-dir>}"
platform_root="$(cd "${dir}/.." && pwd)"
deploy_web="${dir}/deployment-web.yaml"
deploy_worker="${dir}/deployment-worker.yaml"
svc="${dir}/service-web.yaml"
netpol="${dir}/networkpolicy.yaml"
kustomization="${dir}/kustomization.yaml"
route_intent="${platform_root}/../../tofu/intent/great-falls-tool-bus/staging-platform-route.json"
secrets_contract="${platform_root}/secrets.contract.yaml"

image_sentinel="PLACEHOLDER-PLATFORM-IMAGE"
tenant_sentinel="PLACEHOLDER-GFTB-TENANT-ID"
runtime_dsn_secret="gftb-member-db-runtime-dsn"
migrator_dsn_secret="gftb-member-db-migrator-dsn"
stripe_secret="gftb-platform-stripe-testmode"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}
require_file() { test -f "$1" || fail "missing $1"; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: got '$1', want '$2'"; }

command -v yq >/dev/null 2>&1 || fail "yq is required"
command -v jq >/dev/null 2>&1 || fail "jq is required (JSON intent assertions)"
command -v kubectl >/dev/null 2>&1 || fail "kubectl is required for kubectl kustomize"

for f in "${deploy_web}" "${deploy_worker}" "${svc}" "${netpol}" \
  "${kustomization}" "${route_intent}" "${secrets_contract}"; do
  require_file "${f}"
done

# --- stack identity: one admitted namespace, two admitted workloads ----------
stack_ns="$(yq -r 'select(.kind == "Deployment") | .metadata.namespace' "${deploy_web}")"
case "${stack_ns}" in
members-greatfallstoolbus-org-production) ;;
*)
  fail "unknown platform stack namespace '${stack_ns}'; the only admitted GFTB platform namespace is members-greatfallstoolbus-org-production (the one k8s/member-db admits on 5432)"
  ;;
esac
assert_eq "$(yq -r 'select(.kind == "Deployment") | .metadata.name' "${deploy_web}")" "gftb-platform-web" "web Deployment name"
assert_eq "$(yq -r 'select(.kind == "Deployment") | .metadata.namespace' "${deploy_worker}")" "${stack_ns}" "worker Deployment namespace"
assert_eq "$(yq -r 'select(.kind == "Deployment") | .metadata.name' "${deploy_worker}")" "gftb-platform-worker" "worker Deployment name"

# --- the label admission contract (member-db ingress + this stack's egress) --
for manifest in "${deploy_web}" "${deploy_worker}"; do
  part_of="$(yq -r 'select(.kind == "Deployment") | .spec.template.metadata.labels["app.kubernetes.io/part-of"]' "${manifest}")"
  assert_eq "${part_of}" "gftb-platform" "pod label part-of in $(basename "${manifest}")"
done
assert_eq "$(yq -r 'select(.kind == "Deployment") | .spec.template.metadata.labels["app.kubernetes.io/component"]' "${deploy_web}")" "web" "web pod component label"
assert_eq "$(yq -r 'select(.kind == "Deployment") | .spec.template.metadata.labels["app.kubernetes.io/component"]' "${deploy_worker}")" "worker" "worker pod component label"

# --- replicas and rollout shape ARE the connection budget --------------------
# gftb_app connectionLimit is 40 (k8s/member-db cluster.yaml, PR #118); pg.Pool
# defaults to max 10 per process. web 2x10 + web surge 1x10 + worker 1x10 = 40.
assert_eq "$(yq -r 'select(.kind == "Deployment") | .spec.replicas' "${deploy_web}")" "2" "web replicas (connection budget)"
assert_eq "$(yq -r 'select(.kind == "Deployment") | .spec.replicas' "${deploy_worker}")" "1" "worker replicas (connection budget)"
assert_eq "$(yq -r 'select(.kind == "Deployment") | .spec.strategy.rollingUpdate.maxSurge' "${deploy_web}")" "1" "web maxSurge (connection budget)"
assert_eq "$(yq -r 'select(.kind == "Deployment") | .spec.strategy.rollingUpdate.maxUnavailable' "${deploy_web}")" "0" "web maxUnavailable"
assert_eq "$(yq -r 'select(.kind == "Deployment") | .spec.strategy.type' "${deploy_worker}")" "Recreate" "worker strategy (never two worker pools at once)"

# --- sentinel discipline: no real image or tenant id in the tree -------------
for pair in "gftb-platform-web:${deploy_web}" "gftb-platform-worker:${deploy_worker}"; do
  app="${pair%%:*}"
  manifest="${pair#*:}"
  image="$(yq -r --arg app "${app}" 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == $app) | .image' "${manifest}")"
  assert_eq "${image}" "${image_sentinel}" "committed image sentinel in $(basename "${manifest}")"
  tenant="$(yq -r --arg app "${app}" 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == $app) | .env[] | select(.name == "GFTB_TENANT_ID") | .value' "${manifest}")"
  assert_eq "${tenant}" "${tenant_sentinel}" "committed tenant sentinel in $(basename "${manifest}")"
done
if grep -REn "@sha256:[0-9a-f]{64}" "${dir}" >/dev/null 2>&1; then
  fail "a real image digest is committed in ${dir}; the platform image arrives only as PLATFORM_APPLY_IMAGE through the attended chain"
fi

# --- entrypoints: one image, the right process boundary per Deployment -------
assert_eq "$(yq -r --arg app "gftb-platform-web" 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == $app) | .command | join(" ")' "${deploy_web}")" "/usr/local/bin/web" "web entrypoint"
assert_eq "$(yq -r --arg app "gftb-platform-worker" 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == $app) | .command | join(" ")' "${deploy_worker}")" "/usr/local/bin/worker" "worker entrypoint"

# --- adapter-node serving shape (web only): :3000 + /health probes -----------
assert_eq "$(yq -r --arg app "gftb-platform-web" 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == $app) | .ports[] | select(.name == "http") | .containerPort' "${deploy_web}")" "3000" "web containerPort"
assert_eq "$(yq -r --arg app "gftb-platform-web" 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == $app) | .livenessProbe.httpGet.path' "${deploy_web}")" "/health" "web liveness probe path"
assert_eq "$(yq -r --arg app "gftb-platform-web" 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == $app) | .readinessProbe.httpGet.path' "${deploy_web}")" "/health" "web readiness probe path"
# The worker listens on nothing: no ports, no probes, no Service.
assert_eq "$(yq -r --arg app "gftb-platform-worker" 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == $app) | .ports // [] | length' "${deploy_worker}")" "0" "worker declares no ports"

# --- house hardening on both -------------------------------------------------
for pair in "gftb-platform-web:${deploy_web}" "gftb-platform-worker:${deploy_worker}"; do
  app="${pair%%:*}"
  manifest="${pair#*:}"
  assert_eq "$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.securityContext.runAsNonRoot' "${manifest}")" "true" "runAsNonRoot in $(basename "${manifest}")"
  assert_eq "$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.automountServiceAccountToken' "${manifest}")" "false" "automountServiceAccountToken in $(basename "${manifest}")"
  assert_eq "$(yq -r --arg app "${app}" 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == $app) | .securityContext.readOnlyRootFilesystem' "${manifest}")" "true" "readOnlyRootFilesystem in $(basename "${manifest}")"
done

# --- the TIN-3817 env contract -----------------------------------------------
# DATABASE_URL: the DML-only runtime DSN, by name, on BOTH — and the owner DSN
# name may not appear anywhere in this stack (two never-crossed Secrets).
for pair in "gftb-platform-web:${deploy_web}" "gftb-platform-worker:${deploy_worker}"; do
  app="${pair%%:*}"
  manifest="${pair#*:}"
  dsn_ref="$(yq -r --arg app "${app}" 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == $app) | .env[] | select(.name == "DATABASE_URL") | .valueFrom.secretKeyRef | "\(.name)/\(.key)"' "${manifest}")"
  assert_eq "${dsn_ref}" "${runtime_dsn_secret}/dsn" "DATABASE_URL secret reference in $(basename "${manifest}")"
done
# (Comment lines may NAME the owner DSN to document the boundary; an
# executable reference to it may not exist.)
if grep -REn "${migrator_dsn_secret}" "${dir}" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' >/dev/null; then
  fail "the owner/DDL DSN ${migrator_dsn_secret} is referenced by the serving stack; it belongs to the pre-rollout migration Job alone (k8s/member-db)"
fi
# GFTB_WORKER_ID: per-replica identity from the downward API, worker only.
assert_eq "$(yq -r --arg app "gftb-platform-worker" 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == $app) | .env[] | select(.name == "GFTB_WORKER_ID") | .valueFrom.fieldRef.fieldPath' "${deploy_worker}")" "metadata.name" "worker GFTB_WORKER_ID fieldRef (per-replica pod name)"
# STRIPE_*: every reference is an OPTIONAL secretKeyRef on the test-mode
# Secret; a committed value (or a required ref before TIN-3818 lands) fails.
for pair in "gftb-platform-web:${deploy_web}" "gftb-platform-worker:${deploy_worker}"; do
  app="${pair%%:*}"
  manifest="${pair#*:}"
  bad_stripe="$(yq -r --arg app "${app}" --arg secret "${stripe_secret}" 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == $app) | .env[] | select(.name | startswith("STRIPE_")) | select((.valueFrom.secretKeyRef.name != $secret) or (.valueFrom.secretKeyRef.optional != true)) | .name' "${manifest}")"
  [ -z "${bad_stripe}" ] || fail "STRIPE_* env in $(basename "${manifest}") must be optional secretKeyRefs on ${stripe_secret}: ${bad_stripe}"
done
if grep -REn "sk_live_|sk_test_[A-Za-z0-9]|pk_test_[A-Za-z0-9]|whsec_[A-Za-z0-9]" "${platform_root}" >/dev/null 2>&1; then
  fail "possible committed Stripe key material under ${platform_root}; names only, ever"
fi

# --- Service: ClusterIP 80 -> 3000, web only ---------------------------------
assert_eq "$(yq -r 'select(.kind == "Service") | .spec.type' "${svc}")" "ClusterIP" "Service type"
assert_eq "$(yq -r 'select(.kind == "Service") | .spec.ports[] | select(.name == "http") | .port' "${svc}")" "80" "Service port"
assert_eq "$(yq -r 'select(.kind == "Service") | .spec.ports[] | select(.name == "http") | .targetPort' "${svc}")" "http" "Service targetPort (named -> 3000)"
assert_eq "$(yq -r 'select(.kind == "Service") | .spec.selector["app.kubernetes.io/component"]' "${svc}")" "web" "Service selects the web component only"

# --- NetworkPolicy doctrine: default-deny BOTH ways + named allows -----------
assert_eq "$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "default-deny-ingress") | .metadata.name' "${netpol}")" "default-deny-ingress" "default-deny-ingress present"
assert_eq "$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "default-deny-egress") | .metadata.name' "${netpol}")" "default-deny-egress" "default-deny-egress present"
for name in default-deny-ingress default-deny-egress; do
  sel="$(yq -r --arg name "${name}" 'select(.kind == "NetworkPolicy" and .metadata.name == $name) | .spec.podSelector | length' "${netpol}")"
  assert_eq "${sel}" "0" "${name} selects every pod (empty podSelector)"
done
assert_eq "$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-cloudflared-tunnel-ingress") | .spec.ingress[].from[].namespaceSelector.matchLabels["kubernetes.io/metadata.name"]' "${netpol}")" "cloudflared" "public ingress source (cloudflared tunnel namespace)"
assert_eq "$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-cloudflared-tunnel-ingress") | .spec.ingress[].ports[].port' "${netpol}")" "3000" "public ingress port"
assert_eq "$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-cloudflared-tunnel-ingress") | .spec.podSelector.matchLabels["app.kubernetes.io/component"]' "${netpol}")" "web" "public ingress reaches the web component only"
# The database egress leg: exactly the member-db instance pods, on 5432, from
# the same three components the DB side admits (PR #118's reciprocal).
assert_eq "$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-egress-member-db") | .spec.egress[].to[].namespaceSelector.matchLabels["kubernetes.io/metadata.name"]' "${netpol}")" "members-greatfallstoolbus-org-db-production" "database egress namespace"
assert_eq "$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-egress-member-db") | .spec.egress[].to[].podSelector.matchLabels["cnpg.io/cluster"]' "${netpol}")" "gftb-member-db" "database egress instance selector"
assert_eq "$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-egress-member-db") | .spec.egress[].ports[].port' "${netpol}")" "5432" "database egress port"
assert_eq "$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-egress-member-db") | .spec.podSelector.matchExpressions[] | select(.key == "app.kubernetes.io/component") | .values | join(",")' "${netpol}")" "web,worker,migrator" "database egress covers web, worker, AND the migrator Job"
if yq -r 'select(.kind == "NetworkPolicy") | .spec.egress[]?.to[]? | select(has("ipBlock")) | .ipBlock.cidr' "${netpol}" | grep -q "0.0.0.0/0"; then
  fail "platform egress must not include 0.0.0.0/0 (Stripe egress is the TIN-3818 sitting's reviewed follow-up, not a broad allow)"
fi

# --- FAIL-CLOSED axes: no Namespace, no Secret, no key material --------------
if grep -REn "^kind:[[:space:]]*Namespace[[:space:]]*$" "${dir}" >/dev/null 2>&1; then
  fail "declare-only stack must NOT create the target namespace"
fi
if grep -REn "^kind:[[:space:]]*Secret[[:space:]]*$" "${dir}" "${secrets_contract}" >/dev/null 2>&1; then
  fail "the declare-only platform stack must not ship a Secret object"
fi
if grep -REn "AGE-SECRET-KEY-1|BEGIN [A-Z ]*PRIVATE KEY|cfat_[A-Za-z0-9_-]{8,}" "${platform_root}" >/dev/null 2>&1; then
  fail "possible committed key material under ${platform_root}; this stack carries none"
fi

# --- FAIL-CLOSED route intent: staging host, every flag false ----------------
assert_eq "$(jq -r '.applied' "${route_intent}")" "false" "staging route intent applied"
assert_eq "$(jq -r '.dns_enabled' "${route_intent}")" "false" "staging route intent dns_enabled"
assert_eq "$(jq -r '.route_enabled' "${route_intent}")" "false" "staging route intent route_enabled"
assert_eq "$(jq -r '.planned_route.dns_record.enabled' "${route_intent}")" "false" "staging route intent dns_record.enabled"
assert_eq "$(jq -r '.planned_route.hostname' "${route_intent}")" "staging.greatfallstoolbus.org" "staging route hostname (slices doc hosts row; TIN-3815)"
if jq -r '.. | strings' "${route_intent}" | grep -Eq "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.cfargotunnel\.com"; then
  fail "staging route intent must NOT inline a live <uuid>.cfargotunnel.com target (dashboard/token-managed)"
fi

# --- Full render must succeed (parse-only; never applies) --------------------
kubectl kustomize "${dir}" >/dev/null

echo "platform stack validation passed for gftb-platform-web + gftb-platform-worker in ${stack_ns}: DECLARE-ONLY (sentineled image/tenant, apply is the attended platform-release chain), web 2 replicas :3000 /health + worker 1 replica Recreate (gftb_app connectionLimit 40 budget), runtime-DSN-only credential boundary, default-deny both directions + cloudflared-only ingress + member-db-only egress, staging route fail-closed, no committed secrets"
