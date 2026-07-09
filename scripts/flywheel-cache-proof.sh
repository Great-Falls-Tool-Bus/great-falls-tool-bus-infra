#!/usr/bin/env bash
# flywheel-cache-proof: org-tenancy cache-backed Bazel soak lane driver.
#
# Declare-only wiring for the GloriousFlywheel L5 org-mint activation
# (TIN-2364). This is INERT until the operator (a) flips
# runtime_grants_enabled:true for this org tenant in
# tinyland-inc/GloriousFlywheel config/org-tenant-registry.json and (b) rolls the
# gf-reapi cell + token-exchange onto the org-grammar image. Before that, the
# driver logs a loud pre-activation notice and exits 0; it MUST NOT hard-fail the
# repo's CI (the workflow job is additionally continue-on-error).
#
# Endpoint authority is fleet-runtime env, NEVER baked here or in workflow YAML:
#   BAZEL_REMOTE_CACHE                 shared Bazel cache (nix-setup exports it
#                                      from cluster DNS on the tinyland-nix runner)
#   GF_REAPI_TOKEN_EXCHANGE_ENDPOINT   hosted gf-reapi-token-exchange URL
#
# Flow (all steps best-effort, fail-soft):
#   1. Exchange the GitHub Actions OIDC identity for a gf-reapi-cell profile via
#      the fleet-packaged flywheel-github-oidc-profile front door (cache-read).
#   2. Source the minted profile. Its BAZEL_REMOTE_INSTANCE_NAME is the tenant
#      the exchange actually authorized: org-<owner> once grants are live, the
#      read-only default before. Routing what the token authorizes keeps the
#      cell from rejecting the request pre-activation.
#   3. Run a cache-backed, READ-ONLY (no upload) Bazel build of the hermetic
#      proof genrule under bazel/flywheel-proof/, routed to that instance. The
#      cache round-trip under the org instance is what the operator observes.

set -uo pipefail

EXPECTED_INSTANCE="${GFW_EXPECTED_INSTANCE_NAME:?set GFW_EXPECTED_INSTANCE_NAME to org-<owner>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROOF_DIR="${REPO_ROOT}/bazel/flywheel-proof"
WRAPPER="${REPO_ROOT}/scripts/gloriousflywheel-bazel.sh"
TARGET="${GFW_PROOF_TARGET:-//:cache_proof}"

note() { echo "::notice::flywheel-cache-proof: $*"; echo "flywheel-cache-proof: $*"; }
warn() { echo "::warning::flywheel-cache-proof: $*"; echo "flywheel-cache-proof: $*"; }

# Cache-read only for the pilot: PR and soak lanes never write the shared cache.
export GF_BAZEL_SUBSTRATE_MODE="${GF_BAZEL_SUBSTRATE_MODE:-shared-cache-backed}"
export GF_BAZEL_REMOTE_UPLOAD=false
export BAZEL_REMOTE_EXECUTOR=""
# Intended org instance. The exchange profile, when produced, overrides this
# with the instance the token authorized (org-<owner> once grants are live).
export BAZEL_REMOTE_INSTANCE_NAME="${EXPECTED_INSTANCE}"

note "declare-only org-tenancy soak lane (TIN-2364); intended instance=${EXPECTED_INSTANCE}"

if ! command -v bazelisk >/dev/null 2>&1 && ! command -v bazel >/dev/null 2>&1; then
  warn "bazelisk/bazel not on PATH (run inside 'nix develop .'). Inert pre-activation; exiting 0."
  exit 0
fi

# --- Step 1 + 2: best-effort GitHub OIDC token exchange ---------------------
if [[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" && -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
  if command -v flywheel-github-oidc-profile >/dev/null 2>&1 && [[ -n "${GF_REAPI_TOKEN_EXCHANGE_ENDPOINT:-}" ]]; then
    tokdir="$(mktemp -d)"
    profile="${tokdir}/gf-reapi-cell-profile.env"
    summary="${tokdir}/token-exchange-summary.json"
    if flywheel-github-oidc-profile \
      --request cache-read \
      --frontdoor-endpoint "${BAZEL_REMOTE_CACHE:-}" \
      --profile-out "${profile}" \
      --summary-out "${summary}" >/dev/null 2>&1; then
      set -a
      # shellcheck disable=SC1090
      source "${profile}"
      set +a
      minted_instance="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("instance_name",""))' "${summary}" 2>/dev/null || true)"
      minted_tenant="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("tenant",""))' "${summary}" 2>/dev/null || true)"
      note "exchange authorized tenant=${minted_tenant:-<none>} instance=${minted_instance:-<none>}"
      if [[ "${BAZEL_REMOTE_INSTANCE_NAME:-}" == "${EXPECTED_INSTANCE}" ]]; then
        note "ACTIVATED: exchange authorized ${EXPECTED_INSTANCE}; routing the org tenant."
      else
        warn "PRE-ACTIVATION: exchange authorized instance='${BAZEL_REMOTE_INSTANCE_NAME:-<none>}', not ${EXPECTED_INSTANCE}. runtime_grants_enabled is still off for this repo; the org tenant is inert. Routing the minted default so the round-trip stays cell-consistent."
      fi
    else
      warn "token exchange call failed (front door not rolled yet?). Inert; continuing without a minted profile."
    fi
  else
    warn "fleet token-exchange front door unavailable (flywheel-github-oidc-profile absent or GF_REAPI_TOKEN_EXCHANGE_ENDPOINT unset). Inert pre-activation."
  fi
else
  note "no GitHub Actions OIDC environment (local/dev run); skipping token exchange."
fi

# --- Step 3: cache-backed, read-only proof build ----------------------------
if [[ -z "${BAZEL_REMOTE_CACHE:-}" ]]; then
  warn "BAZEL_REMOTE_CACHE is unset (the fleet nix-setup exports it on-cluster). Nothing to attach; inert pre-activation. Exiting 0."
  exit 0
fi

note "cache-backed read-only build of ${TARGET} @ instance=${BAZEL_REMOTE_INSTANCE_NAME} (upload=false)"
cd "${PROOF_DIR}"
if bash "${WRAPPER}" build "${TARGET}"; then
  note "org-tenancy cache round-trip completed (instance=${BAZEL_REMOTE_INSTANCE_NAME})."
else
  rc=$?
  warn "cache-backed proof build returned rc=${rc}. Pre-activation this is expected (cold org namespace, or the cell/exchange not yet on the org-grammar image); the job is continue-on-error. Post-activation, investigate cell auth + instance routing."
  exit "${rc}"
fi
