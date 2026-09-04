#!/usr/bin/env bash
# Self-test for the bounded legacy ARC continuity contract: workflow-facing
# labels remain capability-shaped, registration URLs remain owner-scoped
# unless a caller explicitly opts into a repository anchor, and the still-live
# Attic key cannot silently regress before ARC retirement. Broader cache,
# endpoint, and execution-mode policy belongs to GF v4.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="${REPO_ROOT}/scripts/validate-overlay-runner-taxonomy.py"
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -f -- \
        "${TMP_DIR}/out" \
        "${TMP_DIR}/valid.tfvars" \
        "${TMP_DIR}/identity-label.tfvars" \
        "${TMP_DIR}/private-label.tfvars" \
        "${TMP_DIR}/org-scope.tfvars" \
        "${TMP_DIR}/repo-scope.tfvars" \
        "${TMP_DIR}/missing-label.tfvars" \
        "${TMP_DIR}/missing-registration.tfvars" \
        "${TMP_DIR}/attic-current.tfvars" \
        "${TMP_DIR}/attic-missing-key.tfvars" \
        "${TMP_DIR}/attic-retired-key.tfvars"
    rmdir -- "${TMP_DIR}"
}
trap cleanup EXIT

run() { python3 "${VALIDATOR}" --allow-repo-registration-anchor "$1" >"${TMP_DIR}/out" 2>&1; }
fail() { echo "SELF-TEST FAILED: $1" >&2; sed -n '1,120p' "${TMP_DIR}/out" >&2; exit 1; }

# 1. A capability-shaped label plus explicit repository registration anchor is
# accepted when the caller opts into that legacy ARC shape.
cat >"${TMP_DIR}/valid.tfvars" <<'EOF'
extra_runner_sets = {
  continuity-nix = {
    github_config_url = "https://github.com/ExampleOwner/example-infra"
    runner_label      = "tinyland-nix-heavy"
  }
}
EOF
run "${TMP_DIR}/valid.tfvars" || fail "valid capability/registration anchor failed"

# 2. Project identity may not leak into a workflow-facing runner label.
sed 's/tinyland-nix-heavy/tinyland-nix-gftb/' "${TMP_DIR}/valid.tfvars" >"${TMP_DIR}/identity-label.tfvars"
run "${TMP_DIR}/identity-label.tfvars" && fail "project-identity label unexpectedly passed"
grep -q "project identity tokens" "${TMP_DIR}/out" || fail "missing project-identity diagnostic"

# 3. Labels outside the shared capability namespace fail closed.
sed 's/tinyland-nix-heavy/product-runner/' "${TMP_DIR}/valid.tfvars" >"${TMP_DIR}/private-label.tfvars"
run "${TMP_DIR}/private-label.tfvars" && fail "private label unexpectedly passed"
grep -q "shared tinyland-\* capability namespace" "${TMP_DIR}/out" || fail "missing namespace diagnostic"

# 4. Org-scoped registration is the overlay default; repository-scoped
# registration needs the explicit legacy opt-in used above.
cat >"${TMP_DIR}/org-scope.tfvars" <<'EOF'
github_config_url = "https://github.com/Great-Falls-Tool-Bus"
EOF
python3 "${VALIDATOR}" "${TMP_DIR}/org-scope.tfvars" >"${TMP_DIR}/out" 2>&1 || fail "org registration unexpectedly failed"
cat >"${TMP_DIR}/repo-scope.tfvars" <<'EOF'
github_config_url = "https://github.com/Great-Falls-Tool-Bus/some-repo"
EOF
python3 "${VALIDATOR}" "${TMP_DIR}/repo-scope.tfvars" >"${TMP_DIR}/out" 2>&1 && fail "repo registration unexpectedly passed without opt-in"
grep -q "repo scoped" "${TMP_DIR}/out" || fail "missing repo-scope diagnostic"

# 5. An extra runner-set continuity entry must keep both its label and its
# registration anchor until the whole ARC resource is retired.
sed '/runner_label/d' "${TMP_DIR}/valid.tfvars" >"${TMP_DIR}/missing-label.tfvars"
run "${TMP_DIR}/missing-label.tfvars" && fail "missing label unexpectedly passed"
grep -q "missing runner_label" "${TMP_DIR}/out" || fail "missing label diagnostic"

sed '/github_config_url/d' "${TMP_DIR}/valid.tfvars" >"${TMP_DIR}/missing-registration.tfvars"
run "${TMP_DIR}/missing-registration.tfvars" && fail "missing registration unexpectedly passed"
grep -q "missing github_config_url" "${TMP_DIR}/out" || fail "missing registration diagnostic"

# 6. The current continuity key remains accepted while the legacy ARC scale
# set exists.
cat >"${TMP_DIR}/attic-current.tfvars" <<'EOF'
attic_server     = "http://attic.nix-cache.svc.cluster.local"
attic_public_key = "main:eaUydxuDu7xBoy5cCo3MdknYAkVyTIASQ7DGuwxa+XA="
EOF
run "${TMP_DIR}/attic-current.tfvars" || fail "current Attic continuity key unexpectedly failed"

# 7. A live Attic server may not lose its trust key independently.
cat >"${TMP_DIR}/attic-missing-key.tfvars" <<'EOF'
attic_server = "http://attic.nix-cache.svc.cluster.local"
EOF
run "${TMP_DIR}/attic-missing-key.tfvars" && fail "Attic server without key unexpectedly passed"
grep -q "attic_public_key is missing" "${TMP_DIR}/out" || fail "missing Attic-key diagnostic"

# 8. The known retired key cannot be restored during the continuity hold.
cat >"${TMP_DIR}/attic-retired-key.tfvars" <<'EOF'
attic_server     = "http://attic.nix-cache.svc.cluster.local"
attic_public_key = "main:l/gpjG5GLg1Gczmn5K97n5iSIRcsaWerICzdXqiBYT8="
EOF
run "${TMP_DIR}/attic-retired-key.tfvars" && fail "retired Attic key unexpectedly passed"
grep -q "retired cache key" "${TMP_DIR}/out" || fail "missing retired Attic-key diagnostic"

echo "overlay runner taxonomy continuity self-test passed"
