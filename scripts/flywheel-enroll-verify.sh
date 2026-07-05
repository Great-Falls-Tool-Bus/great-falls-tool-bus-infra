#!/usr/bin/env bash
# flywheel-enroll-verify: confirm a registered RBE/image consumer against the
# three live realities GF-core CI structurally cannot see, each REUSING an
# already-built guard. Read-only. Needs: the GF-core consumer-registry
# (GF_CORE_PATH), this overlay's tfvars, the consumer checkout, and (for the
# live gate) a kubeconfig.
#
# Usage: flywheel-enroll-verify.sh [owner/repo]
#   (default: Great-Falls-Tool-Bus/great-falls-tool-bus.github.io)
#   GF_CORE_PATH    GloriousFlywheel core checkout (default ../GloriousFlywheel)
#   CONSUMER_PATH   the consumer repo checkout      (default ~/git/<repo-basename>)
set -euo pipefail

OVERLAY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GF_CORE="${GF_CORE_PATH:-$(cd "${OVERLAY_ROOT}/../GloriousFlywheel" 2>/dev/null && pwd || true)}"
ARC_TFVARS="${OVERLAY_ROOT}/tofu/stacks/arc-runners/great-falls-tool-bus.tfvars"
REPO="${1:-Great-Falls-Tool-Bus/great-falls-tool-bus.github.io}"
CONSUMER_PATH="${CONSUMER_PATH:-${HOME}/git/$(basename "${REPO}")}"
REGISTRY="${GF_CORE}/config/consumer-registry.json"

fail() { echo "VERIFY FAIL [${REPO}]: $1" >&2; exit 1; }
note() { echo "  $1"; }

[ -n "${GF_CORE}" ] && [ -f "${REGISTRY}" ] || fail "consumer-registry.json not found (set GF_CORE_PATH to the GloriousFlywheel core checkout)"

read_field() {
  python3 -c "import json;d=json.load(open('${REGISTRY}'));e=[c for c in d['consumers'] if c['github_repository']=='${REPO}'];print(e[0].get('$1','') if e else '')"
}
runner_class="$(read_field runner_class)"
anchor="$(read_field tfvars_anchor)"
workflow="$(read_field workflow)"
[ -n "${runner_class}" ] || fail "${REPO} is not in consumer-registry.json"

echo "flywheel-enroll-verify: ${REPO} (runner_class=${runner_class}, anchor=${anchor})"

# CHECK 0 — registry is internally honest (GF-core static validator).
echo "CHECK 0: registry static validity"
python3 "${GF_CORE}/scripts/validate-consumer-registry.py" --self-test >/dev/null || fail "consumer-registry self-test failed"
python3 "${GF_CORE}/scripts/validate-consumer-registry.py" >/dev/null || fail "consumer-registry validation failed"
note "ok: static validator + registry valid"

# CHECK 1 — overlay tfvars anchor exists, RBE-wired, runner_label == runner_class.
# Org-shape delta from the older personal-account overlay: GFTB registers ARC at the ORG
# scope, so a consumer's tfvars_anchor is normally the PRIMARY nix lane
# (nix_runner_scale_set_name) rather than an extra_runner_sets block. Accept
# either; the taxonomy validator runs WITHOUT --allow-repo-registration-anchor
# because repo-scoped config URLs are a contract violation in this overlay.
echo "CHECK 1: overlay tfvars anchor + RBE wiring"
python3 "${OVERLAY_ROOT}/scripts/validate-overlay-runner-taxonomy.py" "${ARC_TFVARS}" >/dev/null \
  || fail "overlay taxonomy/RBE-wiring validation failed"
if grep -qE "^[[:space:]]+${anchor}[[:space:]]*=[[:space:]]*\{" "${ARC_TFVARS}"; then
  block_label="$(awk "/^  ${anchor} = \{/{f=1} f && /runner_label/{gsub(/.*= *\"|\".*/,\"\");print;exit}" "${ARC_TFVARS}")"
elif grep -qE "^nix_runner_scale_set_name[[:space:]]*=[[:space:]]*\"${anchor}\"" "${ARC_TFVARS}"; then
  # The primary nix lane publishes the shared capability label.
  block_label="tinyland-nix"
else
  fail "tfvars_anchor '${anchor}' not found in ${ARC_TFVARS} (neither extra_runner_sets block nor primary nix lane)"
fi
[ "${block_label}" = "${runner_class}" ] \
  || fail "anchor '${anchor}' runner_label '${block_label}' != registry runner_class '${runner_class}'"
note "ok: anchor present, RBE-wired, runner_label=${block_label}"

# CHECK 2 — consumer workflow runs-on uses the shared runner_class (runs-on rule).
echo "CHECK 2: consumer workflow runs-on"
if [ -d "${CONSUMER_PATH}/.github/workflows" ] && [ -f "${CONSUMER_PATH}/${workflow}" ]; then
  bad="$(grep -hE '^[[:space:]]*runs-on:' "${CONSUMER_PATH}/${workflow}" \
    | grep -ivE "ubuntu-|macos-|windows-" \
    | grep -v "${runner_class}" \
    | grep -iE 'nix|dind|docker|self-hosted' || true)"
  [ -z "${bad}" ] || fail "consumer workflow ${workflow} has non-shared self-hosted runs-on: ${bad}"
  note "ok: ${workflow} self-hosted runs-on uses ${runner_class}"
else
  note "skip: consumer checkout/workflow not found at ${CONSUMER_PATH}/${workflow} (set CONSUMER_PATH)"
fi

# CHECK 3 — live runner managed-by=Helm, no manual drift (the enrolled:true gate).
echo "CHECK 3: live runner managed-by=Helm"
if command -v kubectl >/dev/null 2>&1 && kubectl -n arc-runners get autoscalingrunnersets >/dev/null 2>&1; then
  mb="$(kubectl -n arc-runners get autoscalingrunnerset "${anchor}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"
  [ "${mb}" = "Helm" ] || fail "live runner '${anchor}' managed-by='${mb:-<absent>}' (must be Helm — run the reconcile: delete the manual object, then just arc-apply)"
  note "ok: ${anchor} managed-by=Helm"
else
  note "skip: cluster not reachable — CHECK 3 is the live gate that earns enrolled:true"
fi

echo "flywheel-enroll-verify: PASS (file/registry checks) for ${REPO}"
