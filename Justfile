set dotenv-load := false
set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

# GF core checkout path default. The jesssullivan-infra template defaulted to
# "../GloriousFlywheel-infra-overlays" — a dead-name rename residue that forced
# every operator to export GF_CORE_PATH. This overlay defaults to the real
# checkout directory name. Override with GF_CORE_PATH / GF_CORE_CI_PATH when
# the core checkout lives elsewhere (CI checks core out as ../GloriousFlywheel).
gf_core := env_var_or_default("GF_CORE_PATH", "../GloriousFlywheel")
gf_core_ci := env_var_or_default("GF_CORE_CI_PATH", "../GloriousFlywheel#ci")
arc_tfvars := "tofu/stacks/arc-runners/great-falls-tool-bus.tfvars"
arc_backend := env_var_or_default("ARC_BACKEND", "tofu/backend/honey.s3.hcl")

default:
    @just --list

check:
    just taxonomy
    just arc-fmt-check
    just arc-validate
    just edge-fmt-check
    just edge-validate

enrollment-preflight:
    python3 "{{ gf_core }}/scripts/implementation-overlay-preflight.py" --overlay-root . --tfvars {{ arc_tfvars }} --repo Great-Falls-Tool-Bus/great-falls-tool-bus-infra

enrollment-preflight-strict:
    python3 "{{ gf_core }}/scripts/implementation-overlay-preflight.py" --overlay-root . --tfvars {{ arc_tfvars }} --repo Great-Falls-Tool-Bus/great-falls-tool-bus-infra --strict

_arc-app-secret-inputs:
    test -n "${GITHUB_APP_ID:-}" || { echo "Set GITHUB_APP_ID"; exit 1; }
    test -n "${GITHUB_APP_INSTALLATION_ID:-}" || { echo "Set GITHUB_APP_INSTALLATION_ID"; exit 1; }
    test -n "${GITHUB_APP_PRIVATE_KEY_PATH:-}" || { echo "Set GITHUB_APP_PRIVATE_KEY_PATH"; exit 1; }
    test -f "${GITHUB_APP_PRIVATE_KEY_PATH}"

arc-app-secret-dry-run: _arc-app-secret-inputs
    bash "{{ gf_core }}/scripts/implementation-overlay-arc-secret.sh" --overlay-root . --dry-run

arc-app-secret-apply: _arc-app-secret-inputs
    bash "{{ gf_core }}/scripts/implementation-overlay-arc-secret.sh" --overlay-root . --apply

# No --allow-repo-registration-anchor: this org overlay registers ARC at the
# ORG scope, so a repo-scoped github_config_url is a contract violation here
# and fails closed.
taxonomy:
    python3 scripts/validate-overlay-runner-taxonomy.py {{ arc_tfvars }}

# Self-test the overlay taxonomy guard (incl. the RBE cache/executor wiring rule).
taxonomy-selftest:
    bash scripts/test-overlay-runner-taxonomy.sh

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
    @echo "  just arc-enrollment-plan   # enrollment-preflight + arc-init + arc-plan"
    @echo "  just arc-plan-show         # review the plan (expect no unexpected destroys)"
    @echo "  just arc-apply             # destroy-checked, ALLOW_ARC_DESTROY-gated"
    @echo "This umbrella does NOT mutate the cluster."

arc-fmt-check:
    #!/usr/bin/env bash
    # Fresh-clone friendly: use tofu from PATH when present; the GF-core nix
    # devshell is the fallback for machines without tofu installed (it requires
    # a sibling GF checkout or GF_CORE_CI_PATH).
    set -euo pipefail
    if command -v tofu >/dev/null 2>&1; then
        tofu fmt -check {{ arc_tfvars }}
    else
        nix develop "{{ gf_core_ci }}" -c tofu fmt -check {{ arc_tfvars }}
    fi

arc-validate:
    #!/usr/bin/env bash
    set -euo pipefail
    test -d "{{ gf_core }}/tofu/stacks/arc-runners"
    tf_data_dir="$(mktemp -d -t great-falls-tool-bus-infra-tofu-data.XXXXXX)"
    trap 'rm -rf "${tf_data_dir}"' EXIT
    nix develop "{{ gf_core_ci }}" -c bash -lc 'cd "{{ gf_core }}/tofu/stacks/arc-runners" && TF_DATA_DIR="'"${tf_data_dir}"'" tofu init -backend=false >/tmp/great-falls-tool-bus-infra-arc-init.log && TF_DATA_DIR="'"${tf_data_dir}"'" tofu validate'

arc-init:
    #!/usr/bin/env bash
    set -euo pipefail
    backend="{{ arc_backend }}"
    test -f "${backend}"
    if [[ "${backend}" != /* ]]; then
        backend="$(pwd)/${backend}"
    fi
    nix develop "{{ gf_core_ci }}" -c tofu -chdir="{{ gf_core }}/tofu/stacks/arc-runners" init -reconfigure -backend-config="${backend}"

arc-plan:
    mkdir -p .tofu-plans
    nix develop "{{ gf_core_ci }}" -c tofu -chdir="{{ gf_core }}/tofu/stacks/arc-runners" plan -var-file="$(pwd)/{{ arc_tfvars }}" -out="$(pwd)/.tofu-plans/arc-runners.tfplan"

arc-plan-show:
    test -f .tofu-plans/arc-runners.tfplan
    nix develop "{{ gf_core_ci }}" -c tofu -chdir="{{ gf_core }}/tofu/stacks/arc-runners" show -no-color "$(pwd)/.tofu-plans/arc-runners.tfplan"

arc-plan-destroy-check:
    #!/usr/bin/env bash
    set -euo pipefail
    test -f .tofu-plans/arc-runners.tfplan
    plan_json="$(mktemp "${TMPDIR:-/tmp}/gftb-arc-plan.XXXXXX.json")"
    trap 'rm -f "${plan_json}"' EXIT
    nix develop "{{ gf_core_ci }}" -c tofu -chdir="{{ gf_core }}/tofu/stacks/arc-runners" show -json "$(pwd)/.tofu-plans/arc-runners.tfplan" > "${plan_json}"
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
        if [ "${ALLOW_ARC_DESTROY:-}" = "1" ]; then
            echo "WARNING: destructive ARC plan allowed because ALLOW_ARC_DESTROY=1"
        else
            echo "ERROR: destructive ARC plan detected. Review just arc-plan-show and record rehome/teardown before apply."
            exit 1
        fi
    fi
    echo "ARC plan destroy guard passed."

arc-apply: arc-plan-destroy-check
    test -f .tofu-plans/arc-runners.tfplan
    nix develop "{{ gf_core_ci }}" -c tofu -chdir="{{ gf_core }}/tofu/stacks/arc-runners" apply "$(pwd)/.tofu-plans/arc-runners.tfplan"

arc-enrollment-plan: enrollment-preflight arc-init arc-plan
    @echo "Review with just arc-plan-show before running just arc-apply."

# --- edge/DNS apply plane (tofu/stacks/edge-dns; TIN-2360 row c amended) ----
# Local stack (no GF-core chdir): the GFTB edge/DNS apply plane consuming the
# site repo's declare-only intent. Fail-closed: both manage_* toggles default
# false, so the default plan is empty (packet row g REVISED + REV-2).

edge_stack := "tofu/stacks/edge-dns"
edge_tfvars := "tofu/stacks/edge-dns/great-falls-tool-bus.tfvars"
edge_backend := env_var_or_default("EDGE_BACKEND", "tofu/backend/honey-edge-dns.s3.hcl")

edge-fmt-check:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v tofu >/dev/null 2>&1; then
        tofu fmt -check -recursive {{ edge_stack }}
    else
        nix develop "{{ gf_core_ci }}" -c tofu fmt -check -recursive {{ edge_stack }}
    fi

edge-validate:
    #!/usr/bin/env bash
    set -euo pipefail
    tf_data_dir="$(mktemp -d -t great-falls-tool-bus-infra-edge-tofu-data.XXXXXX)"
    trap 'rm -rf "${tf_data_dir}"' EXIT
    if command -v tofu >/dev/null 2>&1; then
        TF_DATA_DIR="${tf_data_dir}" tofu -chdir={{ edge_stack }} init -backend=false >/tmp/great-falls-tool-bus-infra-edge-init.log
        TF_DATA_DIR="${tf_data_dir}" tofu -chdir={{ edge_stack }} validate
    else
        nix develop "{{ gf_core_ci }}" -c bash -lc 'TF_DATA_DIR="'"${tf_data_dir}"'" tofu -chdir={{ edge_stack }} init -backend=false >/tmp/great-falls-tool-bus-infra-edge-init.log && TF_DATA_DIR="'"${tf_data_dir}"'" tofu -chdir={{ edge_stack }} validate'
    fi

edge-init:
    #!/usr/bin/env bash
    set -euo pipefail
    backend="{{ edge_backend }}"
    test -f "${backend}"
    if [[ "${backend}" != /* ]]; then
        backend="$(pwd)/${backend}"
    fi
    tofu -chdir={{ edge_stack }} init -reconfigure -backend-config="${backend}"

edge-plan:
    mkdir -p .tofu-plans
    tofu -chdir={{ edge_stack }} plan -var-file="$(pwd)/{{ edge_tfvars }}" -out="$(pwd)/.tofu-plans/edge-dns.tfplan"

edge-plan-show:
    test -f .tofu-plans/edge-dns.tfplan
    tofu -chdir={{ edge_stack }} show -no-color "$(pwd)/.tofu-plans/edge-dns.tfplan"

edge-plan-destroy-check:
    #!/usr/bin/env bash
    set -euo pipefail
    test -f .tofu-plans/edge-dns.tfplan
    plan_json="$(mktemp "${TMPDIR:-/tmp}/gftb-edge-plan.XXXXXX.json")"
    trap 'rm -f "${plan_json}"' EXIT
    tofu -chdir={{ edge_stack }} show -json "$(pwd)/.tofu-plans/edge-dns.tfplan" > "${plan_json}"
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
        if [ "${ALLOW_EDGE_DESTROY:-}" = "1" ]; then
            echo "WARNING: destructive edge-dns plan allowed because ALLOW_EDGE_DESTROY=1"
        else
            echo "ERROR: destructive edge-dns plan detected. Review just edge-plan-show and record the decision before apply."
            exit 1
        fi
    fi
    echo "edge-dns plan destroy guard passed."

edge-apply: edge-plan-destroy-check
    test -f .tofu-plans/edge-dns.tfplan
    tofu -chdir={{ edge_stack }} apply "$(pwd)/.tofu-plans/edge-dns.tfplan"
