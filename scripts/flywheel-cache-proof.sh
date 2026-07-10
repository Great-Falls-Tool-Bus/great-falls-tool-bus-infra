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
#      the fleet-packaged flywheel-github-oidc-profile front door. PRs and
#      unarmed runs request cache-read; trusted main/enforce-cell runs request
#      cache-write.
#   2. Source the minted profile. Its BAZEL_REMOTE_INSTANCE_NAME is the tenant
#      the exchange actually authorized: org-<owner> once grants are live, the
#      read-only default before. Routing what the token authorizes keeps the
#      cell from rejecting the request pre-activation.
#   3. Run a cache-backed Bazel build of the hermetic proof genrule under
#      bazel/flywheel-proof/, routed to that instance. cache-write mode permits
#      upload only on the minted enforce-cell profile; cache-read stays read-only.

set -uo pipefail

EXPECTED_INSTANCE="${GFW_EXPECTED_INSTANCE_NAME:?set GFW_EXPECTED_INSTANCE_NAME to org-<owner>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROOF_DIR="${REPO_ROOT}/bazel/flywheel-proof"
WRAPPER="${REPO_ROOT}/scripts/gloriousflywheel-bazel.sh"
TARGET="${GFW_PROOF_TARGET:-//:cache_proof}"
request_mode_raw="${GFW_PROOF_REQUEST_MODE:-auto}"
enforce_cell_endpoint="${GF_REAPI_CACHE_FRONTDOOR_ENDPOINT:-}"

note() { echo "::notice::flywheel-cache-proof: $*"; echo "flywheel-cache-proof: $*"; }
warn() { echo "::warning::flywheel-cache-proof: $*"; echo "flywheel-cache-proof: $*"; }

case "${request_mode_raw}" in
auto | cache-read | cache-write) ;;
*)
  echo "ERROR: GFW_PROOF_REQUEST_MODE must be auto, cache-read, or cache-write." >&2
  exit 2
  ;;
esac

request_mode="${request_mode_raw}"
if [[ "${request_mode}" == "auto" ]]; then
  request_mode="cache-read"
  if [[ "${GITHUB_EVENT_NAME:-}" == "push" && "${GITHUB_REF:-}" == "refs/heads/main" && -n "${enforce_cell_endpoint}" ]]; then
    request_mode="cache-write"
  fi
fi

case "${request_mode}" in
cache-read)
  profile_frontdoor_endpoint="${BAZEL_REMOTE_CACHE:-}"
  remote_upload=false
  ;;
cache-write)
  if [[ -z "${enforce_cell_endpoint}" ]]; then
    echo "ERROR: cache-write proof requires GF_REAPI_CACHE_FRONTDOOR_ENDPOINT from runner env; refusing to infer or hard-code the enforce-cell endpoint." >&2
    exit 1
  fi
  profile_frontdoor_endpoint="${enforce_cell_endpoint}"
  remote_upload=true
  ;;
esac

export GF_BAZEL_SUBSTRATE_MODE="${GF_BAZEL_SUBSTRATE_MODE:-shared-cache-backed}"
export GF_BAZEL_REMOTE_UPLOAD="${remote_upload}"
export BAZEL_REMOTE_EXECUTOR=""
# Intended org instance. The exchange profile, when produced, overrides this
# with the instance the token authorized (org-<owner> once grants are live).
export BAZEL_REMOTE_INSTANCE_NAME="${EXPECTED_INSTANCE}"

note "org-tenancy cache proof; intended instance=${EXPECTED_INSTANCE} request=${request_mode} upload=${GF_BAZEL_REMOTE_UPLOAD}"

if ! command -v bazelisk >/dev/null 2>&1 && ! command -v bazel >/dev/null 2>&1; then
  warn "bazelisk/bazel not on PATH (run inside 'nix develop .'). Inert pre-activation; exiting 0."
  exit 0
fi

# --- Step 1 + 2: best-effort GitHub OIDC token exchange ---------------------
strict_actions=false
if [[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" && -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
  strict_actions=true
  if command -v flywheel-github-oidc-profile >/dev/null 2>&1 && [[ -n "${GF_REAPI_TOKEN_EXCHANGE_ENDPOINT:-}" ]]; then
    tokdir="$(mktemp -d)"
    profile="${tokdir}/gf-reapi-cell-profile.env"
    summary="${tokdir}/token-exchange-summary.json"
    if flywheel-github-oidc-profile \
      --request "${request_mode}" \
      --frontdoor-endpoint "${profile_frontdoor_endpoint}" \
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
      warn "token exchange call failed."
      if [[ "${strict_actions}" == "true" ]]; then
        exit 1
      fi
    fi
  else
    warn "fleet token-exchange front door unavailable (flywheel-github-oidc-profile absent or GF_REAPI_TOKEN_EXCHANGE_ENDPOINT unset)."
    if [[ "${strict_actions}" == "true" ]]; then
      exit 1
    fi
  fi
else
  note "no GitHub Actions OIDC environment (local/dev run); skipping token exchange."
fi

# --- Step 3: cache-backed proof build ---------------------------------------
if [[ -z "${BAZEL_REMOTE_CACHE:-}" ]]; then
  warn "BAZEL_REMOTE_CACHE is unset after profile generation."
  if [[ "${strict_actions}" == "true" ]]; then
    exit 1
  fi
  exit 0
fi

note "cache-backed build of ${TARGET} @ instance=${BAZEL_REMOTE_INSTANCE_NAME} (request=${request_mode}, upload=${GF_BAZEL_REMOTE_UPLOAD})"
cd "${PROOF_DIR}"
if bash "${WRAPPER}" build "${TARGET}"; then
  note "org-tenancy cache round-trip completed (instance=${BAZEL_REMOTE_INSTANCE_NAME}, request=${request_mode}, upload=${GF_BAZEL_REMOTE_UPLOAD})."
else
  rc=$?
  warn "cache-backed proof build returned rc=${rc}; investigate cell auth + instance routing."
  exit "${rc}"
fi
