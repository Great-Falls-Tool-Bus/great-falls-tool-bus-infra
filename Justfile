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
    just secrets-scan-dir
    just taxonomy
    just mail-cr-validate
    just list-stack-validate
    just form-stack-validate
    just web-stack-validate
    just arc-fmt-check
    just arc-validate
    just edge-fmt-check
    just edge-validate
    just edge-zones-fmt-check
    just edge-zones-validate
    just substrate-boundary-selftest
    just substrate-boundary

# Gitleaks scan of working tree files (AGENTS.md hard rule: no secrets in Git)
secrets-scan-dir:
    gitleaks dir --config .gitleaks.toml --redact --verbose .

# Gitleaks scan of git history
secrets-scan:
    gitleaks git --config .gitleaks.toml --redact --verbose .

# Generate changelog (git-cliff)
changelog:
    git-cliff --output CHANGELOG.md

# Preview changelog without writing
changelog-preview:
    git-cliff --unreleased

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

edge-zones-validate:
    #!/usr/bin/env bash
    set -euo pipefail
    tf_data_dir="$(mktemp -d -t great-falls-tool-bus-infra-edge-zones-tofu-data.XXXXXX)"
    trap 'rm -rf "${tf_data_dir}"' EXIT
    if command -v tofu >/dev/null 2>&1; then
        TF_DATA_DIR="${tf_data_dir}" tofu -chdir={{ edge_zones_stack }} init -backend=false >/tmp/great-falls-tool-bus-infra-edge-zones-init.log
        TF_DATA_DIR="${tf_data_dir}" tofu -chdir={{ edge_zones_stack }} validate
    else
        nix develop "{{ gf_core_ci }}" -c bash -lc 'TF_DATA_DIR="'"${tf_data_dir}"'" tofu -chdir={{ edge_zones_stack }} init -backend=false >/tmp/great-falls-tool-bus-infra-edge-zones-init.log && TF_DATA_DIR="'"${tf_data_dir}"'" tofu -chdir={{ edge_zones_stack }} validate'
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
    test -n "${GFTB_MAIL_KUBECONFIG:-}" || { echo "Set GFTB_MAIL_KUBECONFIG to the namespace-scoped kubeconfig path"; exit 1; }
    test -f "${GFTB_MAIL_KUBECONFIG}"

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

form-stack-server-dry-run: form-stack-validate _mail-kubeconfig-inputs
    kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace latoolb-us-production apply --dry-run=server -k {{ form_stack_dir }}

form-stack-apply: form-stack-server-dry-run
    kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace latoolb-us-production apply -k {{ form_stack_dir }}

# --- GFTB on-cluster web serving skeleton (TIN-2541) ------------------------
# DECLARE-ONLY. SvelteKit adapter-node -> ClusterIP 80->3000 -> honey-ingress
# cloudflared tunnel, mirroring the proven MassageIthaca full-on-cluster pattern.
# NOTHING IS APPLIED: the Deployment ships replicas:0 with a non-resolvable
# placeholder image, the namespace is not created, and the tunnel route is
# dashboard/token-managed (never in git; TIN-991). There is deliberately NO
# web-stack-apply recipe — applying this skeleton is not a supported operation;
# a cutover is operator-gated under a superseding hosting ADR. See k8s/web/README.md.

web_stack_dir := "k8s/web/greatfallstoolbus-org-production"

web-stack-validate:
    bash scripts/validate-web-stack.sh {{ web_stack_dir }}
