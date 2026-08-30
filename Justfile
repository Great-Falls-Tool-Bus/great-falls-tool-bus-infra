Warning: truncated output (original token count: 60381)
Total output lines: 4118

set dotenv-load := false
set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

# GF core checkout path default. The older personal-account overlay defaulted to
# "../GloriousFlywheel-infra-overlays" — a dead-name rename residue that forced
# every operator to export GF_CORE_PATH. This overlay defaults to the real
# checkout directory name. Override GF_CORE_PATH when the core source checkout
# lives elsewhere. GF_CORE_CI_PATH is a pinned GitHub flake ref by default so
# tooling no longer assumes a sibling checkout for the #ci devshell.
#
# GloriousFlywheel went private (TIN-4015, 2026-08-22). The `github:` defaults
# below (gf_core_ci, arc_core_ci_default) are unauthenticated and now 404 for a
# local operator who has not exported GF_CORE_CI_PATH / GF_ARC_CORE_CI_PATH.
# The CI workflows (.github/workflows/) already export a credentialed
# path:${GF_CORE_PATH}#ci override per-invocation and are unaffected. A local
# operator with an authenticated GloriousFlywheel checkout at gf_core /
# arc_core_default should export GF_CORE_CI_PATH="path:${gf_core}#ci" (or the
# ARC equivalent) themselves; _reviewed-arc-core already accepts and verifies
# that local-path form (see its pinned_ci/local_ci/declared_local_ci check
# below). Not fixed here -- follow-up TIN-4034.
gf_core := env_var_or_default("GF_CORE_PATH", "../GloriousFlywheel")
gf_core_ci := env_var_or_default("GF_CORE_CI_PATH", "github:tinyland-inc/GloriousFlywheel/2281b576bce0e8dd776a047b84e7464f5b508a62#ci")
gf_core_sha := "2281b576bce0e8dd776a047b84e7464f5b508a62"
arc_core_default := "../GloriousFlywheel-arc-11ace"
arc_core_sha := "11ace397282ff89aeb1dfeb4a32fcbed3200c2ff"
arc_core_ci_default := "github:tinyland-inc/GloriousFlywheel/11ace397282ff89aeb1dfeb4a32fcbed3200c2ff#ci"
arc_tfvars := "tofu/stacks/arc-runners/great-falls-tool-bus.tfvars"
arc_backend_default := "tofu/backend/honey.s3.hcl"
arc_cluster_uid := "cc121476-7a95-4b24-aa61-79d1f45713bd"
arc_target_uid := "c768fdd2-e76f-4fbf-bc39-922430fedbb6"

default:
    @just --list

check-hosted:
    just workflow-lint
    just secrets-scan-dir
    just public-surface-selftest
    just public-surface
    just public-pii
    just core-checkout-selftest
    just core-checkout
    just taxonomy
    just taxonomy-selftest
    just runner-group-contract-selftest
    just runner-group-contract
    just mail-cr-validate
    just list-stack-validate
    just listsync-stack-validate
    just form-stack-validate
    just archive-stack-validate
    just guard-no-remote-kustomize-resources-selftest
    just web-stack-validate
    just web-stack-diff-selftest
    just grafana-dashboards-validate
    just arc-fmt-check
    just edge-zones-fmt-check
    just edge-zones-validate
    just substrate-boundary-selftest
    just substrate-boundary

# Private GloriousFlywheel source-dependent ARC module validation remains an
# operator-local extension. Public CI runs only `check-hosted`. The recipe name
# is historical (TIN-3914 moved CI off GitHub-hosted runners); it is referenced
# by scripts/validate-public-operator-surface.py's reviewed allowlist and is
# deliberately not renamed here.
check: check-hosted
    just arc-validate

# Gitleaks scan of working tree files (AGENTS.md hard rule: no secrets in Git)
secrets-scan-dir:
    gitleaks dir --config .gitleaks.toml --redact --verbose .

# Gitleaks scan of git history
secrets-scan:
    gitleaks git --config .gitleaks.toml --redact --verbose .

# Keep public docs/workflows pointed at audited Justfile recipes, not raw
# tofu/kubectl copy-paste snippets.
public-surface:
    python3 scripts/validate-public-operator-surface.py

public-surface-selftest:
    python3 -B scripts/validate-public-operator-surface.py --self-test

# Keep public-ready surfaces free of personal PII while allowing role/list
# addresses and example domains.
public-pii:
    python3 scripts/validate-public-pii-surface.py

# Finite pinned-source declaration contract. Workflows bind GloriousFlywheel to
# the exact reviewed commit for each role. GloriousFlywheel went private
# (TIN-4015, 2026-08-22); every core-repository checkout now carries exactly
# one credential, the read-only GF_CORE_DEPLOY_KEY deploy key
# (docs/ci-credentials.md) -- this check enforces that it is that credential,
# on that checkout shape, and nothing broader (no token, no other secret name,
# no off-census path).
core-checkout:
    python3 -B scripts/validate-core-checkout.py

core-checkout-selftest:
    python3 -B scripts/validate-core-checkout.py --self-test

core-checkout-bazel:
    bazelisk test --lockfile_mode=off //:core_checkout_contract_tests

# TIN-3902 runner-group admission contract. config/organization.yaml declares
# the GitHub-side roster and the ARC tfvars binds the scale sets to it; nothing
# else holds the two together, because the GloriousFlywheel arc-runners module
# never reads the roster and the taxonomy validator only parses runner labels.
runner-group-contract:
    python3 -B scripts/validate-runner-group-contract.py

runner-group-contract-selftest:
    python3 -B scripts/validate-runner-group-contract.py --self-test

workflow-lint:
    #!/usr/bin/env -S BASH_ENV= ENV= SHELLOPTS= BASHOPTS= bash -p
    set +x
    set -euo pipefail
    export LC_ALL=C
    command -v actionlint >/dev/null 2>&1 || {
      echo "actionlint is required (nix develop provides it)" >&2
      exit 1
    }
    command -v timeout >/dev/null 2>&1 || {
      echo "GNU timeout is required (nix develop provides coreutils)" >&2
      exit 1
    }
    shopt -s nullglob dotglob
    workflows=(.github/workflows/*.yml .github/workflows/*.yaml)
    ((${#workflows[@]} > 0)) || {
      echo "no GitHub Actions workflow files found" >&2
      exit 1
    }
    for workflow in "${workflows[@]}"; do
      [[ -f "${workflow}" && ! -L "${workflow}" ]] || {
        echo "workflow input must be a regular non-symlink file: ${workflow}" >&2
        exit 1
      }
      printf 'actionlint: %s\n' "${workflow}"
      lint_rc=0
      timeout --signal=TERM --kill-after=5s 30s \
        actionlint -ignore 'label "tinyland-nix" is unknown' -ignore 'SC2155' "${workflow}" || lint_rc=$?
      case "${lint_rc}" in
        0) ;;
        124|137)
          printf '::error file=%s,title=actionlint timeout::actionlint exceeded 30 seconds for %s\n' "${workflow}" "${workflow}" >&2
          exit 1
          ;;
        *)
          printf '::error file=%s,title=actionlint failed::actionlint exited %s for %s\n' "${workflow}" "${lint_rc}" "${workflow}" >&2
          exit "${lint_rc}"
          ;;
      esac
    done

# Generate changelog (git-cliff)
changelog:
    git-cliff --output CHANGELOG.md

# Preview changelog without writing
changelog-preview:
    git-cliff --unreleased

enrollment-preflight: _reviewed-implementation-core _arc-kubeconfig-contract
    #!/usr/bin/env bash
    set -euo pipefail
    core="${GF_CORE_PATH:-../GloriousFlywheel}"
    KUBECONFIG="${GFTB_ARC_KUBECONFIG}" python3 "${core}/scripts/implementation-overlay-preflight.py" --overlay-root . --tfvars {{ arc_tfvars }} --repo Great-Falls-Tool-Bus/great-falls-tool-bus-infra | python3 -I -c 'import sys; text=sys.stdin.read(); print(text.replace("`just arc-app-secret-dry-run`, then `just arc-app-secret-apply`.", "`GFTB_APPLY_CONFIRM=apply just arc-app-secret-apply` (the secret-printing dry-run is retired)."), end="")'

enrollment-preflight-strict: _reviewed-implementation-core _arc-kubeconfig-contract
    #!/usr/bin/env bash
    set -euo pipefail
    core="${GF_CORE_PATH:-../GloriousFlywheel}"
    KUBECONFIG="${GFTB_ARC_KUBECONFIG}" python3 "${core}/scripts/implementation-overlay-preflight.py" --overlay-root . --tfvars {{ arc_tfvars }} --repo Great-Falls-Tool-Bus/great-falls-tool-bus-infra --strict | python3 -I -c 'import sys; text=sys.stdin.read(); print(text.replace("`just arc-app-secret-dry-run`, then `just arc-app-secret-apply`.", "`GFTB_APPLY_CONFIRM=apply just arc-app-secret-apply` (the secret-printing dry-run is retired)."), end="")'

_arc-app-secret-inputs:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${GITHUB_APP_ID:?Set GITHUB_APP_ID}"
    : "${GITHUB_APP_INSTALLATION_ID:?Set GITHUB_APP_INSTALLATION_ID}"
    : "${GITHUB_APP_PRIVATE_KEY_PATH:?Set GITHUB_APP_PRIVATE_KEY_PATH}"
    [[ "${GITHUB_APP_ID}" =~ ^[1-9][0-9]*$ ]] || { echo "GITHUB_APP_ID must be a positive decimal integer" >&2; exit 2; }
    [[ "${GITHUB_APP_INSTALLATION_ID}" =~ ^[1-9][0-9]*$ ]] || { echo "GITHUB_APP_INSTALLATION_ID must be a positive decimal integer" >&2; exit 2; }
    python3 -I - "${GITHUB_APP_PRIVATE_KEY_PATH}" "$(git rev-parse --show-toplevel)" <<'PY'
    import os
    import stat
    import sys
    from pathlib import Path

    path = Path(sys.argv[1]).expanduser().resolve(strict=True)
    repo = Path(sys.argv[2]).resolve(strict=True)
    try:
        path.relative_to(repo)
    except ValueError:
        pass
    else:
        raise SystemExit("GITHUB_APP_PRIVATE_KEY_PATH must remain outside the public repository")
    metadata = path.stat()
    if not path.is_file() or metadata.st_uid != os.getuid():
        raise SystemExit("GITHUB_APP_PRIVATE_KEY_PATH must be a regular file owned by the operator")
    if stat.S_IMODE(metadata.st_mode) != 0o600:
        raise SystemExit("GITHUB_APP_PRIVATE_KEY_PATH must have mode 0600")
    value = path.read_text(encoding="utf-8")
    if "-----BEGIN" not in value or "PRIVATE KEY-----" not in value or "-----END" not in value:
        raise SystemExit("GITHUB_APP_PRIVATE_KEY_PATH is not a PEM private key")
    PY
    command -v openssl >/dev/null || { echo "openssl is required to validate the GitHub App private key" >&2; exit 2; }
    openssl pkey -check -noout -in "${GITHUB_APP_PRIVATE_KEY_PATH}" >/dev/null 2>&1 || { echo "GITHUB_APP_PRIVATE_KEY_PATH is not a valid private key" >&2; exit 2; }

# A Secret dry-run would print the private key as base64 YAML. There is no
# reviewable public diff, so only the guarded attended apply remains.
arc-app-secret-apply: _arc-app-secret-inputs _reviewed-clean-main _reviewed-implementation-core _arc-kubeconfig-contract _operator-apply-confirm
    #!/usr/bin/env bash
    set -euo pipefail
    core="${GF_CORE_PATH:-../GloriousFlywheel}"
    KUBECONFIG="${GFTB_ARC_KUBECONFIG}" bash "${core}/scripts/implementation-overlay-arc-secret.sh" --overlay-root . --apply

# No --allow-repo-registration-anchor: this org overlay registers ARC at the
# ORG scope, so a repo-scoped github_config_url is a contract violation here
# and fails closed.
taxonomy:
    python3 scripts/validate-overlay-runner-taxonomy.py {{ arc_tfvars }}

# Self-test the overlay taxonomy guard (incl. the RBE cache/executor wiring rule).
taxonomy-selftest:
    bash scripts/test-overlay-runner-taxonomy.sh

# Substrate-boundary conformance (TIN-2423 / ledger item 30): this overlay's
# CODE surfaces may reach the blahaj substrate only via a named interface
# recorded in config/substrate-boundary-allowlist.json. Wired into `check`
# below (the sole finding — a boundary-disclaiming comment in
# tofu/stacks/edge-dns/versions.tf that named the substrate org/repo in
# prose, not an actual code reach — was reworded so the scan reports
# 0 violations).
substrate-boundary:
    python3 scripts/validate-substrate-boundary.py

substrate-boundary-selftest:
    python3 scripts/validate-substrate-boundary.py --self-test

# Verify a registered RBE/image consumer against the three live realities GF-core
# CI cannot see (overlay tfvars anchor + RBE wiring, consumer workflow runs-on,
# live Helm-managed runner), each reusing an already-built guard. Read-only.
flywheel-enroll-verify repo="Great-Falls-Tool-Bus/great-falls-tool-bus.github.io":
    GF_CORE_PATH="{{ gf_core }}" bash scripts/flywheel-enroll-verify.sh "{{ repo }}"

# Read-only enrollment orchestrator: GF-core registry static check -> live verify
# -> operator-gated provisioning handoff. Never mutates the cluster (mirrors
# arc-enrollment-plan: sequence read-only verbs, then hand off to the operator).
flywheel-enroll repo="Great-Falls-Tool-Bus/great-falls-tool-bus.github.io":
    @python3 "{{ gf_core }}/scripts/validate-consumer-registry.py" --self-test
    @GF_CORE_PATH="{{ gf_core }}" bash scripts/flywheel-enroll-verify.sh "{{ repo }}"
    @echo ""
    @echo "Runner provisioning is operator-gated. To provision/update the scale set:"
    @echo "  GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive just arc-enrollment-plan"
    @echo "  just arc-plan-show         # review the plan (expect no unexpected destroys)"
    @echo "  just arc-plan-scope-check  # exact capacity/cutover/rollback plan only"
    @echo "  GFTB_APPLY_CONFIRM=apply GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive just arc-apply"
    @echo "  GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive just arc-capacity-readback"
    @echo "This umbrella does NOT mutate the cluster."

# GloriousFlywheel org-tenancy cache-backed Bazel proof (TIN-2364 pre-soak
# surface). Declare-only + INERT until the operator flips
# runtime_grants_enabled:true for org-great-falls-tool-bus and rolls the
# gf-reapi cell + exchange onto the org-grammar image. Exchanges this repo's
# GitHub OIDC identity for a gf-reapi-cell profile and runs a cache-backed,
# READ-ONLY Bazel round-trip routed to remote_instance_name=org-great-falls-tool-bus
# against the hermetic bazel/flywheel-proof/ genrule. Endpoint authority is
# fleet-runtime env (BAZEL_REMOTE_CACHE, GF_REAPI_TOKEN_EXCHANGE_ENDPOINT); this
# recipe bakes none and never hard-fails when they are absent. NOT part of
# `check` (it needs the on-cluster cache substrate).
flywheel-cache-proof:
    GFW_EXPECTED_INSTANCE_NAME=org-great-falls-tool-bus bash scripts/flywheel-cache-proof.sh

arc-fmt-check:
    #!/usr/bin/env bash
    # Fresh-clone friendly: use tofu from PATH when present; the GF-core nix
    # devshell is the fallback for machines without tofu installed. GF_CORE_CI_PATH
    # defaults to a pinned GitHub flake ref, not a sibling checkout.
    set -euo pipefail
    if command -v tofu >/dev/null 2>&1; then
        tofu fmt -check {{ arc_tfvars }}
    else
        nix develop "{{ gf_core_ci }}" -c tofu fmt -check {{ arc_tfvars }}
    fi

arc-validate: _reviewed-arc-core _arc-tofu-environment-contract
    #!/usr/bin/env bash
    set -euo pipefail
    core="${GF_ARC_CORE_PATH:-{{ arc_core_default }}}"
    core_ci="${GF_ARC_CORE_CI_PATH:-{{ arc_core_ci_default }}}"
    test -d "${core}/tofu/stacks/arc-runners"
    tf_data_dir="$(mktemp -d -t great-falls-tool-bus-infra-tofu-data.XXXXXX)"
    trap 'rm -rf "${tf_data_dir}"' EXIT
    TF_CLI_CONFIG_FILE=/dev/null TF_DATA_DIR="${tf_data_dir}" nix develop "${core_ci}" -c tofu -chdir="${core}/tofu/stacks/arc-runners" init -backend=false -input=false -lockfile=readonly >/dev/null
    TF_CLI_CONFIG_FILE=/dev/null TF_DATA_DIR="${tf_data_dir}" nix develop "${core_ci}" -c tofu -chdir="${core}/tofu/stacks/arc-runners" validate

arc-init: _reviewed-arc-core _arc-exclusive-confirm _arc-backend-contract _arc-runtime-contract _arc-artifact-root-contract
    #!/usr/bin/env bash
    set -euo pipefail
    core="${GF_ARC_CORE_PATH:-{{ arc_core_default }}}"
    core_ci="${GF_ARC_CORE_CI_PATH:-{{ arc_core_ci_default }}}"
    kubeconfig="${GFTB_ARC_KUBECONFIG:?Set GFTB_ARC_KUBECONFIG to the reviewed ARC kubeconfig}"
    data_dir="$(pwd)/.tofu-plans/arc-runners.tfdata"
    if [[ ! -e "${data_dir}" && ! -L "${data_dir}" ]]; then
        mkdir -m 700 "${data_dir}"
    fi
    [[ -d "${data_dir}" && ! -L "${data_dir}" ]] || { echo "ARC TF_DATA_DIR must be a real directory" >&2; exit 2; }
    backend="${ARC_BACKEND:-{{ arc_backend_default }}}"
    test -f "${backend}"
    if [[ "${backend}" != /* ]]; then
        backend="$(pwd)/${backend}"
    fi
    TF_CLI_CONFIG_FILE=/dev/null TF_VAR_k8s_config_path="${kubeconfig}" TF_DATA_DIR="${data_dir}" nix develop "${core_ci}" -c tofu -chdir="${core}/tofu/stacks/arc-runners" init -reconfigure -input=false -lockfile=readonly -backend-config="${backend}"
    workspace="$(TF_CLI_CONFIG_FILE=/dev/null TF_VAR_k8s_config_path="${kubeconfig}" TF_DATA_DIR="${data_dir}" nix develop "${core_ci}" -c tofu -chdir="${core}/tofu/stacks/arc-runners" workspace show)"
    [[ "${workspace}" == "default" ]] || { echo "ARC state must use the default workspace, observed ${workspace}" >&2; exit 2; }

arc-plan: _reviewed-clean-main _reviewed-arc-core _arc-exclusive-confirm _arc-plan-input-snapshot arc-init
    #!/usr/bin/env bash
    set -euo pipefail
    core="${GF_ARC_CORE_PATH:-{{ arc_core_default }}}"
    core_ci="${GF_ARC_CORE_CI_PATH:-{{ arc_core_ci_default }}}"
    kubeconfig="${GFTB_ARC_KUBECONFIG:?Set GFTB_ARC_KUBECONFIG to the reviewed ARC kubeconfig}"
    data_dir="$(pwd)/.tofu-plans/arc-runners.tfdata"
    backend="${ARC_BACKEND:-{{ arc_backend_default }}}"
    if [[ "${backend}" != /* ]]; then
        backend="$(pwd)/${backend}"
    fi
    umask 077
    just _arc-artifact-root-contract
    test -f .tofu-plans/arc-runners.source-sha
    test -f .tofu-plans/arc-runners.core-sha
    test -f .tofu-plans/arc-runners.backend-blob
    test -f .tofu-plans/arc-runners.kubeconfig-blob
    test -f .tofu-plans/arc-runners.cluster-uid
    test -f .tofu-plans/arc-runners.target-uid
    check_inputs() {
        [[ -z "$(git status --porcelain)" ]] || { echo "Infra worktree changed after ARC input snapshot" >&2; exit 2; }
        [[ -z "$(git -C "${core}" status --porcelain)" ]] || { echo "ARC core changed after input snapshot" >&2; exit 2; }
        test "$(git rev-parse HEAD)" = "$(tr -d '\n' < .tofu-plans/arc-runners.source-sha)" || { echo "Infra revision changed after ARC input snapshot" >&2; exit 2; }
        test "$(git -C "${core}" rev-parse HEAD)" = "$(tr -d '\n' < .tofu-plans/arc-runners.core-sha)" || { echo "ARC core revision changed after input snapshot" >&2; exit 2; }
        test "$(python3 -I -c 'import hashlib,pathlib,sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "${backend}")" = "$(tr -d '\n' < .tofu-plans/arc-runners.backend-blob)" || { echo "ARC backend changed after input snapshot" >&2; exit 2; }
        test "$(python3 -I -c 'import hashlib,pathlib,sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "${kubeconfig}")" = "$(tr -d '\n' < .tofu-plans/arc-runners.kubeconfig-blob)" || { echo "ARC kubeconfig changed after input snapshot" >&2; exit 2; }
        cluster_uid="$(kubectl --kubeconfig "${kubeconfig}" --context honey get namespace kube-system -o jsonpath='{.metadata.uid}')"
        test "${cluster_uid}" = "$(tr -d '\n' < .tofu-plans/arc-runners.cluster-uid)" || { echo "ARC target cluster changed after input snapshot" >&2; exit 2; }
        target_uid="$(kubectl --kubeconfig "${kubeconfig}" --context honey -n arc-runners get autoscalingrunnerset great-falls-tool-bus-nix -o jsonpath='{.metadata.uid}')"
        test "${target_uid}" = "$(tr -d '\n' < .tofu-plans/arc-runners.target-uid)" || { echo "ARC target cluster/release changed after input snapshot" >&2; exit 2; }
    }
    check_workspace() {
        workspace="$(TF_CLI_CONFIG_FILE=/dev/null TF_VAR_k8s_config_path="${kubeconfig}" TF_DATA_DIR="${data_dir}" nix develop "${core_ci}" -c tofu -chdir="${core}/tofu/stacks/arc-runners" workspace show)"
        [[ "${workspace}" == "default" ]] || { echo "ARC state must use the default workspace, observed ${workspace}" >&2; exit 2; }
    }
    just _reviewed-clean-main
    just _reviewed-arc-core
    just _arc-backend-contract
    just _arc-runtime-contract
    check_inputs
    check_workspace
    TF_CLI_CONFIG_FILE=/dev/null TF_VAR_k8s_config_path="${kubeconfig}" TF_DATA_DIR="${data_dir}" nix develop "${core_ci}" -c tofu -chdir="${core}/tofu/stacks/arc-runners" plan -input=false -var-file="$(pwd)/{{ arc_tfvars }}" -out="$(pwd)/.tofu-plans/arc-runners.tfplan"
    just _reviewed-clean-main
    just _reviewed-arc-core
    just _arc-backend-contract
    just _arc-runtime-contract
    check_inputs
    check_workspace
    plan_digest="$(python3 -I -c 'import hashlib,pathlib,sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' .tofu-plans/arc-runners.tfplan)"
    printf '%s\n' "${plan_digest}" > .tofu-plans/arc-runners.plan-sha256
    rm -f .tofu-plans/arc-runners.scope-sha256
    chmod 600 .tofu-plans/arc-runners.tfplan .tofu-plans/arc-runners.source-sha .tofu-plans/arc-runners.core-sha .tofu-plans/arc-runners.backend-blob .tofu-plans/arc-runners.kubeconfig-blob .tofu-plans/arc-runners.cluster-uid .tofu-plans/arc-runners.target-uid .tofu-plans/arc-runners.plan-sha256

arc-plan-show: _reviewed-arc-core _arc-tofu-environment-contract _arc-artifact-root-contract
    #!/usr/bin/env bash
    set -euo pipefail
    core="${GF_ARC_CORE_PATH:-{{ arc_core_default }}}"
    core_ci="${GF_ARC_CORE_CI_PATH:-{{ arc_core_ci_default }}}"
    data_dir="$(pwd)/.tofu-plans/arc-runners.tfdata"
    test -f .tofu-plans/arc-runners.tfplan
    TF_CLI_CONFIG_FILE=/dev/null TF_DATA_DIR="${data_dir}" nix develop "${core_ci}" -c tofu -chdir="${core}/tofu/stacks/arc-runners" show -no-color "$(pwd)/.tofu-plans/arc-runners.tfplan"

arc-plan-scope-check: _reviewed-arc-core _arc-tofu-environment-contract _arc-artifact-root-contract
    #!/usr/bin/env bash
    set -euo pipefail
    core="${GF_ARC_CORE_PATH:-{{ arc_core_default }}}"
    core_ci="${GF_ARC_CORE_CI_PATH:-{{ arc_core_ci_default }}}"
    plan_path="${GFTB_ARC_RECONCILE_PLAN_PATH:-$(pwd)/.tofu-plans/arc-runners.tfplan}"
    data_dir="${GFTB_ARC_RECONCILE_DATA_DIR:-$(pwd)/.tofu-plans/arc-runners.tfdata}"
    reconcile=false
    if [[ -n "${GFTB_ARC_RECONCILE_PLAN_PATH:-}" || -n "${GFTB_ARC_RECONCILE_DATA_DIR:-}" ]]; then
        [[ "${GFTB_ARC_READBACK_MODE:-}" == "reconcile" && -n "${GFTB_ARC_RECONCILE_PLAN_PATH:-}" && -n "${GFTB_ARC_RECONCILE_DATA_DIR:-}" ]] || { echo "Temporary ARC scope review is reserved for reconcile readback" >&2; exit 2; }
        test -f .tofu-plans/arc-runners.apply-attempted || { echo "No ambiguous ARC apply attempt requires reconciliation" >&2; exit 2; }
        reconcile=true
    else
        test -f "${plan_path}"
        test -f .tofu-plans/arc-runners.plan-sha256
        test ! -e .tofu-plans/arc-runners.apply-attempted || { echo "ARC plan was already submitted; create and review a fresh plan" >&2; exit 2; }
    fi
    python3 -I - "${reconcile}" "${plan_path}" "${data_dir}" "$(pwd)/.tofu-plans" <<'PY'
    import os
    import stat
    import sys
    from pathlib import Path

    reconcile_mode = sys.argv[1]
    if reconcile_mode not in {"true", "false"}:
        raise SystemExit("invalid ARC scope-review mode")
    if reconcile_mode == "false":
        raise SystemExit(0)
    plan_input = Path(sys.argv[2])
    data_input = Path(sys.argv[3])
    if plan_input.is_symlink() or data_input.is_symlink():
        raise SystemExit("reconcile plan and TF_DATA_DIR may not be symlinks")
    plan = plan_input.resolve(strict=True)
    data = data_input.resolve(strict=True)
    root = Path(sys.argv[4]).resolve(strict=True)
    if plan.parent != data.parent or plan.parent.parent != root or not plan.parent.name.startswith("arc-readback."):
        raise SystemExit("reconcile plan and TF_DATA_DIR must share a private arc-readback directory")
    plan_stat = plan.lstat()
    data_stat = data.lstat()
    if not stat.S_ISREG(plan_stat.st_mode) or stat.S_ISLNK(plan_stat.st_mode) or plan_stat.st_uid != os.getuid() or stat.S_IMODE(plan_stat.st_mode) != 0o600:
        raise SystemExit("reconcile plan must be an operator-owned mode-0600 regular file")
    if not stat.S_ISDIR(data_stat.st_mode) or stat.S_ISLNK(data_stat.st_mode) or data_stat.st_uid != os.getuid() or stat.S_IMODE(data_stat.st_mode) != 0o700:
        raise SystemExit("reconcile TF_DATA_DIR must be an operator-owned mode-0700 directory")
    PY
    plan_digest="$(python3 -I -c 'import hashlib,pathlib,sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "${plan_path}")"
    if [[ "${reconcile}" == "false" ]]; then
        test "${plan_digest}" = "$(tr -d '\n' < .tofu-plans/arc-runners.plan-sha256)" || { echo "ARC plan digest changed before scope review" >&2; exit 2; }
    fi
    plan_json="$(mktemp "${TMPDIR:-/tmp}/gftb-arc-plan.XXXXXX.json")"
    trap 'rm -f "${plan_json}"' EXIT
    TF_CLI_CONFIG_FILE=/dev/null TF_DATA_DIR="${data_dir}" nix develop "${core_ci}" -c tofu -chdir="${core}/tofu/stacks/arc-runners" show -json "${plan_path}" > "${plan_json}"
    python3 -I - "${plan_json}" <<'PY'
    import json
    import re
    import sys
    from pathlib import Path

    plan = json.loads(Path(sys.argv[1]).read_text())
    if not isinstance(plan, dict):
        raise SystemExit("ERROR: ARC plan JSON must be an object")
    if plan.get("format_version") != "1.2":
        raise SystemExit("ERROR: ARC plan format_version must be exactly 1.2")
    if plan.get("terraform_version") != "1.11.6":
        raise SystemExit("ERROR: ARC plan terraform_version must be exactly 1.11.6")
    if plan.get("errored") is not False:
        raise SystemExit("ERROR: ARC plan errored must be exactly false")
    top_level_fields = {
        "format_version",
        "terraform_version",
        "variables",
        "planned_values",
        "resource_drift",
        "resource_changes",
        "output_changes",
        "prior_state",
        "configuration",
        "relevant_attributes",
        "checks",
        "timestamp",
        "errored",
    }
    unexpected_top_level_fields = sorted(set(plan) - top_level_fields)
    if unexpected_top_level_fields:
        raise SystemExit(
            "ERROR: ARC plan contains fields outside the pinned OpenTofu schema: "
            + repr(unexpected_top_level_fields)
        )
    resource_drift = plan.get("resource_drift", [])
    if not isinstance(resource_drift, list):
        raise SystemExit("ERROR: ARC plan resource_drift must be a list")
    if not all(isinstance(change, dict) for change in resource_drift):
        raise SystemExit("ERROR: every ARC resource_drift entry must be an object")
    if resource_drift:
        raise SystemExit(
            "ERROR: ARC plan contains resource drift: "
            + repr([change.get("address") for change in resource_drift])
        )

    # ---------------------------------------------------------------------------
    # Enumerated ARC scope contract (TIN-2299 capacity + TIN-3902 runner group).
    #
    # Three plans are admitted and nothing else. Every address, action, output
    # name, Helm `set` entry, and Helm-values byte is enumerated; there are no
    # wildcards and no "allow anything under this prefix" escape.
    #
    #   capacity  1 in-place gh_nix Helm update whose only values delta is the
    #             runner container ephemeral-storage 4Gi->8Gi / 8Gi->16Gi bump.
    #   cutover   the runner-group move: 1 in-place gh_nix Helm update
    #             (runnerGroup set entry, runner image digest, the
    #             GF_FLYWHEEL_PROFILE_STATE env pair, template.spec
    #             priorityClassName) and 1 create of the state-only
    #             terraform_data.runner_group_policy receipt. Its storage
    #             transition is one of exactly two: 4/8Gi -> 8/16Gi (the
    #             original combined shape, cutover carrying the capacity bump)
    #             or 8/16Gi -> 8/16Gi with zero storage delta (the decomposed
    #             shape; see the operational note below).
    #   rollback  the exact byte-for-byte reverse of `cutover`: the same Helm
    #             update inverted plus 1 destroy of the policy receipt, with
    #             the correspondingly admitted storage transitions
    #             8/16Gi -> 4/8Gi or 8/16Gi -> 8/16Gi.
    #
    # Operational fact this code cannot show: the TIN-2299 capacity bump was
    # applied on 2026-08-17 as helm_release great-falls-tool-bus-nix revision 6
    # with runnerGroup still `default`, decomposing TIN-3902's combined cutover.
    # The live pre-cutover state is therefore already 8/16Gi, so a fresh cutover
    # plan (and the ratified rollback fallback from the post-cutover state)
    # carries no storage delta. Each shape admits both storage transitions and
    # nothing in between: mixed states are refused, and the group-move deltas
    # stay byte-strict either way.
    #
    # Any capacity, roster, image, or module-pin change beyond these requires its
    # own reviewed scope-contract update. This guard fails closed.
    # ---------------------------------------------------------------------------
    HELM_ADDRESS = "module.gh_nix.helm_release.arc_runner"
    POLICY_ADDRESS = "terraform_data.runner_group_policy"
    DEFAULT_RUNNER_GROUP = "default"
    DEDICATED_RUNNER_GROUP = "great-falls-tool-bus-infra"
    RUNNER_IMAGE_LOW = (
        "ghcr.io/tinyland-inc/actions-runner-nix@sha256:"
        "086a6c5553f21a5ef59256ebe8fbf2d7b6bbf486def1d0f5ed1c05dcbdab084e"
    )
    RUNNER_IMAGE_HIGH = (
        "ghcr.io/tinyland-inc/actions-runner-nix@sha256:"
        "1ccce66d92dadecb648ea5c509a4806bf319b73e9730828e234c19670325397b"
    )
    PROFILE_STATE_ENV_NAME = "GF_FLYWHEEL_PROFILE_STATE"
    PROFILE_STATE_ENV_VALUE = "shared-cache-backed"
    RUNNER_PRIORITY_CLASS = "arc-runner"
    LOW_STORAGE = {"requests": "4Gi", "limits": "8Gi"}
    HIGH_STORAGE = {"requests": "8Gi", "limits": "16Gi"}
    # Root outputs the advanced ARC role pin adds. They are pure source-derived
    # receipts: creating or destroying them mutates nothing outside tofu state.
    RUNNER_GROUP_OUTPUTS = {
        "dind_runner_group": "",
        "docker_runner_group": "",
        "extra_runner_groups": {},
        "nix_runner_group": DEDICATED_RUNNER_GROUP,
        "overlay_tenant_legacy_shared_grant_owners": [],
        "tofu_plan_cluster_role": "",
        "tofu_plan_secret_read_namespaces": [],
        "tofu_plan_service_account": "",
        "tofu_plan_token_secret": "",
    }
    POLICY_INPUT = {
        "legacy_expires": "",
        "legacy_reason": "",
        "legacy_receipt": {},
        "policy": "organization-restricted",
        "scale_sets": [
            {"group": DEDICATED_RUNNER_GROUP, "name": "great-falls-tool-bus-nix"}
        ],
    }
    POLICY_OPAQUE_MASK = {"legacy_receipt": {}, "scale_sets": [{}]}


    def canonical(value):
        return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


    all_changes = plan.get("resource_changes", [])
    if not isinstance(all_changes, list):
        raise SystemExit("ERROR: ARC plan resource_changes must be a list")
    for index, resource in enumerate(all_changes):
        if not isinstance(resource, dict):
            raise SystemExit(f"ERROR: ARC resource_changes[{index}] must be an object")
        resource_change = resource.get("change", {})
        if not isinstance(resource_change, dict):
            raise SystemExit(f"ERROR: ARC resource_changes[{index}].change must be an object")
        actions = resource_change.get("actions")
        if not isinstance(actions, list) or not actions or not all(isinstance(action, str) for action in actions):
            raise SystemExit(f"ERROR: ARC resource_changes[{index}] must carry concrete actions")
        forbidden_metadata = []
        for owner, key in (
            (resource, "previous_address"),
            (resource, "deposed"),
            (resource, "generated_config"),
            (resource_change, "importing"),
            (resource_change, "generated_config"),
        ):
            if key in owner and owner[key] not in (None, ""):
                forbidden_metadata.append(key)
        if forbidden_metadata:
            raise SystemExit(
                "ERROR: ARC plan contains move/import/deposed/generated metadata on "
                + repr(resource.get("address"))
                + ": "
                + repr(sorted(set(forbidden_metadata)))
            )
        # Mirror the output-Change rule. Entries claiming no-op are dropped from
        # `changes` below and never inspected again, so without this a real diff
        # could ride into the apply under a no-op label. OpenTofu derives actions
        # from the diff and the plan is digest-pinned either side of this review,
        # so this is defense in depth -- but the contract above says every action
        # is enumerated, and this is the one place that would not have been.
        if actions == ["no-op"] and canonical(resource_change.get("before")) != canonical(
            resource_change.get("after")
        ):
            raise SystemExit(
                "ERROR: ARC plan contains a no-op resource change that modifies "
                + repr(resource.get("address"))
            )
    changes = [
        change
        for change in all_changes
        if change.get("change", {}).get("actions", ["no-op"]) != ["no-op"]
    ]
    observed = [
        (
            change.get("address"),
            change.get("mode"),
            change.get("type"),
            change.get("name"),
            change.get("change", {}).get("actions", []),
        )
        for change in changes
    ]
    helm_update = (HELM_ADDRESS, "managed", "helm_release", "arc_runner", ["update"])
    policy_create = (
        POLICY_ADDRESS,
        "managed",
        "terraform_data",
        "runner_group_policy",
        ["create"],
    )
    policy_delete = (
        POLICY_ADDRESS,
        "managed",
        "terraform_data",
        "runner_group_policy",
        ["delete"],
    )
    admitted_shapes = (
        ("capacity", [helm_update]),
        ("cutover", [policy_create, helm_update]),
        ("rollback", [policy_delete, helm_update]),
    )
    shape = None
    for candidate, expected in admitted_shapes:
        if observed == expected:
            shape = candidate
            break
    if shape is None:
        print(
            "ERROR: ARC plan must be exactly one enumerated reviewed shape - the "
            "gh_nix capacity update, the runner-group cutover, or its rollback; "
            "observed " + repr(observed),
            file=sys.stderr,
        )
        print(
            "Land a separate reviewed ARC scope contract before applying any other plan.",
            file=sys.stderr,
        )
        sys.exit(1)

    output_changes = plan.get("output_changes", {})
    if not isinstance(output_changes, dict):
        raise SystemExit("ERROR: ARC plan output_changes must be an object")
    output_fields = {
        "actions",
        "before",
        "after",
        "after_unknown",
        "before_sensitive",
        "after_sensitive",
    }
    if shape == "capacity":
        expected_output_actions = {}
    elif shape == "cutover":
        expected_output_actions = dict.fromkeys(RUNNER_GROUP_OUTPUTS, "create")
    else:
        expected_output_actions = dict.fromkeys(RUNNER_GROUP_OUTPUTS, "delete")
    observed_output_actions = {}
    for output_name, output in output_changes.items():
        if not isinstance(output_name, str) or not output_name:
            raise SystemExit("ERROR: every ARC output_changes name must be a nonempty string")
        if not isinstance(output, dict):
            raise SystemExit("ERROR: every ARC output_changes value must be an object")
        observed_fields = set(output)
        if observed_fields != output_fields:
            raise SystemExit(
                "ERROR: ARC output Change fields must be exact for "
                + repr(output_name)
                + "; missing="
                + repr(sorted(output_fields - observed_fields))
                + ", unexpected="
                + repr(sorted(observed_fields - output_fields))
            )
        if output["after_unknown"] is not False:
            raise SystemExit(
                "ERROR: ARC output Change contains unknown after-values for "
                + repr(output_name)
            )
        if not isinstance(output["before_sensitive"], bool) or not isinstance(output["after_sensitive"], bool):
            raise SystemExit(
                "ERROR: ARC output Change has an invalid sensitive-field shape for "
                + repr(output_name)
            )
        expected_action = expected_output_actions.get(output_name)
        if output["actions"] == ["no-op"]:
            if output["before_sensitive"] != output["after_sensitive"]:
                raise SystemExit(
                    "ERROR: ARC output Change changes sensitive-field shape for "
                    + repr(output_name)
                )
            if canonical(output["before"]) != canonical(output["after"]):
                raise SystemExit(
                    "ERROR: ARC output Change modifies the value for " + repr(output_name)
                )
            continue
        if expected_action is None or output["actions"] != [expected_action]:
            raise SystemExit(
                "ERROR: ARC output Change must have exactly no-op actions for "
                + repr(output_name)
            )
        if output["before_sensitive"] is not False or output["after_sensitive"] is not False:
            raise SystemExit(
                "ERROR: ARC runner-group output Change must be non-sensitive for "
                + repr(output_name)
            )
        reviewed = canonical(RUNNER_GROUP_OUTPUTS[output_name])
        if expected_action == "create":
            materialized, absent = output["after"], output["before"]
        else:
            materialized, absent = output["before"], output["after"]
        if absent is not None or canonical(materialized) != reviewed:
            raise SystemExit(
                "ERROR: ARC runner-group output Change must "
                + expected_action
                + " the reviewed value "
                + reviewed
                + " for "
                + repr(output_name)
            )
        observed_output_actions[output_name] = expected_action
    if observed_output_actions != expected_output_actions:
        raise SystemExit(
            "ERROR: ARC plan must change exactly the reviewed runner-group outputs; "
            "missing="
            + repr(sorted(set(expected_output_actions) - set(observed_output_actions)))
            + ", unexpected="
            + repr(sorted(set(observed_output_actions) - set(expected_output_actions)))
        )

    resource_change_fields = {
        "actions",
        "before",
        "after",
        "after_unknown",
        "before_sensitive",
        "after_sensitive",
    }
    by_address = {change.get("address"): change for change in changes}


    def check_policy_receipt(resource):
        change = resource.get("change", {})
        observed_fields = set(change)
        extra_fields = observed_fields - resource_change_fields - {"replace_paths"}
        if extra_fields:
            raise SystemExit(
                "ERROR: ARC runner-group policy Change carries unexpected fields: "
                + repr(sorted(extra_fields))
            )
        if change.get("replace_paths"):
            raise SystemExit("ERROR: ARC runner-group policy plan contains replacement paths")
        creating = change.get("actions") == ["create"]
        if creating:
            if change.get("before") is not None or change.get("before_sensitive") is not False:
                raise SystemExit("ERROR: ARC runner-group policy create must have no prior state")
            if canonical(change.get("after")) != canonical(
                {"input": POLICY_INPUT, "triggers_replace": None}
            ):
                raise SystemExit(
                    "ERROR: ARC runner-group policy create must record exactly the reviewed "
                    "organization-restricted receipt"
                )
            if canonical(change.get("after_unknown")) != canonical(
                {"id": True, "input": POLICY_OPAQUE_MASK, "output": True}
            ):
                raise SystemExit(
                    "ERROR: ARC runner-group policy create has an unexpected unknown mask"
                )
            if canonical(change.get("after_sensitive")) != canonical(
                {"input": POLICY_OPAQUE_MASK, "output": {}}
            ):
                raise SystemExit(
                    "ERROR: ARC runner-group policy create has an unexpected sensitive mask"
                )
            if "action_reason" in resource:
                raise SystemExit(
                    "ERROR: ARC runner-group policy create must carry no action_reason"
                )
            return
        if resource.get("action_reason") != "delete_because_no_resource_config":
            raise SystemExit(
                "ERROR: ARC runner-group policy destroy is admitted only as "
                "delete_because_no_resource_config; observed "
                + repr(resource.get("action_reason"))
            )
        if change.get("after") is not None or change.get("after_sensitive") is not False:
            raise SystemExit("ERROR: ARC runner-group policy destroy must have no planned state")
        if canonical(change.get("after_unknown")) != canonical({}):
            raise SystemExit(
                "ERROR: ARC runner-group policy destroy has an unexpected unknown mask"
            )
        if canonical(change.get("before_sensitive")) != canonical(
            {"input": POLICY_OPAQUE_MASK, "output": POLICY_OPAQUE_MASK}
        ):
            raise SystemExit(
                "ERROR: ARC runner-group policy destroy has an unexpected sensitive mask"
            )
        before_state = change.get("before")
        if not isinstance(before_state, dict) or set(before_state) != {
            "id",
            "input",
            "output",
            "triggers_replace",
        }:
            raise SystemExit(
                "ERROR: ARC runner-group policy destroy must expose the exact prior receipt fields"
            )
        if not isinstance(before_state["id"], str) or not before_state["id"]:
            raise SystemExit("ERROR: ARC runner-group policy destroy must carry a concrete id")
        if before_state["triggers_replace"] is not None:
            raise SystemExit(
                "ERROR: ARC runner-group policy destroy must carry no replacement trigger"
            )
        reviewed = canonical(POLICY_INPUT)
        if canonical(before_state["input"]) != reviewed or canonical(before_state["output"]) != reviewed:
            raise SystemExit(
                "ERROR: ARC runner-group policy destroy must retire exactly the reviewed "
                "organization-restricted receipt"
            )


    if shape != "capacity":
        check_policy_receipt(by_address[POLICY_ADDRESS])

    change = by_address[HELM_ADDRESS]["change"]
    if change.get("replace_paths"):
        raise SystemExit("ERROR: ARC capacity plan unexpectedly contains replacement paths")


    def sensitive_true_paths(value, mask_name, path=()):
        if isinstance(value, bool):
            return {path} if value else set()
        if isinstance(value, dict):
            paths = set()
            for key, item in value.items():
                paths.update(sensitive_true_paths(item, mask_name, path + (key,)))
            return paths
        if isinstance(value, list):
            paths = set()
            for index, item in enumerate(value):
                paths.update(sensitive_true_paths(item, mask_name, path + (index,)))
            return paths
        raise SystemExit(
            "ERROR: ARC capacity plan contains a non-Boolean sensitive-field leaf in "
            + mask_name
        )


    expected_sensitive_true_paths = {("repository_password",)}
    for mask_name in ("before_sensitive", "after_sensitive"):
        true_paths = sensitive_true_paths(change.get(mask_name), mask_name)
        if true_paths != expected_sensitive_true_paths:
            raise SystemExit(
                "ERROR: ARC capacity plan must mark exactly repository_password "
                "as sensitive in "
                + mask_name
            )
    before = change.get("before")
    after = change.get("after")
    after_unknown = change.get("after_unknown") or {}
    if not isinstance(before, dict) or not isinstance(after, dict):
        raise SystemExit("ERROR: ARC capacity plan must expose concrete before/after values")
    if not isinstance(after_unknown, dict):
        raise SystemExit("ERROR: ARC capacity plan after_unknown must be an object")


    def has_unknown(value):
        if value is True:
            return True
        if isinstance(value, dict):
            return any(has_unknown(item) for item in value.values())
        if isinstance(value, list):
            return any(has_unknown(item) for item in value)
        return False


    unknown_keys = {key for key, value in after_unknown.items() if has_unknown(value)}
    allowed_computed_unknowns = {"manifest", "metadata", "status"}
    if not unknown_keys <= allowed_computed_unknowns:
        raise SystemExit(
            "ERROR: ARC capacity plan contains unexpected unknown after-values: "
            + repr(sorted(unknown_keys - allowed_computed_unknowns))
        )
    # `set` carries runnerGroup, so the cutover and its rollback review it against
    # an enumerated one-entry delta instead of requiring byte equality.
    values_scoped_keys = {"values"} if shape == "capacity" else {"values", "set"}
    changed_known = []
    for key in sorted(set(before) | set(after)):
        if key in values_scoped_keys or key in unknown_keys:
            continue
        if before.get(key) != after.get(key):
            changed_known.append(key)
    if changed_known:
        raise SystemExit(
            "ERROR: gh_nix Helm plan changes fields outside values: "
            + ", ".join(changed_known)
        )

    if shape != "capacity":
        before_set = before.get("set")
        after_set = after.get("set")
        if not (
            isinstance(before_set, list)
            and isinstance(after_set, list)
            and len(before_set) == len(after_set)
        ):
            raise SystemExit("ERROR: gh_nix Helm set blocks must be two aligned lists")
        for entries in (before_set, after_set):
            if not all(isinstance(entry, dict) for entry in entries):
                raise SystemExit("ERROR: every gh_nix Helm set entry must be an object")
            if len([entry for entry in entries if entry.get("name") == "runnerGroup"]) != 1:
                raise SystemExit("ERROR: gh_nix Helm set must carry exactly one runnerGroup entry")
        if shape == "cutover":
            group_from, group_to = DEFAULT_RUNNER_GROUP, DEDICATED_RUNNER_GROUP
        else:
            group_from, group_to = DEDICATED_RUNNER_GROUP, DEFAULT_RUNNER_GROUP
        observed_set_delta = [
            (was, now) for was, now in zip(before_set, after_set) if was != now
        ]
        expected_set_delta = [
            (
                {"name": "runnerGroup", "type": "", "value": group_from},
                {"name": "runnerGroup", "type": "", "value": group_to},
            )
        ]
        if observed_set_delta != expected_set_delta:
            raise SystemExit(
                "ERROR: gh_nix Helm set must change exactly runnerGroup "
                + repr(group_from)
                + " -> "
                + repr(group_to)
                + "; observed "
                + repr(observed_set_delta)
            )

    before_values = before.get("values")
    after_values = after.get("values")
    if not (
        isinstance(before_values, list)
        and isinstance(after_values, list)
        and len(before_values) == 1
        and len(after_values) == 1
        and isinstance(before_values[0], str)
        and isinstance(after_values[0], str)
    ):
        raise SystemExit("ERROR: gh_nix Helm values must be one concrete YAML document")

    storage = re.compile(
        r'(?m)^(?P<prefix>\s*"?ephemeral-storage"?\s*:\s*)'
        r'(?P<quote>"?)(?P<value>[0-9]+Gi)(?P=quote)(?P<suffix>\s*)$'
    )


    def indentation(line):
        return len(line) - len(line.lstrip(" "))


    def header(line):
        match = re.match(r'^\s*"?([A-Za-z0-9_-]+)"?\s*:\s*$', line)
        return match.group(1) if match else None


    def parent_header(lines, index):
        child_indent = indentation(lines[index])
        for cursor in range(index - 1, -1, -1):
            if not lines[cursor].strip() or lines[cursor].lstrip().startswith("#"):
                continue
            if indentation(lines[cursor]) < child_indent:
                return cursor, header(lines[cursor])
        return None, None


    def runner_container(lines):
        name_lines = [
            index
            for index, line in enumerate(lines)
            if re.match(r'^\s*"?name"?\s*:\s*"?runner"?\s*$', line)
        ]
        if len(name_lines) != 1:
            raise SystemExit("ERROR: ARC Helm values must contain one runner container")
        name_index = name_lines[0]
        name_indent = indentation(lines[name_index])
        item_start = None
        item_indent = None
        for cursor in range(name_index - 1, -1, -1):
            match = re.match(r'^(\s*)-\s+', lines[cursor])
            if match and len(match.group(1)) < name_indent:
                item_start = cursor
                item_indent = len(match.group(1))
                break
        if item_start is None:
            raise SystemExit("ERROR: runner container is not a YAML list item")
        container_header = None
        container_header_index = None
        for cursor in range(item_start - 1, -1, -1):
            if indentation(lines[cursor]) <= item_indent and header(lines[cursor]):
                container_header = header(lines[cursor])
                container_header_index = cursor
                break
        if container_header != "containers":
            raise SystemExit("ERROR: runner item is not under template.spec.containers")
        spec_index, spec_header = parent_header(lines, container_header_index)
        _, template_header = parent_header(lines, spec_index)
        if spec_header != "spec" or template_header != "template":
            raise SystemExit("ERROR: runner item is not under template.spec.containers")
        item_end = len(lines)
        for cursor in range(item_start + 1, len(lines)):
            line = lines[cursor]
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if indentation(line) <= item_indent:
                item_end = cursor
                break
        return item_start, item_end, name_indent, spec_index


    def runner_storage(document):
        lines = document.splitlines()
        item_start, item_end, name_indent, _ = runner_container(lines)
        entries = {}
        resources_indexes = set()
        all_storage_lines = []
        for index, line in enumerate(lines):
            match = storage.match(line)
            if not match:
                continue
            all_storage_lines.append(index)
            if not item_start <= index < item_end:
                raise SystemExit("ERROR: ephemeral-storage exists outside the runner container")
            parent_index, parent = parent_header(lines, index)
            grandparent_index, grandparent = parent_header(lines, parent_index)
            if grandparent != "resources" or parent not in {"requests", "limits"}:
                raise SystemExit("ERROR: runner ephemeral-storage is outside resources requests/limits")
            if indentation(lines[grandparent_index]) != name_indent:
                raise SystemExit("ERROR: resources must be a direct runner-container field")
            resources_indexes.add(grandparent_index)
            if parent in entries:
                raise SystemExit("ERROR: duplicate runner ephemeral-storage field")
            entries[parent] = match.group("value")
        if len(all_storage_lines) != 2 or set(entries) != {"requests", "limits"} or len(resources_indexes) != 1:
            raise SystemExit("ERROR: expected exactly runner request and limit storage fields")
        return entries


    def restore_pre_cutover(document, demote_storage):
        """Invert every enumerated runner-group delta, byte for byte.

        The result must equal the pre-cutover document exactly, which is what makes
        the cutover and its rollback the same reviewed transaction read in opposite
        directions.

        `demote_storage` selects which of the two admitted pre-cutover documents
        to reconstruct. True inverts the ephemeral-storage bump too (the original
        combined shape, pre-cutover at 4/8Gi). False leaves storage untouched:
        TIN-2299's capacity bump applied on 2026-08-17 as helm_release revision 6
        while runnerGroup stayed `default`, so the decomposed cutover starts from
        8/16Gi and must carry zero storage delta. The caller derives the flag
        from the storage transition already asserted against the enumerated pair.

        This is not injective, and that is accepted. The pre-image is exactly
        "the pre-cutover document plus the three reviewed lines inserted at any
        anchor-valid position", because the anchors below fix each line's PARENT
        but not its index among that parent's siblings: priorityClassName may sit
        anywhere directly under the same template.spec that owns the runner
        container, and the env pair anywhere directly under that container's env.
        Every such variant renders the identical Kubernetes object -- YAML mapping
        order is not semantic, and env-list order matters only for $(VAR)
        expansion, which these rendered values do not use. Duplicate or extra env
        names, a relocated parent, and any other line are all still refused.
        """
        if not document.endswith("\n") or "\n".join(document.splitlines()) + "\n" != document:
            raise SystemExit("ERROR: ARC Helm values must be newline-terminated LF text")
        lines = document.splitlines()
        item_start, item_end, name_indent, spec_index = runner_container(lines)

        image_lines = [
            index
            for index, line in enumerate(lines)
            if re.match(r'^\s*"?image"?\s*:\s*\S+\s*$', line)
        ]
        if len(image_lines) != 1:
            raise SystemExit("ERROR: ARC Helm values must contain one runner image reference")
        image_index = image_lines[0]
        if not item_start <= image_index < item_end or indentation(lines[image_index]) != name_indent:
            raise SystemExit("ERROR: runner image is not a direct runner-container field")
        if lines[image_index].count(RUNNER_IMAGE_HIGH) != 1:
            raise SystemExit(
                "ERROR: runner image must be exactly the reviewed advanced ARC role-pin digest"
            )

        priority_lines = [
            index
            for index, line in enumerate(lines)
            if re.match(
                r'^\s*"?priorityClassName"?\s*:\s*"?' + re.escape(RUNNER_PRIORITY_CLASS) + r'"?\s*$',
                line,
            )
        ]
        if len(priority_lines) != 1:
            raise SystemExit(
                "ERROR: ARC Helm values must contain one arc-runner priorityClassName"
            )
        priority_index = priority_lines[0]
        parent_index, parent = parent_header(lines, priority_index)
        _, grandparent = parent_header(lines, parent_index)
        if parent != "spec" or grandparent != "template" or parent_index != spec_index:
            raise SystemExit("ERROR: priorityClassName is not a direct template.spec field")

        env_lines = [
            index
            for index, line in enumerate(lines)
            if re.match(
                r'^\s*-\s+"?name"?\s*:\s*"?' + re.escape(PROFILE_STATE_ENV_NAME) + r'"?\s*$',
                line,
            )
        ]
        if len(env_lines) != 1:
            raise SystemExit(
                "ERROR: ARC Helm values must contain one GF_FLYWHEEL_PROFILE_STATE env entry"
            )
        env_index = env_lines[0]
        if not item_start <= env_index < item_end:
            raise SystemExit(
                "ERROR: GF_FLYWHEEL_PROFILE_STATE is outside the runner container"
            )
        env_indent = indentation(lines[env_index])
        env_parent = None
        env_parent_index = None
        for cursor in range(env_index - 1, -1, -1):
            if indentation(lines[cursor]) <= env_indent and header(lines[cursor]):
                env_parent = header(lines[cursor])
                env_parent_index = cursor
                break
        if env_parent != "env" or env_parent_index is None or indentation(lines[env_parent_index]) != name_indent:
            raise SystemExit(
                "ERROR: GF_FLYWHEEL_PROFILE_STATE is not a direct runner-container env entry"
            )
        if env_parent_index < item_start:
            raise SystemExit(
                "ERROR: GF_FLYWHEEL_PROFILE_STATE is outside the runner container"
            )
        value_index = env_index + 1
        if value_index >= item_end or not re.match(
            r'^\s*"?value"?\s*:\s*"?' + re.escape(PROFILE_STATE_ENV_VALUE) + r'"?\s*$',
            lines[value_index],
        ):
            raise SystemExit(
                "ERROR: GF_FLYWHEEL_PROFILE_STATE must be exactly a shared-cache-backed pair"
            )
        if indentation(lines[value_index]) != indentation(lines[env_index]) + 2:
            raise SystemExit(
                "ERROR: GF_FLYWHEEL_PROFILE_STATE value is not part of its own env entry"
            )

        dropped = {priority_index, env_index, value_index}
        kept = [
            line.replace(RUNNER_IMAGE_HIGH, RUNNER_IMAGE_LOW)
            if index == image_index
            else line
            for index, line in enumerate(lines)
            if index not in dropped
        ]
        restored = "\n".join(kept) + "\n"
        if not demote_storage:
            return restored
        demote = {"8Gi": "4Gi", "16Gi": "8Gi"}
        return storage.sub(
            lambda match: (
                match.group("prefix")
                + match.group("quote")
                + demote[match.group("value")]
                + match.group("quote")
                + match.group("suffix")
            ),
            restored,
        )


    before_storage = runner_storage(before_values[0])
    after_storage = runner_storage(after_values[0])
    # TIN-2299's capacity bump applied on 2026-08-17 as helm_release revision 6
    # (runnerGroup still `default`), decomposing TIN-3902's combined cutover, so
    # the move shapes each admit exactly two storage transitions: the original
    # combined one and the post-capacity zero-delta one. The capacity shape is
    # unchanged. Anything else -- including mixed states such as 8Gi/8Gi on
    # either side -- is refused here before the byte-level document comparison.
    if shape == "rollback":
        admitted_storage = (
            (HIGH_STORAGE, LOW_STORAGE),
            (HIGH_STORAGE, HIGH_STORAGE),
        )
    elif shape == "cutover":
        admitted_storage = (
            (LOW_STORAGE, HIGH_STORAGE),
            (HIGH_STORAGE, HIGH_STORAGE),
        )
    else:
        admitted_storage = ((LOW_STORAGE, HIGH_STORAGE),)
    if (before_storage, after_storage) not in admitted_storage:
        raise SystemExit(
            "ERROR: expected runner resources.requests/resources.limits "
            "ephemeral-storage to move as one of "
            + " or ".join(
                was["requests"]
                + "/"
                + was["limits"]
                + "->"
                + now["requests"]
                + "/"
                + now["limits"]
                for was, now in admitted_storage
            )
            + "; observed "
            + before_storage["requests"]
            + "/"
            + before_storage["limits"]
            + "->"
            + after_storage["requests"]
            + "/"
            + after_storage["limits"]
        )
    storage_delta = before_storage != after_storage

    if shape == "capacity":
        promote = {"4Gi": "8Gi", "8Gi": "16Gi"}
        expected_values = storage.sub(
            lambda match: (
                match.group("prefix")
                + match.group("quote")
                + promote[match.group("value")]
                + match.group("quote")
                + match.group("suffix")
            ),
            before_values[0],
        )
        if expected_values != after_values[0]:
            raise SystemExit("ERROR: gh_nix Helm values contain changes beyond 4/8Gi -> 8/16Gi")
        print("ARC plan scope guard passed: exact gh_nix 4/8Gi -> 8/16Gi update only.")
    elif shape == "cutover":
        if restore_pre_cutover(after_values[0], storage_delta) != before_values[0]:
            raise SystemExit(
                "ERROR: gh_nix Helm values contain changes beyond the reviewed runner-group "
                "cutover (runnerGroup, the admitted ephemeral-storage transition, "
                "pinned runner image digest, GF_FLYWHEEL_PROFILE_STATE, "
                "arc-runner priorityClassName)"
            )
        print(
            "ARC plan scope guard passed: exact gh_nix runner-group cutover update "
            "plus the state-only runner_group_policy receipt."
        )
    else:
        if restore_pre_cutover(before_values[0], storage_delta) != after_values[0]:
            raise SystemExit(
          …30381 tokens truncated…ody validation")
    if not raw.is_absolute() or raw.is_symlink():
        raise SystemExit("WEB_RELEASE_KUBECONFIG must be an absolute non-symlink path")
    path = raw.resolve(strict=True)
    try:
        path.relative_to(repo)
    except ValueError:
        pass
    else:
        raise SystemExit("WEB_RELEASE_KUBECONFIG must remain outside the public repository")
    expected = path.stat()
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    source_fd = os.open(raw, flags)
    metadata = os.fstat(source_fd)
    if (metadata.st_dev, metadata.st_ino) != (expected.st_dev, expected.st_ino):
        os.close(source_fd)
        raise SystemExit("WEB_RELEASE_KUBECONFIG changed during custody validation")
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_nlink != 1:
        os.close(source_fd)
        raise SystemExit("WEB_RELEASE_KUBECONFIG must be a regular file owned by the operator")
    if stat.S_IMODE(metadata.st_mode) != 0o600:
        os.close(source_fd)
        raise SystemExit("WEB_RELEASE_KUBECONFIG must have mode 0600")
    destination_fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    digest = hashlib.sha256()
    with os.fdopen(source_fd, "rb") as source, os.fdopen(destination_fd, "wb") as target:
        while chunk := source.read(131072):
            digest.update(chunk)
            target.write(chunk)
        target.flush()
        os.fsync(target.fileno())
    print(digest.hexdigest())
    PY
    )"
    kube_contract_receipt="$(env -i PATH="${PATH}" HOME="${proof_dir}/home" WEB_RELEASE_KUBECONFIG="${release_kubeconfig}" just --justfile "${repo_root}/Justfile" --working-directory "${repo_root}" _web-release-kubeconfig-inputs)"
    [[ "${kube_contract_receipt}" =~ ^reviewed\ stable\ web\ release-object\ mutation\ denial:\ Honey/greatfallstoolbus-org-production\ authority=([0-9a-f]{64})$ ]] || { echo "WEB_RELEASE_KUBECONFIG helper returned an invalid authority receipt" >&2; exit 2; }
    authority_digest="${BASH_REMATCH[1]}"
    kubectl_clean() {
      env -i PATH="${PATH}" HOME="${proof_dir}/home" kubectl --kubeconfig "${release_kubeconfig}" "$@"
    }
    current_auth_decision() {
      local output status error_file="${proof_dir}/current-auth.stderr"
      : > "${error_file}"
      set +e
      output="$(kubectl_clean "$@" 2>"${error_file}")"
      status=$?
      set -e
      if [[ -s "${error_file}" ]]; then
        echo "Kubernetes named-object authorization review returned diagnostics" >&2
        return 2
      fi
      rm -f "${error_file}"
      if [[ "${status}" -eq 0 && "${output}" == "yes" ]]; then
        printf 'yes\n'
      elif [[ "${status}" -eq 1 && "${output}" == "no" ]]; then
        printf 'no\n'
      else
        echo "Kubernetes named-object authorization review returned an unexpected result" >&2
        return 2
      fi
    }
    deny_current_base_mutation() {
      local resource="$1" resource_name="$2" verb decision
      for verb in update patch delete; do
        decision="$(current_auth_decision auth can-i "${verb}" "${resource}/${resource_name}" --namespace {{ web_stack_ns }})" || return 2
        [[ "${decision}" == "no" ]] || { echo "WEB_RELEASE_KUBECONFIG can mutate observed release object ${resource}/${resource_name} (${verb})" >&2; return 2; }
      done
    }
    deny_current_subresource_access() {
      local resource="$1" resource_name="$2" subresource="$3" verbs="$4" verb decision
      local -a verb_list
      read -r -a verb_list <<<"${verbs}"
      for verb in "${verb_list[@]}"; do
        decision="$(current_auth_decision auth can-i "${verb}" "${resource}/${resource_name}" --subresource="${subresource}" --namespace {{ web_stack_ns }})" || return 2
        [[ "${decision}" == "no" ]] || { echo "WEB_RELEASE_KUBECONFIG can access observed release subresource ${resource}/${resource_name}/${subresource} (${verb})" >&2; return 2; }
      done
    }
    rules_request="${proof_dir}/rules-request.json"
    jq -n --arg namespace "{{ web_stack_ns }}" '{apiVersion:"authorization.k8s.io/v1",kind:"SelfSubjectRulesReview",spec:{namespace:$namespace}}' > "${rules_request}"
    deployment="$(kubectl_clean --namespace {{ web_stack_ns }} get deployment/greatfallstoolbus-org -o json)"
    deployment_uid="$(jq -er '.metadata.uid | select(test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))' <<<"${deployment}")"
    generation="$(jq -er '.metadata.generation | select(type == "number" and . > 0)' <<<"${deployment}")"
    revision="$(jq -er '.metadata.annotations["deployment.kubernetes.io/revision"] | select(test("^[1-9][0-9]*$"))' <<<"${deployment}")"
    jq -e --arg image "${WEB_APPLY_IMAGE}" --arg sha "${WEB_APPLY_SHA}" '
      .metadata.name == "greatfallstoolbus-org"
      and .metadata.namespace == "greatfallstoolbus-org-production"
      and .metadata.deletionTimestamp == null
      and (.metadata.generation == .status.observedGeneration)
      and .spec.replicas == 2
      and .spec.selector.matchLabels == {"app.kubernetes.io/component": "web", "app.kubernetes.io/name": "greatfallstoolbus-org"}
      and .status.replicas == 2
      and .status.updatedReplicas == 2
      and .status.readyReplicas == 2
      and .status.availableReplicas == 2
      and ((.status.unavailableReplicas // 0) == 0)
      and any(.status.conditions[]?; .type == "Available" and .status == "True")
      and any(.status.conditions[]?; .type == "Progressing" and .status == "True")
      and .spec.template.metadata.annotations["app.tinyland.dev/source-sha"] == $sha
      and .spec.template.metadata.labels["app.kubernetes.io/name"] == "greatfallstoolbus-org"
      and .spec.template.metadata.labels["app.kubernetes.io/component"] == "web"
      and .spec.template.metadata.labels["app.kubernetes.io/part-of"] == "great-falls-tool-bus"
      and .spec.template.spec.automountServiceAccountToken == false
      and .spec.template.spec.enableServiceLinks == false
      and (.spec.template.spec.serviceAccountName // "default") == "default"
      and .spec.template.spec.securityContext.runAsNonRoot == true
      and .spec.template.spec.securityContext.runAsUser == 65532
      and .spec.template.spec.securityContext.runAsGroup == 65532
      and .spec.template.spec.securityContext.fsGroup == 65532
      and .spec.template.spec.securityContext.seccompProfile.type == "RuntimeDefault"
      and ((.spec.template.spec.securityContext | keys | sort) == (["fsGroup", "runAsGroup", "runAsNonRoot", "runAsUser", "seccompProfile"] | sort))
      and ((.spec.template.spec.securityContext.seccompProfile | keys) == ["type"])
      and ((.spec.template.spec | has("hostNetwork")) | not)
      and ((.spec.template.spec | has("hostPID")) | not)
      and ((.spec.template.spec | has("hostIPC")) | not)
      and ((.spec.template.spec | has("shareProcessNamespace")) | not)
      and ((.spec.template.spec | has("initContainers")) | not)
      and ((.spec.template.spec | has("ephemeralContainers")) | not)
      and ((.spec.template.spec | has("imagePullSecrets")) | not)
      and ((.spec.template.spec | has("volumes")) | not)
      and ((.spec.template.spec.containers | length) == 1)
      and .spec.template.spec.containers[0].name == "greatfallstoolbus-org"
      and .spec.template.spec.containers[0].image == $image
      and ((.spec.template.spec.containers[0] | has("command")) | not)
      and ((.spec.template.spec.containers[0] | has("args")) | not)
      and ((.spec.template.spec.containers[0] | has("env")) | not)
      and ((.spec.template.spec.containers[0] | has("envFrom")) | not)
      and ((.spec.template.spec.containers[0] | has("volumeMounts")) | not)
      and ((.spec.template.spec.containers[0] | has("lifecycle")) | not)
      and ((.spec.template.spec.containers[0] | has("workingDir")) | not)
      and ((.spec.template.spec.containers[0] | has("stdin")) | not)
      and ((.spec.template.spec.containers[0] | has("stdinOnce")) | not)
      and ((.spec.template.spec.containers[0] | has("tty")) | not)
      and (.spec.template.spec.containers[0].ports == [{"containerPort": 3000, "name": "http", "protocol": "TCP"}])
      and .spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation == false
      and .spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem == true
      and .spec.template.spec.containers[0].securityContext.capabilities.drop == ["ALL"]
      and ((.spec.template.spec.containers[0].securityContext | keys | sort) == (["allowPrivilegeEscalation", "capabilities", "readOnlyRootFilesystem"] | sort))
      and ((.spec.template.spec.containers[0].securityContext.capabilities | keys) == ["drop"])
    ' <<<"${deployment}" >/dev/null || { echo "PINNED Deployment contract mismatch" >&2; exit 1; }
    deployment_snapshot="$(jq -S -c . <<<"${deployment}")"
    replica_sets="$(kubectl_clean --namespace {{ web_stack_ns }} get replicasets -o json)"
    active_rs="$(jq -e -c --arg owner "${deployment_uid}" --arg revision "${revision}" '
      [.items[] | select(.metadata.deletionTimestamp == null) | select([.metadata.ownerReferences[]? | select(.controller == true) | .uid] == [$owner]) | select(.metadata.annotations["deployment.kubernetes.io/revision"] == $revision) | select(.spec.replicas == 2)] as $active
      | if ($active | length) == 1 then $active[0] else error("expected exactly one active ReplicaSet") end
    ' <<<"${replica_sets}")"
    active_rs_uid="$(jq -er '.metadata.uid | select(test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))' <<<"${active_rs}")"
    pod_hash="$(jq -er '.metadata.labels["pod-template-hash"] | select(test("^[a-z0-9]+$"))' <<<"${active_rs}")"
    jq -e --arg image "${WEB_APPLY_IMAGE}" --arg sha "${WEB_APPLY_SHA}" --arg hash "${pod_hash}" '
      .metadata.namespace == "greatfallstoolbus-org-production"
      and (.metadata.name | startswith("greatfallstoolbus-org-"))
      and .metadata.labels["app.kubernetes.io/name"] == "greatfallstoolbus-org"
      and .metadata.labels["app.kubernetes.io/component"] == "web"
      and .metadata.labels["app.kubernetes.io/part-of"] == "great-falls-tool-bus"
      and .metadata.labels["pod-template-hash"] == $hash
      and .spec.selector.matchLabels["pod-template-hash"] == $hash
      and .status.replicas == 2 and .status.readyReplicas == 2 and .status.availableReplicas == 2 and .status.fullyLabeledReplicas == 2
      and .spec.template.metadata.annotations["app.tinyland.dev/source-sha"] == $sha
      and .spec.template.metadata.labels["app.kubernetes.io/name"] == "greatfallstoolbus-org"
      and .spec.template.metadata.labels["app.kubernetes.io/component"] == "web"
      and .spec.template.metadata.labels["app.kubernetes.io/part-of"] == "great-falls-tool-bus"
      and .spec.template.metadata.labels["pod-template-hash"] == $hash
      and .spec.template.spec.automountServiceAccountToken == false
      and .spec.template.spec.enableServiceLinks == false
      and (.spec.template.spec.serviceAccountName // "default") == "default"
      and .spec.template.spec.securityContext.runAsNonRoot == true
      and .spec.template.spec.securityContext.runAsUser == 65532
      and .spec.template.spec.securityContext.runAsGroup == 65532
      and .spec.template.spec.securityContext.fsGroup == 65532
      and .spec.template.spec.securityContext.seccompProfile.type == "RuntimeDefault"
      and ((.spec.template.spec.securityContext | keys | sort) == (["fsGroup", "runAsGroup", "runAsNonRoot", "runAsUser", "seccompProfile"] | sort))
      and ((.spec.template.spec.securityContext.seccompProfile | keys) == ["type"])
      and ((.spec.template.spec | has("hostNetwork")) | not)
      and ((.spec.template.spec | has("hostPID")) | not)
      and ((.spec.template.spec | has("hostIPC")) | not)
      and ((.spec.template.spec | has("shareProcessNamespace")) | not)
      and ((.spec.template.spec | has("initContainers")) | not)
      and ((.spec.template.spec | has("ephemeralContainers")) | not)
      and ((.spec.template.spec | has("imagePullSecrets")) | not)
      and ((.spec.template.spec | has("volumes")) | not)
      and ((.spec.template.spec.containers | length) == 1)
      and .spec.template.spec.containers[0].name == "greatfallstoolbus-org"
      and .spec.template.spec.containers[0].image == $image
      and ((.spec.template.spec.containers[0] | has("command")) | not)
      and ((.spec.template.spec.containers[0] | has("args")) | not)
      and ((.spec.template.spec.containers[0] | has("env")) | not)
      and ((.spec.template.spec.containers[0] | has("envFrom")) | not)
      and ((.spec.template.spec.containers[0] | has("volumeMounts")) | not)
      and ((.spec.template.spec.containers[0] | has("lifecycle")) | not)
      and ((.spec.template.spec.containers[0] | has("workingDir")) | not)
      and ((.spec.template.spec.containers[0] | has("stdin")) | not)
      and ((.spec.template.spec.containers[0] | has("stdinOnce")) | not)
      and ((.spec.template.spec.containers[0] | has("tty")) | not)
      and (.spec.template.spec.containers[0].ports == [{"containerPort": 3000, "name": "http", "protocol": "TCP"}])
      and .spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation == false
      and .spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem == true
      and .spec.template.spec.containers[0].securityContext.capabilities.drop == ["ALL"]
      and ((.spec.template.spec.containers[0].securityContext | keys | sort) == (["allowPrivilegeEscalation", "capabilities", "readOnlyRootFilesystem"] | sort))
      and ((.spec.template.spec.containers[0].securityContext.capabilities | keys) == ["drop"])
    ' <<<"${active_rs}" >/dev/null || { echo "RUNNING active ReplicaSet contract mismatch" >&2; exit 1; }
    jq -e --arg owner "${deployment_uid}" --arg active "${active_rs_uid}" '[.items[] | select([.metadata.ownerReferences[]? | select(.controller == true) | .uid] == [$owner]) | select(.metadata.uid != $active)] | all(.[]; ((.spec.replicas // 0) == 0) and ((.status.replicas // 0) == 0))' <<<"${replica_sets}" >/dev/null || { echo "RUNNING old ReplicaSet is not fully scaled down" >&2; exit 1; }
    replica_sets_snapshot="$(jq -S -c '.items | sort_by(.metadata.uid)' <<<"${replica_sets}")"
    pods="$(kubectl_clean --namespace {{ web_stack_ns }} get pods -o json)"
    expected_digest="${WEB_APPLY_IMAGE##*@}"
    jq -e --arg owner "${active_rs_uid}" --arg image "${WEB_APPLY_IMAGE}" --arg digest "${expected_digest}" --arg sha "${WEB_APPLY_SHA}" --arg hash "${pod_hash}" '
      [.items[] | select(.metadata.deletionTimestamp == null) | select([.metadata.ownerReferences[]? | select(.controller == true) | .uid] == [$owner])] as $pods
      | [.items[] | select(.metadata.deletionTimestamp == null) | select(.metadata.labels["app.kubernetes.io/name"] == "greatfallstoolbus-org" and .metadata.labels["app.kubernetes.io/component"] == "web")] as $labeled
      | ($pods | length) == 2
        and ($labeled | length) == 2
        and (([$pods[].metadata.uid] | sort) == ([$labeled[].metadata.uid] | sort))
        and all($pods[];
          .metadata.namespace == "greatfallstoolbus-org-production"
          and ([.metadata.ownerReferences[]? | select(.controller == true) | .uid] == [$owner])
          and .metadata.labels["app.kubernetes.io/part-of"] == "great-falls-tool-bus"
          and .metadata.labels["pod-template-hash"] == $hash
          and .metadata.annotations["app.tinyland.dev/source-sha"] == $sha
          and (.metadata.uid | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
          and .status.phase == "Running"
          and (.status.podIP | test("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$"))
          and .status.podIPs == [{"ip": .status.podIP}]
          and any(.status.conditions[]?; .type == "Ready" and .status == "True")
          and any(.status.conditions[]?; .type == "ContainersReady" and .status == "True")
          and .spec.automountServiceAccountToken == false
          and .spec.enableServiceLinks == false
          and (.spec.serviceAccountName // "default") == "default"
          and .spec.securityContext.runAsNonRoot == true
          and .spec.securityContext.runAsUser == 65532
          and .spec.securityContext.runAsGroup == 65532
          and .spec.securityContext.fsGroup == 65532
          and .spec.securityContext.seccompProfile.type == "RuntimeDefault"
          and ((.spec.securityContext | keys | sort) == (["fsGroup", "runAsGroup", "runAsNonRoot", "runAsUser", "seccompProfile"] | sort))
          and ((.spec.securityContext.seccompProfile | keys) == ["type"])
          and ((.spec | has("hostNetwork")) | not)
          and ((.spec | has("hostPID")) | not)
          and ((.spec | has("hostIPC")) | not)
          and ((.spec | has("shareProcessNamespace")) | not)
          and ((.spec | has("initContainers")) | not)
          and ((.spec | has("ephemeralContainers")) | not)
          and ((.spec | has("imagePullSecrets")) | not)
          and ((.spec | has("volumes")) | not)
          and ((.spec.containers | length) == 1)
          and .spec.containers[0].name == "greatfallstoolbus-org"
          and .spec.containers[0].image == $image
          and ((.spec.containers[0] | has("command")) | not)
          and ((.spec.containers[0] | has("args")) | not)
          and ((.spec.containers[0] | has("env")) | not)
          and ((.spec.containers[0] | has("envFrom")) | not)
          and ((.spec.containers[0] | has("volumeMounts")) | not)
          and ((.spec.containers[0] | has("lifecycle")) | not)
          and ((.spec.containers[0] | has("workingDir")) | not)
          and ((.spec.containers[0] | has("stdin")) | not)
          and ((.spec.containers[0] | has("stdinOnce")) | not)
          and ((.spec.containers[0] | has("tty")) | not)
          and (.spec.containers[0].ports == [{"containerPort": 3000, "name": "http", "protocol": "TCP"}])
          and .spec.containers[0].securityContext.allowPrivilegeEscalation == false
          and .spec.containers[0].securityContext.readOnlyRootFilesystem == true
          and .spec.containers[0].securityContext.capabilities.drop == ["ALL"]
          and ((.spec.containers[0].securityContext | keys | sort) == (["allowPrivilegeEscalation", "capabilities", "readOnlyRootFilesystem"] | sort))
          and ((.spec.containers[0].securityContext.capabilities | keys) == ["drop"])
          and ((.status.containerStatuses | length) == 1)
          and .status.containerStatuses[0].name == "greatfallstoolbus-org"
          and .status.containerStatuses[0].ready == true
          and .status.containerStatuses[0].started == true
          and ((.status.containerStatuses[0].state.running.startedAt // "") | length > 0)
          and .status.containerStatuses[0].restartCount == 0
          and (.status.containerStatuses[0].imageID | endswith("@" + $digest)))
    ' <<<"${pods}" >/dev/null || { echo "RUNNING pod ownership/readiness/image contract mismatch" >&2; exit 1; }
    pods_snapshot="$(jq -S -c '.items | sort_by(.metadata.uid)' <<<"${pods}")"
    pod_uids="$(jq -c --arg owner "${active_rs_uid}" '[.items[] | select(.metadata.deletionTimestamp == null) | select([.metadata.ownerReferences[]? | select(.controller == true) | .uid] == [$owner]) | .metadata.uid] | sort' <<<"${pods}")"
    pod_network="$(jq -c --arg owner "${active_rs_uid}" '[.items[] | select(.metadata.deletionTimestamp == null) | select([.metadata.ownerReferences[]? | select(.controller == true) | .uid] == [$owner]) | {key: .metadata.uid, value: .status.podIP}] | from_entries' <<<"${pods}")"
    service="$(kubectl_clean --namespace {{ web_stack_ns }} get service/greatfallstoolbus-org -o json)"
    service_uid="$(jq -er '.metadata.uid | select(test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))' <<<"${service}")"
    jq -e '
      .metadata.name == "greatfallstoolbus-org"
      and .metadata.namespace == "greatfallstoolbus-org-production"
      and .metadata.deletionTimestamp == null
      and (.metadata.uid | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
      and .spec.type == "ClusterIP"
      and ((.spec.clusterIP // "") | length > 0 and . != "None")
      and .spec.selector == {"app.kubernetes.io/component": "web", "app.kubernetes.io/name": "greatfallstoolbus-org"}
      and (.spec.ports | length) == 1
      and .spec.ports[0].name == "http"
      and .spec.ports[0].port == 80
      and .spec.ports[0].targetPort == "http"
      and .spec.ports[0].protocol == "TCP"
      and ((.spec | has("externalName")) | not)
      and ((.spec.externalIPs // []) | length) == 0
      and ((.spec | has("loadBalancerIP")) | not)
      and ((.spec.loadBalancerSourceRanges // []) | length) == 0
      and ((.spec | has("healthCheckNodePort")) | not)
      and ((.spec.publishNotReadyAddresses // false) == false)
    ' <<<"${service}" >/dev/null || { echo "RUNNING Service selector/port contract mismatch" >&2; exit 1; }
    service_snapshot="$(jq -S -c . <<<"${service}")"
    endpoint_slices="$(kubectl_clean --namespace {{ web_stack_ns }} get endpointslices.discovery.k8s.io --selector kubernetes.io/service-name=greatfallstoolbus-org -o json)"
    jq -e --argjson expected_uids "${pod_uids}" --argjson expected_network "${pod_network}" --arg service_uid "${service_uid}" '
      [.items[] | select(.metadata.deletionTimestamp == null)] as $slices
      | [$slices[].endpoints[]] as $endpoints
      | (.items | length) == ($slices | length)
        and ($slices | length) > 0
        and all($slices[];
          .metadata.namespace == "greatfallstoolbus-org-production"
          and .metadata.labels["kubernetes.io/service-name"] == "greatfallstoolbus-org"
          and (.metadata.uid | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
          and ([.metadata.ownerReferences[]? | select(.controller == true)] | length) == 1
          and any(.metadata.ownerReferences[]?;
            .controller == true
            and .apiVersion == "v1"
            and .kind == "Service"
            and .name == "greatfallstoolbus-org"
            and .uid == $service_uid)
          and .addressType == "IPv4"
          and (.ports | length) == 1
          and .ports[0].name == "http"
          and .ports[0].port == 3000
          and .ports[0].protocol == "TCP")
        and ($endpoints | length) == 2
        and all($endpoints[];
          .conditions.ready == true
          and ((.conditions.serving // true) == true)
          and ((.conditions.terminating // false) == false)
          and .targetRef.kind == "Pod"
          and .targetRef.namespace == "greatfallstoolbus-org-production"
          and (.targetRef.uid | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
          and (.addresses | length) == 1
          and .addresses[0] == $expected_network[.targetRef.uid])
        and (([$endpoints[].targetRef.uid] | sort) == $expected_uids)
    ' <<<"${endpoint_slices}" >/dev/null || { echo "RUNNING Service EndpointSlice does not bind the two reviewed pods" >&2; exit 1; }
    endpoint_slices_snapshot="$(jq -S -c '.items | (sort_by(.metadata.uid) | map(.endpoints |= sort_by(.targetRef.uid)))' <<<"${endpoint_slices}")"
    network_policies="$(kubectl_clean --namespace {{ web_stack_ns }} get networkpolicies.networking.k8s.io -o json)"
    jq -e '
      (.items | length) == 4
      and all(.items[];
        .apiVersion == "networking.k8s.io/v1"
        and .kind == "NetworkPolicy"
        and .metadata.namespace == "greatfallstoolbus-org-production"
        and .metadata.deletionTimestamp == null
        and (.metadata.uid | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")))
    ' <<<"${network_policies}" >/dev/null || { echo "RUNNING NetworkPolicy object census/identity mismatch" >&2; exit 1; }
    network_policies_semantic="$(jq -S -c '
      def canonical_rule:
        (if ((.from? // null) | type) == "array" then .from |= sort_by(tojson) else . end)
        | (if ((.to? // null) | type) == "array" then (if .to == [] then del(.to) else .to |= sort_by(tojson) end) else . end)
        | (if ((.ports? // null) | type) == "array" then .ports |= sort_by(tojson) else . end);
      [.items[] | {
        apiVersion,
        kind,
        metadata: {name: .metadata.name, namespace: .metadata.namespace, labels: .metadata.labels},
        spec: (.spec
          | .ingress = (.ingress // [])
          | .egress = (.egress // [])
          | (if ((.policyTypes? // null) | type) == "array" then .policyTypes |= sort else . end)
          | (if ((.ingress? // null) | type) == "array" then .ingress |= (map(canonical_rule) | sort_by(tojson)) else . end)
          | (if ((.egress? // null) | type) == "array" then .egress |= (map(canonical_rule) | sort_by(tojson)) else . end))
      }] | sort_by(.metadata.name)
    ' <<<"${network_policies}")"
    network_policies_digest="$(python3 -I -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())' "${network_policies_semantic}")"
    [[ "${network_policies_digest}" == "301eecb4ad234fdd7258ac7351a5a563e1b53cb250bce6f51a68824854b28220" ]] || { echo "RUNNING NetworkPolicy semantic content mismatch" >&2; exit 1; }
    network_policies_snapshot="$(jq -S -c '.items | sort_by(.metadata.uid)' <<<"${network_policies}")"
    mapfile -t observed_rs_names < <(jq -r --arg owner "${deployment_uid}" '.items[] | select([.metadata.ownerReferences[]? | select(.controller == true) | .uid] == [$owner]) | .metadata.name' <<<"${replica_sets}" | LC_ALL=C sort -u)
    mapfile -t observed_pod_names < <(jq -r --arg owner "${active_rs_uid}" '.items[] | select(.metadata.deletionTimestamp == null) | select([.metadata.ownerReferences[]? | select(.controller == true) | .uid] == [$owner]) | .metadata.name' <<<"${pods}" | LC_ALL=C sort -u)
    mapfile -t observed_slice_names < <(jq -r '.items[].metadata.name' <<<"${endpoint_slices}" | LC_ALL=C sort -u)
    [[ "${#observed_rs_names[@]}" -ge 1 && "${#observed_pod_names[@]}" -eq 2 && "${#observed_slice_names[@]}" -ge 1 ]] || { echo "RUNNING observed-object authorization census mismatch" >&2; exit 1; }
    for resource_name in "${observed_rs_names[@]}" "${observed_pod_names[@]}" "${observed_slice_names[@]}"; do
      [[ "${resource_name}" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ && "${#resource_name}" -le 253 ]] || { echo "RUNNING observed object name is malformed" >&2; exit 1; }
    done
    for resource_name in "${observed_rs_names[@]}"; do
      deny_current_base_mutation replicasets.apps "${resource_name}"
      deny_current_subresource_access replicasets.apps "${resource_name}" status "update patch"
      deny_current_subresource_access replicasets.apps "${resource_name}" scale "update patch"
    done
    for resource_name in "${observed_pod_names[@]}"; do
      deny_current_base_mutation pods "${resource_name}"
      deny_current_subresource_access pods "${resource_name}" status "update patch"
      deny_current_subresource_access pods "${resource_name}" ephemeralcontainers "update patch"
      deny_current_subresource_access pods "${resource_name}" eviction "create"
      deny_current_subresource_access pods "${resource_name}" binding "create"
      deny_current_subresource_access pods "${resource_name}" exec "get create"
      deny_current_subresource_access pods "${resource_name}" attach "get create"
      deny_current_subresource_access pods "${resource_name}" portforward "get create"
      deny_current_subresource_access pods "${resource_name}" log "get"
      deny_current_subresource_access pods "${resource_name}" proxy "get create update patch delete"
      deny_current_subresource_access pods "${resource_name}" resize "update patch"
    done
    for resource_name in "${observed_slice_names[@]}"; do
      deny_current_base_mutation endpointslices.discovery.k8s.io "${resource_name}"
      deny_current_subresource_access endpointslices.discovery.k8s.io "${resource_name}" status "update patch"
    done
    final_deployment="$(kubectl_clean --namespace {{ web_stack_ns }} get deployment/greatfallstoolbus-org -o json)"
    final_replica_sets="$(kubectl_clean --namespace {{ web_stack_ns }} get replicasets -o json)"
    final_pods="$(kubectl_clean --namespace {{ web_stack_ns }} get pods -o json)"
    final_service="$(kubectl_clean --namespace {{ web_stack_ns }} get service/greatfallstoolbus-org -o json)"
    final_endpoint_slices="$(kubectl_clean --namespace {{ web_stack_ns }} get endpointslices.discovery.k8s.io --selector kubernetes.io/service-name=greatfallstoolbus-org -o json)"
    final_network_policies="$(kubectl_clean --namespace {{ web_stack_ns }} get networkpolicies.networking.k8s.io -o json)"
    [[ "$(jq -S -c . <<<"${final_deployment}")" == "${deployment_snapshot}" ]] || { echo "RUNNING Deployment changed or degraded during readback" >&2; exit 1; }
    [[ "$(jq -S -c '.items | sort_by(.metadata.uid)' <<<"${final_replica_sets}")" == "${replica_sets_snapshot}" ]] || { echo "RUNNING ReplicaSet state changed during readback" >&2; exit 1; }
    [[ "$(jq -S -c '.items | sort_by(.metadata.uid)' <<<"${final_pods}")" == "${pods_snapshot}" ]] || { echo "RUNNING pod state changed during readback" >&2; exit 1; }
    [[ "$(jq -S -c . <<<"${final_service}")" == "${service_snapshot}" ]] || { echo "RUNNING Service changed during readback" >&2; exit 1; }
    [[ "$(jq -S -c '.items | (sort_by(.metadata.uid) | map(.endpoints |= sort_by(.targetRef.uid)))' <<<"${final_endpoint_slices}")" == "${endpoint_slices_snapshot}" ]] || { echo "RUNNING EndpointSlice state changed during readback" >&2; exit 1; }
    [[ "$(jq -S -c '.items | sort_by(.metadata.uid)' <<<"${final_network_policies}")" == "${network_policies_snapshot}" ]] || { echo "RUNNING NetworkPolicy state changed during readback" >&2; exit 1; }
    final_rules_response="${proof_dir}/rules-response-final.json"
    final_rules_stderr="${proof_dir}/rules-response-final.stderr"
    if ! kubectl_clean create --raw /apis/authorization.k8s.io/v1/selfsubjectrulesreviews -f "${rules_request}" > "${final_rules_response}" 2> "${final_rules_stderr}"; then
      echo "Kubernetes authority reread failed" >&2
      exit 1
    fi
    [[ ! -s "${final_rules_stderr}" ]] && test -s "${final_rules_response}" || { echo "Kubernetes authority reread returned diagnostics or no data" >&2; exit 1; }
    jq -e '.apiVersion == "authorization.k8s.io/v1" and .kind == "SelfSubjectRulesReview" and .status.incomplete == false and ((.status.evaluationError // "") == "")' "${final_rules_response}" >/dev/null || { echo "Kubernetes authority reread was incomplete or malformed" >&2; exit 1; }
    final_rules_snapshot="$(jq -S -c '
      def resource_rule: {
        apiGroups: ((.apiGroups // []) | sort | unique),
        resources: ((.resources // []) | sort | unique),
        resourceNames: ((.resourceNames // []) | sort | unique),
        verbs: ((.verbs // []) | sort | unique)
      };
      def non_resource_rule: {
        nonResourceURLs: ((.nonResourceURLs // []) | sort | unique),
        verbs: ((.verbs // []) | sort | unique)
      };
      {
        incomplete: .status.incomplete,
        evaluationError: (.status.evaluationError // ""),
        resourceRules: ([.status.resourceRules[]? | resource_rule] | sort_by(tojson) | unique),
        nonResourceRules: ([.status.nonResourceRules[]? | non_resource_rule] | sort_by(tojson) | unique)
      }
    ' "${final_rules_response}")"
    final_authority_digest="$(python3 -I -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())' "${final_rules_snapshot}")"
    [[ "${final_authority_digest}" == "${authority_digest}" ]] || { echo "WEB_RELEASE_KUBECONFIG authority changed during readback" >&2; exit 1; }
    python3 -I - "${release_kubeconfig}" "${kubeconfig_digest}" <<'PY'
    import hashlib
    import hmac
    import sys
    from pathlib import Path

    observed = hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest()
    if not hmac.compare_digest(observed, sys.argv[2]):
        raise SystemExit("WEB_RELEASE_KUBECONFIG changed during readback")
    PY
    echo "PINNED/RUNNING proof passed: source=${WEB_APPLY_SHA} digest=${expected_digest} generation=${generation} revision=${revision} replicas=2/2"

# External SERVED source proof. Gated mode first proves anonymous Cloudflare
# Access interception and then uses one operator-held cookie jar. Public mode
# forbids all cookies. This endpoint proves the source SHA only: it deliberately
# does not claim the selected image digest is served. The later mutation lane
# must close that cross-command boundary with one atomic deploy/readback receipt.
web-release-served-proof: _web-release-candidate-inputs
    #!/usr/bin/env -S BASH_ENV= ENV= SHELLOPTS= BASHOPTS= bash -p
    set +x
    set -euo pipefail
    command -v curl >/dev/null 2>&1 || { echo "curl is required (nix develop provides it)" >&2; exit 1; }
    origin="https://greatfallstoolbus.org"
    access_state="${WEB_ACCESS_STATE:?Set WEB_ACCESS_STATE to gated or public after edge readback}"
    for name in GODEBUG CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR SSLKEYLOGFILE; do
      if [[ -n "${!name:-}" ]]; then
        echo "Refusing ambient ${name}; served proof uses one clean TLS process environment" >&2
        exit 2
      fi
    done
    umask 077
    temp_root="$(python3 -I - "${TMPDIR:-/tmp}" "$(git rev-parse --show-toplevel)" <<'PY'
    import os
    import stat
    import sys
    from pathlib import Path

    path = Path(sys.argv[1]).resolve(strict=True)
    repo = Path(sys.argv[2]).resolve(strict=True)
    try:
        path.relative_to(repo)
    except ValueError:
        pass
    else:
        raise SystemExit("TMPDIR must remain outside the public repository")
    metadata = path.stat()
    mode = stat.S_IMODE(metadata.st_mode)
    private = metadata.st_uid == os.getuid() and (mode & 0o022) == 0
    shared_sticky = metadata.st_uid == 0 and bool(mode & stat.S_ISVTX)
    if not path.is_dir() or not (private or shared_sticky):
        raise SystemExit("TMPDIR must be operator-private or a root-owned sticky directory")
    print(path)
    PY
    )"
    proof_dir="$(mktemp -d "${temp_root}/gftb-web-served.XXXXXX")"
    trap 'rm -rf "${proof_dir}"' EXIT
    mkdir -m 700 "${proof_dir}/home"
    curl_auth=()
    copy_private_file() {
      python3 -I - "$1" "$2" "$(git rev-parse --show-toplevel)" <<'PY'
    import os
    import shutil
    import stat
    import sys
    from pathlib import Path

    raw = Path(sys.argv[1])
    destination = Path(sys.argv[2])
    repo = Path(sys.argv[3]).resolve(strict=True)
    destination_parent = destination.parent.stat()
    if not stat.S_ISDIR(destination_parent.st_mode) or destination_parent.st_uid != os.getuid() or stat.S_IMODE(destination_parent.st_mode) != 0o700:
        raise SystemExit("private cookie staging directory failed custody validation")
    if not raw.is_absolute() or raw.is_symlink():
        raise SystemExit("cookie jar must be an absolute non-symlink path")
    path = raw.resolve(strict=True)
    try:
        path.relative_to(repo)
    except ValueError:
        pass
    else:
        raise SystemExit("cookie jar must remain outside the public repository")
    expected = path.stat()
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    source_fd = os.open(raw, flags)
    metadata = os.fstat(source_fd)
    if (metadata.st_dev, metadata.st_ino) != (expected.st_dev, expected.st_ino):
        os.close(source_fd)
        raise SystemExit("cookie jar changed during custody validation")
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) != 0o600:
        os.close(source_fd)
        raise SystemExit("cookie jar must be an operator-owned regular mode-0600 file")
    destination_fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(source_fd, "rb") as source, os.fdopen(destination_fd, "wb") as target:
        shutil.copyfileobj(source, target)
        target.flush()
        os.fsync(target.fileno())
    PY
    }
    fetch() {
      local path="$1" body="$2" headers="$3"
      shift 3
      env -i PATH="${PATH}" HOME="${proof_dir}/home" curl --disable --silent --show-error --connect-timeout 10 --max-time 20 --max-filesize 1048576 --max-redirs 0 --output "${body}" --dump-header "${headers}" --write-out '%{http_code}' "$@" "${origin}${path}"
    }
    case "${access_state}" in
      gated)
        : "${CF_ACCESS_COOKIE_JAR:?Set CF_ACCESS_COOKIE_JAR to the operator-held Access cookie jar}"
        release_cookie_jar="${proof_dir}/access.cookies"
        copy_private_file "${CF_ACCESS_COOKIE_JAR}" "${release_cookie_jar}"
        for path in / /health /health.sha /qr/greatfallstoolbus-apex.svg; do
          key="$(printf '%s' "${path}" | tr '/.' '__')"
          body="${proof_dir}/${key}.anonymous.body"
          headers="${proof_dir}/${key}.anonymous.headers"
          status="$(fetch "${path}" "${body}" "${headers}")"
          [[ "${status}" == "302" ]] || { echo "Access anonymous status mismatch for ${path}" >&2; exit 1; }
          mapfile -t locations < <(awk 'tolower($1) == "location:" { print $2 }' "${headers}" | tr -d '\r')
          [[ "${#locations[@]}" -eq 1 ]] || { echo "Access response must contain exactly one Location header for ${path}" >&2; exit 1; }
          location="${locations[0]}"
          python3 -I - "${location}" "${path}" <<'PY'
    import sys
    from urllib.parse import parse_qs, urlsplit

    value = urlsplit(sys.argv[1])
    params = parse_qs(value.query, keep_blank_values=True)
    expected_redirect = sys.argv[2]
    if value.scheme != "https" or value.hostname != "sulliwood.cloudflareaccess.com" or value.username is not None or value.password is not None or value.port is not None or value.path != "/cdn-cgi/access/login/greatfallstoolbus.org" or value.fragment or params.get("redirect_url") != [expected_redirect]:
        raise SystemExit("unexpected Cloudflare Access redirect")
    PY
        done
        curl_auth=(--cookie "${release_cookie_jar}")
        ;;
      public)
        [[ -z "${CF_ACCESS_COOKIE_JAR:-}" ]] || { echo "public served proof must not use an Access cookie jar" >&2; exit 2; }
        ;;
      *) echo "WEB_ACCESS_STATE must be gated or public" >&2; exit 2 ;;
    esac
    home_body="${proof_dir}/home.body"; home_headers="${proof_dir}/home.headers"
    health_body="${proof_dir}/health.body"; health_headers="${proof_dir}/health.headers"
    sha_body="${proof_dir}/sha.body"; sha_headers="${proof_dir}/sha.headers"
    qr_body="${proof_dir}/qr.body"; qr_headers="${proof_dir}/qr.headers"
    [[ "$(fetch / "${home_body}" "${home_headers}" "${curl_auth[@]}")" == "200" ]] || { echo "SERVED homepage status mismatch" >&2; exit 1; }
    [[ "$(fetch /health "${health_body}" "${health_headers}" "${curl_auth[@]}")" == "200" ]] || { echo "SERVED health status mismatch" >&2; exit 1; }
    [[ "$(fetch /health.sha "${sha_body}" "${sha_headers}" "${curl_auth[@]}")" == "200" ]] || { echo "SERVED source status mismatch" >&2; exit 1; }
    [[ "$(fetch /qr/greatfallstoolbus-apex.svg "${qr_body}" "${qr_headers}" "${curl_auth[@]}")" == "200" ]] || { echo "SERVED QR status mismatch" >&2; exit 1; }
    grep -qi 'Great Falls Tool Bus' "${home_body}" || { echo "SERVED homepage marker missing" >&2; exit 1; }
    python3 -I - "${health_body}" "ok" <<'PY'
    import sys
    from pathlib import Path

    if Path(sys.argv[1]).read_bytes() != sys.argv[2].encode("ascii"):
        raise SystemExit("SERVED health body mismatch")
    PY
    python3 -I - "${sha_body}" "${WEB_APPLY_SHA}" <<'PY'
    import sys
    from pathlib import Path

    if Path(sys.argv[1]).read_bytes() != sys.argv[2].encode("ascii"):
        raise SystemExit("SERVED source SHA mismatch")
    PY
    grep -Eq '<svg([[:space:]>])' "${qr_body}" || { echo "SERVED QR is not SVG" >&2; exit 1; }
    qr_type="$(awk 'tolower($1) == "content-type:" { print tolower($2) }' "${qr_headers}" | tr -d '\r' | tail -n 1)"
    [[ "${qr_type}" == image/svg+xml* ]] || { echo "SERVED QR content type mismatch" >&2; exit 1; }
    echo "SERVED source proof passed: source=${WEB_APPLY_SHA} access=${access_state}"

# --- Reviewed gftb-site release MUTATION chain -------------------------------
# The mutating complement to the proof-only recipes above. It reuses their input
# contract verbatim (_web-release-candidate-inputs: exact gftb-site digest, exact
# 40-hex source SHA, replicas exactly 2, no ambient proxy) and it reuses their
# renderer verbatim (web-release-render) -- there is exactly ONE renderer in this
# repository and the apply plane may not carry a second one.
#
# The load-bearing property is that NO step here resolves an image, sets an
# image, or patches replicas. `web-release-render` already bakes ${WEB_APPLY_IMAGE}
# and replicas: 2 into the rendered bytes; `web-release-plan` records those exact
# bytes under an operator-private plan root; `web-release-apply` re-renders,
# refuses unless the re-render is byte-identical to the recorded plan, and then
# applies THOSE bytes. So the reviewed bytes and the applied bytes cannot diverge,
# and `kubectl rollout history` can always be reconciled against a render of the
# reviewed inputs. This is deliberately unlike the legacy `web-stack-apply`
# carrier, which imperatively `set image`s the adapter-node origin.
#
# Nothing here creates the namespace (the apply identity is namespace-scoped and
# cannot), ships a Secret, or touches Cloudflare. The public path does not change:
# the apex already resolves to the honey-ingress tunnel and the tunnel already
# routes to Service/greatfallstoolbus-org -- which is exactly why the cutover is
# in place in {{ web_stack_ns }} rather than in a parallel namespace.

# Plan artifacts are release evidence, never Git content: operator-owned private
# root, 0700, artifacts 0600. Mirrors the .tofu-plans/ contract.
_web-release-plan-root-contract:
    #!/usr/bin/env -S BASH_ENV= ENV= SHELLOPTS= BASHOPTS= bash -p
    set +x
    set -euo pipefail
    umask 077
    python3 -I - "$(git rev-parse --show-toplevel)/.k8s-plans" <<'PY'
    import os
    import stat
    import sys
    from pathlib import Path

    root = Path(sys.argv[1])
    if not root.exists() and not root.is_symlink():
        root.mkdir(mode=0o700)
    metadata = root.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise SystemExit(".k8s-plans must be a real directory, not a symlink")
    if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
        raise SystemExit(".k8s-plans must be operator-owned and mode 0700")
    for path in sorted(root.glob("web-release.*")):
        item = path.lstat()
        if stat.S_ISLNK(item.st_mode) or not stat.S_ISREG(item.st_mode):
            raise SystemExit(f"web release plan artifact must be a regular file: {path.name}")
        if item.st_uid != os.getuid() or stat.S_IMODE(item.st_mode) != 0o600:
            raise SystemExit(f"web release plan artifact {path.name} must be operator-owned and mode 0600")
    PY

# The apply identity. Same NAME as the existing cutover credential
# (WEB_APPLY_KUBECONFIG) so no new secret is introduced, but held to the ARC
# custody bar: operator-owned regular file, mode 0600, outside every repository
# tree, and no ambient KUBECONFIG allowed to shadow it.
#
# It also runs the AUTHORIZATION PREFLIGHT for the whole mutating chain, before
# any mutation is attempted. `apply --dry-run=server` authorizes only the objects
# it applies; it does NOT authorize the NetworkPolicy delete web-release-apply
# performs afterwards, and the render introduces a NetworkPolicy object that does
# not exist yet (default-deny-egress), so `create networkpolicies` is a new verb
# too. Without this preflight the realistic failure is: dry-run green -> apply
# succeeds (the Deployment now runs the gftb-site image) -> delete denied ->
# `set -e` aborts before the rollout wait, leaving the promotion half-done with
# allow-egress-dns still additively permitting egress and the stated "no egress
# at all" invariant silently false. Mirrors the auth can-i preflights the ARC and
# proof recipes already use.
_web-release-apply-kubeconfig-contract:
    #!/usr/bin/env -S BASH_ENV= ENV= SHELLOPTS= BASHOPTS= bash -p
    set +x
    set -euo pipefail
    : "${WEB_APPLY_KUBECONFIG:?Set WEB_APPLY_KUBECONFIG to the namespace-scoped web-apply kubeconfig}"
    [[ -z "${KUBECONFIG:-}" ]] || { echo "Refusing ambient KUBECONFIG; WEB_APPLY_KUBECONFIG is authoritative" >&2; exit 2; }
    python3 -I - "${WEB_APPLY_KUBECONFIG}" "$(git rev-parse --show-toplevel)" <<'PY'
    import os
    import stat
    import sys
    from pathlib import Path

    path = Path(sys.argv[1]).expanduser().resolve(strict=True)
    repo = Path(sys.argv[2]).resolve(strict=True)
    try:
        path.relative_to(repo)
    except ValueError:
        pass
    else:
        raise SystemExit("WEB_APPLY_KUBECONFIG must remain outside the repository")
    metadata = path.stat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
        raise SystemExit("WEB_APPLY_KUBECONFIG must be a regular file owned by the operator")
    if stat.S_IMODE(metadata.st_mode) != 0o600:
        raise SystemExit("WEB_APPLY_KUBECONFIG must have mode 0600")
    PY
    umask 077
    authz_dir="$(mktemp -d "${TMPDIR:-/tmp}/gftb-web-release-authz.XXXXXX")"
    trap 'rm -rf "${authz_dir}"' EXIT
    authz_stderr="${authz_dir}/authz.stderr"
    # Every verb the chain needs, in {{ web_stack_ns }}: `apply -f` on the three
    # rendered kinds (get/create/update/patch), `rollout status` (get/list/watch
    # deployments), and the NetworkPolicy prune (delete). Fail closed on a "no"
    # AND on any diagnostic output, so an authorization transport error is a
    # refusal rather than a pass.
    for authz_contract in \
      "get deployments.apps" "list deployments.apps" "watch deployments.apps" \
      "create deployments.apps" "update deployments.apps" "patch deployments.apps" \
      "get services" "create services" "update services" "patch services" \
      "get networkpolicies.networking.k8s.io" \
      "create networkpolicies.networking.k8s.io" \
      "update networkpolicies.networking.k8s.io" \
      "patch networkpolicies.networking.k8s.io" \
      "delete networkpolicies.networking.k8s.io"; do
      read -r authz_verb authz_resource <<<"${authz_contract}"
      : > "${authz_stderr}"
      authz_decision="$(kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" auth can-i "${authz_verb}" "${authz_resource}" --namespace {{ web_stack_ns }} 2>"${authz_stderr}" || true)"
      [[ ! -s "${authz_stderr}" ]] || { echo "Kubernetes authorization review for ${authz_verb} ${authz_resource} emitted diagnostics; refusing before any mutation" >&2; exit 2; }
      [[ "${authz_decision}" == "yes" ]] || { echo "WEB_APPLY_KUBECONFIG cannot ${authz_verb} ${authz_resource} in {{ web_stack_ns }}; refusing before any mutation" >&2; exit 2; }
    done
    echo "web release apply authorization preflight passed in {{ web_stack_ns }}"

# PLAN. Offline: renders the reviewed inputs ONCE through web-release-render and
# records the bytes, their digest, the selected image/source SHA, and the infra
# carrier commit. Contacts no cluster and no registry.
web-release-plan: _web-release-candidate-inputs _web-release-plan-root-contract
    #!/usr/bin/env -S BASH_ENV= ENV= SHELLOPTS= BASHOPTS= bash -p
    set +x
    set -euo pipefail
    umask 077
    repo_root="$(git rev-parse --show-toplevel)"
    plan_root="${repo_root}/.k8s-plans"
    just --justfile "${repo_root}/Justfile" --working-directory "${repo_root}" web-release-render > "${plan_root}/web-release.rendered.yaml"
    test -s "${plan_root}/web-release.rendered.yaml" || { echo "web-release-render produced no manifest" >&2; exit 1; }
    python3 -I -c 'import hashlib, pathlib, sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "${plan_root}/web-release.rendered.yaml" > "${plan_root}/web-release.render-sha256"
    printf '%s\n' "${WEB_APPLY_IMAGE}" > "${plan_root}/web-release.image"
    printf '%s\n' "${WEB_APPLY_SHA}" > "${plan_root}/web-release.source-sha"
    git -C "${repo_root}" rev-parse HEAD > "${plan_root}/web-release.carrier-sha"
    chmod 600 "${plan_root}/web-release.rendered.yaml" "${plan_root}/web-release.render-sha256" "${plan_root}/web-release.image" "${plan_root}/web-release.source-sha" "${plan_root}/web-release.carrier-sha"
    echo "web release plan recorded"
    echo "  image:   ${WEB_APPLY_IMAGE}"
    echo "  source:  ${WEB_APPLY_SHA}"
    echo "  carrier: $(tr -d '\n' < "${plan_root}/web-release.carrier-sha")"
    echo "  render:  sha256:$(tr -d '\n' < "${plan_root}/web-release.render-sha256")"

# Refuse a stale or foreign plan: the inputs, the carrier, and a fresh render
# must all still equal what the plan recorded.
_web-release-plan-preflight: _web-release-candidate-inputs _web-release-plan-root-contract
    #!/usr/bin/env -S BASH_ENV= ENV= SHELLOPTS= BASHOPTS= bash -p
    set +x
    set -euo pipefail
    umask 077
    repo_root="$(git rev-parse --show-toplevel)"
    plan_root="${repo_root}/.k8s-plans"
    for artifact in rendered.yaml render-sha256 image source-sha carrier-sha; do
      test -f "${plan_root}/web-release.${artifact}" || { echo "No web release plan recorded; run just web-release-plan first" >&2; exit 2; }
    done
    [[ "$(tr -d '\n' < "${plan_root}/web-release.image")" == "${WEB_APPLY_IMAGE}" ]] || { echo "Planned image differs from WEB_APPLY_IMAGE; re-plan" >&2; exit 2; }
    [[ "$(tr -d '\n' < "${plan_root}/web-release.source-sha")" == "${WEB_APPLY_SHA}" ]] || { echo "Planned source SHA differs from WEB_APPLY_SHA; re-plan" >&2; exit 2; }
    [[ "$(git -C "${repo_root}" rev-parse HEAD)" == "$(tr -d '\n' < "${plan_root}/web-release.carrier-sha")" ]] || { echo "Infra carrier changed after the web release plan; re-plan" >&2; exit 2; }
    recorded_digest="$(tr -d '\n' < "${plan_root}/web-release.render-sha256")"
    [[ "$(python3 -I -c 'import hashlib, pathlib, sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "${plan_root}/web-release.rendered.yaml")" == "${recorded_digest}" ]] || { echo "Recorded web release plan bytes do not match their receipt; re-plan" >&2; exit 2; }
    recheck="$(mktemp "${plan_root}/web-release.recheck.XXXXXX")"
    chmod 600 "${recheck}"
    trap 'rm -f "${recheck}"' EXIT
    just --justfile "${repo_root}/Justfile" --working-directory "${repo_root}" web-release-render > "${recheck}"
    [[ "$(python3 -I -c 'import hashlib, pathlib, sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "${recheck}")" == "${recorded_digest}" ]] || { echo "Reviewed manifests re-render differently than the recorded plan; re-plan" >&2; exit 2; }
    echo "web release plan preflight passed: render sha256:${recorded_digest}"

# Server-side dry-run of the EXACT recorded plan bytes. No mutation.
web-release-server-dry-run: _web-release-apply-kubeconfig-contract _web-release-plan-preflight
    #!/usr/bin/env -S BASH_ENV= ENV= SHELLOPTS= BASHOPTS= bash -p
    set +x
    set -euo pipefail
    repo_root="$(git rev-parse --show-toplevel)"
    kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" --namespace {{ web_stack_ns }} apply --dry-run=server -f "${repo_root}/.k8s-plans/web-release.rendered.yaml"

# ATTENDED APPLY. Gated exactly like arc-apply: a clean, signed checkout equal to
# canonical main, GFTB_APPLY_CONFIRM=apply, an operator-custody kubeconfig, and a
# plan that still reproduces byte-for-byte. It dry-runs, applies the recorded
# bytes, prunes the two legacy adapter-node egress policies the render omits
# (`kubectl apply` does not prune omissions), and waits for the rollout.
web-release-apply: _reviewed-clean-main _operator-apply-confirm _web-release-apply-kubeconfig-contract _web-release-plan-preflight
    #!/usr/bin/env -S BASH_ENV= ENV= SHELLOPTS= BASHOPTS= bash -p
    set +x
    set -euo pipefail
    repo_root="$(git rev-parse --show-toplevel)"
    plan="${repo_root}/.k8s-plans/web-release.rendered.yaml"
    kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" --namespace {{ web_stack_ns }} apply --dry-run=server -f "${plan}"
    kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" --namespace {{ web_stack_ns }} apply -f "${plan}"
    kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" --namespace {{ web_stack_ns }} delete networkpolicy allow-egress-dns allow-egress-discuss-archive --ignore-not-found
    kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" --namespace {{ web_stack_ns }} rollout status deployment/greatfallstoolbus-org --timeout=300s
    echo "web release applied; now run the PINNED/RUNNING and SERVED proofs"

# --- K8s stack drift check (read-only; scheduled by .github/workflows/k8s-stack-drift.yml) ---
# `kubectl diff -k <dir>` against the LIVE cluster, namespace-scoped -- no
# mutation. Reuses the SAME kubeconfig secrets the existing server-dry-run/apply
# recipes above already require; no new credential is introduced. Exit code
# semantics of `kubectl diff`: 0 = no drift, 1 = drift found, >1 = a real error
# (bad kubeconfig, RBAC, API reachability).
#
# Every stack is now a TRUE zero-diff assertion: nothing patches any of them
# imperatively after their apply recipe runs, so ANY diff is real drift and
# the check fails, mirroring edge-drift.yml's "assert zero-diff" gate.
# `fail_on_drift` was a per-caller toggle until 2026-08-21's adversarial
# review (B1/E1) -- every one of the six callers below had already been set
# to `true`, making the `false` branch (a "parked skeleton, EXPECTED by
# design" warning) dead code that kept restating exactly the class of stale
# claim this whole PR exists to retire. Removed rather than left dormant.
#
# web (rung 1 tree honesty, 2026-08-21; session register L71 Q2 rungs 1+2):
# k8s/web/greatfallstoolbus-org-production is ATTENDED-ONLY declare-only, not
# parked: it carries replicas:2 and a digest-pinned image of the promoted
# gftb-site static origin, and creates no namespace
# (scripts/validate-web-stack.sh guards exactly that). Until this fix, this
# header claimed the live/git divergence was PERMANENT and by-design,
# because the tree still named the retired legacy adapter-node image after
# the gftb-site promotion. It wasn't by design; it was this declarative
# record never being updated at promotion time.
#
# WHY WEB IS REACHABLE-ZERO-DIFF, NOT GUARANTEED-RED (adversarial review B2):
# the web-release-* ceremony's render step (`web-release-render`)
# unconditionally stamps `app.tinyland.dev/source-sha` onto the live
# Deployment's pod-template annotations at every release; the checked-in base
# deliberately never carries a static value for it (the value changes every
# release, so no committed value could ever be "correct"). A raw `kubectl
# diff -k` would therefore report that one annotation as drift on EVERY run,
# forever, making a fail-on-diff gate permanently red for a reason that is
# not drift. `web-stack-drift-check` below wires `scripts/web-stack-diff.sh`
# in as `KUBECTL_EXTERNAL_DIFF` to strip exactly that one known-synthesized
# annotation from both sides before diffing -- see that script for the full
# rationale. This is scoped to the web caller only; the other five stacks
# below are untouched and still use kubectl's own default differ.
#
# WHAT THIS GATE CANNOT SEE, EVEN AFTER THAT FIX: `kubectl diff -k` compares
# the rendered LOCAL manifest set against LIVE and has no prune awareness --
# it is blind to any object that exists ONLY on the cluster. The
# web-release-* ceremony also synthesizes a `default-deny-egress`
# NetworkPolicy at render time that the checked-in base does not declare;
# that object will NEVER surface as a diff here, for any input, by
# construction of `kubectl diff -k` itself -- there is nothing on the LOCAL
# side to diff it against. A clean run of this gate is not evidence that
# NetworkPolicy is absent or correct; it is simply invisible to this specific
# check (see k8s/web/greatfallstoolbus-org-production/networkpolicy.yaml and
# k8s/web/README.md). This check is read-only and therefore not interlocked;
# the attended mutating carrier is (see _web-stack-promotion-interlock).
_k8s-drift-check kubeconfig namespace dir label:
    #!/usr/bin/env bash
    set -uo pipefail
    test -n "{{ kubeconfig }}" || { echo "kubeconfig path is required"; exit 1; }
    test -f "{{ kubeconfig }}" || { echo "kubeconfig not found at {{ kubeconfig }}"; exit 1; }
    kubectl --kubeconfig "{{ kubeconfig }}" --namespace {{ namespace }} diff -k {{ dir }} > "{{ label }}-drift.txt" 2>&1
    rc=$?
    cat "{{ label }}-drift.txt"
    if [ "${rc}" -eq 0 ]; then
      echo "{{ label }}: zero-diff (live cluster matches git)."
      exit 0
    elif [ "${rc}" -eq 1 ]; then
      echo "::error::{{ label }} DRIFTED: live cluster state differs from the committed manifests. See {{ label }}-drift.txt (uploaded as a workflow artifact)."
      exit 1
    else
      echo "::error::kubectl diff errored (rc=${rc}) probing {{ label }}."
      exit "${rc}"
    fi

mail-cr-drift-check: _mail-kubeconfig-inputs
    just _k8s-drift-check "${GFTB_MAIL_KUBECONFIG}" latoolb-us-production {{ mail_cr_dir }} mail-cr

list-stack-drift-check: _mail-kubeconfig-inputs
    just _k8s-drift-check "${GFTB_MAIL_KUBECONFIG}" latoolb-us-production {{ list_stack_dir }} list-stack

form-stack-drift-check: _mail-kubeconfig-inputs
    just _k8s-drift-check "${GFTB_MAIL_KUBECONFIG}" latoolb-us-production {{ form_stack_dir }} form-stack

archive-stack-drift-check: _mail-kubeconfig-inputs
    just _k8s-drift-check "${GFTB_MAIL_KUBECONFIG}" latoolb-us-production {{ archive_stack_dir }} archive-stack

# TIN-3813 EDIT-2 (infra #122 review): "activation is an operator decision in
# git" is only true if drift enforces it, specifically so an out-of-band
# `kubectl patch cronjob mailman-listsync -p '{"spec":{"suspend":false}}'`
# (or a dry-run/secret/list-pair patch) shows up here instead of silently
# taking effect between scheduled runs.
listsync-stack-drift-check: _mail-kubeconfig-inputs
    just _k8s-drift-check "${GFTB_MAIL_KUBECONFIG}" latoolb-us-production {{ listsync_stack_dir }} listsync-stack

# rung 1 tree honesty (2026-08-21): see the _k8s-drift-check header -- the web
# declaration now names the same repository the promoted static origin
# actually runs, so a diff here is a real signal, not by-design noise.
# KUBECTL_EXTERNAL_DIFF is set to scripts/web-stack-diff.sh (this caller
# ONLY) so the one ceremony-synthesized `source-sha` annotation doesn't make
# this gate permanently red -- see the _k8s-drift-check header and that
# script for why, and for the separate default-deny-egress NetworkPolicy
# residual this gate can never observe regardless.
web-stack-drift-check: _web-apply-kubeconfig-only
    #!/usr/bin/env bash
    set -euo pipefail
    repo_root="$(git rev-parse --show-toplevel)"
    export KUBECTL_EXTERNAL_DIFF="${repo_root}/scripts/web-stack-diff.sh"
    just _k8s-drift-check "${WEB_APPLY_KUBECONFIG}" {{ web_stack_ns }} {{ web_stack_dir }} web-stack

# Reconciliation-safety review (PR #135, E3): scripts/web-stack-diff.sh had
# ZERO tests (`git grep web-stack-diff` returned only Justfile wiring and
# doc comments) even though its own header has demanded since round 2 that
# it "MUST be exercised with two directories in any test, never two bare
# files, or a regression here reads as passing again." This runs the five
# fixture cases that proved the yq-go/jq rewrite (sweep g1, 2026-08-29)
# actually works, folded into `just check-hosted` so the next calling-convention
# change cannot ship blind. Requires real yq-go + jq on PATH; flake.nix pins
# both for the repo devshell and remote validation.
web-stack-diff-selftest:
    ./scripts/test-web-stack-diff.sh
