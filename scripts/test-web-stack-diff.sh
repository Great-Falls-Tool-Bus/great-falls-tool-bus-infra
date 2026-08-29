#!/usr/bin/env bash
# Self-test for web-stack-diff.sh (Justfile web-stack-diff-selftest, folded
# into `just check`). This is the fixture the reconciliation-safety review
# of infra PR #135 asked for (E3): the script's own header has demanded
# since round 2 that it "MUST be exercised with two directories in any test,
# never two bare files, or a regression here reads as passing again" -- until
# this file, nothing enforced that, and `git grep web-stack-diff` returned
# zero tests. Every case below was run by hand during that review with real
# yq-go + jq before being committed here; see the review comment for the
# execution transcript this codifies.
#
# Exercises the exact five cases the review used to prove the yq-go/jq
# rewrite (E2026-08-29, sweep g1) actually works, and that it still fails
# closed the way round-2 (B2/E4/E5) required:
#   1. empty-annotations-map normalization -> rc=0 (no real diff)
#   2. replicas 2->50 + swapped image digest -> rc=1 (the PR #126 false-green
#      regression this script exists to catch)
#   3. two bare files instead of directories -> rc=2 (fails closed)
#   4. multi-document YAML with a real diff in doc 2 -> rc=3 (fails closed;
#      a silent doc-drop would read as zero-diff otherwise)
#   5. a similarly-named key (x-app.tinyland.dev/source-sha-legacy) changes
#      -> rc=1 (the NORMALIZE_FILTER's anchored key match must not eat it)
#
# Requires REAL yq-go (mikefarah) and jq on PATH -- the same tooling
# GF-core's `ci` devshell provides. Do not run this under this repo's own
# flake.nix devshell, which pins python-yq (kislyuk): that would validate
# the wrong binary and could pass while CI stays broken (see the script's
# own CALLING CONVENTION header for why that distinction is load-bearing).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIFF_SCRIPT="${REPO_ROOT}/scripts/web-stack-diff.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

if ! yq --version 2>&1 | grep -qi 'mikefarah\|version v4\|version 4\.'; then
  echo "web-stack-diff-selftest: SKIP -- PATH yq is not yq-go (mikefarah); got: $(yq --version 2>&1 | head -1)" >&2
  echo "web-stack-diff-selftest: this self-test requires the same yq-go binary CI's GF-core devshell provides" >&2
  exit 1
fi
command -v jq >/dev/null 2>&1 || { echo "web-stack-diff-selftest: jq is required" >&2; exit 1; }

fail() {
  echo "SELF-TEST FAILED: $1" >&2
  exit 1
}

run_diff() {
  # Runs the script, captures rc without tripping this file's own
  # set -e (the script's exit codes ARE the thing under test).
  local a="$1" b="$2"
  set +e
  "${DIFF_SCRIPT}" "$a" "$b" >"${TMP_DIR}/out" 2>"${TMP_DIR}/err"
  rc=$?
  set -e
}

# --- Case 1: empty-annotations-map normalization -> rc=0 ------------------
c1_local="${TMP_DIR}/c1-local"; c1_live="${TMP_DIR}/c1-live"
mkdir -p "${c1_local}" "${c1_live}"
cat >"${c1_local}/deploy.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: greatfallstoolbus-org-production
  labels:
    app: web
spec:
  replicas: 2
EOF
cat >"${c1_live}/deploy.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: greatfallstoolbus-org-production
  labels:
    app: web
  annotations:
    app.tinyland.dev/source-sha: abc123deadbeef
spec:
  replicas: 2
EOF
run_diff "${c1_local}" "${c1_live}"
[ "${rc}" -eq 0 ] || fail "case 1 (empty-annotations normalization): expected rc=0, got rc=${rc}: $(cat "${TMP_DIR}/out" "${TMP_DIR}/err")"
echo "case 1 OK (rc=0, source-sha-only annotations normalize away)"

# --- Case 2: replicas 2->50 + swapped image digest -> rc=1 -----------------
c2_local="${TMP_DIR}/c2-local"; c2_live="${TMP_DIR}/c2-live"
mkdir -p "${c2_local}" "${c2_live}"
cat >"${c2_local}/deploy.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: greatfallstoolbus-org-production
spec:
  replicas: 2
  template:
    spec:
      containers:
        - name: web
          image: ghcr.io/example/gftb-site@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
cat >"${c2_live}/deploy.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: greatfallstoolbus-org-production
spec:
  replicas: 50
  template:
    spec:
      containers:
        - name: web
          image: ghcr.io/example/gftb-site@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF
run_diff "${c2_local}" "${c2_live}"
[ "${rc}" -eq 1 ] || fail "case 2 (replicas+image diff): expected rc=1, got rc=${rc}: $(cat "${TMP_DIR}/out" "${TMP_DIR}/err")"
grep -q 'replicas' "${TMP_DIR}/out" || fail "case 2: diff output did not mention replicas"
echo "case 2 OK (rc=1, real diff surfaced -- the PR #126 false-green regression stays caught)"

# --- Case 3: two bare files instead of directories -> rc=2 -----------------
c3_local="${TMP_DIR}/c3-local.yaml"; c3_live="${TMP_DIR}/c3-live.yaml"
echo "kind: Deployment" >"${c3_local}"
echo "kind: Deployment" >"${c3_live}"
run_diff "${c3_local}" "${c3_live}"
[ "${rc}" -eq 2 ] || fail "case 3 (bare files, not directories): expected rc=2, got rc=${rc}: $(cat "${TMP_DIR}/out" "${TMP_DIR}/err")"
echo "case 3 OK (rc=2, fails closed on non-directory input)"

# --- Case 4: multi-document YAML, real diff in doc 2 -> rc=3 ---------------
c4_local="${TMP_DIR}/c4-local"; c4_live="${TMP_DIR}/c4-live"
mkdir -p "${c4_local}" "${c4_live}"
cat >"${c4_local}/multi.yaml" <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: web
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 2
EOF
cat >"${c4_live}/multi.yaml" <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: web
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 9
EOF
run_diff "${c4_local}" "${c4_live}"
[ "${rc}" -eq 3 ] || fail "case 4 (multi-document YAML): expected rc=3 (fails closed -- this script does not support multi-doc files), got rc=${rc}: $(cat "${TMP_DIR}/out" "${TMP_DIR}/err")"
echo "case 4 OK (rc=3, fails closed rather than silently dropping a document)"

# --- Case 5: similarly-named key must not be swallowed by the filter ------
c5_local="${TMP_DIR}/c5-local"; c5_live="${TMP_DIR}/c5-live"
mkdir -p "${c5_local}" "${c5_live}"
cat >"${c5_local}/deploy.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  annotations:
    x-app.tinyland.dev/source-sha-legacy: "one"
spec:
  replicas: 2
EOF
cat >"${c5_live}/deploy.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  annotations:
    x-app.tinyland.dev/source-sha-legacy: "two"
spec:
  replicas: 2
EOF
run_diff "${c5_local}" "${c5_live}"
[ "${rc}" -eq 1 ] || fail "case 5 (similarly-named key): expected rc=1 (anchored key match must not eat this), got rc=${rc}: $(cat "${TMP_DIR}/out" "${TMP_DIR}/err")"
echo "case 5 OK (rc=1, anchored has()/del() match on the exact key survives a lookalike key)"

echo "web-stack-diff-selftest: all 5 cases passed"
