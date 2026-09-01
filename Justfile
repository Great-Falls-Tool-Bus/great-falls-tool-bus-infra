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
    @bash scripts/remote-only-guard.sh check-hosted
    just workflow-lint
    just secrets-scan-dir
    # history-mode gitleaks (hosted home of the removed local-only secrets-scan recipe)
    gitleaks git --config .gitleaks.toml --redact --verbose .
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
    @bash scripts/remote-only-guard.sh secrets-scan-dir
    gitleaks dir --config .gitleaks.toml --redact --verbose .

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
    bash scripts/remote-only-guard.sh workflow-lint
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
      printf "actionlint: %s\n" "${workflow}"
      lint_rc=0
      timeout --signal=TERM --kill-after=5s 30s \
        actionlint -ignore "label \"tinyland-nix\" is unknown" -ignore "SC2155" "${workflow}" || lint_rc=$?
      case "${lint_rc}" in
        0) ;;
        124|137)
          printf "::error file=%s,title=actionlint timeout::actionlint exceeded 30 seconds for %s\n" "${workflow}" "${workflow}" >&2
          exit 1
          ;;
        *)
          printf "::error file=%s,title=actionlint failed::actionlint exited %s for %s\n" "${workflow}" "${lint_rc}" "${workflow}" >&2
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
    @bash scripts/remote-only-guard.sh flywheel-cache-proof
    GFW_EXPECTED_INSTANCE_NAME=org-great-falls-tool-bus bash scripts/flywheel-cache-proof.sh

arc-fmt-check:
    #!/usr/bin/env bash
    # Fresh-clone friendly: use tofu from PATH when present; the GF-core nix
    # devshell is the fallback for machines without tofu installed. GF_CORE_CI_PATH
    # defaults to a pinned GitHub flake ref, not a sibling checkout.
    set -euo pipefail
    bash scripts/remote-only-guard.sh arc-fmt-check
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
    #             runner container ephemeral-storage 4Gi->8Gi / 8Gi->16Gi bump,
    #             or (TIN-4246, bounded exception) the 8Gi->12Gi / 16Gi->24Gi
    #             bump, or that bump's exact reverse 12Gi->8Gi / 24Gi->16Gi.
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
    # #113 landed the runner-group cutover itself; live state has been 8/16Gi
    # in the dedicated great-falls-tool-bus-infra runner group ever since. The
    # live pre-cutover state was therefore already 8/16Gi, so a fresh cutover
    # plan (and the ratified rollback fallback from the post-cutover state)
    # carries no storage delta. TIN-4246 (2026-08-31, bounded exception) moves
    # live state from that same dedicated group to 12/24Gi; its own reverse is
    # admitted in the capacity shape so the exception can be rolled back
    # without a fresh scope-contract PR, and Codex #146's generic-ephemeral
    # PVC pattern is the durable fix that retires it. Each shape admits only
    # its enumerated storage transitions and nothing in between: mixed states
    # are refused, and the group-move deltas stay byte-strict either way.
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
    EXPANDED_STORAGE = {"requests": "12Gi", "limits": "24Gi"}
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
        admitted_storage = (
            (LOW_STORAGE, HIGH_STORAGE),
            (HIGH_STORAGE, EXPANDED_STORAGE),
            (EXPANDED_STORAGE, HIGH_STORAGE),
        )
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
        # Keyed on the observed BEFORE pair, which admitted_storage above has
        # already constrained to one of exactly three rows, so this lookup is
        # unambiguous and cannot silently fall through to the wrong direction.
        capacity_transforms = {
            (LOW_STORAGE["requests"], LOW_STORAGE["limits"]): {"4Gi": "8Gi", "8Gi": "16Gi"},
            (HIGH_STORAGE["requests"], HIGH_STORAGE["limits"]): {"8Gi": "12Gi", "16Gi": "24Gi"},
            (EXPANDED_STORAGE["requests"], EXPANDED_STORAGE["limits"]): {"12Gi": "8Gi", "24Gi": "16Gi"},
        }
        promote = capacity_transforms[(before_storage["requests"], before_storage["limits"])]
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
        transition_label = (
            before_storage["requests"]
            + "/"
            + before_storage["limits"]
            + " -> "
            + after_storage["requests"]
            + "/"
            + after_storage["limits"]
        )
        if expected_values != after_values[0]:
            raise SystemExit(
                "ERROR: gh_nix Helm values contain changes beyond " + transition_label
            )
        print("ARC plan scope guard passed: exact gh_nix " + transition_label + " update only.")
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
                "ERROR: gh_nix Helm values contain changes beyond the reviewed runner-group "
                "rollback (runnerGroup, the admitted ephemeral-storage transition, "
                "pinned runner image digest, GF_FLYWHEEL_PROFILE_STATE, "
                "arc-runner priorityClassName)"
            )
        print(
            "ARC plan scope guard passed: exact gh_nix runner-group rollback update "
            "plus the state-only runner_group_policy destroy."
        )
    PY
    plan_digest_after="$(python3 -I -c 'import hashlib,pathlib,sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "${plan_path}")"
    test "${plan_digest_after}" = "${plan_digest}" || { echo "ARC plan changed during scope review" >&2; exit 2; }
    if [[ "${reconcile}" == "false" ]]; then
        printf '%s\n' "${plan_digest}" > .tofu-plans/arc-runners.scope-sha256
        chmod 600 .tofu-plans/arc-runners.scope-sha256
    fi

arc-apply: _reviewed-clean-main _reviewed-arc-core _operator-apply-confirm _arc-exclusive-confirm _arc-plan-input-preflight arc-init arc-plan-scope-check
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
    test -f .tofu-plans/arc-runners.tfplan
    test -f .tofu-plans/arc-runners.source-sha
    test -f .tofu-plans/arc-runners.core-sha
    test -f .tofu-plans/arc-runners.backend-blob
    test -f .tofu-plans/arc-runners.plan-sha256
    test -f .tofu-plans/arc-runners.scope-sha256
    test ! -e .tofu-plans/arc-runners.apply-attempted || { echo "ARC plan was already submitted; create and review a fresh plan" >&2; exit 2; }
    test "$(git rev-parse HEAD)" = "$(tr -d '\n' < .tofu-plans/arc-runners.source-sha)" || { echo "ARC plan was created from a different infra revision" >&2; exit 2; }
    test "$(git -C "${core}" rev-parse HEAD)" = "$(tr -d '\n' < .tofu-plans/arc-runners.core-sha)" || { echo "ARC plan was created from a different GloriousFlywheel revision" >&2; exit 2; }
    test "$(python3 -I -c 'import hashlib,pathlib,sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "${backend}")" = "$(tr -d '\n' < .tofu-plans/arc-runners.backend-blob)" || { echo "ARC plan was created with a different backend declaration" >&2; exit 2; }
    [[ -z "$(git status --porcelain)" ]] || { echo "Infra worktree changed before ARC apply" >&2; exit 2; }
    [[ -z "$(git -C "${core}" status --porcelain)" ]] || { echo "ARC core changed before apply" >&2; exit 2; }
    just _arc-plan-input-preflight
    workspace="$(TF_CLI_CONFIG_FILE=/dev/null TF_VAR_k8s_config_path="${kubeconfig}" TF_DATA_DIR="${data_dir}" nix develop "${core_ci}" -c tofu -chdir="${core}/tofu/stacks/arc-runners" workspace show)"
    [[ "${workspace}" == "default" ]] || { echo "ARC state must use the default workspace, observed ${workspace}" >&2; exit 2; }
    just _arc-plan-input-preflight
    plan_digest="$(python3 -I -c 'import hashlib,pathlib,sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' .tofu-plans/arc-runners.tfplan)"
    test "${plan_digest}" = "$(tr -d '\n' < .tofu-plans/arc-runners.plan-sha256)" || { echo "ARC plan digest changed after planning" >&2; exit 2; }
    test "${plan_digest}" = "$(tr -d '\n' < .tofu-plans/arc-runners.scope-sha256)" || { echo "ARC plan is not the exact scope-reviewed artifact" >&2; exit 2; }
    printf '%s\n' "${plan_digest}" > .tofu-plans/arc-runners.apply-attempted
    chmod 600 .tofu-plans/arc-runners.apply-attempted
    TF_CLI_CONFIG_FILE=/dev/null TF_VAR_k8s_config_path="${kubeconfig}" TF_DATA_DIR="${data_dir}" nix develop "${core_ci}" -c tofu -chdir="${core}/tofu/stacks/arc-runners" apply -input=false "$(pwd)/.tofu-plans/arc-runners.tfplan"
    rm -f .tofu-plans/arc-runners.tfplan .tofu-plans/arc-runners.source-sha .tofu-plans/arc-runners.core-sha .tofu-plans/arc-runners.backend-blob .tofu-plans/arc-runners.kubeconfig-blob .tofu-plans/arc-runners.cluster-uid .tofu-plans/arc-runners.target-uid .tofu-plans/arc-runners.plan-sha256 .tofu-plans/arc-runners.scope-sha256 .tofu-plans/arc-runners.apply-attempted
    rm -rf -- "${data_dir}"

# Read-only closure receipt for the reviewed ARC transaction. It proves that
# canonical remote state, a refreshed plan, the live ARC object, and the listener
# all converge on the same reviewed capacity AND the same reviewed runner group,
# without reusing the apply session. TIN-3902: `.spec.runnerGroup` is the one
# thing the cutover changes, so a receipt that never reads it can go green while
# the fleet is still idle in GitHub's Default group.
arc-capacity-readback: _reviewed-clean-main _reviewed-arc-core _arc-exclusive-confirm _arc-backend-contract _arc-runtime-contract _arc-artifact-root-contract
    #!/usr/bin/env bash
    set -euo pipefail
    umask 077
    core="${GF_ARC_CORE_PATH:-{{ arc_core_default }}}"
    core_ci="${GF_ARC_CORE_CI_PATH:-{{ arc_core_ci_default }}}"
    kubeconfig="${GFTB_ARC_KUBECONFIG:?Set GFTB_ARC_KUBECONFIG to the reviewed ARC kubeconfig}"
    backend="${ARC_BACKEND:-{{ arc_backend_default }}}"
    if [[ "${backend}" != /* ]]; then
        backend="$(pwd)/${backend}"
    fi
    mode="${GFTB_ARC_READBACK_MODE:-promoted}"
    [[ "${mode}" == "promoted" || "${mode}" == "rolled-back" || "${mode}" == "reconcile" ]] || { echo "GFTB_ARC_READBACK_MODE must be promoted, rolled-back, or reconcile" >&2; exit 2; }
    if [[ "${mode}" == "reconcile" ]]; then
        test -f .tofu-plans/arc-runners.apply-attempted || { echo "No ambiguous ARC apply attempt requires reconciliation" >&2; exit 2; }
    fi
    readback_dir="$(mktemp -d "$(pwd)/.tofu-plans/arc-readback.XXXXXX")"
    data_dir="${readback_dir}/tfdata"
    state_json="${readback_dir}/state.json"
    nochange_plan="${readback_dir}/nochange.tfplan"
    plan_log="${readback_dir}/plan.log"
    mkdir -m 700 "${data_dir}"
    trap 'rm -rf "${readback_dir}"' EXIT
    TF_CLI_CONFIG_FILE=/dev/null TF_VAR_k8s_config_path="${kubeconfig}" TF_DATA_DIR="${data_dir}" nix develop "${core_ci}" -c tofu -chdir="${core}/tofu/stacks/arc-runners" init -reconfigure -input=false -lockfile=readonly -backend-config="${backend}" >/dev/null
    workspace="$(TF_CLI_CONFIG_FILE=/dev/null TF_VAR_k8s_config_path="${kubeconfig}" TF_DATA_DIR="${data_dir}" nix develop "${core_ci}" -c tofu -chdir="${core}/tofu/stacks/arc-runners" workspace show)"
    [[ "${workspace}" == "default" ]] || { echo "ARC state must use the default workspace, observed ${workspace}" >&2; exit 2; }
    TF_CLI_CONFIG_FILE=/dev/null TF_VAR_k8s_config_path="${kubeconfig}" TF_DATA_DIR="${data_dir}" nix develop "${core_ci}" -c tofu -chdir="${core}/tofu/stacks/arc-runners" show -json > "${state_json}"
    state_values="$(jq -er '
      [.. | objects | select(.address? == "module.gh_nix.helm_release.arc_runner")]
      | if length == 1 and (.[0].values.values | length) == 1
        then .[0].values.values[0]
        else error("expected exactly one gh_nix Helm state value")
        end
    ' "${state_json}")"
    state_request="$(yq -r '.template.spec.containers[] | select(.name == "runner") | .resources.requests."ephemeral-storage"' <<<"${state_values}")"
    state_limit="$(yq -r '.template.spec.containers[] | select(.name == "runner") | .resources.limits."ephemeral-storage"' <<<"${state_values}")"
    live_json="$(kubectl --kubeconfig "${kubeconfig}" --context honey -n arc-runners get autoscalingrunnerset great-falls-tool-bus-nix -o json)"
    jq -e --arg uid "{{ arc_target_uid }}" '
      .metadata.uid == $uid
      and .spec.minRunners == 0
      and .spec.maxRunners == 4
      and .status.phase == "Running"
      and (.status.pendingEphemeralRunners // 0) == 0
      and ([.spec.template.spec.containers[] | select(.name == "runner")] | length == 1)
    ' <<<"${live_json}" >/dev/null || { echo "Live great-falls-tool-bus-nix is not healthy" >&2; exit 2; }
    live_request="$(jq -er '[.spec.template.spec.containers[] | select(.name == "runner")] | if length == 1 then .[0].resources.requests["ephemeral-storage"] else error("expected one runner container") end' <<<"${live_json}")"
    live_limit="$(jq -er '[.spec.template.spec.containers[] | select(.name == "runner")] | if length == 1 then .[0].resources.limits["ephemeral-storage"] else error("expected one runner container") end' <<<"${live_json}")"
    [[ "${state_request}" == "${live_request}" && "${state_limit}" == "${live_limit}" ]] || { echo "Canonical ARC state and live runner capacity disagree" >&2; exit 2; }
    [[ ( "${state_request}" == "4Gi" && "${state_limit}" == "8Gi" ) || ( "${state_request}" == "8Gi" && "${state_limit}" == "16Gi" ) || ( "${state_request}" == "12Gi" && "${state_limit}" == "24Gi" ) ]] || { echo "ARC capacity is outside the reviewed pre/post states" >&2; exit 2; }
    state_group="$(jq -er '
      [.. | objects | select(.address? == "module.gh_nix.helm_release.arc_runner")]
      | if length == 1
        then [.[0].values.set[] | select(.name == "runnerGroup")]
        else error("expected exactly one gh_nix Helm state resource")
        end
      | if length == 1
        then .[0].value
        else error("expected exactly one gh_nix runnerGroup set entry")
        end
    ' "${state_json}")"
    live_group="$(jq -er '.spec.runnerGroup' <<<"${live_json}")"
    [[ "${state_group}" == "${live_group}" ]] || { echo "Canonical ARC state and live runner group disagree: ${state_group} vs ${live_group}" >&2; exit 2; }
    [[ "${state_group}" == "default" || "${state_group}" == "great-falls-tool-bus-infra" ]] || { echo "ARC runner group is outside the reviewed pre/post admission identities: ${state_group}" >&2; exit 2; }
    if [[ "${mode}" == "promoted" ]]; then
        [[ ( "${state_request}" == "8Gi" && "${state_limit}" == "16Gi" ) || ( "${state_request}" == "12Gi" && "${state_limit}" == "24Gi" ) ]] || { echo "ARC capacity promotion is not converged at 8Gi/16Gi or the TIN-4246 12Gi/24Gi" >&2; exit 2; }
        [[ "${state_group}" == "great-falls-tool-bus-infra" ]] || { echo "ARC runner-group cutover is not converged at great-falls-tool-bus-infra" >&2; exit 2; }
    fi
    if [[ "${mode}" == "rolled-back" ]]; then
        # TIN-2299's capacity bump applied on 2026-08-17 as helm_release
        # great-falls-tool-bus-nix revision 6 with runnerGroup still `default`,
        # decomposing TIN-3902's cutover. The ratified rollback from the
        # post-cutover state is therefore the group-move reversal alone, which
        # converges at the retained 8Gi/16Gi; the original combined reversal
        # converges at 4Gi/8Gi and stays certifiable for a deliberate,
        # separately-decided capacity revert. Both converge at group `default`.
        [[ ( "${state_request}" == "4Gi" && "${state_limit}" == "8Gi" ) || ( "${state_request}" == "8Gi" && "${state_limit}" == "16Gi" ) ]] || { echo "ARC rollback is not converged at 4Gi/8Gi or the capacity-retained 8Gi/16Gi" >&2; exit 2; }
        [[ "${state_group}" == "default" ]] || { echo "ARC runner-group rollback is not converged at default" >&2; exit 2; }
    fi
    listener_json="$(kubectl --kubeconfig "${kubeconfig}" --context honey -n arc-systems get pods -l actions.github.com/scale-set-name=great-falls-tool-bus-nix,actions.github.com/scale-set-namespace=arc-runners,app.kubernetes.io/component=runner-scale-set-listener -o json)"
    jq -e '
      (.items | length) == 1
      and .items[0].metadata.deletionTimestamp == null
      and .items[0].status.phase == "Running"
      and any(.items[0].status.conditions[]?; .type == "Ready" and .status == "True")
      and (.items[0].status.containerStatuses | length) > 0
      and all(.items[0].status.containerStatuses[]; .ready == true and .restartCount == 0)
    ' <<<"${listener_json}" >/dev/null || { echo "GFTB ARC listener is not one Ready zero-restart pod" >&2; exit 2; }
    set +e
    TF_CLI_CONFIG_FILE=/dev/null TF_VAR_k8s_config_path="${kubeconfig}" TF_DATA_DIR="${data_dir}" nix develop "${core_ci}" -c tofu -chdir="${core}/tofu/stacks/arc-runners" plan -input=false -detailed-exitcode -var-file="$(pwd)/{{ arc_tfvars }}" -out="${nochange_plan}" >"${plan_log}" 2>&1
    plan_status=$?
    set -e
    # Classification is keyed on the refreshed plan and the runner group, NOT on
    # the storage level. Storage stopped being a pre/post proxy on 2026-08-17,
    # when TIN-2299's capacity bump applied on its own as helm_release revision 6
    # and left the pre-cutover state already at 8Gi/16Gi: a pending decomposed
    # cutover (or rollback) plan must still be able to reach the reconcile arm
    # that re-runs arc-plan-scope-check, and a converged group=default state at
    # either admitted storage level must be certifiable as rolled-back.
    # TIN-4246 adds a third admitted level, 12Gi/24Gi, reachable only through
    # the capacity shape and therefore only inside the dedicated runner group:
    # `promoted` certifies 8Gi/16Gi or 12Gi/24Gi, while `rolled-back` still
    # demands 4Gi/8Gi or 8Gi/16Gi, so a group-move reversal cannot certify
    # itself while the bounded exception is still live.
    if [[ "${plan_status}" == "2" ]]; then
        [[ "${mode}" == "reconcile" ]] || { echo "ARC state/source/live refresh is not a no-change plan (status 2); only GFTB_ARC_READBACK_MODE=reconcile may certify a pending plan" >&2; exit 2; }
        GFTB_ARC_READBACK_MODE=reconcile GFTB_ARC_RECONCILE_PLAN_PATH="${nochange_plan}" GFTB_ARC_RECONCILE_DATA_DIR="${data_dir}" just arc-plan-scope-check
        receipt="pre-change state/live ${state_request}/${state_limit} in runner group ${state_group} with an exact pending scope-reviewed plan; create and review a fresh plan"
    elif [[ "${state_group}" == "great-falls-tool-bus-infra" ]]; then
        [[ ( "${state_request}" == "8Gi" && "${state_limit}" == "16Gi" ) || ( "${state_request}" == "12Gi" && "${state_limit}" == "24Gi" ) ]] || { echo "ARC dedicated-group state is outside the reviewed promoted capacity" >&2; exit 2; }
        [[ "${plan_status}" == "0" ]] || { echo "Promoted ARC state/source/live refresh is not a no-change plan (status ${plan_status})" >&2; exit 2; }
        receipt="promoted state/live ${state_request}/${state_limit} in runner group ${state_group} with refreshed no-change plan"
    else
        [[ "${plan_status}" == "0" ]] || { echo "ARC state/source/live refresh failed (status ${plan_status})" >&2; exit 2; }
        [[ "${mode}" == "rolled-back" ]] || { echo "ARC state/live is converged in runner group default with a no-change plan, which is a completed rollback or the decomposed pre-cutover state; re-run with GFTB_ARC_READBACK_MODE=rolled-back" >&2; exit 2; }
        if [[ "${state_request}" == "8Gi" && "${state_limit}" == "16Gi" ]]; then
            receipt="rolled-back state/live 8Gi/16Gi in runner group default with refreshed no-change plan; decomposed group-move reversal, TIN-2299 capacity retained"
        else
            receipt="rolled-back state/live 4Gi/8Gi in runner group default with refreshed no-change plan"
        fi
    fi
    just _reviewed-clean-main
    just _reviewed-arc-core
    just _arc-backend-contract
    just _arc-runtime-contract
    if [[ -e .tofu-plans/arc-runners.apply-attempted ]]; then
        rm -f .tofu-plans/arc-runners.tfplan .tofu-plans/arc-runners.source-sha .tofu-plans/arc-runners.core-sha .tofu-plans/arc-runners.backend-blob .tofu-plans/arc-runners.kubeconfig-blob .tofu-plans/arc-runners.cluster-uid .tofu-plans/arc-runners.target-uid .tofu-plans/arc-runners.plan-sha256 .tofu-plans/arc-runners.scope-sha256 .tofu-plans/arc-runners.apply-attempted
        attempted_data_dir="$(pwd)/.tofu-plans/arc-runners.tfdata"
        if [[ -e "${attempted_data_dir}" || -L "${attempted_data_dir}" ]]; then
            [[ -d "${attempted_data_dir}" && ! -L "${attempted_data_dir}" ]] || { echo "ARC attempted TF_DATA_DIR is not a real directory" >&2; exit 2; }
            rm -rf -- "${attempted_data_dir}"
        fi
    fi
    echo "ARC capacity/runner-group receipt passed: ${receipt}; listener Ready."

arc-enrollment-plan: enrollment-preflight arc-plan
    @echo "Review with just arc-plan-show and just arc-plan-scope-check."
    @echo "Then run: GFTB_APPLY_CONFIRM=apply GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive just arc-apply"
    @echo "Then prove: GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive just arc-capacity-readback"

# Production mutation must originate from clean, signed, current canonical main.
# The remote readback prevents a stale local origin/main ref from becoming apply
# authority.
_reviewed-clean-main:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "$(git branch --show-current)" == "main" ]] || { echo "Guarded ARC operation requires the main branch" >&2; exit 2; }
    [[ -z "$(git status --porcelain)" ]] || { echo "Guarded ARC operation requires a clean worktree" >&2; exit 2; }
    index_flags="$(git ls-files -v | awk '$1 != "H"')"
    [[ -z "${index_flags}" ]] || { echo "Guarded ARC operation refuses assume-unchanged, skip-worktree, or non-cached index flags: ${index_flags}" >&2; exit 2; }
    canonical_remote="https://github.com/Great-Falls-Tool-Bus/great-falls-tool-bus-infra.git"
    origin_url="$(git remote get-url origin)"
    case "${origin_url}" in
      https://github.com/Great-Falls-Tool-Bus/great-falls-tool-bus-infra|https://github.com/Great-Falls-Tool-Bus/great-falls-tool-bus-infra.git|git@github.com:Great-Falls-Tool-Bus/great-falls-tool-bus-infra.git) ;;
      *) echo "Guarded ARC operation origin is not the canonical GFTB infra repository: ${origin_url}" >&2; exit 2 ;;
    esac
    git show-ref --verify --quiet refs/remotes/origin/main || { echo "Fetch canonical origin/main before the guarded ARC operation" >&2; exit 2; }
    head_sha="$(git rev-parse HEAD)"
    origin_sha="$(git rev-parse origin/main)"
    [[ "${head_sha}" == "${origin_sha}" ]] || { echo "Guarded ARC operation HEAD ${head_sha} is not origin/main ${origin_sha}" >&2; exit 2; }
    remote_sha="$(git ls-remote --exit-code "${canonical_remote}" refs/heads/main | awk 'NR == 1 { print $1 }')"
    [[ "${remote_sha}" =~ ^[0-9a-f]{40}$ ]] || { echo "Could not resolve the current remote main SHA" >&2; exit 2; }
    [[ "${head_sha}" == "${remote_sha}" ]] || { echo "Guarded ARC operation HEAD ${head_sha} is not current remote main ${remote_sha}" >&2; exit 2; }
    git verify-commit "${head_sha}" >/dev/null
    echo "reviewed infra carrier: ${head_sha}"

# Enrollment and GitHub App Secret materialization use the implementation-role
# core pin. They may not execute an arbitrary sibling checkout.
_reviewed-implementation-core:
    #!/usr/bin/env bash
    set -euo pipefail
    core="${GF_CORE_PATH:-../GloriousFlywheel}"
    test -d "${core}/.git" -o -f "${core}/.git" || { echo "GF_CORE_PATH is not a Git checkout: ${core}" >&2; exit 2; }
    [[ -z "$(git -C "${core}" status --porcelain)" ]] || { echo "GloriousFlywheel implementation core must be clean" >&2; exit 2; }
    index_flags="$(git -C "${core}" ls-files -v | awk '$1 != "H"')"
    [[ -z "${index_flags}" ]] || { echo "GloriousFlywheel implementation core refuses assume-unchanged, skip-worktree, or non-cached index flags: ${index_flags}" >&2; exit 2; }
    [[ "$(git -C "${core}" rev-parse HEAD)" == "{{ gf_core_sha }}" ]] || { echo "GloriousFlywheel implementation core must be {{ gf_core_sha }}" >&2; exit 2; }
    case "$(git -C "${core}" remote get-url origin)" in
      https://github.com/tinyland-inc/GloriousFlywheel|https://github.com/tinyland-inc/GloriousFlywheel.git|git@github.com:tinyland-inc/GloriousFlywheel.git) ;;
      *) echo "GloriousFlywheel implementation core origin is not canonical" >&2; exit 2 ;;
    esac
    git -C "${core}" verify-commit "{{ gf_core_sha }}" >/dev/null

# ARC uses the role-specific, signed GloriousFlywheel source pin. The separate
# checkout avoids silently substituting a newer implementation-core worktree.
_reviewed-arc-core:
    #!/usr/bin/env bash
    set -euo pipefail
    core="${GF_ARC_CORE_PATH:-{{ arc_core_default }}}"
    test -d "${core}/.git" -o -f "${core}/.git" || { echo "GF_ARC_CORE_PATH is not a Git checkout: ${core}" >&2; exit 2; }
    [[ -z "$(git -C "${core}" status --porcelain)" ]] || { echo "GloriousFlywheel ARC core must be clean" >&2; exit 2; }
    index_flags="$(git -C "${core}" ls-files -v | awk '$1 != "H"')"
    [[ -z "${index_flags}" ]] || { echo "GloriousFlywheel ARC core refuses assume-unchanged, skip-worktree, or non-cached index flags: ${index_flags}" >&2; exit 2; }
    [[ "$(git -C "${core}" rev-parse HEAD)" == "{{ arc_core_sha }}" ]] || { echo "GloriousFlywheel ARC core must be {{ arc_core_sha }}" >&2; exit 2; }
    case "$(git -C "${core}" remote get-url origin)" in
      https://github.com/tinyland-inc/GloriousFlywheel|https://github.com/tinyland-inc/GloriousFlywheel.git|git@github.com:tinyland-inc/GloriousFlywheel.git) ;;
      *) echo "GloriousFlywheel ARC core origin is not canonical" >&2; exit 2 ;;
    esac
    git -C "${core}" verify-commit "{{ arc_core_sha }}" >/dev/null
    core_abs="$(cd "${core}" && pwd -P)"
    core_ci="${GF_ARC_CORE_CI_PATH:-{{ arc_core_ci_default }}}"
    pinned_ci="github:tinyland-inc/GloriousFlywheel/{{ arc_core_sha }}#ci"
    local_ci="path:${core_abs}#ci"
    declared_local_ci="path:${core}#ci"
    [[ "${core_ci}" == "${pinned_ci}" || "${core_ci}" == "${local_ci}" || "${core_ci}" == "${declared_local_ci}" ]] || { echo "GF_ARC_CORE_CI_PATH must be ${pinned_ci} or the reviewed local checkout ${local_ci}" >&2; exit 2; }
    untracked="$(
      {
        git -C "${core}" ls-files --others --exclude-standard -- tofu/stacks/arc-runners tofu/modules
        git -C "${core}" ls-files --others --ignored --exclude-standard -- tofu/stacks/arc-runners tofu/modules
      } | sort -u
    )"
    unexpected="$(python3 -I -c 'import re,sys; pattern=re.compile(r"(^|/)\.terraform(/|$)|(^|/)(override\.(tf|tofu)|.*_override\.(tf|tofu)|.*\.auto\.tfvars(\.json)?|.*\.tfvars(\.json)?|.*\.(tf|tofu)(\.json)?)$"); print("\\n".join(line for line in sys.stdin.read().splitlines() if pattern.search(line)))' <<<"${untracked}")"
    [[ -z "${unexpected}" ]] || { echo "GloriousFlywheel ARC core contains untracked/ignored Terraform input: ${unexpected}" >&2; exit 2; }

# The canonical RustFS state identity is immutable here. A temporary backend may
# replace only the S3 endpoint with a loopback port-forward; it must stay outside
# the public repository and mode 0600.
_arc-tofu-environment-contract:
    #!/usr/bin/env bash
    set -euo pipefail
    while IFS='=' read -r name _; do
        case "${name}" in
          TF_*|TOFU_*) echo "Refusing ambient ${name}; the ARC OpenTofu contract owns this input" >&2; exit 2 ;;
        esac
    done < <(env)

_arc-backend-contract: _arc-tofu-environment-contract
    #!/usr/bin/env bash
    set -euo pipefail
    backend="${ARC_BACKEND:-{{ arc_backend_default }}}"
    : "${AWS_ACCESS_KEY_ID:?Set the exact RustFS ARC state access key}"
    : "${AWS_SECRET_ACCESS_KEY:?Set the exact RustFS ARC state secret key}"
    while IFS='=' read -r name _; do
        case "${name}" in
          AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY) ;;
          AWS_*) echo "Refusing ambient ${name}; only the exact RustFS access-key pair is accepted" >&2; exit 2 ;;
          HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|http_proxy|https_proxy|all_proxy) echo "Refusing ambient ${name}; ARC state traffic may not transit a proxy" >&2; exit 2 ;;
        esac
    done < <(env)
    python3 -I - "${backend}" "$(pwd)/{{ arc_backend_default }}" "$(pwd)" <<'PY'
    import os
    import re
    import stat
    import sys
    from pathlib import Path

    candidate = Path(sys.argv[1]).expanduser()
    canonical = Path(sys.argv[2]).resolve(strict=True)
    repo = Path(sys.argv[3]).resolve(strict=True)
    if not candidate.is_absolute():
        candidate = repo / candidate
    candidate = candidate.resolve(strict=True)
    if not candidate.is_file():
        raise SystemExit("ARC_BACKEND must be a regular file")

    endpoint_pattern = re.compile(r'(?m)^(\s*s3\s*=\s*)"([^"]+)"(\s*)$')
    canonical_text = canonical.read_text(encoding="utf-8")
    candidate_text = candidate.read_text(encoding="utf-8")
    canonical_matches = endpoint_pattern.findall(canonical_text)
    candidate_matches = endpoint_pattern.findall(candidate_text)
    if len(canonical_matches) != 1 or len(candidate_matches) != 1:
        raise SystemExit("ARC backend must declare exactly one endpoints.s3 value")
    normalized_canonical = endpoint_pattern.sub(r'\1"<ENDPOINT>"\3', canonical_text)
    normalized_candidate = endpoint_pattern.sub(r'\1"<ENDPOINT>"\3', candidate_text)
    if normalized_candidate != normalized_canonical:
        raise SystemExit("ARC_BACKEND may differ from the reviewed backend only at endpoints.s3")

    endpoint = candidate_matches[0][1]
    if candidate == canonical:
        if endpoint != "http://tofu-state-rustfs.nix-cache.svc:9000":
            raise SystemExit("canonical ARC backend endpoint changed unexpectedly")
    else:
        try:
            candidate.relative_to(repo)
        except ValueError:
            pass
        else:
            raise SystemExit("temporary ARC_BACKEND must remain outside the public repository")
        metadata = candidate.stat()
        if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o600:
            raise SystemExit("temporary ARC_BACKEND must be operator-owned and mode 0600")
        match = re.fullmatch(r"http://127\.0\.0\.1:([0-9]{1,5})", endpoint)
        if match is None or not 1 <= int(match.group(1)) <= 65535:
            raise SystemExit("temporary ARC_BACKEND endpoint must be http://127.0.0.1:<port>")
    print(f"reviewed ARC backend: tofu-state/great-falls-tool-bus-infra/arc-runners via {endpoint}")
    PY

_arc-kubeconfig-contract:
    #!/usr/bin/env bash
    set -euo pipefail
    kubeconfig="${GFTB_ARC_KUBECONFIG:?Set GFTB_ARC_KUBECONFIG to the reviewed ARC kubeconfig}"
    [[ -z "${KUBECONFIG:-}" ]] || { echo "Refusing ambient KUBECONFIG; GFTB_ARC_KUBECONFIG is authoritative" >&2; exit 2; }
    [[ -z "${TF_VAR_k8s_config_path:-}" ]] || { echo "Refusing ambient TF_VAR_k8s_config_path; GFTB_ARC_KUBECONFIG is authoritative" >&2; exit 2; }
    while IFS='=' read -r name _; do
        case "${name}" in
          KUBE_*|HELM_*) echo "Refusing ambient ${name}; the reviewed ARC kubeconfig is authoritative" >&2; exit 2 ;;
          HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|http_proxy|https_proxy|all_proxy) echo "Refusing ambient ${name}; ARC Kubernetes traffic may not transit a proxy" >&2; exit 2 ;;
        esac
    done < <(env)
    python3 -I - "${kubeconfig}" "$(pwd)" <<'PY'
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
        raise SystemExit("GFTB_ARC_KUBECONFIG must remain outside the public repository")
    metadata = path.stat()
    if not path.is_file() or metadata.st_uid != os.getuid():
        raise SystemExit("GFTB_ARC_KUBECONFIG must be a regular file owned by the operator")
    if stat.S_IMODE(metadata.st_mode) != 0o600:
        raise SystemExit("GFTB_ARC_KUBECONFIG must have mode 0600")
    PY
    config_json="$(kubectl --kubeconfig "${kubeconfig}" config view --raw -o json)"
    jq -e '
      .["current-context"] == "honey"
      and (.contexts | length == 1)
      and (.contexts[0].name == "honey")
      and (.contexts[0].context.cluster == "honey")
      and (.contexts[0].context.user == "honey")
      and (.clusters | length == 1)
      and (.clusters[0].name == "honey")
      and ((.clusters[0].cluster.server // "") | test("^https://[^/?#]+$"))
      and ((.clusters[0].cluster["certificate-authority-data"] // "") | length > 0)
      and ((.clusters[0].cluster["insecure-skip-tls-verify"] // false) == false)
      and (.clusters[0].cluster | has("proxy-url") | not)
      and (.users | length == 1)
      and (.users[0].name == "honey")
      and (.users[0].user | has("exec") | not)
      and (.users[0].user | has("auth-provider") | not)
      and (.users[0].user | has("tokenFile") | not)
      and (.users[0].user | has("client-certificate") | not)
      and (.users[0].user | has("client-key") | not)
      and (
        ((.users[0].user.token // "") | length > 0)
        or (
          ((.users[0].user["client-certificate-data"] // "") | length > 0)
          and ((.users[0].user["client-key-data"] // "") | length > 0)
        )
      )
    ' <<<"${config_json}" >/dev/null || { echo "GFTB_ARC_KUBECONFIG must be a single TLS-verified honey context with embedded credentials" >&2; exit 2; }
    cluster_uid="$(kubectl --kubeconfig "${kubeconfig}" --context honey get namespace kube-system -o jsonpath='{.metadata.uid}')"
    [[ "${cluster_uid}" == "{{ arc_cluster_uid }}" ]] || { echo "ARC kubeconfig does not target the reviewed Honey cluster UID" >&2; exit 2; }
    echo "reviewed ARC cluster: honey (${cluster_uid})"

_arc-runtime-contract: _arc-kubeconfig-contract
    #!/usr/bin/env bash
    set -euo pipefail
    kubeconfig="${GFTB_ARC_KUBECONFIG:?Set GFTB_ARC_KUBECONFIG to the reviewed ARC kubeconfig}"
    target_uid="$(kubectl --kubeconfig "${kubeconfig}" --context honey -n arc-runners get autoscalingrunnerset great-falls-tool-bus-nix -o jsonpath='{.metadata.uid}')"
    [[ "${target_uid}" == "{{ arc_target_uid }}" ]] || { echo "ARC kubeconfig does not target the reviewed great-falls-tool-bus-nix UID" >&2; exit 2; }
    echo "reviewed ARC target: honey/arc-runners/great-falls-tool-bus-nix (${target_uid})"

_arc-artifact-root-contract:
    #!/usr/bin/env bash
    set -euo pipefail
    python3 -I - "$(pwd)/.tofu-plans" <<'PY'
    import os
    import stat
    import sys
    from pathlib import Path

    root = Path(sys.argv[1])
    if not root.exists() and not root.is_symlink():
        root.mkdir(mode=0o700)
    metadata = root.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise SystemExit(".tofu-plans must be a real directory, not a symlink")
    if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
        raise SystemExit(".tofu-plans must be operator-owned and mode 0700")
    for path in root.glob("arc-runners.*"):
        item = path.lstat()
        if path.name == "arc-runners.tfdata":
            if not stat.S_ISDIR(item.st_mode) or stat.S_ISLNK(item.st_mode):
                raise SystemExit("ARC TF_DATA_DIR must be a real directory")
            expected_mode = 0o700
        else:
            if not stat.S_ISREG(item.st_mode) or stat.S_ISLNK(item.st_mode):
                raise SystemExit(f"ARC plan artifact must be a regular file: {path.name}")
            expected_mode = 0o600
        if item.st_uid != os.getuid() or stat.S_IMODE(item.st_mode) != expected_mode:
            raise SystemExit(
                f"ARC artifact {path.name} must be operator-owned and mode {expected_mode:04o}"
            )
    PY

_arc-plan-input-snapshot: _reviewed-clean-main _reviewed-arc-core _arc-exclusive-confirm _arc-backend-contract _arc-runtime-contract _arc-artifact-root-contract
    #!/usr/bin/env bash
    set -euo pipefail
    umask 077
    core="${GF_ARC_CORE_PATH:-{{ arc_core_default }}}"
    kubeconfig="${GFTB_ARC_KUBECONFIG:?Set GFTB_ARC_KUBECONFIG to the reviewed ARC kubeconfig}"
    data_dir="$(pwd)/.tofu-plans/arc-runners.tfdata"
    backend="${ARC_BACKEND:-{{ arc_backend_default }}}"
    if [[ "${backend}" != /* ]]; then
        backend="$(pwd)/${backend}"
    fi
    just _reviewed-clean-main
    just _reviewed-arc-core
    just _arc-backend-contract
    just _arc-runtime-contract
    just _arc-artifact-root-contract
    test ! -e .tofu-plans/arc-runners.apply-attempted || { echo "A prior ARC apply attempt must be reconciled before creating a fresh plan" >&2; exit 2; }
    if [[ -e "${data_dir}" || -L "${data_dir}" ]]; then
        [[ -d "${data_dir}" && ! -L "${data_dir}" ]] || { echo "ARC TF_DATA_DIR must be a real directory" >&2; exit 2; }
        rm -rf -- "${data_dir}"
    fi
    mkdir -m 700 "${data_dir}"
    rm -f .tofu-plans/arc-runners.tfplan .tofu-plans/arc-runners.source-sha .tofu-plans/arc-runners.core-sha .tofu-plans/arc-runners.backend-blob .tofu-plans/arc-runners.kubeconfig-blob .tofu-plans/arc-runners.cluster-uid .tofu-plans/arc-runners.target-uid .tofu-plans/arc-runners.plan-sha256 .tofu-plans/arc-runners.scope-sha256
    git rev-parse HEAD > .tofu-plans/arc-runners.source-sha
    git -C "${core}" rev-parse HEAD > .tofu-plans/arc-runners.core-sha
    python3 -I -c 'import hashlib,pathlib,sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "${backend}" > .tofu-plans/arc-runners.backend-blob
    python3 -I -c 'import hashlib,pathlib,sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "${kubeconfig}" > .tofu-plans/arc-runners.kubeconfig-blob
    kubectl --kubeconfig "${kubeconfig}" --context honey get namespace kube-system -o jsonpath='{.metadata.uid}' > .tofu-plans/arc-runners.cluster-uid
    kubectl --kubeconfig "${kubeconfig}" --context honey -n arc-runners get autoscalingrunnerset great-falls-tool-bus-nix -o jsonpath='{.metadata.uid}' > .tofu-plans/arc-runners.target-uid
    chmod 600 .tofu-plans/arc-runners.source-sha .tofu-plans/arc-runners.core-sha .tofu-plans/arc-runners.backend-blob .tofu-plans/arc-runners.kubeconfig-blob .tofu-plans/arc-runners.cluster-uid .tofu-plans/arc-runners.target-uid

_arc-plan-input-preflight: _reviewed-clean-main _reviewed-arc-core _arc-backend-contract _arc-runtime-contract _arc-artifact-root-contract
    #!/usr/bin/env bash
    set -euo pipefail
    core="${GF_ARC_CORE_PATH:-{{ arc_core_default }}}"
    kubeconfig="${GFTB_ARC_KUBECONFIG:?Set GFTB_ARC_KUBECONFIG to the reviewed ARC kubeconfig}"
    backend="${ARC_BACKEND:-{{ arc_backend_default }}}"
    if [[ "${backend}" != /* ]]; then
        backend="$(pwd)/${backend}"
    fi
    test -f .tofu-plans/arc-runners.tfplan
    test -f .tofu-plans/arc-runners.source-sha
    test -f .tofu-plans/arc-runners.core-sha
    test -f .tofu-plans/arc-runners.backend-blob
    test -f .tofu-plans/arc-runners.kubeconfig-blob
    test -f .tofu-plans/arc-runners.cluster-uid
    test -f .tofu-plans/arc-runners.target-uid
    test "$(git rev-parse HEAD)" = "$(tr -d '\n' < .tofu-plans/arc-runners.source-sha)" || { echo "ARC plan was created from a different infra revision" >&2; exit 2; }
    test "$(git -C "${core}" rev-parse HEAD)" = "$(tr -d '\n' < .tofu-plans/arc-runners.core-sha)" || { echo "ARC plan was created from a different GloriousFlywheel revision" >&2; exit 2; }
    test "$(python3 -I -c 'import hashlib,pathlib,sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "${backend}")" = "$(tr -d '\n' < .tofu-plans/arc-runners.backend-blob)" || { echo "ARC plan was created with a different backend declaration" >&2; exit 2; }
    test "$(python3 -I -c 'import hashlib,pathlib,sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "${kubeconfig}")" = "$(tr -d '\n' < .tofu-plans/arc-runners.kubeconfig-blob)" || { echo "ARC plan was created with a different kubeconfig" >&2; exit 2; }
    cluster_uid="$(kubectl --kubeconfig "${kubeconfig}" --context honey get namespace kube-system -o jsonpath='{.metadata.uid}')"
    test "${cluster_uid}" = "$(tr -d '\n' < .tofu-plans/arc-runners.cluster-uid)" || { echo "ARC plan was created for a different cluster" >&2; exit 2; }
    target_uid="$(kubectl --kubeconfig "${kubeconfig}" --context honey -n arc-runners get autoscalingrunnerset great-falls-tool-bus-nix -o jsonpath='{.metadata.uid}')"
    test "${target_uid}" = "$(tr -d '\n' < .tofu-plans/arc-runners.target-uid)" || { echo "ARC plan was created for a different target cluster/release" >&2; exit 2; }

_operator-apply-confirm:
    [[ "${GFTB_APPLY_CONFIRM:-}" == "apply" ]] || { echo "Set GFTB_APPLY_CONFIRM=apply for this attended mutation" >&2; exit 2; }

_arc-exclusive-confirm:
    [[ "${GFTB_ARC_EXCLUSIVE_CONFIRM:-}" == "exclusive" ]] || { echo "Set GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive after confirming no concurrent ARC plan/apply" >&2; exit 2; }

# --- edge zone stack (tofu/stacks/edge; TIN-2378 prep + TIN-2385) -----------
# Console-created zones on the house CF account, looked up by name with a
# ZONE-SCOPED token (TF_VAR_cloudflare_api_token; protected-environment
# secret CLOUDFLARE_API_TOKEN_GFTB_ZONES in CI, sops-lane
# cloudflare-api-token-gftb-zones on the operator machine). Records +
# apex Access gate + latoolb.us redirect ruleset; NO mail records
# (TIN-2379). Never applied while edge-dns manage_* toggles are on — see
# tofu/stacks/edge/README.md.

edge_zones_stack := "tofu/stacks/edge"
edge_zones_backend := env_var_or_default("EDGE_ZONES_BACKEND", "tofu/backend/honey-edge.s3.hcl")

edge-zones-fmt-check:
    #!/usr/bin/env bash
    set -euo pipefail
    bash scripts/remote-only-guard.sh edge-zones-fmt-check
    if command -v tofu >/dev/null 2>&1; then
        tofu fmt -check -recursive {{ edge_zones_stack }}
    else
        nix develop "{{ gf_core_ci }}" -c tofu fmt -check -recursive {{ edge_zones_stack }}
    fi

# Regenerate the provider lock for the supported hosted-CI and operator
# platforms. Review and commit the resulting lockfile change.
edge-zones-lock:
    tofu -chdir={{ edge_zones_stack }} providers lock -platform=linux_amd64 -platform=darwin_arm64

edge-zones-validate:
    #!/usr/bin/env bash
    set -euo pipefail
    bash scripts/remote-only-guard.sh edge-zones-validate
    tf_data_dir="$(mktemp -d -t great-falls-tool-bus-infra-edge-zones-tofu-data.XXXXXX)"
    trap 'rm -rf "${tf_data_dir}"' EXIT
    if command -v tofu >/dev/null 2>&1; then
        TF_DATA_DIR="${tf_data_dir}" tofu -chdir={{ edge_zones_stack }} init -backend=false -lockfile=readonly >/tmp/great-falls-tool-bus-infra-edge-zones-init.log
        TF_DATA_DIR="${tf_data_dir}" tofu -chdir={{ edge_zones_stack }} validate
    else
        nix develop "{{ gf_core_ci }}" -c bash -lc 'TF_DATA_DIR="'"${tf_data_dir}"'" tofu -chdir={{ edge_zones_stack }} init -backend=false -lockfile=readonly >/tmp/great-falls-tool-bus-infra-edge-zones-init.log && TF_DATA_DIR="'"${tf_data_dir}"'" tofu -chdir={{ edge_zones_stack }} validate'
    fi

edge-zones-init:
    #!/usr/bin/env bash
    set -euo pipefail
    bash scripts/remote-only-guard.sh edge-zones-init
    backend="{{ edge_zones_backend }}"
    test -f "${backend}"
    if [[ "${backend}" != /* ]]; then
        backend="$(pwd)/${backend}"
    fi
    tofu -chdir={{ edge_zones_stack }} init -reconfigure -backend-config="${backend}"

edge-zones-plan:
    @bash scripts/remote-only-guard.sh edge-zones-plan
    mkdir -p .tofu-plans
    tofu -chdir={{ edge_zones_stack }} plan -out="$(pwd)/.tofu-plans/edge.tfplan"

_edge-zones-plan-json:
    @bash scripts/remote-only-guard.sh _edge-zones-plan-json
    test -f .tofu-plans/edge.tfplan
    tofu -chdir={{ edge_zones_stack }} show -json "$(pwd)/.tofu-plans/edge.tfplan" > .tofu-plans/edge.tfplan.json

_edge-zones-plan-text:
    @bash scripts/remote-only-guard.sh _edge-zones-plan-text
    @tofu -chdir={{ edge_zones_stack }} plan -no-color

edge-zones-plan-show:
    @bash scripts/remote-only-guard.sh edge-zones-plan-show
    test -f .tofu-plans/edge.tfplan
    tofu -chdir={{ edge_zones_stack }} show -no-color "$(pwd)/.tofu-plans/edge.tfplan"

edge-zones-plan-destroy-check:
    #!/usr/bin/env bash
    set -euo pipefail
    bash scripts/remote-only-guard.sh edge-zones-plan-destroy-check
    test -f .tofu-plans/edge.tfplan
    plan_json="$(mktemp "${TMPDIR:-/tmp}/gftb-edge-zones-plan.XXXXXX.json")"
    trap 'rm -f "${plan_json}"' EXIT
    tofu -chdir={{ edge_zones_stack }} show -json "$(pwd)/.tofu-plans/edge.tfplan" > "${plan_json}"
    if python3 - "${plan_json}" <<'PY'
    import json
    import sys
    from pathlib import Path

    plan = json.loads(Path(sys.argv[1]).read_text())
    for change in plan.get("resource_changes", []):
        if "delete" in change.get("change", {}).get("actions", []):
            sys.exit(0)
    sys.exit(1)
    PY
    then
        if [ "${ALLOW_EDGE_ZONES_DESTROY:-}" = "1" ]; then
            echo "WARNING: destructive edge plan allowed because ALLOW_EDGE_ZONES_DESTROY=1"
        else
            echo "ERROR: destructive edge plan detected. Review just edge-zones-plan-show and record the decision before apply."
            exit 1
        fi
    fi
    echo "edge plan destroy guard passed."

edge-zones-apply: edge-zones-plan-destroy-check
    @bash scripts/remote-only-guard.sh edge-zones-apply
    test -f .tofu-plans/edge.tfplan
    tofu -chdir={{ edge_zones_stack }} apply "$(pwd)/.tofu-plans/edge.tfplan"

# --- GFTB tenant mail custom resources (TIN-2379) ---------------------------
# Tenant-owned MailDomain/MailAccount declarations live here and apply through
# the namespace grant declared in blahaj (latoolb-us-production only). The
# checked-in validation is offline. Live server dry-run/apply requires a
# namespace-scoped kubeconfig from the protected mail environment.

mail_cr_dir := "k8s/mail/latoolb-us-production"

mail-cr-validate:
    @bash scripts/remote-only-guard.sh mail-cr-validate
    bash scripts/validate-mail-crs.sh {{ mail_cr_dir }}

_mail-kubeconfig-inputs:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${GFTB_MAIL_KUBECONFIG:?Set GFTB_MAIL_KUBECONFIG to the namespace-scoped kubeconfig path}"
    python3 -I - "${GFTB_MAIL_KUBECONFIG}" "$(git rev-parse --show-toplevel)" <<'PY'
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
        raise SystemExit("GFTB_MAIL_KUBECONFIG must remain outside the public repository")
    metadata = path.stat()
    if not path.is_file() or metadata.st_uid != os.getuid():
        raise SystemExit("GFTB_MAIL_KUBECONFIG must be a regular file owned by the operator")
    if stat.S_IMODE(metadata.st_mode) != 0o600:
        raise SystemExit("GFTB_MAIL_KUBECONFIG must have mode 0600")
    PY

mail-cr-server-dry-run: mail-cr-validate _mail-kubeconfig-inputs
    @bash scripts/remote-only-guard.sh mail-cr-server-dry-run
    kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace latoolb-us-production apply --dry-run=server -k {{ mail_cr_dir }}

mail-cr-apply: mail-cr-server-dry-run
    @bash scripts/remote-only-guard.sh mail-cr-apply
    kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace latoolb-us-production apply -k {{ mail_cr_dir }}

# --- GFTB Mailman 3 list stack (TIN-2380) -----------------------------------
# First-of-kind mailing-list engine (Mailman core + Postorius + HyperKitty) for
# keyholders@latoolb.us, deployed overlay-side into latoolb-us-production and
# consuming the blahaj mail substrate through the tenant-list-engine SMTP relay
# contract (ADR 010). Checked-in validation is offline. Live server
# dry-run/apply needs a namespace-scoped kubeconfig with WORKLOAD verbs — see
# the RBAC note in docs/runbooks/list-bringup.md (the existing mail kubeconfig
# is scoped to mail CRs only and cannot apply Deployments/Services/PVCs).

list_stack_dir := "k8s/list/latoolb-us-production"

list-stack-validate:
    @bash scripts/remote-only-guard.sh list-stack-validate
    bash scripts/validate-list-stack.sh {{ list_stack_dir }}

list-stack-server-dry-run: list-stack-validate _mail-kubeconfig-inputs
    @bash scripts/remote-only-guard.sh list-stack-server-dry-run
    kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace latoolb-us-production apply --dry-run=server -k {{ list_stack_dir }}

list-stack-apply: list-stack-server-dry-run
    @bash scripts/remote-only-guard.sh list-stack-apply
    kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace latoolb-us-production apply -k {{ list_stack_dir }}

_list-member-add-inputs:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${GFTB_LIST_KUBECONFIG:?Set GFTB_LIST_KUBECONFIG to the dedicated namespace list-admin kubeconfig}"
    : "${GFTB_LIST_ID:?Set GFTB_LIST_ID to keyholders.latoolb.us or discuss.latoolb.us}"
    : "${GFTB_LIST_SUBSCRIBER:?Set GFTB_LIST_SUBSCRIBER to the consented address}"
    [[ "${GFTB_LIST_ID}" == "keyholders.latoolb.us" || "${GFTB_LIST_ID}" == "discuss.latoolb.us" ]] || { echo "GFTB_LIST_ID is not an allowed GFTB list" >&2; exit 2; }
    test "${GFTB_LIST_MEMBER_CONSENT:-}" = "confirmed" || { echo "Set GFTB_LIST_MEMBER_CONSENT=confirmed after consent readback" >&2; exit 2; }
    expected_confirm="${GFTB_LIST_ID}:${GFTB_LIST_SUBSCRIBER}"
    test "${GFTB_LIST_MEMBER_CONFIRM:-}" = "${expected_confirm}" || { echo "Set GFTB_LIST_MEMBER_CONFIRM to the exact list-id:subscriber target" >&2; exit 2; }
    python3 -I - "${GFTB_LIST_KUBECONFIG}" "$(git rev-parse --show-toplevel)" <<'PY'
    import os
    import re
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
        raise SystemExit("GFTB_LIST_KUBECONFIG must remain outside the public repository")
    metadata = path.stat()
    if not path.is_file() or metadata.st_uid != os.getuid():
        raise SystemExit("GFTB_LIST_KUBECONFIG must be a regular file owned by the operator")
    if stat.S_IMODE(metadata.st_mode) != 0o600:
        raise SystemExit("GFTB_LIST_KUBECONFIG must have mode 0600")

    address = os.environ["GFTB_LIST_SUBSCRIBER"]
    display = os.environ.get("GFTB_LIST_DISPLAY_NAME", "")
    if len(address) > 254 or not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", address):
        raise SystemExit("GFTB_LIST_SUBSCRIBER must be one valid email address")
    if len(display) > 100 or any(ord(character) < 32 or ord(character) == 127 for character in display):
        raise SystemExit("GFTB_LIST_DISPLAY_NAME must be at most 100 control-free characters")
    PY

# Idempotently add one consented person as a member of one exact GFTB list.
# Owner/moderator grants, removals, moderation, and settings changes remain held
# for their own lifecycle/rollback contracts rather than sharing this surface.
list-member-add: _list-member-add-inputs _reviewed-clean-main _operator-apply-confirm
    #!/usr/bin/env bash
    set -euo pipefail
    namespace="latoolb-us-production"
    pod_json="$(kubectl --kubeconfig "${GFTB_LIST_KUBECONFIG}" --namespace "${namespace}" get pods -l app.kubernetes.io/name=mailman-core -o json)"
    core_pod="$(jq -er '[.items[] | select(.metadata.deletionTimestamp == null)] as $active | if (($active | length) == 1 and $active[0].status.phase == "Running" and any($active[0].status.conditions[]?; .type == "Ready" and .status == "True")) then $active[0].metadata.name else error("expected exactly one active Ready mailman-core pod") end' <<<"${pod_json}")"
    find_membership() {
      printf '%s\n%s\n' "${GFTB_LIST_ID}" "${GFTB_LIST_SUBSCRIBER}" | \
        kubectl --kubeconfig "${GFTB_LIST_KUBECONFIG}" --namespace "${namespace}" exec -i "${core_pod}" --container mailman-core -- sh -eu -c '
          IFS= read -r list_id
          IFS= read -r subscriber
          curl --fail --silent --show-error \
            --user "restadmin:${MAILMAN_REST_PASSWORD}" --get \
            --data-urlencode "list_id=${list_id}" \
            --data-urlencode "subscriber=${subscriber}" \
            --data-urlencode "role=member" \
            "http://$(hostname -i):8001/3.1/members/find"
        '
    }
    classify_membership() {
      jq -er --arg list_id "${GFTB_LIST_ID}" --arg subscriber "${GFTB_LIST_SUBSCRIBER}" '
        (.entries // []) as $entries
        | [$entries[]
            | select(.list_id == $list_id)
            | select((.email | ascii_downcase) == ($subscriber | ascii_downcase))
            | select(.role == "member")] as $exact
        | if (.total_size == 0 and ($entries | length) == 0) then "absent"
          elif (.total_size == 1 and ($entries | length) == 1 and ($exact | length) == 1) then "present"
          else error("ambiguous or mismatched Mailman membership readback")
          end
      '
    }
    before_json="$(find_membership)"
    before_state="$(classify_membership <<<"${before_json}")"
    if [[ "${before_state}" == "present" ]]; then
      echo "Selected list membership already present; no mutation."
      exit 0
    fi
    status="$(printf '%s\n%s\n%s\n' "${GFTB_LIST_ID}" "${GFTB_LIST_SUBSCRIBER}" "${GFTB_LIST_DISPLAY_NAME:-}" | \
      kubectl --kubeconfig "${GFTB_LIST_KUBECONFIG}" --namespace "${namespace}" exec -i "${core_pod}" --container mailman-core -- sh -eu -c '
        IFS= read -r list_id
        IFS= read -r subscriber
        IFS= read -r display_name
        curl --silent --show-error --output /dev/null --write-out "%{http_code}" \
          --user "restadmin:${MAILMAN_REST_PASSWORD}" --request POST \
          --data-urlencode "list_id=${list_id}" \
          --data-urlencode "subscriber=${subscriber}" \
          --data-urlencode "display_name=${display_name}" \
          --data-urlencode "pre_verified=true" \
          --data-urlencode "pre_confirmed=true" \
          --data-urlencode "pre_approved=true" \
          --data-urlencode "role=member" \
          "http://$(hostname -i):8001/3.1/members"
      ')"
    test "${status}" = "201" || { echo "Membership add returned HTTP ${status}." >&2; exit 2; }
    after_json="$(find_membership)"
    test "$(classify_membership <<<"${after_json}")" = "present" || { echo "Membership readback did not converge." >&2; exit 2; }
    echo "Selected list membership added and read back."

# --- keyholders -> discuss add-only membership reconciler (TIN-3813 lane) ---
# Enforces members(keyholders@latoolb.us) as a subset of
# members(discuss@latoolb.us) going forward (the ratified private/public list
# pairing, meta decisions/0014 ruling 5). Mailman owns list membership and
# account-controller owns mail RESOURCE reconciliation only (launch-member-v0
# spec responsibilities table), so the invariant lives here in the GFTB apply
# plane as a narrow suspended CronJob: add-only, two pinned lists, dry-run
# default-on, no k8s API identity, egress pinned to core REST, and gated on
# the operator-minted mailman-listsync-rest Secret (Mailman core 3.3.10 has a
# single global REST identity — the restricted-proxy scoping TIN-3813 calls
# for does not exist yet and is tracked there; see the manifest comments and
# docs/runbooks/list-operations.md section 8 for the declared gap and the
# three-step attended activation). Checked-in validation is offline; live
# server dry-run/apply uses the same protected mail-environment kubeconfig as
# the other latoolb-us-production stacks. Merging changes nothing on its own.

listsync_stack_dir := "k8s/list-sync/latoolb-us-production"

listsync-stack-validate:
    @bash scripts/remote-only-guard.sh listsync-stack-validate
    bash scripts/validate-listsync-stack.sh {{ listsync_stack_dir }}

listsync-stack-server-dry-run: listsync-stack-validate _mail-kubeconfig-inputs
    kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace latoolb-us-production apply --dry-run=server -k {{ listsync_stack_dir }}

listsync-stack-apply: listsync-stack-server-dry-run
    kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace latoolb-us-production apply -k {{ listsync_stack_dir }}

# --- GFTB contact-intake stack (TIN-2420 Path B) ----------------------------
# Anubis PoW gate -> stdlib form-handler -> LMTP inject to keyholders@latoolb.us
# (the list fans out to every keyholder; LMTP needs no SMTP credential).
# Deployed overlay-side into latoolb-us-production. Checked-in validation is
# offline. Live server dry-run/apply needs a namespace-scoped kubeconfig with
# WORKLOAD verbs (same RBAC caveat as the list stack — see
# docs/runbooks/form-intake.md). Nothing is exposed until the Cloudflare tunnel
# public-hostname route is added (dashboard-side) and a live smoke passes.

form_stack_dir := "k8s/form/latoolb-us-production"

form-stack-validate:
    @bash scripts/remote-only-guard.sh form-stack-validate
    bash scripts/validate-form-stack.sh {{ form_stack_dir }}

# Offline ALTCHA challenge/solve/verify round-trip against the shipping server.py
# (no network, no cluster). Also runs inside form-stack-validate.
form-altcha-test:
    python3 scripts/test-form-altcha.py

# Create or rotate the names-only ALTCHA HMAC Secret from a mode-restricted
# operator file without placing key bytes in argv, Git, or shell history.
form-altcha-secret-apply: _mail-kubeconfig-inputs _reviewed-clean-main _operator-apply-confirm
    #!/usr/bin/env bash
    set -euo pipefail
    : "${FORM_ALTCHA_HMAC_KEY_PATH:?Set FORM_ALTCHA_HMAC_KEY_PATH to the retained operator key file outside this worktree}"
    test "${GFTB_ALTCHA_SECRET_CONFIRM:-}" = "form-altcha-hmac" || { echo "Set GFTB_ALTCHA_SECRET_CONFIRM=form-altcha-hmac" >&2; exit 2; }
    repo_root="$(git rev-parse --show-toplevel)"
    key_path="$(python3 -I - "${FORM_ALTCHA_HMAC_KEY_PATH}" "${repo_root}" <<'PY'
    import os
    import re
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
        raise SystemExit("FORM_ALTCHA_HMAC_KEY_PATH must remain outside the public repository")
    if not path.is_file():
        raise SystemExit("FORM_ALTCHA_HMAC_KEY_PATH must name a regular file")
    metadata = path.stat()
    if metadata.st_uid != os.getuid():
        raise SystemExit("FORM_ALTCHA_HMAC_KEY_PATH must be owned by the operator")
    if stat.S_IMODE(metadata.st_mode) != 0o600:
        raise SystemExit("FORM_ALTCHA_HMAC_KEY_PATH must have mode 0600")
    value = path.read_bytes()
    if not re.fullmatch(rb"[0-9a-f]{64}", value):
        raise SystemExit("FORM_ALTCHA_HMAC_KEY_PATH must contain exactly 64 lowercase hex bytes and no newline")
    print(path)
    PY
    )"
    namespace="latoolb-us-production"
    pod_json="$(kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace "${namespace}" get pods -l app.kubernetes.io/name=form-handler -o json)"
    active_count="$(jq -er '[.items[] | select(.metadata.deletionTimestamp == null)] | length' <<<"${pod_json}")"
    [[ "${active_count}" =~ ^[01]$ ]] || { echo "Expected no more than one active form-handler pod." >&2; exit 2; }
    old_name="$(jq -r '[.items[] | select(.metadata.deletionTimestamp == null)][0].metadata.name // ""' <<<"${pod_json}")"
    old_uid="$(jq -r '[.items[] | select(.metadata.deletionTimestamp == null)][0].metadata.uid // ""' <<<"${pod_json}")"
    umask 077
    manifest="$(mktemp "${TMPDIR:-/tmp}/gftb-altcha-secret.XXXXXX.yaml")"
    trap 'rm -f "${manifest}"' EXIT
    kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace "${namespace}" create secret generic form-altcha-hmac --from-file=hmac-key="${key_path}" --dry-run=client -o yaml > "${manifest}"
    chmod 600 "${manifest}"
    kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace "${namespace}" apply --dry-run=server -f "${manifest}"
    kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace "${namespace}" apply -f "${manifest}"
    if [[ -n "${old_name}" ]]; then
      kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace "${namespace}" delete pod "${old_name}" --wait=true --timeout=120s
    fi
    kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace "${namespace}" wait --for=create pod -l app.kubernetes.io/name=form-handler --timeout=180s
    kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace "${namespace}" wait --for=condition=Ready pod -l app.kubernetes.io/name=form-handler --timeout=180s
    new_pod_json="$(kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace "${namespace}" get pods -l app.kubernetes.io/name=form-handler -o json)"
    jq -e --arg old_uid "${old_uid}" '[.items[] | select(.metadata.deletionTimestamp == null)] as $active | ($active | length) == 1 and $active[0].status.phase == "Running" and any($active[0].status.conditions[]?; .type == "Ready" and .status == "True") and ($old_uid == "" or $active[0].metadata.uid != $old_uid)' <<<"${new_pod_json}" >/dev/null
    echo "Secret applied and a replacement form-handler pod is Ready. Run the challenge and delivery smoke."

form-stack-server-dry-run: form-stack-validate _mail-kubeconfig-inputs
    @bash scripts/remote-only-guard.sh form-stack-server-dry-run
    kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace latoolb-us-production apply --dry-run=server -k {{ form_stack_dir }}

form-stack-apply: form-stack-server-dry-run
    @bash scripts/remote-only-guard.sh form-stack-apply
    kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace latoolb-us-production apply -k {{ form_stack_dir }}

# --- GFTB public discuss@ archive stack (TIN-2528) --------------------------
# SECOND Anubis PoW gate (anubis-archive) fronting the HyperKitty web tier so
# the PUBLIC discuss@ archive can ride the shared honey-ingress Cloudflare
# Tunnel (anti-scrape, NOT auth). Faithful mirror of the form-stack recipes
# above, pointed at k8s/archive. Deployed overlay-side into latoolb-us-production
# and dry-run/applied with the SAME namespace-scoped mail kubeconfig (same RBAC
# caveat as the form/list stacks). Checked-in validation is offline. LIVE: this
# stack is applied and the public discuss@ archive is served at lists.latoolb.us.
# Apply is manual (workflow_dispatch action=apply into the protected mail
# environment, i.e. the archive-stack-apply recipe below); merging changes
# nothing on its own. Go-live also required the privacy pre-flight, the Cloudflare
# tunnel public-hostname route (dashboard-side), and the archive DNS enable
# (var.archives_dns_enabled), all now satisfied. See
# k8s/archive/latoolb-us-production/README.md and docs/discuss-archive-packet.md.

archive_stack_dir := "k8s/archive/latoolb-us-production"

archive-stack-validate:
    @bash scripts/remote-only-guard.sh archive-stack-validate
    bash scripts/validate-archive-stack.sh {{ archive_stack_dir }}

archive-stack-server-dry-run: archive-stack-validate _mail-kubeconfig-inputs
    @bash scripts/remote-only-guard.sh archive-stack-server-dry-run
    kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace latoolb-us-production apply --dry-run=server -k {{ archive_stack_dir }}

archive-stack-apply: archive-stack-server-dry-run
    @bash scripts/remote-only-guard.sh archive-stack-apply
    kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace latoolb-us-production apply -k {{ archive_stack_dir }}

# --- GFTB on-cluster web serving (TIN-2541 skeleton; TIN-2543 cutover) -------
# ATTENDED-ONLY DECLARE-ONLY IN GIT. The promoted gftb-site static Caddy origin
# -> ClusterIP 80->3000 -> honey-ingress cloudflared tunnel, mirroring the
# proven MassageIthaca full-on-cluster pattern. The checked-in overlay is
# DECLARED AND VALIDATED, not parked: the Deployment carries replicas: 2 and a
# digest-pinned ghcr.io/great-falls-tool-bus/gftb-site image, this stack
# creates no Namespace, and the tunnel route is dashboard/token-managed (never
# in git; TIN-991). scripts/validate-web-stack.sh enforces exactly that
# posture.
#
# LEGACY CD RETIRED (TIN-3899, Phase 5 step 2). The cutover recipes below were
# the operator-gated APPLY plane (TIN-2543, ADR 0008) reached through
# .github/workflows/web-stack.yml -- workflow_dispatch + confirm=apply, or the
# site repo's repository_dispatch: web-image-published. That workflow is DELETED:
# no workflow in this repository applies this stack any more, and no
# repository_dispatch consumer can reach kubectl. MERGING APPLIES NOTHING, and
# now neither does any push to the public site repo.
#
# LEGACY CARRIER IS NOW DEAD CODE. `web-stack-apply` below still exists as the
# original adapter-node cutover carrier (an operator with an operator-custody
# web-apply kubeconfig could run `just web-stack-apply` by hand), but
# `_web-stack-promotion-interlock` refuses it unconditionally now that the
# gftb-site static origin is permanently promoted onto
# Deployment/greatfallstoolbus-org -- there is no live state this carrier could
# run against without the interlock firing. The reviewed, actually-used
# forward path for the static origin is the web-release-* chain below, not
# this carrier.
#
# TREE HONESTY (rung 1, 2026-08-21; ratification basis: operator interview
# 2026-08-21, session register L71 Q2 rungs 1+2). This comment used to say the
# operator-supplied WEB_APPLY_IMAGE was "re-pinned imperatively post-apply, so
# the live pin may diverge from the declarative record in the tree" -- as if
# that divergence were an accepted, permanent property of the design. It
# wasn't a property of the design; it was this declarative record never being
# updated at promotion time. The honest invariant is: THE TREE PINS WHAT IS
# SERVED, and the operator updates k8s/web/greatfallstoolbus-org-production/
# deployment.yaml as part of each web-release-* ceremony's pin step, the same
# ceremony that already computes and asserts the exact served image digest
# (see `_web-release-candidate-inputs`, `web-release-plan`). The
# namespace-scoped web-apply SA cannot create namespaces; the operator minted
# the greatfallstoolbus-org-production namespace + SA/RBAC out of band, once,
# already. See k8s/web/README.md and docs/runbooks/oncluster-web-cutover.md.

web_stack_dir := "k8s/web/greatfallstoolbus-org-production"
web_stack_ns := "greatfallstoolbus-org-production"

# Remote-resource ALLOWLIST guard (round 4, adversarial review PR #127
# comments 5380010266 + 5380172269): every kustomize reference-carrying field
# (resources/bases/components/generators/transformers/configurations/crds
# and more -- see the script header) is accepted ONLY if it resolves to a
# real, contained local path; everything else is refused before any
# `kubectl kustomize` call. Replaces a round-3 denylist that adversarial
# review proved leaky three separate ways (scheme-less git-host shorthand on
# `resources`, and the `transformers`/`configurations`/`crds` fields being
# absent from the field list entirely).
guard-no-remote-kustomize-resources:
    bash scripts/guard-no-remote-kustomize-resources.sh {{ web_stack_dir }}

guard-no-remote-kustomize-resources-selftest:
    bash scripts/guard-no-remote-kustomize-resources.sh --self-test

# REMOTE-ONLY-GUARD EXEMPTION (deliberate, operator ruling 2026-09-01): this
# recipe is the receipt-pinned WEB_RELEASE_VALIDATION_CALLEE and the reviewed
# web-release-render invokes it under `env -i PATH=... HOME=...`, which strips
# GITHUB_ACTIONS. A guard line here would break the ratified attended release
# ceremony (and the public-surface self-test fixture that executes it) while
# adding nothing: every recipe-level entrypoint that reaches it is guarded.
web-stack-validate:
    bash scripts/validate-web-stack.sh {{ web_stack_dir }}

# Rung 2 (org-standard-cd-pattern-truth-20260821.md sec 4.1 -- "great-falls-
# tool-bus-infra: no preview needed; wire the existing <stack>-plan ...
# recipes as PR-required statuses. That IS rung 2 for the overlay." --
# ratification basis: operator interview 2026-08-21, register L71 Q2 = rungs
# 1+2, L73). Render the COMMITTED declare-only tree to stdout: kustomize only,
# nothing else. This is deliberately NOT web-release-render: it takes no
# WEB_APPLY_IMAGE/WEB_APPLY_SHA, resolves no GHCR candidate, injects no
# source-sha annotation, and synthesizes no default-deny-egress NetworkPolicy.
# It calls no `just` recipe at all, so it cannot reach -- directly or
# transitively -- any member of the web-release-* reviewed candidate-
# promotion family (scripts/validate-public-operator-surface.py
# WEB_RELEASE_OPERATOR_LOCAL_ROOTS): that family stays exactly what TIN-3899 /
# decisions/0016 made it, attended-operator-only and unreachable from every
# CI workflow, and this recipe is written to stay outside its closure by
# construction rather than by a validator exemption. Since rung 1
# (deployment.yaml's "TREE HONESTY" fix) the committed tree already matches
# web-release-render's own contract for every field except THREE it still
# names as ceremony-only residuals -- in order of consequence: (1) the
# PER-RELEASE CONTAINER IMAGE DIGEST (the field that decides what code
# production actually runs; this render shows whatever digest is currently
# committed, which is NOT necessarily what the next release ceremony will
# pin), (2) the per-release source-sha annotation, and (3) the synthesized
# default-deny-egress NetworkPolicy -- so this render is close to, but not
# byte-identical with, what the attended ceremony would apply. Say that
# honestly, and name the digest explicitly, in anything that consumes this
# output; do not call it "the exact apply-time bytes". (The ceremony also
# prunes two legacy egress NetworkPolicies at apply time -- that is an
# apply-time-only concern, not a render residual: those two objects are not
# in the committed tree at all, so this render never carries them either.)
#
# Runs the standalone remote-resource ALLOWLIST guard
# (scripts/guard-no-remote-kustomize-resources.sh; round 4 after adversarial
# review found the round-3 denylist leaky -- see that script's header)
# directly, as a plain script call -- NOT via a `web-stack-validate` Just
# dependency, because that recipe's own success message would print onto
# this recipe's stdout ahead of the YAML, corrupting every caller that
# captures `just web-stack-render` as a pure render (the workflow does
# exactly that). The guard script itself is silent on success and calls no
# `just` recipe, so this stays outside the web-release-* closure exactly as
# before.
web-stack-render:
    @bash scripts/remote-only-guard.sh web-stack-render
    bash scripts/guard-no-remote-kustomize-resources.sh {{ web_stack_dir }}
    kubectl kustomize {{ web_stack_dir }}

# Operator-supplied cutover inputs (attended env; never baked, and since
# TIN-3899 never workflow-delivered either):
#   WEB_APPLY_KUBECONFIG  path to the materialized namespace-scoped SA kubeconfig
#   WEB_APPLY_IMAGE       image to serve (operator-resolved; not the PLACEHOLDER)
# WEB_APPLY_REPLICAS    replica count to flip to (default 2, the MI prod shape)
_web-apply-inputs:
    test -n "${WEB_APPLY_KUBECONFIG:-}" || { echo "Set WEB_APPLY_KUBECONFIG to the web-apply kubeconfig path"; exit 1; }
    test -f "${WEB_APPLY_KUBECONFIG}"
    test -n "${WEB_APPLY_IMAGE:-}" || { echo "Set WEB_APPLY_IMAGE to the operator-resolved image reference"; exit 1; }
    case "${WEB_APPLY_IMAGE}" in *PLACEHOLDER*) echo "refusing the declare-only PLACEHOLDER image; supply the real operator-resolved reference"; exit 1 ;; esac

# Lighter-weight input check for read-only commands (drift-check) that need
# only the kubeconfig, not an image to pin.
_web-apply-kubeconfig-only:
    test -n "${WEB_APPLY_KUBECONFIG:-}" || { echo "Set WEB_APPLY_KUBECONFIG to the web-apply kubeconfig path"; exit 1; }
    test -f "${WEB_APPLY_KUBECONFIG}"

# Server-side dry-run of the workload apply against the live API (no mutation).
web-stack-server-dry-run: web-stack-validate _web-apply-inputs
    kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" --namespace {{ web_stack_ns }} apply --dry-run=server -k {{ web_stack_dir }}

# PROMOTION INTERLOCK (TIN-3816; unattended trigger retired by TIN-3899). This
# legacy adapter-node carrier and the reviewed web-release chain both mutate
# Deployment/greatfallstoolbus-org in {{ web_stack_ns }}. Once the gftb-site
# static origin is promoted in place, re-running this carrier would re-pin the
# adapter-node image over it and `apply -k` would recreate allow-egress-dns /
# allow-egress-discuss-archive -- silently reverting the promotion and falsifying
# the SERVED proof.
#
# The carrier USED TO be fired unattended by web-stack.yml's
# `repository_dispatch: web-image-published` (sent by greatfallstoolbus.org's
# container-ghcr.yml on every push to main). TIN-3899 deleted that workflow and
# the site-side signal job, so the carrier now has no automated caller at all and
# the runbook quiesce rule is retired. This interlock is KEPT as the mechanical
# belt-and-braces on the one remaining, attended path: it refuses from live
# state, so an operator cannot revert the promotion by hand either, and its
# receipt in WEB_RELEASE_CRITICAL_RECIPE_DIGESTS keeps any future re-wiring of a
# mutating carrier failing closed at `just public-surface`.
_web-stack-promotion-interlock: _web-apply-kubeconfig-only
    #!/usr/bin/env bash
    set -euo pipefail
    live_image="$(kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" --namespace {{ web_stack_ns }} get deployment/greatfallstoolbus-org --ignore-not-found -o jsonpath='{.spec.template.spec.containers[?(@.name=="greatfallstoolbus-org")].image}')"
    case "${live_image}" in
      ghcr.io/great-falls-tool-bus/gftb-site@*|ghcr.io/great-falls-tool-bus/gftb-site:*)
        echo "::error::promotion interlock: Deployment/greatfallstoolbus-org in {{ web_stack_ns }} already carries the promoted gftb-site origin (${live_image}). The legacy adapter-node carrier would revert it. Refusing." >&2
        echo "Quiesce greatfallstoolbus.org main (the repository_dispatch source) until this carrier is retired; see docs/runbooks/oncluster-web-cutover.md section S." >&2
        exit 1
        ;;
    esac
    echo "promotion interlock: live image '${live_image:-<absent>}' is not a promoted gftb-site origin; the legacy carrier may proceed"

# Operator-gated cutover apply: workload -> pin image -> flip replicas 0 -> N.
# The namespace must already exist (the SA is namespace-scoped and cannot create
# it); replicas are patched on the Deployment resource, not via the scale
# subresource, so the least-privilege patch-Deployment grant is sufficient.
web-stack-apply: _web-stack-promotion-interlock web-stack-server-dry-run
    kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" --namespace {{ web_stack_ns }} apply -k {{ web_stack_dir }}
    kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" --namespace {{ web_stack_ns }} set image deployment/greatfallstoolbus-org greatfallstoolbus-org="${WEB_APPLY_IMAGE}"
    kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" --namespace {{ web_stack_ns }} patch deployment/greatfallstoolbus-org --type merge --patch '{"spec":{"replicas":'"${WEB_APPLY_REPLICAS:-2}"'}}'
    # 300s (was 180s): run 28769199755 (2026-07-06) hit `timed out waiting for the condition` on a cold-node image pull, but the rollout verified Ready seconds later -- a benign race, not a real failure.
    kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" --namespace {{ web_stack_ns }} rollout status deployment/greatfallstoolbus-org --timeout=300s

# Post-apply read-only health gate: Deployment readyReplicas == desired. A ready
# replica means the kubelet readinessProbe (GET /health on :3000) passed, so this
# IS the /health gate. An in-namespace ad hoc curl is intentionally NOT the gate:
# the NetworkPolicy admits :3000 only from the cloudflared tunnel and Prometheus,
# so the Service /health curl is verified at runbook P4 through the tunnel.
web-stack-health:
    #!/usr/bin/env bash
    set -euo pipefail
    test -n "${WEB_APPLY_KUBECONFIG:-}" || { echo "Set WEB_APPLY_KUBECONFIG to the web-apply kubeconfig path"; exit 1; }
    desired="$(kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" --namespace {{ web_stack_ns }} get deployment/greatfallstoolbus-org -o jsonpath='{.spec.replicas}')"
    ready="$(kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" --namespace {{ web_stack_ns }} get deployment/greatfallstoolbus-org -o jsonpath='{.status.readyReplicas}')"
    ready="${ready:-0}"
    echo "web stack health: ${ready}/${desired} replicas Ready (readinessProbe = GET /health on :3000)"
    if [ "${ready}" != "${desired}" ]; then
      echo "health gate FAILED: ready ${ready} != desired ${desired}" >&2
      exit 1
    fi
    echo "web stack health gate passed"

# --- GFTB Grafana dashboards (TIN-3896) -------------------------------------
# Checked-in dashboard JSON for the three GFTB surfaces (web serve; mail/list/
# form; ARC runners). These are DECLARATIONS ONLY: this recipe never contacts
# Grafana, and the repo holds no Grafana credential. Importing them into the
# live instance is an operator action -- see the README beside the JSON for the
# provisioning proposal and the panel inventory.
#
# Every PromQL expression was discovered against the live cluster Prometheus
# before it was written; where a signal has no exporter, the dashboard carries
# a "signal not exported yet" text panel instead of an invented metric name.

grafana_dashboard_dir := "observability/grafana/dashboards/gftb"

grafana-dashboards-validate:
    bash scripts/validate-grafana-dashboards.sh {{ grafana_dashboard_dir }}

# --- Reviewed gftb-site release candidate proofs ----------------------------
# These recipes are read-only/proof-only. They deliberately do not share the
# legacy `web-stack-apply` mutation carrier, which pins the adapter-node image
# and must never receive the static Caddy candidate; that candidate travels only
# through the reviewed exact-render/apply/rollback contract below. The workflow
# that used to drive the legacy carrier (.github/workflows/web-stack.yml) is
# retired (TIN-3899).

_web-release-candidate-inputs:
    #!/usr/bin/env -S BASH_ENV= ENV= SHELLOPTS= BASHOPTS= bash -p
    set +x
    set -euo pipefail
    : "${WEB_APPLY_IMAGE:?Set WEB_APPLY_IMAGE to the reviewed gftb-site digest}"
    : "${WEB_APPLY_SHA:?Set WEB_APPLY_SHA to the exact gftb-site source commit}"
    [[ "${WEB_APPLY_IMAGE}" =~ ^ghcr\.io/great-falls-tool-bus/gftb-site@sha256:[0-9a-f]{64}$ ]] || { echo "WEB_APPLY_IMAGE must be the exact gftb-site sha256 digest" >&2; exit 2; }
    [[ "${WEB_APPLY_SHA}" =~ ^[0-9a-f]{40}$ ]] || { echo "WEB_APPLY_SHA must be 40 lowercase hex characters" >&2; exit 2; }
    [[ "${WEB_APPLY_REPLICAS:-2}" == "2" ]] || { echo "WEB_APPLY_REPLICAS must be exactly 2 for the ratified production shape" >&2; exit 2; }
    while IFS='=' read -r name value; do
      case "${name}" in
        HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|http_proxy|https_proxy|all_proxy|no_proxy)
          if [[ -n "${value}" ]]; then
            echo "Refusing ambient ${name}; release proofs must use the direct reviewed route" >&2
            exit 2
          fi
          ;;
      esac
    done < <(env)

# Discover the immutable candidate for ONE exact gftb-site source commit, prove
# that digest, then re-resolve the tag and refuse if it moved. This is the
# reviewed single entrypoint for OBTAINING WEB_APPLY_IMAGE: the operator supplies
# only WEB_APPLY_SHA, the one allowed tag is constructed here rather than typed,
# and the digest is never hand-copied out of a registry UI. It takes no Just
# dependency: _web-release-candidate-inputs demands a WEB_APPLY_IMAGE that does
# not exist yet, so the guard is applied by the nested candidate-proof call once
# the digest is known.
#
# NOTHING is printed to stdout until BOTH the nested proof receipt and the
# second tag read have been checked, so a green-looking line can never precede a
# refusal. The proof's own receipt is captured rather than streamed for the same
# reason, and because its exact text is what positively confirms the reviewed
# callee actually ran: a renamed/skipped recipe that exits 0 silently (e.g. under
# JUST_ALLOW_MISSING) yields no receipt and is refused here.
web-release-resolve-candidate:
    #!/usr/bin/env -S BASH_ENV= ENV= SHELLOPTS= BASHOPTS= bash -p
    set +x
    set -euo pipefail
    : "${WEB_APPLY_SHA:?Set WEB_APPLY_SHA to the exact gftb-site source commit}"
    [[ "${WEB_APPLY_SHA}" =~ ^[0-9a-f]{40}$ ]] || { echo "WEB_APPLY_SHA must be 40 lowercase hex characters" >&2; exit 2; }
    [[ "${WEB_APPLY_IMAGE+x}" != x ]] || { echo "WEB_APPLY_IMAGE must be unset; the resolver selects the immutable digest" >&2; exit 2; }
    command -v crane >/dev/null 2>&1 || { echo "crane is required (nix develop provides it)" >&2; exit 1; }
    command -v just >/dev/null 2>&1 || { echo "just is required (nix develop provides it)" >&2; exit 1; }
    umask 077
    source_sha="${WEB_APPLY_SHA}"
    candidate_tag="ghcr.io/great-falls-tool-bus/gftb-site:sha-${source_sha}"
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
    resolver_dir="$(mktemp -d "${temp_root}/gftb-web-resolver.XXXXXX")"
    trap 'rm -rf "${resolver_dir}"' EXIT
    mkdir -m 700 "${resolver_dir}/home" "${resolver_dir}/xdg" "${resolver_dir}/docker"
    printf '{}\n' > "${resolver_dir}/docker/config.json"
    chmod 600 "${resolver_dir}/docker/config.json"
    crane_clean() {
      env -i PATH="${PATH}" HOME="${resolver_dir}/home" XDG_CONFIG_HOME="${resolver_dir}/xdg" DOCKER_CONFIG="${resolver_dir}/docker" crane "$@"
    }
    resolve_candidate_tag() {
      local stage="$1"
      local resolved
      resolved="$(crane_clean digest "${candidate_tag}")" || { echo "candidate tag ${stage} resolution failed" >&2; exit 1; }
      [[ "${resolved}" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "candidate tag ${stage} digest is malformed" >&2; exit 1; }
      printf '%s\n' "${resolved}"
    }
    first_digest="$(resolve_candidate_tag first)"
    candidate_image="ghcr.io/great-falls-tool-bus/gftb-site@${first_digest}"
    # Deliberately NOT run under `env -i`: unlike the registry reads above, this
    # is the reviewed guard re-entering on the OPERATOR's real environment.
    # _web-release-candidate-inputs exists to refuse ambient proxy settings and a
    # non-2 WEB_APPLY_REPLICAS; scrubbing the environment here would hide exactly
    # the ambient state that guard is there to catch. For the same reason
    # WEB_APPLY_REPLICAS is passed through untouched rather than pinned to 2 --
    # the resolver discovers a digest, it does not launder release inputs. Only
    # WEB_APPLY_IMAGE is contributed, and it is the digest just resolved.
    proof_output="$(WEB_APPLY_IMAGE="${candidate_image}" WEB_APPLY_SHA="${source_sha}" just web-release-candidate-proof)"
    [[ "${proof_output}" == *"anonymous candidate proof passed: source=${source_sha} digest=${first_digest}"* ]] || { echo "nested candidate proof did not emit its receipt" >&2; exit 1; }
    second_digest="$(resolve_candidate_tag second)"
    [[ "${second_digest}" == "${first_digest}" ]] || { echo "candidate tag moved during the proof; refusing" >&2; exit 1; }
    printf '%s\n' "${proof_output}"
    echo "resolved candidate: source=${source_sha} tag=${candidate_tag} digest=${first_digest}"

# Prove the package is anonymously readable, is the selected immutable digest,
# and carries the exact static-Caddy runtime/source identity. Every registry
# call runs with an empty process environment and fresh Docker credential root.
web-release-candidate-proof: _web-release-candidate-inputs
    #!/usr/bin/env -S BASH_ENV= ENV= SHELLOPTS= BASHOPTS= bash -p
    set +x
    set -euo pipefail
    command -v crane >/dev/null 2>&1 || { echo "crane is required (nix develop provides it)" >&2; exit 1; }
    command -v jq >/dev/null 2>&1 || { echo "jq is required (nix develop provides it)" >&2; exit 1; }
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
    proof_dir="$(mktemp -d "${temp_root}/gftb-web-candidate.XXXXXX")"
    trap 'rm -rf "${proof_dir}"' EXIT
    mkdir -m 700 "${proof_dir}/home" "${proof_dir}/xdg" "${proof_dir}/docker"
    printf '{}\n' > "${proof_dir}/docker/config.json"
    chmod 600 "${proof_dir}/docker/config.json"
    crane_clean() {
      env -i PATH="${PATH}" HOME="${proof_dir}/home" XDG_CONFIG_HOME="${proof_dir}/xdg" DOCKER_CONFIG="${proof_dir}/docker" crane "$@"
    }
    expected_digest="${WEB_APPLY_IMAGE##*@}"
    actual_digest="$(crane_clean digest "${WEB_APPLY_IMAGE}")"
    [[ "${actual_digest}" == "${expected_digest}" ]] || { echo "anonymous digest mismatch" >&2; exit 1; }
    crane_clean manifest "${WEB_APPLY_IMAGE}" > "${proof_dir}/manifest.json"
    crane_clean config "${WEB_APPLY_IMAGE}" > "${proof_dir}/config.json"
    jq -e '
      .schemaVersion == 2
      and ((.mediaType == "application/vnd.oci.image.manifest.v1+json") or (.mediaType == "application/vnd.docker.distribution.manifest.v2+json"))
      and (has("manifests") | not)
      and ((.config.digest // "") | test("^sha256:[0-9a-f]{64}$"))
      and ((.config.size // 0) > 0)
      and ((.layers | length) > 0)
      and all(.layers[]; ((.digest // "") | test("^sha256:[0-9a-f]{64}$")) and ((.size // 0) > 0))
    ' "${proof_dir}/manifest.json" >/dev/null || { echo "candidate is not one valid OCI/Docker image manifest" >&2; exit 1; }
    jq -e --arg sha "${WEB_APPLY_SHA}" '
      .os == "linux"
      and .architecture == "amd64"
      and .config.User == "65532:65532"
      and .config.Entrypoint == ["/bin/dumb-init", "--"]
      and .config.Cmd == ["/bin/caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
      and .config.WorkingDir == "/srv"
      and (.config.Env | sort) == (["HOME=/tmp", "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt", "XDG_CONFIG_HOME=/tmp", "XDG_DATA_HOME=/tmp"] | sort)
      and (.config.ExposedPorts | type == "object" and (keys == ["3000/tcp"]))
      and .config.Labels["org.opencontainers.image.source"] == "https://github.com/Great-Falls-Tool-Bus/gftb-site"
      and .config.Labels["org.opencontainers.image.revision"] == $sha
    ' "${proof_dir}/config.json" >/dev/null || { echo "candidate OCI runtime/source contract mismatch" >&2; exit 1; }
    crane_clean pull "${WEB_APPLY_IMAGE}" "${proof_dir}/image.tar"
    test -s "${proof_dir}/image.tar" || { echo "anonymous candidate pull produced no image" >&2; exit 1; }
    echo "anonymous candidate proof passed: source=${WEB_APPLY_SHA} digest=${expected_digest}"

# Render the exact static-Caddy workload to stdout for the given
# WEB_APPLY_IMAGE/WEB_APPLY_SHA. The checked-in base (rung 1 tree honesty,
# 2026-08-21) already carries the static-Caddy shape -- this transform's
# per-container overrides are now idempotent no-ops for everything except the
# per-release image, source-sha annotation, and the synthesized
# default-deny-egress NetworkPolicy (see k8s/web/.../deployment.yaml and
# networkpolicy.yaml headers). This recipe never writes back to the checked-in
# manifest; callers may redirect stdout only to a caller-owned temporary
# receipt. No cluster or registry is contacted here.
web-release-render: _web-release-candidate-inputs
    #!/usr/bin/env -S BASH_ENV= ENV= SHELLOPTS= BASHOPTS= bash -p
    set +x
    set -euo pipefail
    command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required (nix develop provides it)" >&2; exit 1; }
    command -v yq >/dev/null 2>&1 || { echo "yq is required (nix develop provides it)" >&2; exit 1; }
    command -v jq >/dev/null 2>&1 || { echo "jq is required (nix develop provides it)" >&2; exit 1; }
    yq_version="$(yq --version 2>&1 || true)"
    if ! printf "%s" "${yq_version}" | grep -qi "mikefarah" || ! printf "%s" "${yq_version}" | grep -Eqi "version v?4\."; then echo "mikefarah yq-go v4 is required; got: ${yq_version:-unavailable}" >&2; exit 1; fi
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
    render_dir="$(mktemp -d "${temp_root}/gftb-web-render.XXXXXX")"
    trap 'rm -rf "${render_dir}"' EXIT
    mkdir -m 700 "${render_dir}/home"
    env -i PATH="${PATH}" HOME="${render_dir}/home" just web-stack-validate >/dev/null
    base="${render_dir}/base.yaml"
    rendered="${render_dir}/rendered.yaml"
    kubectl kustomize {{ web_stack_dir }} > "${base}"
    # Keep YAML parsing/serialization in mikefarah yq-go and all mutation
    # semantics in jq; -I=0 produces one JSON document per input document.
    yq eval-all -o=json -I=0 '.' "${base}" \
      | jq --arg image "${WEB_APPLY_IMAGE}" --arg sha "${WEB_APPLY_SHA}" '
      if .kind == "NetworkPolicy" and (.metadata.name == "allow-egress-dns" or .metadata.name == "allow-egress-discuss-archive") then
        empty
      elif .kind == "Deployment" and .metadata.name == "greatfallstoolbus-org" and .metadata.namespace == "greatfallstoolbus-org-production" then
        .spec.replicas = 2
        | .spec.template.metadata.annotations["app.tinyland.dev/source-sha"] = $sha
        | .spec.template.spec.automountServiceAccountToken = false
        | .spec.template.spec.enableServiceLinks = false
        | .spec.template.spec.securityContext = {
            "runAsNonRoot": true,
            "runAsUser": 65532,
            "runAsGroup": 65532,
            "fsGroup": 65532,
            "seccompProfile": {"type": "RuntimeDefault"}
          }
        | del(
            .spec.template.spec.hostNetwork,
            .spec.template.spec.hostPID,
            .spec.template.spec.hostIPC,
            .spec.template.spec.shareProcessNamespace
          )
        | .spec.template.spec.containers |= map(
            if .name == "greatfallstoolbus-org" then
              .image = $image
              | .securityContext = {
                  "allowPrivilegeEscalation": false,
                  "readOnlyRootFilesystem": true,
                  "capabilities": {"drop": ["ALL"]}
                }
              | del(.command, .args, .env, .envFrom, .volumeMounts, .lifecycle, .workingDir, .stdin, .stdinOnce, .tty)
              | .ports |= map(del(.hostIP, .hostPort))
            else . end
          )
      elif .kind == "NetworkPolicy" and .metadata.name == "default-deny-ingress" and .metadata.namespace == "greatfallstoolbus-org-production" then
        .,
        {
          "apiVersion": "networking.k8s.io/v1",
          "kind": "NetworkPolicy",
          "metadata": {
            "name": "default-deny-egress",
            "namespace": "greatfallstoolbus-org-production",
            "labels": {
              "app.kubernetes.io/managed-by": "great-falls-tool-bus-infra",
              "app.kubernetes.io/part-of": "great-falls-tool-bus",
              "app.tinyland.dev/lifecycle": "declare-only",
              "app.tinyland.dev/tenant": "great-falls-tool-bus"
            }
          },
          "spec": {
            "podSelector": {
              "matchLabels": {
                "app.kubernetes.io/name": "greatfallstoolbus-org",
                "app.kubernetes.io/component": "web"
              }
            },
            "policyTypes": ["Egress"],
            "egress": []
          }
        }
      else . end
      ' \
      | yq eval-all -p=json -o=yaml -P '.' - > "${rendered}"
    # The later mutation lane must explicitly delete the two omitted legacy
    # adapter-node egress policies; `kubectl apply` does not prune omissions.
    expected_census=$'Deployment\tgreatfallstoolbus-org\tgreatfallstoolbus-org-production\nNetworkPolicy\tallow-cloudflared-tunnel-ingress\tgreatfallstoolbus-org-production\nNetworkPolicy\tallow-prometheus-scrape\tgreatfallstoolbus-org-production\nNetworkPolicy\tdefault-deny-egress\tgreatfallstoolbus-org-production\nNetworkPolicy\tdefault-deny-ingress\tgreatfallstoolbus-org-production\nService\tgreatfallstoolbus-org\tgreatfallstoolbus-org-production'
    actual_census="$(
      yq eval-all -o=json -I=0 '.' "${rendered}" \
        | jq -r '[.kind, .metadata.name, (.metadata.namespace // "")] | @tsv' \
        | LC_ALL=C sort
    )"
    [[ "${actual_census}" == "${expected_census}" ]] || { echo "rendered object census mismatch" >&2; exit 1; }
    yq eval-all -o=json -I=0 '.' "${rendered}" \
      | jq --slurp -e --arg image "${WEB_APPLY_IMAGE}" --arg sha "${WEB_APPLY_SHA}" '
      [.[] | select(.kind == "Deployment" and .metadata.name == "greatfallstoolbus-org" and .metadata.namespace == "greatfallstoolbus-org-production")] as $deployments
      | [.[] | select(.kind == "Service" and .metadata.name == "greatfallstoolbus-org" and .metadata.namespace == "greatfallstoolbus-org-production")] as $services
      | ($deployments | length) == 1
        and ($deployments[0].spec.replicas == 2)
        and ($deployments[0].spec.template.metadata.annotations["app.tinyland.dev/source-sha"] == $sha)
        and ($deployments[0].spec.template.spec.automountServiceAccountToken == false)
        and ($deployments[0].spec.template.spec.enableServiceLinks == false)
        and ($deployments[0].spec.template.spec.securityContext.runAsNonRoot == true)
        and ($deployments[0].spec.template.spec.securityContext.runAsUser == 65532)
        and ($deployments[0].spec.template.spec.securityContext.runAsGroup == 65532)
        and ($deployments[0].spec.template.spec.securityContext.fsGroup == 65532)
        and ($deployments[0].spec.template.spec.securityContext.seccompProfile.type == "RuntimeDefault")
        and (($deployments[0].spec.template.spec.securityContext | keys | sort) == (["fsGroup", "runAsGroup", "runAsNonRoot", "runAsUser", "seccompProfile"] | sort))
        and (($deployments[0].spec.template.spec.securityContext.seccompProfile | keys) == ["type"])
        and (($deployments[0].spec.template.spec | has("hostNetwork")) | not)
        and (($deployments[0].spec.template.spec | has("hostPID")) | not)
        and (($deployments[0].spec.template.spec | has("hostIPC")) | not)
        and (($deployments[0].spec.template.spec | has("shareProcessNamespace")) | not)
        and (($deployments[0].spec.template.spec | has("initContainers")) | not)
        and (($deployments[0].spec.template.spec | has("ephemeralContainers")) | not)
        and (($deployments[0].spec.template.spec | has("imagePullSecrets")) | not)
        and (($deployments[0].spec.template.spec | has("volumes")) | not)
        and (($deployments[0].spec.template.spec.containers | length) == 1)
        and ($deployments[0].spec.template.spec.containers[0].name == "greatfallstoolbus-org")
        and ($deployments[0].spec.template.spec.containers[0].image == $image)
        and (($deployments[0].spec.template.spec.containers[0] | has("command")) | not)
        and (($deployments[0].spec.template.spec.containers[0] | has("args")) | not)
        and (($deployments[0].spec.template.spec.containers[0] | has("env")) | not)
        and (($deployments[0].spec.template.spec.containers[0] | has("envFrom")) | not)
        and (($deployments[0].spec.template.spec.containers[0] | has("volumeMounts")) | not)
        and (($deployments[0].spec.template.spec.containers[0] | has("lifecycle")) | not)
        and (($deployments[0].spec.template.spec.containers[0] | has("workingDir")) | not)
        and (($deployments[0].spec.template.spec.containers[0] | has("stdin")) | not)
        and (($deployments[0].spec.template.spec.containers[0] | has("stdinOnce")) | not)
        and (($deployments[0].spec.template.spec.containers[0] | has("tty")) | not)
        and ($deployments[0].spec.template.spec.containers[0].ports == [{"containerPort": 3000, "name": "http", "protocol": "TCP"}])
        and ($deployments[0].spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation == false)
        and ($deployments[0].spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem == true)
        and ($deployments[0].spec.template.spec.containers[0].securityContext.capabilities.drop == ["ALL"])
        and (($deployments[0].spec.template.spec.containers[0].securityContext | keys | sort) == (["allowPrivilegeEscalation", "capabilities", "readOnlyRootFilesystem"] | sort))
        and (($deployments[0].spec.template.spec.containers[0].securityContext.capabilities | keys) == ["drop"])
        and ($services | length) == 1
        and ($services[0].apiVersion == "v1")
        and ($services[0].kind == "Service")
        and (($services[0].spec | keys | sort) == (["ports", "selector", "type"] | sort))
        and ($services[0].spec.type == "ClusterIP")
        and ($services[0].spec.selector == {"app.kubernetes.io/component": "web", "app.kubernetes.io/name": "greatfallstoolbus-org"})
        and ($services[0].spec.ports == [{"name": "http", "port": 80, "protocol": "TCP", "targetPort": "http"}])
        and ([.[] | select(.kind == "Namespace" or .kind == "Secret" or .kind == "SecretList")] | length) == 0
      ' >/dev/null || { echo "rendered static-Caddy workload contract mismatch" >&2; exit 1; }
    rendered_network_policies_semantic="$(
      yq eval-all -o=json -I=0 '.' "${rendered}" \
        | jq --slurp -S -c '
      def canonical_rule:
        (if ((.from? // null) | type) == "array" then .from |= sort_by(tojson) else . end)
        | (if ((.to? // null) | type) == "array" then (if .to == [] then del(.to) else .to |= sort_by(tojson) end) else . end)
        | (if ((.ports? // null) | type) == "array" then .ports |= sort_by(tojson) else . end);
      [.[] | select(.kind == "NetworkPolicy") | {
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
        '
    )"
    rendered_network_policies_digest="$(python3 -I -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())' "${rendered_network_policies_semantic}")"
    [[ "${rendered_network_policies_digest}" == "301eecb4ad234fdd7258ac7351a5a563e1b53cb250bce6f51a68824854b28220" ]] || { echo "rendered static-Caddy NetworkPolicy contract mismatch" >&2; exit 1; }
    cat "${rendered}"

_web-release-kubeconfig-inputs:
    #!/usr/bin/env -S BASH_ENV= ENV= SHELLOPTS= BASHOPTS= bash -p
    set +x
    set -euo pipefail
    : "${WEB_RELEASE_KUBECONFIG:?Set WEB_RELEASE_KUBECONFIG to the proof-only web release kubeconfig}"
    source_kubeconfig="${WEB_RELEASE_KUBECONFIG}"
    [[ -z "${KUBECONFIG:-}" ]] || { echo "Refusing ambient KUBECONFIG; WEB_RELEASE_KUBECONFIG is authoritative" >&2; exit 2; }
    while IFS='=' read -r name value; do
      case "${name}" in
        HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|http_proxy|https_proxy|all_proxy|no_proxy)
          if [[ -n "${value}" ]]; then
            echo "Refusing ambient ${name}; web release readback may not transit a proxy" >&2
            exit 2
          fi
          ;;
      esac
    done < <(env)
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
    kube_dir="$(mktemp -d "${temp_root}/gftb-web-kubeconfig.XXXXXX")"
    trap 'rm -rf "${kube_dir}"' EXIT
    mkdir -m 700 "${kube_dir}/home"
    release_kubeconfig="${kube_dir}/kubeconfig"
    python3 -I - "${source_kubeconfig}" "$(git rev-parse --show-toplevel)" "${release_kubeconfig}" <<'PY'
    import os
    import shutil
    import stat
    import sys
    from pathlib import Path

    raw = Path(sys.argv[1])
    repo = Path(sys.argv[2]).resolve(strict=True)
    destination = Path(sys.argv[3])
    destination_parent = destination.parent.stat()
    if not stat.S_ISDIR(destination_parent.st_mode) or destination_parent.st_uid != os.getuid() or stat.S_IMODE(destination_parent.st_mode) != 0o700:
        raise SystemExit("private kubeconfig staging directory failed custody validation")
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
    with os.fdopen(source_fd, "rb") as source, os.fdopen(destination_fd, "wb") as target:
        shutil.copyfileobj(source, target)
        target.flush()
        os.fsync(target.fileno())
    PY
    kubectl_clean() {
      env -i PATH="${PATH}" HOME="${kube_dir}/home" kubectl --kubeconfig "${release_kubeconfig}" "$@"
    }
    auth_stdout="${kube_dir}/auth.stdout"
    auth_stderr="${kube_dir}/auth.stderr"
    auth_decision() {
      local status output
      : > "${auth_stdout}"
      : > "${auth_stderr}"
      if kubectl_clean "$@" > "${auth_stdout}" 2> "${auth_stderr}"; then
        status=0
      else
        status=$?
      fi
      output="$(tr -d '\r\n' < "${auth_stdout}")"
      if [[ -s "${auth_stderr}" ]] || { [[ "${status}" -ne 0 ]] && [[ "${status}" -ne 1 ]]; } || { [[ "${status}" -eq 0 ]] && [[ "${output}" != "yes" ]]; } || { [[ "${status}" -eq 1 ]] && [[ "${output}" != "no" ]]; }; then
        echo "Kubernetes authorization decision was not an exact yes/no result" >&2
        return 2
      fi
      printf '%s\n' "${output}"
    }
    capture_kubectl_output() {
      local destination="$1"
      local requirement="$2"
      shift 2
      : > "${auth_stderr}"
      if ! kubectl_clean "$@" > "${destination}" 2> "${auth_stderr}"; then
        echo "Kubernetes authorization/discovery request failed" >&2
        return 2
      fi
      [[ ! -s "${auth_stderr}" ]] || { echo "Kubernetes authorization/discovery request emitted diagnostics" >&2; return 2; }
      [[ "${requirement}" == "allow-empty" ]] || test -s "${destination}" || { echo "Kubernetes authorization/discovery request returned no data" >&2; return 2; }
    }
    raw_ssar_decision() {
      local verb="$1" api_group="$2" resource="$3"
      local request="${kube_dir}/raw-ssar-request.json"
      local response="${kube_dir}/raw-ssar-response.json"
      jq -n --arg verb "${verb}" --arg api_group "${api_group}" --arg resource "${resource}" '
        {
          apiVersion: "authorization.k8s.io/v1",
          kind: "SelfSubjectAccessReview",
          spec: {resourceAttributes: {verb: $verb, group: $api_group, resource: $resource}}
        }
      ' > "${request}"
      capture_kubectl_output "${response}" require-data create --raw /apis/authorization.k8s.io/v1/selfsubjectaccessreviews -f "${request}" || return 2
      jq -e '
        .apiVersion == "authorization.k8s.io/v1"
        and .kind == "SelfSubjectAccessReview"
        and (.status.allowed | type == "boolean")
        and ((.status.denied // false) | type == "boolean")
        and ((.status.evaluationError // "") == "")
        and ((.status.allowed == false) or ((.status.denied // false) == false))
      ' "${response}" >/dev/null || { echo "Kubernetes raw authorization review was malformed" >&2; return 2; }
      if jq -e '.status.allowed == true' "${response}" >/dev/null; then printf 'yes\n'; else printf 'no\n'; fi
    }
    config_parse_stderr="${kube_dir}/config-parse.stderr"
    # yq-go owns YAML decoding; jq slurps the JSON stream and keeps the
    # exact-one-document guard fail-closed before any schema assertion.
    if ! { env -i PATH="${PATH}" HOME="${kube_dir}/home" yq eval-all -o=json -I=0 '.' "${release_kubeconfig}" | env -i PATH="${PATH}" HOME="${kube_dir}/home" jq --slurp -e '
      if length == 1 then .[0] else error("expected exactly one kubeconfig document") end
      | .["current-context"] as $current
      | type == "object"
        and ((keys | sort) == (["apiVersion", "clusters", "contexts", "current-context", "kind", "preferences", "users"] | sort))
        and .apiVersion == "v1"
        and .kind == "Config"
        and .preferences == {}
        and ($current | type == "string" and length > 0)
        and (.clusters | length) == 1
        and (.contexts | length) == 1
        and (.users | length) == 1
        and ((.clusters[0] | keys | sort) == ["cluster", "name"])
        and ((.contexts[0] | keys | sort) == ["context", "name"])
        and ((.users[0] | keys | sort) == ["name", "user"])
        and ((.clusters[0].cluster | keys | sort) == ["certificate-authority-data", "server"])
        and ((.contexts[0].context | keys | sort) == ["cluster", "namespace", "user"])
        and ((.users[0].user | keys) == ["token"])
        and (.contexts[0].name == $current)
        and (.contexts[0].context.cluster == .clusters[0].name)
        and (.contexts[0].context.user == .users[0].name)
        and (.contexts[0].context.namespace == "greatfallstoolbus-org-production")
        and ((.clusters[0].cluster.server // "") | test("^https://[A-Za-z0-9.-]+(?::[0-9]{1,5})?$"))
        and ((.clusters[0].cluster["certificate-authority-data"] // "") | type == "string" and test("^[A-Za-z0-9+/]+={0,2}$") and length >= 16)
        and ((.users[0].user.token // "") | type == "string" and test("^[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}$"))
    '; } >/dev/null 2> "${config_parse_stderr}"; then
      echo "WEB_RELEASE_KUBECONFIG must be one TLS-verified namespace-bound token context" >&2
      exit 2
    fi
    [[ ! -s "${config_parse_stderr}" ]] || { echo "WEB_RELEASE_KUBECONFIG parsing emitted unexpected diagnostics" >&2; exit 2; }
    cluster_uid="$(kubectl_clean get namespace kube-system -o jsonpath='{.metadata.uid}')"
    [[ "${cluster_uid}" == "cc121476-7a95-4b24-aa61-79d1f45713bd" ]] || { echo "WEB_RELEASE_KUBECONFIG does not target the reviewed Honey cluster" >&2; exit 2; }
    for read_contract in "get deployments" "list replicasets" "list pods" "get services" "list endpointslices.discovery.k8s.io" "list networkpolicies.networking.k8s.io"; do
      read -r verb resource <<<"${read_contract}"
      decision="$(auth_decision auth can-i "${verb}" "${resource}" --namespace {{ web_stack_ns }})" || exit 2
      [[ "${decision}" == "yes" ]] || { echo "WEB_RELEASE_KUBECONFIG cannot ${verb} ${resource}" >&2; exit 2; }
    done
    decision="$(auth_decision auth can-i get namespaces --all-namespaces)" || exit 2
    [[ "${decision}" == "yes" ]] || { echo "WEB_RELEASE_KUBECONFIG cannot read the Honey cluster identity" >&2; exit 2; }

    # SelfSubjectRulesReview is only an auxiliary, reject-only grant census.
    # Kubernetes explicitly warns that it may be incomplete and must not be the
    # authority for external decisions. Every mutation decision below is made
    # independently through SelfSubjectAccessReview (`kubectl auth can-i`).
    rules_request="${kube_dir}/rules-request.json"
    rules_response="${kube_dir}/rules-response.json"
    jq -n --arg namespace "{{ web_stack_ns }}" '{apiVersion:"authorization.k8s.io/v1",kind:"SelfSubjectRulesReview",spec:{namespace:$namespace}}' > "${rules_request}"
    capture_kubectl_output "${rules_response}" require-data create --raw /apis/authorization.k8s.io/v1/selfsubjectrulesreviews -f "${rules_request}"
    python3 -I - "${rules_response}" <<'PY'
    import json
    import sys
    from pathlib import Path

    review = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    if review.get("apiVersion") != "authorization.k8s.io/v1" or review.get("kind") != "SelfSubjectRulesReview":
        raise SystemExit("unexpected SelfSubjectRulesReview response shape")
    status = review.get("status")
    if not isinstance(status, dict) or status.get("incomplete") is not False or status.get("evaluationError", "") != "":
        raise SystemExit("SelfSubjectRulesReview is incomplete or reported an evaluation error")
    allowed_resource_actions = {
        ("", "namespaces", "get"),
        ("", "pods", "list"),
        ("", "services", "get"),
        ("apps", "deployments", "get"),
        ("apps", "replicasets", "list"),
        ("authentication.k8s.io", "selfsubjectreviews", "create"),
        ("authorization.k8s.io", "selfsubjectaccessreviews", "create"),
        ("authorization.k8s.io", "selfsubjectrulesreviews", "create"),
        ("discovery.k8s.io", "endpointslices", "list"),
        ("networking.k8s.io", "networkpolicies", "list"),
    }
    observed_resource_actions = set()
    for rule in status.get("resourceRules", []):
        if not isinstance(rule, dict):
            raise SystemExit("malformed SelfSubjectRulesReview resource rule")
        api_groups = rule.get("apiGroups")
        resources = rule.get("resources")
        verbs = rule.get("verbs")
        resource_names = rule.get("resourceNames", [])
        if not isinstance(api_groups, list) or not api_groups or not all(isinstance(value, str) for value in api_groups):
            raise SystemExit("malformed SelfSubjectRulesReview apiGroups field")
        if not all(isinstance(values, list) and values and all(isinstance(value, str) and value for value in values) for values in (resources, verbs)):
            raise SystemExit("malformed SelfSubjectRulesReview resource rule fields")
        if resource_names not in (None, []) or any("*" in values for values in (api_groups, resources, verbs)):
            raise SystemExit("named or wildcard resource authority is outside the web proof contract")
        for api_group in api_groups:
            for resource in resources:
                for verb in verbs:
                    action = (api_group, resource, verb)
                    if action not in allowed_resource_actions:
                        raise SystemExit(f"unexpected reported resource authority: {api_group}/{resource}:{verb}")
                    observed_resource_actions.add(action)
    allowed_non_resource_urls = {
        "/.well-known/openid-configuration",
        "/.well-known/openid-configuration/",
        "/api",
        "/api/*",
        "/apis",
        "/apis/*",
        "/healthz",
        "/livez",
        "/openid/v1/jwks",
        "/openid/v1/jwks/",
        "/openapi",
        "/openapi/*",
        "/readyz",
        "/version",
        "/version/",
    }
    for rule in status.get("nonResourceRules", []):
        if not isinstance(rule, dict):
            raise SystemExit("malformed SelfSubjectRulesReview non-resource rule")
        urls = rule.get("nonResourceURLs")
        verbs = rule.get("verbs")
        if not isinstance(urls, list) or not urls or not isinstance(verbs, list) or not verbs:
            raise SystemExit("malformed SelfSubjectRulesReview non-resource fields")
        if not all(isinstance(url, str) and url in allowed_non_resource_urls for url in urls):
            raise SystemExit("unexpected reported non-resource URL authority")
        if not all(isinstance(verb, str) and verb in {"get", "head"} for verb in verbs):
            raise SystemExit("unexpected reported non-resource verb authority")
    required_resource_actions = {
        ("", "namespaces", "get"),
        ("", "pods", "list"),
        ("", "services", "get"),
        ("apps", "deployments", "get"),
        ("apps", "replicasets", "list"),
        ("discovery.k8s.io", "endpointslices", "list"),
        ("networking.k8s.io", "networkpolicies", "list"),
    }
    if not required_resource_actions <= observed_resource_actions:
        raise SystemExit("SelfSubjectRulesReview omitted a required reported read grant")
    PY
    rules_snapshot="$(jq -S -c '
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
    ' "${rules_response}")"
    rules_digest="$(python3 -I -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())' "${rules_snapshot}")"

    for scope in namespaced cluster; do
      if [[ "${scope}" == "namespaced" ]]; then
        discovery_scope=(--namespaced=true)
        auth_scope=(--namespace {{ web_stack_ns }})
      else
        discovery_scope=(--namespaced=false)
        auth_scope=(--all-namespaces)
      fi
      for verb in create update patch delete deletecollection; do
        resources_file="${kube_dir}/resources-${scope}-${verb}.txt"
        normalized_resources_file="${kube_dir}/resources-${scope}-${verb}.normalized"
        capture_kubectl_output "${resources_file}" allow-empty api-resources --cached=false "${discovery_scope[@]}" --verbs="${verb}" -o name
        python3 -I - "${resources_file}" "${normalized_resources_file}" <<'PY'
    import re
    import sys
    from pathlib import Path

    resources = [line for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line]
    if len(resources) != len(set(resources)) or any(not re.fullmatch(r"[a-z0-9.-]+(?:/[a-z0-9.-]+)?", resource) for resource in resources):
        raise SystemExit("Kubernetes API discovery returned malformed or duplicate resource names")
    normalized = []
    for discovered in resources:
        if "/" not in discovered:
            normalized.append((discovered, ""))
            continue
        base, qualified_subresource = discovered.split("/", 1)
        if "." in qualified_subresource:
            subresource, api_group = qualified_subresource.split(".", 1)
            if "." in base or not api_group:
                raise SystemExit("Kubernetes API discovery returned an ambiguous grouped subresource")
            base = f"{base}.{api_group}"
        else:
            subresource = qualified_subresource
        if not re.fullmatch(r"[a-z0-9][a-z0-9.-]*", base) or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", subresource):
            raise SystemExit("Kubernetes API discovery returned a malformed subresource")
        normalized.append((base, subresource))
    if len(normalized) != len(set(normalized)):
        raise SystemExit("Kubernetes API discovery returned duplicate normalized resources")
    Path(sys.argv[2]).write_text("".join(f"{base}|{subresource}\n" for base, subresource in normalized), encoding="utf-8")
    PY
        while IFS='|' read -r resource subresource; do
          [[ -n "${resource}" ]] || continue
          auth_args=(auth can-i "${verb}" "${resource}")
          display_resource="${resource}"
          if [[ -n "${subresource}" ]]; then
            auth_args+=(--subresource="${subresource}")
            display_resource="${resource}/${subresource}"
          fi
          decision="$(auth_decision "${auth_args[@]}" "${auth_scope[@]}")" || exit 2
          if [[ "${decision}" == "yes" ]]; then
            case "${scope}:${verb}:${display_resource}" in
              cluster:create:selfsubjectaccessreviews.authorization.k8s.io|cluster:create:selfsubjectrulesreviews.authorization.k8s.io|cluster:create:selfsubjectreviews.authentication.k8s.io) ;;
              *) echo "WEB_RELEASE_KUBECONFIG can mutate ${scope} resource ${display_resource} (${verb})" >&2; exit 2 ;;
            esac
          fi
        done < "${normalized_resources_file}"
      done
    done
    for resource in secrets configmaps serviceaccounts roles.rbac.authorization.k8s.io rolebindings.rbac.authorization.k8s.io; do
      for verb in get list watch create update patch delete deletecollection; do
        decision="$(auth_decision auth can-i "${verb}" "${resource}" --namespace {{ web_stack_ns }})" || exit 2
        [[ "${decision}" == "no" ]] || { echo "WEB_RELEASE_KUBECONFIG must not access ${resource} (${verb})" >&2; exit 2; }
      done
    done
    for resource in clusterroles.rbac.authorization.k8s.io clusterrolebindings.rbac.authorization.k8s.io; do
      for verb in get list watch create update patch delete deletecollection; do
        decision="$(auth_decision auth can-i "${verb}" "${resource}" --all-namespaces)" || exit 2
        [[ "${decision}" == "no" ]] || { echo "WEB_RELEASE_KUBECONFIG must not access ${resource} (${verb})" >&2; exit 2; }
      done
    done
    for named_contract in \
      "namespaces|greatfallstoolbus-org-production|cluster" \
      "deployments.apps|greatfallstoolbus-org|namespaced" \
      "services|greatfallstoolbus-org|namespaced" \
      "networkpolicies.networking.k8s.io|allow-cloudflared-tunnel-ingress|namespaced" \
      "networkpolicies.networking.k8s.io|allow-prometheus-scrape|namespaced" \
      "networkpolicies.networking.k8s.io|default-deny-egress|namespaced" \
      "networkpolicies.networking.k8s.io|default-deny-ingress|namespaced" \
      "networkpolicies.networking.k8s.io|allow-egress-dns|namespaced" \
      "networkpolicies.networking.k8s.io|allow-egress-discuss-archive|namespaced"; do
      IFS='|' read -r resource resource_name scope <<<"${named_contract}"
      if [[ "${scope}" == "namespaced" ]]; then auth_scope=(--namespace {{ web_stack_ns }}); else auth_scope=(--all-namespaces); fi
      for verb in update patch delete; do
        decision="$(auth_decision auth can-i "${verb}" "${resource}/${resource_name}" "${auth_scope[@]}")" || exit 2
        [[ "${decision}" == "no" ]] || { echo "WEB_RELEASE_KUBECONFIG must not mutate named release object ${resource}/${resource_name} (${verb})" >&2; exit 2; }
      done
    done
    for named_subresource_contract in \
      "namespaces|greatfallstoolbus-org-production|status|cluster|update patch" \
      "namespaces|greatfallstoolbus-org-production|finalize|cluster|update patch" \
      "deployments.apps|greatfallstoolbus-org|status|namespaced|update patch" \
      "deployments.apps|greatfallstoolbus-org|scale|namespaced|update patch" \
      "services|greatfallstoolbus-org|status|namespaced|update patch" \
      "services|greatfallstoolbus-org|proxy|namespaced|get create update patch delete"; do
      IFS='|' read -r resource resource_name subresource scope verbs <<<"${named_subresource_contract}"
      if [[ "${scope}" == "namespaced" ]]; then auth_scope=(--namespace {{ web_stack_ns }}); else auth_scope=(--all-namespaces); fi
      read -r -a verb_list <<<"${verbs}"
      for verb in "${verb_list[@]}"; do
        decision="$(auth_decision auth can-i "${verb}" "${resource}/${resource_name}" --subresource="${subresource}" "${auth_scope[@]}")" || exit 2
        [[ "${decision}" == "no" ]] || { echo "WEB_RELEASE_KUBECONFIG must not access named release subresource ${resource}/${resource_name}/${subresource} (${verb})" >&2; exit 2; }
      done
    done
    for resource_contract in \
      "deployments scale namespaced" \
      "deployments status namespaced" \
      "replicasets scale namespaced" \
      "replicasets status namespaced" \
      "pods exec namespaced" \
      "pods attach namespaced" \
      "pods portforward namespaced" \
      "pods ephemeralcontainers namespaced" \
      "pods eviction namespaced" \
      "pods binding namespaced" \
      "pods log namespaced" \
      "pods proxy namespaced" \
      "pods resize namespaced" \
      "pods status namespaced" \
      "services proxy namespaced" \
      "services status namespaced" \
      "namespaces finalize cluster" \
      "namespaces status cluster" \
      "nodes log cluster" \
      "nodes metrics cluster" \
      "nodes proxy cluster" \
      "nodes stats cluster" \
      "endpointslices.discovery.k8s.io status namespaced" \
      "networkpolicies.networking.k8s.io status namespaced" \
      "serviceaccounts token namespaced"; do
      read -r resource subresource scope <<<"${resource_contract}"
      if [[ "${scope}" == "namespaced" ]]; then auth_scope=(--namespace {{ web_stack_ns }}); else auth_scope=(--all-namespaces); fi
      for verb in get list watch create update patch delete deletecollection; do
        decision="$(auth_decision auth can-i "${verb}" "${resource}" --subresource="${subresource}" "${auth_scope[@]}")" || exit 2
        [[ "${decision}" == "no" ]] || { echo "WEB_RELEASE_KUBECONFIG must not access privileged subresource ${resource}/${subresource} (${verb})" >&2; exit 2; }
      done
    done
    for special_contract in \
      "bind roles.rbac.authorization.k8s.io namespaced" \
      "bind clusterroles.rbac.authorization.k8s.io cluster" \
      "escalate roles.rbac.authorization.k8s.io namespaced" \
      "escalate clusterroles.rbac.authorization.k8s.io cluster" \
      "impersonate users cluster" \
      "impersonate groups cluster" \
      "impersonate serviceaccounts cluster"; do
      read -r verb resource scope <<<"${special_contract}"
      if [[ "${scope}" == "namespaced" ]]; then auth_scope=(--namespace {{ web_stack_ns }}); else auth_scope=(--all-namespaces); fi
      decision="$(auth_decision auth can-i "${verb}" "${resource}" "${auth_scope[@]}")" || exit 2
      [[ "${decision}" == "no" ]] || { echo "WEB_RELEASE_KUBECONFIG must not ${verb} ${resource}" >&2; exit 2; }
    done
    for signer_verb in approve attest sign; do
      decision="$(raw_ssar_decision "${signer_verb}" certificates.k8s.io signers)" || exit 2
      [[ "${decision}" == "no" ]] || { echo "WEB_RELEASE_KUBECONFIG must not ${signer_verb} certificates.k8s.io signers" >&2; exit 2; }
    done
    for auth_scope_flag in "--namespace={{ web_stack_ns }}" "--all-namespaces"; do
      decision="$(auth_decision auth can-i '*' '*' "${auth_scope_flag}")" || exit 2
      [[ "${decision}" == "no" ]] || { echo "WEB_RELEASE_KUBECONFIG must not hold wildcard authority" >&2; exit 2; }
    done
    echo "reviewed stable web release-object mutation denial: Honey/{{ web_stack_ns }} authority=${rules_digest}"

# Read-only PINNED/RUNNING proof for the later static release. It accepts only a
# fully observed two-replica rollout whose Deployment, active ReplicaSet, and
# both pods all bind the selected source SHA and immutable image digest.
web-release-pinned-running-proof: _web-release-candidate-inputs
    #!/usr/bin/env -S BASH_ENV= ENV= SHELLOPTS= BASHOPTS= bash -p
    set +x
    set -euo pipefail
    : "${WEB_RELEASE_KUBECONFIG:?Set WEB_RELEASE_KUBECONFIG to the proof-only web release kubeconfig}"
    source_kubeconfig="${WEB_RELEASE_KUBECONFIG}"
    repo_root="$(git rev-parse --show-toplevel)"
    umask 077
    temp_root="$(python3 -I - "${TMPDIR:-/tmp}" "${repo_root}" <<'PY'
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
    proof_dir="$(mktemp -d "${temp_root}/gftb-web-running.XXXXXX")"
    trap 'rm -rf "${proof_dir}"' EXIT
    mkdir -m 700 "${proof_dir}/home"
    release_kubeconfig="${proof_dir}/kubeconfig"
    kubeconfig_digest="$(python3 -I - "${source_kubeconfig}" "${repo_root}" "${release_kubeconfig}" <<'PY'
    import hashlib
    import os
    import stat
    import sys
    from pathlib import Path

    raw = Path(sys.argv[1])
    repo = Path(sys.argv[2]).resolve(strict=True)
    destination = Path(sys.argv[3])
    destination_parent = destination.parent.stat()
    if not stat.S_ISDIR(destination_parent.st_mode) or destination_parent.st_uid != os.getuid() or stat.S_IMODE(destination_parent.st_mode) != 0o700:
        raise SystemExit("private kubeconfig staging directory failed custody validation")
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
      "get deployments.apps/greatfallstoolbus-org" \
      "list deployments.apps" "watch deployments.apps" "create deployments.apps" \
      "update deployments.apps/greatfallstoolbus-org" \
      "patch deployments.apps/greatfallstoolbus-org" \
      "get services/greatfallstoolbus-org" "create services" \
      "update services/greatfallstoolbus-org" \
      "patch services/greatfallstoolbus-org" \
      "get networkpolicies.networking.k8s.io/default-deny-ingress" \
      "get networkpolicies.networking.k8s.io/allow-cloudflared-tunnel-ingress" \
      "get networkpolicies.networking.k8s.io/allow-prometheus-scrape" \
      "get networkpolicies.networking.k8s.io/default-deny-egress" \
      "create networkpolicies.networking.k8s.io" \
      "update networkpolicies.networking.k8s.io/default-deny-ingress" \
      "update networkpolicies.networking.k8s.io/allow-cloudflared-tunnel-ingress" \
      "update networkpolicies.networking.k8s.io/allow-prometheus-scrape" \
      "update networkpolicies.networking.k8s.io/default-deny-egress" \
      "patch networkpolicies.networking.k8s.io/default-deny-ingress" \
      "patch networkpolicies.networking.k8s.io/allow-cloudflared-tunnel-ingress" \
      "patch networkpolicies.networking.k8s.io/allow-prometheus-scrape" \
      "patch networkpolicies.networking.k8s.io/default-deny-egress" \
      "delete networkpolicies.networking.k8s.io/allow-egress-dns" \
      "delete networkpolicies.networking.k8s.io/allow-egress-discuss-archive"; do
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
    bash scripts/remote-only-guard.sh _k8s-drift-check || exit 3
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
    @bash scripts/remote-only-guard.sh mail-cr-drift-check
    just _k8s-drift-check "${GFTB_MAIL_KUBECONFIG}" latoolb-us-production {{ mail_cr_dir }} mail-cr

list-stack-drift-check: _mail-kubeconfig-inputs
    @bash scripts/remote-only-guard.sh list-stack-drift-check
    just _k8s-drift-check "${GFTB_MAIL_KUBECONFIG}" latoolb-us-production {{ list_stack_dir }} list-stack

form-stack-drift-check: _mail-kubeconfig-inputs
    @bash scripts/remote-only-guard.sh form-stack-drift-check
    just _k8s-drift-check "${GFTB_MAIL_KUBECONFIG}" latoolb-us-production {{ form_stack_dir }} form-stack

archive-stack-drift-check: _mail-kubeconfig-inputs
    @bash scripts/remote-only-guard.sh archive-stack-drift-check
    just _k8s-drift-check "${GFTB_MAIL_KUBECONFIG}" latoolb-us-production {{ archive_stack_dir }} archive-stack

# TIN-3813 EDIT-2 (infra #122 review): "activation is an operator decision in
# git" is only true if drift enforces it, specifically so an out-of-band
# `kubectl patch cronjob mailman-listsync -p '{"spec":{"suspend":false}}'`
# (or a dry-run/secret/list-pair patch) shows up here instead of silently
# taking effect between scheduled runs.
listsync-stack-drift-check: _mail-kubeconfig-inputs
    @bash scripts/remote-only-guard.sh listsync-stack-drift-check
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
    bash scripts/remote-only-guard.sh web-stack-drift-check
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
