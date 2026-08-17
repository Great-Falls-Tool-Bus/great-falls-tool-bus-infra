set dotenv-load := false
set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

# GF core checkout path default. The older personal-account overlay defaulted to
# "../GloriousFlywheel-infra-overlays" — a dead-name rename residue that forced
# every operator to export GF_CORE_PATH. This overlay defaults to the real
# checkout directory name. Override GF_CORE_PATH when the core source checkout
# lives elsewhere. GF_CORE_CI_PATH is a pinned GitHub flake ref by default so
# tooling no longer assumes a sibling checkout for the #ci devshell.
gf_core := env_var_or_default("GF_CORE_PATH", "../GloriousFlywheel")
gf_core_ci := env_var_or_default("GF_CORE_CI_PATH", "github:tinyland-inc/GloriousFlywheel/2281b576bce0e8dd776a047b84e7464f5b508a62#ci")
gf_core_sha := "2281b576bce0e8dd776a047b84e7464f5b508a62"
arc_core_default := "../GloriousFlywheel-arc-df510"
arc_core_sha := "df510574d17b85e7f15470caf3574fcabc4768f1"
arc_core_ci_default := "github:tinyland-inc/GloriousFlywheel/df510574d17b85e7f15470caf3574fcabc4768f1#ci"
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
    just mail-cr-validate
    just list-stack-validate
    just form-stack-validate
    just archive-stack-validate
    just web-stack-validate
    just arc-fmt-check
    just edge-zones-fmt-check
    just edge-zones-validate
    just substrate-boundary-selftest
    just substrate-boundary

# Private GloriousFlywheel source-dependent ARC module validation remains an
# operator-local extension. Public hosted CI runs only `check-hosted`.
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

# Finite pinned-source declaration contract. Legacy workflows bind
# GloriousFlywheel to the exact reviewed commit for each role, but this public
# repository supplies no private-core deploy key, PAT, or App credential.
core-checkout:
    python3 -B scripts/validate-core-checkout.py

core-checkout-selftest:
    python3 -B scripts/validate-core-checkout.py --self-test

core-checkout-bazel:
    bazelisk test --lockfile_mode=off //:core_checkout_contract_tests

workflow-lint:
    actionlint -ignore 'label "tinyland-nix" is unknown' -ignore 'SC2155'

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
    @echo "  just arc-plan-scope-check  # exact 4/8Gi -> 8/16Gi plan only"
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
        if output["actions"] != ["no-op"]:
            raise SystemExit(
                "ERROR: ARC output Change must have exactly no-op actions for "
                + repr(output_name)
            )
        before_json = json.dumps(
            output["before"], sort_keys=True, separators=(",", ":"), ensure_ascii=False
        )
        after_json = json.dumps(
            output["after"], sort_keys=True, separators=(",", ":"), ensure_ascii=False
        )
        if before_json != after_json:
            raise SystemExit(
                "ERROR: ARC output Change modifies the value for " + repr(output_name)
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
        if output["before_sensitive"] != output["after_sensitive"]:
            raise SystemExit(
                "ERROR: ARC output Change changes sensitive-field shape for "
                + repr(output_name)
            )
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
    expected = [
        (
            "module.gh_nix.helm_release.arc_runner",
            "managed",
            "helm_release",
            "arc_runner",
            ["update"],
        )
    ]
    if observed != expected:
        print(
            "ERROR: ARC plan must contain exactly one in-place update to "
            "module.gh_nix.helm_release.arc_runner; observed " + repr(observed),
            file=sys.stderr,
        )
        print(
            "Land a separate reviewed ARC scope contract before applying any other plan.",
            file=sys.stderr,
        )
        sys.exit(1)

    change = changes[0]["change"]
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
    changed_known = []
    for key in sorted(set(before) | set(after)):
        if key == "values" or key in unknown_keys:
            continue
        if before.get(key) != after.get(key):
            changed_known.append(key)
    if changed_known:
        raise SystemExit(
            "ERROR: gh_nix Helm plan changes fields outside values: "
            + ", ".join(changed_known)
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

    def runner_storage(document):
        lines = document.splitlines()
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

    before_storage = runner_storage(before_values[0])
    after_storage = runner_storage(after_values[0])
    if before_storage != {"requests": "4Gi", "limits": "8Gi"} or after_storage != {"requests": "8Gi", "limits": "16Gi"}:
        raise SystemExit(
            "ERROR: expected runner resources.requests.ephemeral-storage 4Gi->8Gi "
            "and resources.limits.ephemeral-storage 8Gi->16Gi"
        )

    size_map = {"4Gi": "8Gi", "8Gi": "16Gi"}
    expected_values = storage.sub(
        lambda match: (
            match.group("prefix")
            + match.group("quote")
            + size_map[match.group("value")]
            + match.group("quote")
            + match.group("suffix")
        ),
        before_values[0],
    )
    if expected_values != after_values[0]:
        raise SystemExit("ERROR: gh_nix Helm values contain changes beyond 4/8Gi -> 8/16Gi")
    print("ARC plan scope guard passed: exact gh_nix 4/8Gi -> 8/16Gi update only.")
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

# Read-only closure receipt for the capacity promotion. It proves canonical
# remote state, refreshed plan, live ARC object, and listener all converge on
# the reviewed 8Gi request / 16Gi limit without reusing the apply session.
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
    [[ "${mode}" == "promoted" || "${mode}" == "reconcile" ]] || { echo "GFTB_ARC_READBACK_MODE must be promoted or reconcile" >&2; exit 2; }
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
    [[ ( "${state_request}" == "4Gi" && "${state_limit}" == "8Gi" ) || ( "${state_request}" == "8Gi" && "${state_limit}" == "16Gi" ) ]] || { echo "ARC capacity is outside the reviewed pre/post states" >&2; exit 2; }
    if [[ "${mode}" == "promoted" ]]; then
        [[ "${state_request}" == "8Gi" && "${state_limit}" == "16Gi" ]] || { echo "ARC capacity promotion is not converged at 8Gi/16Gi" >&2; exit 2; }
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
    if [[ "${state_request}" == "8Gi" && "${state_limit}" == "16Gi" ]]; then
        [[ "${plan_status}" == "0" ]] || { echo "Promoted ARC state/source/live refresh is not a no-change plan (status ${plan_status})" >&2; exit 2; }
        receipt="promoted state/live 8Gi/16Gi with refreshed no-change plan"
    else
        [[ "${mode}" == "reconcile" && "${plan_status}" == "2" ]] || { echo "Pre-change ARC reconciliation expected the exact pending promotion plan (status ${plan_status})" >&2; exit 2; }
        GFTB_ARC_READBACK_MODE=reconcile GFTB_ARC_RECONCILE_PLAN_PATH="${nochange_plan}" GFTB_ARC_RECONCILE_DATA_DIR="${data_dir}" just arc-plan-scope-check
        receipt="pre-change state/live 4Gi/8Gi with exact pending 8Gi/16Gi promotion; create and review a fresh plan"
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
    echo "ARC capacity receipt passed: ${receipt}; listener Ready."

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
    backend="{{ edge_zones_backend }}"
    test -f "${backend}"
    if [[ "${backend}" != /* ]]; then
        backend="$(pwd)/${backend}"
    fi
    tofu -chdir={{ edge_zones_stack }} init -reconfigure -backend-config="${backend}"

edge-zones-plan:
    mkdir -p .tofu-plans
    tofu -chdir={{ edge_zones_stack }} plan -out="$(pwd)/.tofu-plans/edge.tfplan"

_edge-zones-plan-json:
    test -f .tofu-plans/edge.tfplan
    tofu -chdir={{ edge_zones_stack }} show -json "$(pwd)/.tofu-plans/edge.tfplan" > .tofu-plans/edge.tfplan.json

_edge-zones-plan-text:
    @tofu -chdir={{ edge_zones_stack }} plan -no-color

edge-zones-plan-show:
    test -f .tofu-plans/edge.tfplan
    tofu -chdir={{ edge_zones_stack }} show -no-color "$(pwd)/.tofu-plans/edge.tfplan"

edge-zones-plan-destroy-check:
    #!/usr/bin/env bash
    set -euo pipefail
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
    test -f .tofu-plans/edge.tfplan
    tofu -chdir={{ edge_zones_stack }} apply "$(pwd)/.tofu-plans/edge.tfplan"

# --- GFTB tenant mail custom resources (TIN-2379) ---------------------------
# Tenant-owned MailDomain/MailAccount declarations live here and apply through
# the namespace grant declared in blahaj (latoolb-us-production only). The
# checked-in validation is offline. Live server dry-run/apply requires a
# namespace-scoped kubeconfig from the protected mail environment.

mail_cr_dir := "k8s/mail/latoolb-us-production"

mail-cr-validate:
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
    kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace latoolb-us-production apply --dry-run=server -k {{ mail_cr_dir }}

mail-cr-apply: mail-cr-server-dry-run
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
    bash scripts/validate-list-stack.sh {{ list_stack_dir }}

list-stack-server-dry-run: list-stack-validate _mail-kubeconfig-inputs
    kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace latoolb-us-production apply --dry-run=server -k {{ list_stack_dir }}

list-stack-apply: list-stack-server-dry-run
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
    kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace latoolb-us-production apply --dry-run=server -k {{ form_stack_dir }}

form-stack-apply: form-stack-server-dry-run
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
    bash scripts/validate-archive-stack.sh {{ archive_stack_dir }}

archive-stack-server-dry-run: archive-stack-validate _mail-kubeconfig-inputs
    kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace latoolb-us-production apply --dry-run=server -k {{ archive_stack_dir }}

archive-stack-apply: archive-stack-server-dry-run
    kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace latoolb-us-production apply -k {{ archive_stack_dir }}

# --- GFTB on-cluster web serving (TIN-2541 skeleton; TIN-2543 cutover) -------
# DECLARE-ONLY IN GIT. SvelteKit adapter-node -> ClusterIP 80->3000 ->
# honey-ingress cloudflared tunnel, mirroring the proven MassageIthaca
# full-on-cluster pattern. The checked-in overlay applies to NOTHING as-is: the
# Deployment ships replicas:0 with a non-resolvable placeholder image, the
# namespace is not created here, and the tunnel route is dashboard/token-managed
# (never in git; TIN-991). scripts/validate-web-stack.sh guards that posture.
#
# The cutover recipes below are the operator-gated APPLY plane (TIN-2543, ADR
# 0008), run ONLY through .github/workflows/web-stack.yml (workflow_dispatch +
# confirm=apply, protected web-apply environment). They do NOT un-park the tree:
# the real image is supplied at dispatch (WEB_APPLY_IMAGE) and replicas are
# flipped imperatively post-apply, so the k8s/web overlay stays replicas:0 +
# placeholder. The namespace-scoped web-apply SA cannot create namespaces; the
# operator mints the greatfallstoolbus-org-production namespace + SA/RBAC out of
# band first. See k8s/web/README.md and docs/runbooks/oncluster-web-cutover.md.

web_stack_dir := "k8s/web/greatfallstoolbus-org-production"
web_stack_ns := "greatfallstoolbus-org-production"

web-stack-validate:
    bash scripts/validate-web-stack.sh {{ web_stack_dir }}

# Operator-supplied cutover inputs (env-delivered by web-stack.yml; never baked):
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

# Operator-gated cutover apply: workload -> pin image -> flip replicas 0 -> N.
# The namespace must already exist (the SA is namespace-scoped and cannot create
# it); replicas are patched on the Deployment resource, not via the scale
# subresource, so the least-privilege patch-Deployment grant is sufficient.
web-stack-apply: web-stack-server-dry-run
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

# Env (delivered by web-stack.yml on the CD path; never baked):
#   CI_GREEN_SHA   the commit SHA to gate on (client_payload.sha)
#   CI_GREEN_REPO  owner/name of the site repo (default the GFTB site repo)
#   GH_TOKEN       read-only token; the site repo is PUBLIC so its CI run metadata
#                  is world-readable — a token with actions:read on it (or the
#                  ambient GITHUB_TOKEN) is sufficient. NOT a cluster credential.
#   CI_GREEN_TIMEOUT_SECONDS  how long to wait for CI to conclude (default 1200).
#
# CD "merge on green" gate: verify SITE ci.yml concluded success before cutover.
web-cd-ci-green-gate:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${CI_GREEN_SHA:?CI_GREEN_SHA is required (the site commit to gate on; client_payload.sha)}"
    site_repo="${CI_GREEN_REPO:-Great-Falls-Tool-Bus/greatfallstoolbus.org}"
    : "${GH_TOKEN:?GH_TOKEN is required (read-only token with actions:read on ${site_repo})}"
    # Fail fast with a clear message if the token cannot even read the site repo,
    # rather than looping until timeout on an auth error.
    if ! gh api "repos/${site_repo}" --jq '.full_name' >/dev/null 2>&1; then
      echo "::error::CI-green gate: GH_TOKEN cannot read ${site_repo}. Provision the purpose-bound SITE_CI_READ_TOKEN with actions:read on the public site repo, or rely on the ambient GITHUB_TOKEN. Fail-closed."
      exit 1
    fi
    echo "CI-green gate: waiting for ${site_repo} ci.yml @ ${CI_GREEN_SHA} to conclude..."
    deadline=$(( SECONDS + ${CI_GREEN_TIMEOUT_SECONDS:-1200} ))
    while :; do
      run_json="$(gh api "repos/${site_repo}/actions/workflows/ci.yml/runs?head_sha=${CI_GREEN_SHA}&event=push&per_page=1" 2>/dev/null || true)"
      status="$(printf '%s' "${run_json}" | jq -r '.workflow_runs[0].status // "missing"')"
      conclusion="$(printf '%s' "${run_json}" | jq -r '.workflow_runs[0].conclusion // ""')"
      if [[ "${status}" == "completed" ]]; then
        if [[ "${conclusion}" == "success" ]]; then
          echo "CI-green gate PASSED: ci.yml concluded success for ${CI_GREEN_SHA}."
          exit 0
        fi
        echo "::error::CI-green gate FAILED: ci.yml for ${CI_GREEN_SHA} concluded '${conclusion}' (not success). Refusing to deploy (merge-on-green)."
        exit 1
      fi
      if [[ "${status}" == "missing" ]]; then
        echo "  no ci.yml push run found yet for ${CI_GREEN_SHA}; waiting..."
      else
        echo "  ci.yml status=${status}; waiting..."
      fi
      if (( SECONDS >= deadline )); then
        echo "::error::CI-green gate TIMEOUT: ci.yml for ${CI_GREEN_SHA} did not conclude success within ${CI_GREEN_TIMEOUT_SECONDS:-1200}s (last status='${status}'). Fail-closed."
        exit 1
      fi
      sleep 20
    done

# --- K8s stack drift check (read-only; scheduled by .github/workflows/k8s-stack-drift.yml) ---
# `kubectl diff -k <dir>` against the LIVE cluster, namespace-scoped -- no
# mutation. Reuses the SAME kubeconfig secrets the existing server-dry-run/apply
# recipes above already require; no new credential is introduced. Exit code
# semantics of `kubectl diff`: 0 = no drift, 1 = drift found, >1 = a real error
# (bad kubeconfig, RBAC, API reachability).
#
# mail/list/form/archive are TRUE zero-diff stacks: nothing patches them
# imperatively after their `*-apply` recipe runs, so ANY diff is real drift and
# the check fails (fail_on_drift=true), mirroring edge-drift.yml's "assert
# zero-diff" gate.
#
# web is NOT held to the same bar, by design: k8s/web/greatfallstoolbus-org-production
# stays parked in git (replicas:0, placeholder image -- scripts/validate-web-stack.sh
# guards this), while the live on-cluster cutover state carries the
# operator-resolved image digest and replicas:2, patched in IMPERATIVELY by
# web-stack-apply's `set image` / `patch` steps above (not by `apply -k`;
# docs/runbooks/oncluster-web-cutover.md P3). A diff there is EXPECTED, not
# drift, so web-stack-drift-check reports it (fail_on_drift=false) and never
# fails the gate on it.
_k8s-drift-check kubeconfig namespace dir label fail_on_drift:
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
      if [ "{{ fail_on_drift }}" = "true" ]; then
        echo "::error::{{ label }} DRIFTED: live cluster state differs from the committed manifests. See {{ label }}-drift.txt (uploaded as a workflow artifact)."
        exit 1
      fi
      echo "::warning::{{ label }} shows a diff against the parked skeleton -- EXPECTED by design (see the _k8s-drift-check header comment); not treated as a drift-gate failure."
      exit 0
    else
      echo "::error::kubectl diff errored (rc=${rc}) probing {{ label }}."
      exit "${rc}"
    fi

mail-cr-drift-check: _mail-kubeconfig-inputs
    just _k8s-drift-check "${GFTB_MAIL_KUBECONFIG}" latoolb-us-production {{ mail_cr_dir }} mail-cr true

list-stack-drift-check: _mail-kubeconfig-inputs
    just _k8s-drift-check "${GFTB_MAIL_KUBECONFIG}" latoolb-us-production {{ list_stack_dir }} list-stack true

form-stack-drift-check: _mail-kubeconfig-inputs
    just _k8s-drift-check "${GFTB_MAIL_KUBECONFIG}" latoolb-us-production {{ form_stack_dir }} form-stack true

archive-stack-drift-check: _mail-kubeconfig-inputs
    just _k8s-drift-check "${GFTB_MAIL_KUBECONFIG}" latoolb-us-production {{ archive_stack_dir }} archive-stack true

# fail_on_drift=false: see the _k8s-drift-check header -- the parked web
# skeleton is expected to diverge from the live cutover state.
web-stack-drift-check: _web-apply-kubeconfig-only
    just _k8s-drift-check "${WEB_APPLY_KUBECONFIG}" {{ web_stack_ns }} {{ web_stack_dir }} web-stack false
