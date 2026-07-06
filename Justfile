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
arc_tfvars := "tofu/stacks/arc-runners/great-falls-tool-bus.tfvars"
arc_backend := env_var_or_default("ARC_BACKEND", "tofu/backend/honey.s3.hcl")

default:
    @just --list

check:
    just secrets-scan-dir
    just public-surface
    just public-pii
    just taxonomy
    just mail-cr-validate
    just list-stack-validate
    just form-stack-validate
    just web-stack-validate
    just arc-fmt-check
    just arc-validate
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

# Keep public docs/workflows pointed at audited Justfile recipes, not raw
# tofu/kubectl copy-paste snippets.
public-surface:
    python3 scripts/validate-public-operator-surface.py

# Keep public-ready surfaces free of personal PII while allowing role/list
# addresses and example domains.
public-pii:
    python3 scripts/validate-public-pii-surface.py

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
    # devshell is the fallback for machines without tofu installed. GF_CORE_CI_PATH
    # defaults to a pinned GitHub flake ref, not a sibling checkout.
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

_arc-plan-json:
    test -f .tofu-plans/arc-runners.tfplan
    nix develop "{{ gf_core_ci }}" -c tofu -chdir="{{ gf_core }}/tofu/stacks/arc-runners" show -json "$(pwd)/.tofu-plans/arc-runners.tfplan" > .tofu-plans/arc-runners.tfplan.json

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

# --- GFTB public discuss@ archive stack (TIN-2528) --------------------------
# SECOND Anubis PoW gate (anubis-archive) fronting the HyperKitty web tier so
# the PUBLIC discuss@ archive can ride the shared honey-ingress Cloudflare
# Tunnel (anti-scrape, NOT auth). Faithful mirror of the form-stack recipes
# above, pointed at k8s/archive. Deployed overlay-side into latoolb-us-production
# and dry-run/applied with the SAME namespace-scoped mail kubeconfig (same RBAC
# caveat as the form/list stacks). Checked-in validation is offline. DECLARE-ONLY:
# applying it exposes nothing until the privacy pre-flight passes, the Cloudflare
# tunnel public-hostname route is added (dashboard-side), and
# var.archives_dns_enabled flips true. See
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
#   WEB_APPLY_REPLICAS    replica count to flip to (default 2, the MI prod shape)
_web-apply-inputs:
    test -n "${WEB_APPLY_KUBECONFIG:-}" || { echo "Set WEB_APPLY_KUBECONFIG to the web-apply kubeconfig path"; exit 1; }
    test -f "${WEB_APPLY_KUBECONFIG}"
    test -n "${WEB_APPLY_IMAGE:-}" || { echo "Set WEB_APPLY_IMAGE to the operator-resolved image reference"; exit 1; }
    case "${WEB_APPLY_IMAGE}" in *PLACEHOLDER*) echo "refusing the declare-only PLACEHOLDER image; supply the real operator-resolved reference"; exit 1 ;; esac

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
