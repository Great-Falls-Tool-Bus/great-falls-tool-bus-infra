#!/usr/bin/env bash
# flywheel-cache-proof: authenticated org-tenancy cache deposit/withdraw proof.
#
# The org mint and cache-write path are active (TIN-2299/TIN-2364). GitHub
# Actions must fail unless exchange returns the exact org instance and a fresh
# output base observes a remote/action-cache hit. Trusted main pushes may
# deposit; pull requests remain read-only. Retire this overlay driver when the
# packaged GF front door exports the same authenticated deposit/withdraw proof.
#
# Endpoint authority is fleet-runtime env, NEVER baked here or in workflow YAML:
#   BAZEL_REMOTE_CACHE                 shared Bazel cache (nix-setup exports it
#                                      from cluster DNS on the tinyland-nix runner)
#   GF_REAPI_TOKEN_EXCHANGE_ENDPOINT   hosted gf-reapi-token-exchange URL
#
# Flow:
#   1. Exchange the GitHub Actions OIDC identity for a gf-reapi-cell profile via
#      the fleet-packaged flywheel-github-oidc-profile front door. PRs and
#      unarmed runs request cache-read; trusted main/enforce-cell runs request
#      cache-write.
#   2. Require the minted profile to name org-great-falls-tool-bus exactly.
#   3. Build the hermetic proof target, then rebuild from a fresh output base
#      with uploads disabled and require a remote/action-cache hit.

set -euo pipefail

EXPECTED_INSTANCE="${GFW_EXPECTED_INSTANCE_NAME:?set GFW_EXPECTED_INSTANCE_NAME to org-<owner>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROOF_DIR="${REPO_ROOT}/bazel/flywheel-proof"
WRAPPER="${REPO_ROOT}/scripts/gloriousflywheel-bazel.sh"
TARGET="${GFW_PROOF_TARGET:-//:cache_proof}"
request_mode_raw="${GFW_PROOF_REQUEST_MODE:-auto}"
enforce_cell_endpoint="${GF_REAPI_CACHE_FRONTDOOR_ENDPOINT:-}"
strict_actions=false
if [[ "${GITHUB_ACTIONS:-}" == "true" || (-n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" && -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}") ]]; then
  strict_actions=true
fi

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
  if [[ "${GITHUB_EVENT_NAME:-}" == "push" && "${GITHUB_REF:-}" == "refs/heads/main" ]]; then
    request_mode="cache-write"
  fi
fi

if [[ -z "${enforce_cell_endpoint}" ]]; then
  echo "ERROR: GF_REAPI_CACHE_FRONTDOOR_ENDPOINT is required; refusing the unauthenticated compatibility cache." >&2
  exit 1
fi

if [[ "${request_mode}" == "cache-write" ]]; then
  if [[ "${GITHUB_ACTIONS:-}" != "true" || "${GITHUB_EVENT_NAME:-}" != "push" || "${GITHUB_REF:-}" != "refs/heads/main" ]]; then
    echo "ERROR: cache-write is automatic trusted-main authority only." >&2
    exit 1
  fi
fi

profile_frontdoor_endpoint="${enforce_cell_endpoint}"
remote_upload=false
[[ "${request_mode}" == "cache-write" ]] && remote_upload=true

export GF_BAZEL_SUBSTRATE_MODE="shared-cache-backed"
export GF_BAZEL_REMOTE_UPLOAD="${remote_upload}"
export BAZEL_REMOTE_EXECUTOR=""

note "org-tenancy cache proof; intended instance=${EXPECTED_INSTANCE} request=${request_mode} upload=${GF_BAZEL_REMOTE_UPLOAD}"

if command -v bazelisk >/dev/null 2>&1; then
  export BAZEL_BIN=bazelisk
elif command -v bazel >/dev/null 2>&1; then
  export BAZEL_BIN=bazel
else
  warn "bazelisk/bazel not on PATH; enter the managed devshell."
  [[ "${strict_actions}" == "true" ]] && exit 1
  exit 0
fi

# --- Step 1 + 2: exact GitHub OIDC token exchange ----------------------------
if [[ "${strict_actions}" == "true" ]]; then
  if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" || -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
    echo "ERROR: GitHub Actions OIDC environment is incomplete." >&2
    exit 1
  fi
  if command -v flywheel-github-oidc-profile >/dev/null 2>&1 && [[ -n "${GF_REAPI_TOKEN_EXCHANGE_ENDPOINT:-}" ]]; then
    tokdir="$(mktemp -d)"
    trap 'rm -rf "${tokdir}"' EXIT
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
      if [[ "${minted_instance}" == "${EXPECTED_INSTANCE}" && "${BAZEL_REMOTE_INSTANCE_NAME:-}" == "${EXPECTED_INSTANCE}" ]]; then
        note "ACTIVATED: exchange authorized ${EXPECTED_INSTANCE}; routing the org tenant."
      else
        echo "ERROR: exchange authorized summary='${minted_instance:-<none>}' profile='${BAZEL_REMOTE_INSTANCE_NAME:-<none>}', expected ${EXPECTED_INSTANCE}." >&2
        exit 1
      fi
    else
      echo "ERROR: token exchange call failed." >&2
      exit 1
    fi
  else
    echo "ERROR: fleet token-exchange front door unavailable." >&2
    exit 1
  fi
else
  note "local diagnostic: no GitHub Actions OIDC exchange; this run is not product evidence."
  export BAZEL_REMOTE_INSTANCE_NAME="${EXPECTED_INSTANCE}"
fi

export GF_BAZEL_SUBSTRATE_MODE="shared-cache-backed"
export BAZEL_REMOTE_EXECUTOR=""

# --- Step 3: cache-backed proof build ---------------------------------------
if [[ -z "${BAZEL_REMOTE_CACHE:-}" ]]; then
  warn "BAZEL_REMOTE_CACHE is unset after profile generation."
  [[ "${strict_actions}" == "true" ]] && exit 1
  exit 0
fi

proof_tmp="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/gftb-cache-proof.XXXXXX")"
if [[ -z "${tokdir:-}" ]]; then
  trap 'rm -rf "${proof_tmp}"' EXIT
else
  trap 'rm -rf "${proof_tmp}" "${tokdir}"' EXIT
fi
round1_log="${proof_tmp}/round1.log"
round2_log="${proof_tmp}/round2.log"

note "round 1: cache-backed build of ${TARGET} @ instance=${BAZEL_REMOTE_INSTANCE_NAME} (request=${request_mode}, upload=${remote_upload})"
cd "${PROOF_DIR}"
BAZEL_OUTPUT_BASE="${proof_tmp}/round1" \
  GF_BAZEL_REMOTE_UPLOAD="${remote_upload}" \
  bash "${WRAPPER}" build "${TARGET}" 2>&1 | tee "${round1_log}"
"${BAZEL_BIN}" --output_base="${proof_tmp}/round1" shutdown >/dev/null 2>&1 || true

note "round 2: fresh output base, read-only withdrawal must hit the shared cache"
BAZEL_OUTPUT_BASE="${proof_tmp}/round2" \
  GF_BAZEL_REMOTE_UPLOAD=false \
  bash "${WRAPPER}" build "${TARGET}" 2>&1 | tee "${round2_log}"
"${BAZEL_BIN}" --output_base="${proof_tmp}/round2" shutdown >/dev/null 2>&1 || true

hit_lines="$(grep -oE '[0-9]+ (remote|action) cache hit' "${round2_log}" || true)"
hits="$(printf '%s\n' "${hit_lines}" | awk 'NF { total += $1 } END { print total + 0 }')"
if [[ "${hits}" -lt 1 ]]; then
  echo "ERROR: fresh output base recorded ${hits} remote/action cache hits." >&2
  exit 1
fi

note "org-tenancy deposit/withdraw PROVEN: ${hits} remote/action cache hit(s), instance=${BAZEL_REMOTE_INSTANCE_NAME}."
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## GFTB Flywheel cache proof"
    echo
    echo "- instance: \`${BAZEL_REMOTE_INSTANCE_NAME}\`"
    echo "- request: \`${request_mode}\`"
    echo "- round 1 upload: \`${remote_upload}\`"
    echo "- round 2 remote/action cache hits: \`${hits}\`"
  } >>"${GITHUB_STEP_SUMMARY}"
fi
