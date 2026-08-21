#!/usr/bin/env bash
set -euo pipefail

# Offline validation of the keyholders -> discuss add-only reconciler stack
# (TIN-3813 lane). Asserts the load-bearing safety properties — add-only,
# two-lists-only, dry-run default-on, suspended, dedicated-Secret gate, narrow
# network + workload identity — so a regression fails CI before any apply.
# Never contacts a cluster; never needs a secret.

dir="${1:?usage: validate-listsync-stack.sh <manifest-dir>}"
cm_file="${dir}/configmap-listsync.yaml"
cron_file="${dir}/cronjob-listsync.yaml"
np_file="${dir}/networkpolicy.yaml"
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

require_file "${cm_file}"
require_file "${cron_file}"
require_file "${np_file}"
require_file "${kustomization_file}"

# --- Add-only program contract ----------------------------------------------
script="$(yq -r 'select(.metadata.name == "mailman-listsync-src") | .data["listsync.py"]' "${cm_file}")"
test -n "${script}" || fail "mailman-listsync-src must carry listsync.py"
echo "${script}" | grep -q 'ALLOWED_METHODS = ("GET", "POST")' \
  || fail "listsync.py must pin the HTTP method allowlist to GET/POST (add-only contract)"
if echo "${script}" | grep -qi 'delete'; then
  fail "listsync.py must contain no removal path (add-only contract)"
fi
echo "${script}" | grep -q 'SOURCE_LIST = "keyholders.latoolb.us"' \
  || fail "listsync.py must pin SOURCE_LIST to keyholders.latoolb.us"
echo "${script}" | grep -q 'TARGET_LIST = "discuss.latoolb.us"' \
  || fail "listsync.py must pin TARGET_LIST to discuss.latoolb.us"
for knob in pre_verified pre_confirmed pre_approved; do
  echo "${script}" | grep -q "\"${knob}\": \"true\"" \
    || fail "listsync.py subscribe must set ${knob}=true (no confirmation mail storms)"
done
echo "${script}" | grep -q 'def redact' \
  || fail "listsync.py must redact subscriber addresses in receipts (TIN-3813 receipt redaction)"

# --- CronJob gates -----------------------------------------------------------
assert_eq "$(field '.kind' "${cron_file}")" "CronJob" "listsync workload kind"
assert_eq "$(field '.metadata.name' "${cron_file}")" "mailman-listsync" "CronJob name"
assert_eq "$(field '.metadata.namespace' "${cron_file}")" "latoolb-us-production" "CronJob namespace"
assert_eq "$(field '.spec.concurrencyPolicy' "${cron_file}")" "Forbid" "CronJob concurrencyPolicy"
assert_eq "$(field '.spec.jobTemplate.spec.template.spec.automountServiceAccountToken' "${cron_file}")" "false" "reconciler must hold no k8s API identity (TIN-3813 narrow workload identity)"
assert_eq "$(field '.spec.jobTemplate.spec.template.spec.restartPolicy' "${cron_file}")" "Never" "Job restartPolicy (failed pods are the dead-letter surface)"
test "$(field '.spec.failedJobsHistoryLimit' "${cron_file}")" -ge 1 \
  || fail "failedJobsHistoryLimit must retain at least one failed Job (dead-letter visibility)"

# --- Operator activation ruling gate ----------------------------------------
# Committed defaults are suspended + dry-run. Relaxing either is a one-line
# edit, so — same pattern as the ARC runner-group admission ruling — it must
# travel with an explicit operator ruling recorded in operator-activation.yaml
# in the stack dir, or validation fails. No file means the safe defaults are
# mandatory. Agents do not author rulings.
activation_file="${dir}/operator-activation.yaml"
expected_suspend="true"
expected_dry_run="true"
if [ -f "${activation_file}" ]; then
  ruling="$(field '.ruling // ""' "${activation_file}")"
  echo "${ruling}" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} ' \
    || fail "operator-activation.yaml must carry a dated operator ruling (\"YYYY-MM-DD <operator>: <decision>\")"
  expected_suspend="$(field '.suspend' "${activation_file}")"
  expected_dry_run="$(field '.dry_run' "${activation_file}")"
  case "${expected_suspend}" in true | false) : ;; *) fail "operator-activation.yaml suspend must be true or false" ;; esac
  case "${expected_dry_run}" in true | false) : ;; *) fail "operator-activation.yaml dry_run must be true or false" ;; esac
fi
assert_eq "$(field '.spec.suspend' "${cron_file}")" "${expected_suspend}" "CronJob suspend must match the operator activation record (default: suspended)"
dry_run_default="$(field '.spec.jobTemplate.spec.template.spec.containers[0].env[] | select(.name == "LISTSYNC_DRY_RUN") | .value' "${cron_file}")"
assert_eq "${dry_run_default}" "${expected_dry_run}" "LISTSYNC_DRY_RUN must match the operator activation record (default: dry-run on)"
if [ "${expected_suspend}" = "true" ] && [ "${expected_dry_run}" = "false" ]; then
  fail "mutation with the schedule suspended is an incoherent activation record; enable dry-run observation before mutation"
fi

# The declared pair must be exactly keyholders -> discuss.
assert_eq "$(field '.spec.jobTemplate.spec.template.spec.containers[0].env[] | select(.name == "LISTSYNC_SOURCE_LIST") | .value' "${cron_file}")" "keyholders.latoolb.us" "declared source list"
assert_eq "$(field '.spec.jobTemplate.spec.template.spec.containers[0].env[] | select(.name == "LISTSYNC_TARGET_LIST") | .value' "${cron_file}")" "discuss.latoolb.us" "declared target list"

# --- Dedicated-Secret credential gate ---------------------------------------
secret_name="$(field '.spec.jobTemplate.spec.template.spec.containers[0].env[] | select(.name == "MAILMAN_REST_PASSWORD") | .valueFrom.secretKeyRef.name' "${cron_file}")"
assert_eq "${secret_name}" "mailman-listsync-rest" "REST credential must come from the dedicated operator-minted Secret"
secret_optional="$(field '.spec.jobTemplate.spec.template.spec.containers[0].env[] | select(.name == "MAILMAN_REST_PASSWORD") | .valueFrom.secretKeyRef.optional // "false"' "${cron_file}")"
assert_eq "${secret_optional}" "false" "the Secret gate must be required (absence keeps the reconciler down)"
# Semantic check (comments may DISCUSS mailman-app; no manifest may MOUNT it):
# every secretKeyRef in the stack must name the dedicated Secret.
referenced_secrets="$(yq -r '.. | objects | select(has("secretKeyRef")) | .secretKeyRef.name' "${cm_file}" "${cron_file}" "${np_file}" "${kustomization_file}" | sort -u)"
assert_eq "${referenced_secrets}" "mailman-listsync-rest" "the only Secret the stack may reference is the dedicated one (never the engine's mailman-app; TIN-3813 separate credential lifecycle)"
if grep -RIn 'kind: Secret' "${dir}" >/dev/null 2>&1; then
  fail "the listsync stack must not create Secrets; the operator mints mailman-listsync-rest"
fi

# --- Images pinned -----------------------------------------------------------
if grep -REn "image:\s*\S*:latest" "${dir}" >/dev/null 2>&1; then
  fail "images must be pinned to a tag/digest, not :latest"
fi
while IFS= read -r line; do
  case "${line}" in
  *"@sha256:"*) : ;;
  *) fail "image not pinned by immutable digest: ${line}" ;;
  esac
done < <(grep -REh "^\s*image:\s*\S+" "${dir}")

# --- Network narrowing -------------------------------------------------------
if grep -q "namespaceSelector: {}" "${np_file}"; then
  fail "listsync NetworkPolicies must not admit every namespace"
fi
sync_ingress_rules="$(yq -r 'select(.metadata.name == "mailman-listsync") | .spec.ingress | length' "${np_file}")"
assert_eq "${sync_ingress_rules}" "0" "reconciler pod must admit no ingress"
sync_egress_ports="$(yq -r 'select(.metadata.name == "mailman-listsync") | [.spec.egress[].ports[].port | tostring] | sort | join(",")' "${np_file}")"
assert_eq "${sync_egress_ports}" "53,53,8001" "reconciler egress must be DNS + core REST only"
core_admit_peer="$(yq -r 'select(.metadata.name == "mailman-core-listsync-ingress") | .spec.ingress[0].from[0].podSelector.matchLabels["app.kubernetes.io/name"]' "${np_file}")"
assert_eq "${core_admit_peer}" "mailman-listsync" "additive core-REST admission must be scoped to the reconciler pod"
core_admit_port="$(yq -r 'select(.metadata.name == "mailman-core-listsync-ingress") | .spec.ingress[0].ports[0].port' "${np_file}")"
assert_eq "${core_admit_port}" "8001" "additive core admission must be REST 8001 only"

# --- No secret material committed --------------------------------------------
if grep -REn "^\s*(password|smtp_pass|POSTGRES_PASSWORD|SECRET_KEY|HYPERKITTY_API_KEY|DATABASE_URL|MAILMAN_REST_PASSWORD)\s*:\s*['\"]?[A-Za-z0-9+/=]{6,}" "${dir}" \
    | grep -v "secretKeyRef" | grep -v "valueFrom" >/dev/null 2>&1; then
  fail "possible committed secret value under ${dir}; secrets must be referenced by name only"
fi

# --- Full render must succeed, and every load-bearing gate re-asserted
# against the APPLIED bytes, not the source files ----------------------------
# scripts/validate-archive-stack.sh:199 is the model. Every check above reads
# configmap-listsync.yaml / cronjob-listsync.yaml / networkpolicy.yaml
# directly — a kustomization.yaml `patches:` block can silently relax any of
# them at apply time while those checks keep passing, because they never look
# at what `kubectl kustomize` actually emits. Render once, split into one
# temp file per rendered document (yq flavors disagree on multi-document
# handling, so splitting on `---` and reusing the same single-document
# `field()` helper as above is the portable approach), and re-assert the
# properties a patch could have moved.
render_dir="$(mktemp -d)"
trap 'rm -rf "${render_dir}"' EXIT

kubectl kustomize "${dir}" > "${render_dir}/rendered.yaml"
awk -v out="${render_dir}" '
  BEGIN { n = 0; file = out "/doc0.yaml" }
  /^---$/ { n++; file = out "/doc" n ".yaml"; next }
  { print > file }
' "${render_dir}/rendered.yaml"

rendered_cronjob_file=""
rendered_cm_file=""
rendered_np_sync_file=""
for f in "${render_dir}"/doc*.yaml; do
  test -s "${f}" || continue
  case "$(field '.kind' "${f}"):$(field '.metadata.name' "${f}")" in
  "CronJob:mailman-listsync") rendered_cronjob_file="${f}" ;;
  "ConfigMap:mailman-listsync-src") rendered_cm_file="${f}" ;;
  "NetworkPolicy:mailman-listsync") rendered_np_sync_file="${f}" ;;
  esac
done
test -n "${rendered_cronjob_file}" || fail "render does not contain the mailman-listsync CronJob"
test -n "${rendered_cm_file}" || fail "render does not contain the mailman-listsync-src ConfigMap"
test -n "${rendered_np_sync_file}" || fail "render does not contain the mailman-listsync NetworkPolicy"

rendered_suspend="$(field '.spec.suspend' "${rendered_cronjob_file}")"
assert_eq "${rendered_suspend}" "${expected_suspend}" "RENDERED CronJob suspend must match the operator activation record (patches-block check)"

rendered_dry_run="$(field '.spec.jobTemplate.spec.template.spec.containers[0].env[] | select(.name == "LISTSYNC_DRY_RUN") | .value' "${rendered_cronjob_file}")"
assert_eq "${rendered_dry_run}" "${expected_dry_run}" "RENDERED LISTSYNC_DRY_RUN must match the operator activation record (patches-block check)"

rendered_secret_name="$(field '.spec.jobTemplate.spec.template.spec.containers[0].env[] | select(.name == "MAILMAN_REST_PASSWORD") | .valueFrom.secretKeyRef.name' "${rendered_cronjob_file}")"
assert_eq "${rendered_secret_name}" "mailman-listsync-rest" "RENDERED REST credential must still come from the dedicated Secret (patches-block check)"

rendered_source_list="$(field '.spec.jobTemplate.spec.template.spec.containers[0].env[] | select(.name == "LISTSYNC_SOURCE_LIST") | .value' "${rendered_cronjob_file}")"
assert_eq "${rendered_source_list}" "keyholders.latoolb.us" "RENDERED declared source list (patches-block check)"

rendered_target_list="$(field '.spec.jobTemplate.spec.template.spec.containers[0].env[] | select(.name == "LISTSYNC_TARGET_LIST") | .value' "${rendered_cronjob_file}")"
assert_eq "${rendered_target_list}" "discuss.latoolb.us" "RENDERED declared target list (patches-block check)"

rendered_egress_ports="$(field '[.spec.egress[].ports[].port | tostring] | sort | join(",")' "${rendered_np_sync_file}")"
assert_eq "${rendered_egress_ports}" "53,53,8001" "RENDERED reconciler egress must be DNS + core REST only (patches-block check)"

if field '.. | objects | select(has("ipBlock")) | .ipBlock.cidr' "${rendered_np_sync_file}" 2>/dev/null | grep -q "0.0.0.0/0"; then
  fail "RENDERED reconciler egress must not include 0.0.0.0/0 (patches-block check)"
fi

# The render's script body must be byte-identical to the source ConfigMap
# already put through the add-only content checks above — not merely "still
# contains no literal 'delete'" (that grep alone is bypassable, e.g.
# `_VERB = "DEL" + "ETE"`, per the review's LOW note). A patch that swaps in
# a different script entirely changes this hash.
rendered_script="$(field '.data["listsync.py"]' "${rendered_cm_file}")"
source_script_sha="$(printf '%s' "${script}" | sha256sum | awk '{print $1}')"
rendered_script_sha="$(printf '%s' "${rendered_script}" | sha256sum | awk '{print $1}')"
assert_eq "${rendered_script_sha}" "${source_script_sha}" "RENDERED listsync.py must be byte-identical to the source verified above (patches-block check)"

echo "listsync stack validation passed: add-only keyholders->discuss reconciler, suspended + dry-run default-on, dedicated-Secret gated, egress pinned to core REST, digests pinned, no committed secrets, RENDERED bytes re-checked against every gate above"
