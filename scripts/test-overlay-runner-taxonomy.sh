#!/usr/bin/env bash
# Self-test for validate-overlay-runner-taxonomy.py's RBE-wiring guard
# (validate_rbe_wiring): an under-wired nix/docker/dind extra_runner_sets anchor
# must FAIL, a fully-wired one must PASS, BARE_EXEMPT lanes must PASS, and
# executor-without-cache must FAIL.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="${REPO_ROOT}/scripts/validate-overlay-runner-taxonomy.py"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ATTIC_KEY='attic_public_key = "main:eaUydxuDu7xBoy5cCo3MdknYAkVyTIASQ7DGuwxa+XA="'
run() { python3 "${VALIDATOR}" --allow-repo-registration-anchor "$1" >"${TMP_DIR}/out" 2>&1; }
fail() { echo "SELF-TEST FAILED: $1" >&2; cat "${TMP_DIR}/out" >&2; exit 1; }

# 1. Under-wired nix (old dollhouse-farm-nix shape) -> FAIL on cache AND attic.
cat >"${TMP_DIR}/underwired-nix.tfvars" <<'EOF'
extra_runner_sets = {
  some-product-nix = {
    github_config_url = "https://github.com/ExampleOwner/x"
    runner_label      = "tinyland-nix"
    runner_type       = "nix"
    cpu_limit         = "4"
    memory_limit      = "8Gi"
  }
}
EOF
run "${TMP_DIR}/underwired-nix.tfvars" && fail "under-wired nix unexpectedly passed"
grep -q "requires bazel_cache_endpoint" "${TMP_DIR}/out" || fail "missing cache error"
grep -q "requires attic_server" "${TMP_DIR}/out" || fail "missing attic error"

# 2. Fully-wired executor nix (post-PR#37 dollhouse shape) -> PASS.
cat >"${TMP_DIR}/wired-nix.tfvars" <<EOF
${ATTIC_KEY}
extra_runner_sets = {
  some-product-nix = {
    github_config_url       = "https://github.com/ExampleOwner/x"
    runner_label            = "tinyland-nix"
    runner_type             = "nix"
    attic_server            = "http://attic.nix-cache.svc.cluster.local"
    bazel_cache_endpoint    = "grpc://bazel-cache.nix-cache.svc.cluster.local:9092"
    bazel_executor_endpoint = "grpc://gf-reapi-cell.gf-rbe.svc.cluster.local:8980"
  }
}
EOF
run "${TMP_DIR}/wired-nix.tfvars" || fail "fully-wired executor nix unexpectedly failed"

# 3. Cache-only nix sibling (no executor) -> PASS.
cat >"${TMP_DIR}/cache-only-nix.tfvars" <<EOF
${ATTIC_KEY}
extra_runner_sets = {
  some-cache-nix = {
    github_config_url    = "https://github.com/ExampleOwner/x"
    runner_label         = "tinyland-nix"
    runner_type          = "nix"
    attic_server         = "http://attic.nix-cache.svc.cluster.local"
    bazel_cache_endpoint = "grpc://bazel-cache.nix-cache.svc.cluster.local:9092"
  }
}
EOF
run "${TMP_DIR}/cache-only-nix.tfvars" || fail "cache-only nix unexpectedly failed"

# 4. Executor dind, no attic required for dind -> PASS.
cat >"${TMP_DIR}/executor-dind.tfvars" <<'EOF'
extra_runner_sets = {
  some-dind = {
    github_config_url       = "https://github.com/ExampleOwner/x"
    runner_label            = "tinyland-dind"
    runner_type             = "dind"
    bazel_cache_endpoint    = "grpc://bazel-cache.nix-cache.svc.cluster.local:9092"
    bazel_executor_endpoint = "grpc://gf-reapi-cell.gf-rbe.svc.cluster.local:8980"
  }
}
EOF
run "${TMP_DIR}/executor-dind.tfvars" || fail "executor dind unexpectedly failed"

# 5. Executor without cache -> FAIL (unconditional executor-implies-cache rule).
cat >"${TMP_DIR}/executor-no-cache.tfvars" <<EOF
${ATTIC_KEY}
extra_runner_sets = {
  bad-executor = {
    github_config_url       = "https://github.com/ExampleOwner/x"
    runner_label            = "tinyland-nix"
    runner_type             = "nix"
    attic_server            = "http://attic.nix-cache.svc.cluster.local"
    bazel_executor_endpoint = "grpc://gf-reapi-cell.gf-rbe.svc.cluster.local:8980"
  }
}
EOF
run "${TMP_DIR}/executor-no-cache.tfvars" && fail "executor-without-cache unexpectedly passed"
grep -q "executor-backed mode requires a remote cache" "${TMP_DIR}/out" || fail "missing executor-implies-cache error"

# 6. BARE_EXEMPT cache-less docker lane -> PASS.
cat >"${TMP_DIR}/exempt-docker.tfvars" <<'EOF'
extra_runner_sets = {
  personal-docker = {
    github_config_url = "https://github.com/ExampleOwner/blog"
    runner_label      = "tinyland-docker"
    runner_type       = "docker"
  }
}
EOF
run "${TMP_DIR}/exempt-docker.tfvars" || fail "BARE_EXEMPT personal-docker unexpectedly failed"

# 7. Org-scoped github_config_url WITHOUT the repo-anchor opt-in -> PASS.
#    (GFTB registers ARC at the org scope; repo-scoped URLs fail closed here.)
cat >"${TMP_DIR}/org-scope.tfvars" <<'EOF'
github_config_url = "https://github.com/Great-Falls-Tool-Bus"
EOF
python3 "${VALIDATOR}" "${TMP_DIR}/org-scope.tfvars" >"${TMP_DIR}/out" 2>&1 || fail "org-scoped config URL unexpectedly failed without anchor flag"
cat >"${TMP_DIR}/repo-scope.tfvars" <<'EOF'
github_config_url = "https://github.com/Great-Falls-Tool-Bus/some-repo"
EOF
python3 "${VALIDATOR}" "${TMP_DIR}/repo-scope.tfvars" >"${TMP_DIR}/out" 2>&1 && fail "repo-scoped config URL unexpectedly passed without anchor flag"
grep -q "repo scoped" "${TMP_DIR}/out" || fail "missing repo-scope error"

echo "overlay runner taxonomy RBE-wiring self-test passed"
