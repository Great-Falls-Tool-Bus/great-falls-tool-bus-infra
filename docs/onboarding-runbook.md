# GFTB onboarding runbook (TIN-2299 L6)

# GFTB Overlay Onboarding Runbook (org #3)

Prereqs: operator machine with kubectl context `honey` working (neo qualifies), side-by-side checkout `~/git/GloriousFlywheel` at `2281b576bce0e8dd776a047b84e7464f5b508a62` or newer, `gh` authed as a Great-Falls-Tool-Bus org owner, RustFS `tofu-state` credentials in the operator secret store.

## 1. Create the org GitHub App (browser)
Open https://github.com/organizations/Great-Falls-Tool-Bus/settings/apps/new
- Name: `gf-arc-great-falls-tool-bus` (per gf-arc-<owner-slug> convention)
- Homepage URL: `https://github.com/Great-Falls-Tool-Bus/great-falls-tool-bus-infra`
- Webhook: UNCHECK Active
- Permissions (ARC github_config requirements): Organization -> Self-hosted runners: **Read and write**; Repository -> Actions: **Read-only**; Repository -> Metadata: **Read-only**
- Where can this App be installed: **Only on this account**
- Create; record the **App ID** from the app page.

## 2. Generate and download the private key (browser)
On the app page: Private keys -> Generate a private key. Move it out of Downloads:
```bash
mkdir -p ~/secrets && mv ~/Downloads/gf-arc-great-falls-tool-bus.*.private-key.pem ~/secrets/gf-arc-great-falls-tool-bus.pem && chmod 600 ~/secrets/gf-arc-great-falls-tool-bus.pem
```
Never commit; record rotation path in the operator password manager.

## 3. Install the App on the org (browser)
App page -> Install App -> Great-Falls-Tool-Bus -> **All repositories** -> Install. Capture the installation ID from the resulting URL (`.../settings/installations/<INSTALLATION_ID>`), or via API:
```bash
gh api /orgs/Great-Falls-Tool-Bus/installations --jq '.installations[] | select(.app_slug=="gf-arc-great-falls-tool-bus") | .id'
```

## 4. Create and populate the overlay repo
```bash
gh repo create Great-Falls-Tool-Bus/great-falls-tool-bus-infra --private --description "GFTB implementation overlay for GloriousFlywheel"
cd ~/git && git clone git@github.com:Great-Falls-Tool-Bus/great-falls-tool-bus-infra.git && cd great-falls-tool-bus-infra
# materialize the files[] from this package, then:
chmod +x scripts/*.sh
git add -A && git commit -m "feat: GFTB implementation overlay (org-scoped ARC, conservative nix-only posture)" && git push -u origin main
```
Note: the CI runs queued by this push stay pending until step 8 registers the scale set (expected).

## 5. Local validation (no cluster needed)
```bash
cd ~/git/great-falls-tool-bus-infra
export GF_CORE_PATH=../GloriousFlywheel   # already the default
just check                                # taxonomy + tofu fmt + tofu validate
just taxonomy-selftest
```

## 6. Write the App secret into the cluster
```bash
export GF_CORE_PATH=../GloriousFlywheel
export GITHUB_APP_ID=<APP_ID>
export GITHUB_APP_INSTALLATION_ID=<INSTALLATION_ID>
export GITHUB_APP_PRIVATE_KEY_PATH=~/secrets/gf-arc-great-falls-tool-bus.pem
just arc-app-secret-dry-run    # renders client-side YAML only
just arc-app-secret-apply      # writes github-app-secret-great-falls-tool-bus into arc-systems + arc-runners
just enrollment-preflight      # read-only; expect App-secret check green, scale set absent (not yet applied)
```

## 7. First plan (OPERATOR MACHINE, bootstrap circularity: overlay CI cannot run yet)
```bash
export AWS_ACCESS_KEY_ID=<rustfs-tofu-state-access-key>       # from operator secret store
# set the S3 credential pair for the RustFS tofu-state backend from operator
# custody (KeePassXC tinyland/infrastructure); never write values into files:
#   export AWS_ACCESS_KEY_ID + the matching SECRET key env var expected by tofu
just arc-init      # backend tofu/backend/honey.s3.hcl -> key great-falls-tool-bus-infra/arc-runners/terraform.tfstate
just arc-plan      # var-file tofu/stacks/arc-runners/great-falls-tool-bus.tfvars
just arc-plan-show
```

## 8. Operator APPLY gate
Review the plan: expect **creates only** (one AutoscalingRunnerSet `great-falls-tool-bus-nix` + listener resources), ZERO deletes. The fresh state key makes cross-overlay destroys impossible; any delete means the wrong backend key. Then:
```bash
just arc-apply     # runs arc-plan-destroy-check first; ALLOW_ARC_DESTROY=1 never needed here
```

## 9. Verify the listener
```bash
kubectl -n arc-runners get autoscalingrunnersets | grep great-falls
kubectl -n arc-runners get pods -l 'actions.github.com/scale-set-name=great-falls-tool-bus-nix'
kubectl -n arc-runners get autoscalingrunnerset great-falls-tool-bus-nix -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}'   # must print Helm
just enrollment-preflight   # now fully green
```

## 10. Arm overlay CI (steady-state plan-only lane)
```bash
gh secret set GF_CORE_DEPLOY_KEY        -R Great-Falls-Tool-Bus/great-falls-tool-bus-infra < ~/secrets/gf-core-deploy-key   # read-only deploy key on tinyland-inc/GloriousFlywheel (mint via GF core admin if absent)
kubectl config view --minify --flatten --context honey | base64 | gh secret set ARC_RUNNERS_KUBECONFIG_B64 -R Great-Falls-Tool-Bus/great-falls-tool-bus-infra
gh secret set ARC_RUNNERS_RUSTFS_ACCESS_KEY -R Great-Falls-Tool-Bus/great-falls-tool-bus-infra --body "<rustfs-access-key>"
gh secret set ARC_RUNNERS_RUSTFS_SECRET_KEY -R Great-Falls-Tool-Bus/great-falls-tool-bus-infra --body "<rustfs-secret-key>"
gh workflow run validate.yml -R Great-Falls-Tool-Bus/great-falls-tool-bus-infra && gh run watch -R Great-Falls-Tool-Bus/great-falls-tool-bus-infra
```
Green validate run on `tinyland-nix` = end-to-end proof: App installation + org registration + scale set + label pickup.

## 11. First repo proof
Execute first_repo_plan (**corrected 2026-07-02 per prompts-enqueue prompt 50 (greatfallstoolbus-mvp)**): repo #1 is the greatfallstoolbus.org MVP site, its creation is gated on the prompt-50 DAG step-1 operator decision packet, and site.scaffold spawning is skill-driven + USER-ONLY house doctrine (`tinyland-spawn-sister-site`). The coding agent prepares the ci.yml/enrollment wiring and drives the proof AFTER the operator spawn; timing measured vs goo's 114 s.

## Step ledger (the TIN-2299 measurement)

- [operator-browser] Create org GitHub App gf-arc-great-falls-tool-bus (permissions: org self-hosted runners RW, Actions R, Metadata R; webhook off) _(automatable via: L5, GitHub App Manifest flow (POST app manifest, org redeem URL) collapses the form to one confirmation click; no full API creation exists)_
- [operator-browser] Generate + download the App private key (.pem), stash in ~/secrets, chmod 600 _(automatable via: L5, the manifest-conversion API response includes the PEM, eliminating this as a separate step once step 1 uses the manifest flow)_
- [operator-browser] Install the App on the org, All repositories _(automatable via: L7, GitHub exposes no public API for installation consent; irreducibly one human click)_
- [operator-terminal] Capture App ID + Installation ID _(automatable via: L3, gh api /orgs/Great-Falls-Tool-Bus/installations (already a one-liner; scriptable into the enroll flow))_
- [operator-terminal] gh repo create Great-Falls-Tool-Bus/great-falls-tool-bus-infra --private _(automatable via: L3, gh CLI; delegable to an agent with permission)_
- [agent] Materialize overlay files from this package, chmod scripts, commit, push _(automatable via: already-automated, this deliverable is the apply-ready file set)_
- [agent] just check + just taxonomy-selftest (local static validation) _(automatable via: already-automated, repo Just verbs)_
- [operator-terminal] Export GITHUB_APP_* env from PEM custody + just arc-app-secret-dry-run / arc-app-secret-apply _(automatable via: already-automated verbs; PEM custody keeps the operator in the loop, L5 with a cluster-side secret broker (external-secrets / mint authority))_
- [agent] just enrollment-preflight (read-only gate, pre-apply) _(automatable via: already-automated, GF-core implementation-overlay-preflight.py)_
- [operator-terminal] Export RustFS tofu-state credentials on the operator machine _(automatable via: L5, blocked on the per-overlay RustFS key mint authority (TIN-2112); today it is manual copy from the operator store)_
- [operator-terminal] just arc-init + just arc-plan + just arc-plan-show (FIRST plan, operator machine, bootstrap circularity) _(automatable via: already-automated verbs locally; L5 to move first-plan into CI (requires secrets to pre-exist AND a runner reachable pre-scale-set, a hosted-plan lane or a fleet bootstrap runner))_
- [operator-browser] Review plan (creates-only, zero deletes) and consent _(automatable via: L7, apply consent is deliberately human; the destroy-guard already automates the safety check)_
- [operator-terminal] just arc-apply (FIRST apply, operator machine) _(automatable via: L7, operator-gated by design; steady-state re-applies can use workflow_dispatch action=apply (already-automated lane))_
- [agent] Verify listener: kubectl -n arc-runners get autoscalingrunnersets | grep great-falls + managed-by=Helm _(automatable via: already-automated, enrollment-preflight + flywheel-enroll-verify CHECK 3 cover this)_
- [operator-terminal] Mint/read GF core read-only deploy key for GF_CORE_DEPLOY_KEY _(automatable via: L5, needs GF-core admin key-mint tooling; gh repo deploy-key add is L3 once the keypair exists)_
- [operator-terminal] Set overlay CI secrets (GF_CORE_DEPLOY_KEY, ARC_RUNNERS_KUBECONFIG_B64, ARC_RUNNERS_RUSTFS_*) _(automatable via: L3, gh secret set one-liners; secret-material custody keeps the operator in the loop (L5 with a broker))_
- [agent] Dispatch validate.yml and watch for green on tinyland-nix (label-pickup proof) _(automatable via: already-automated, gh workflow run + gh run watch)_
- [operator-terminal] Spawn repo #1 via the user-only `tinyland-spawn-sister-site` skill (gated on the prompt-50 step-1 decision packet; greatfallstoolbus.org MVP per prompts-enqueue prompt 50) _(automatable via: L7 provisioning seed, spawn stays user-only by doctrine)_
- [agent] Wire the spawned repo: goo two-tier ci.yml + mint script + registry PR + proof runs _(automatable via: already-automated, this package's first_repo_plan)_
- [agent] GF consumer-registry PR (entry + enrolled_via enum extension if required) _(automatable via: already-automated, PR flow; merge gate is Codex/operator review)_
- [operator-terminal] Set consumer repo vars: FLYWHEEL_ENABLED=true (+ optional GF_REAPI_TOKEN_EXCHANGE_URL) _(automatable via: L3, gh variable set; delegable to an agent with permission)_
- [agent] First-repo proof: two dispatches, assert remote cache hits on run 2, measure dispatch->green vs goo 114s _(automatable via: already-automated, gh run watch + timestamps + flywheel-check output)_

## First-repo plan

# GFTB repo #1 (shared-cache-backed), NAME/SHAPE per prompt 50: the greatfallstoolbus.org MVP
# (github.io Pages fallback acceptable if the MVP decision packet chooses Pages hosting)

**Repo**: `gh repo create Great-Falls-Tool-Bus/great-falls-tool-bus.github.io --public` (org Pages site must be public on the free plan), seeded from `~/git/site.scaffold` (SvelteKit static site + Nix devshell + Justfile + Bazel toolchain-only module graph, the tinyland-goo lineage).

**Runner story (the org inversion)**: `runs-on: tinyland-nix` resolves via the GFTB App's org-wide installation + the `great-falls-tool-bus-nix` scale set. The arc-runner module publishes the shared `tinyland-nix` label alongside the owner-distinct registration name. NO jesssullivan-infra anchor, NO extra_runner_sets entry, NO tfvars change: org-scoped registration already reaches this repo. This is the structural payoff vs orgs #1/#2.

**ci.yml**: copy tinyland-goo's two-tier shape verbatim, adjusted for GFTB:
1. `check-build` + `bazel-graph` baseline lanes on `ubuntu-latest` (hosted; always green independent of the flywheel).
2. `flywheel-cache` lane: `runs-on: tinyland-nix`, `if: vars.FLYWHEEL_ENABLED == 'true'` (skip-green until armed), job env `GF_BAZEL_SUBSTRATE_MODE: shared-cache-backed`, `GF_BAZEL_REMOTE_UPLOAD: 'false'` (read-only per TIN-1147), `GF_FLYWHEEL_PROFILE_STATE: shared-cache-backed`; steps: flywheel-doctor then flywheel-check. The runner-injected `BAZEL_REMOTE_CACHE` comes from the tfvars' `bazel_cache_endpoint`.
3. `flywheel-executor` lane: included but double-gated (`vars.FLYWHEEL_EXECUTOR_ENABLED == 'true'` AND same-repo), `id-token: write`, require-executor assert step, mint via `scripts/mint-gf-reapi-token-from-exchange.sh` with `GF_REAPI_TOKEN_EXCHANGE_URL: ${{ vars.GF_REAPI_TOKEN_EXCHANGE_URL }}` falling through to the live public front door `https://gf-token-exchange.tinyland.dev/v1/token/exchange`. NOTE: this lane CANNOT pass until the deliberate executor flip (add `bazel_executor_endpoint` to the GFTB tfvars + plan/apply). It fails closed on the missing `BAZEL_REMOTE_EXECUTOR` until then, which is the honest state. Copy goo's `scripts/mint-gf-reapi-token-from-exchange.sh` + `scripts/cache-attachment-contract.sh` with the seed.

**GF consumer-registry PR** (tinyland-inc/GloriousFlywheel): add entry `{github_repository: "Great-Falls-Tool-Bus/great-falls-tool-bus.github.io", runner_class: "tinyland-nix", tfvars_anchor: "great-falls-tool-bus-nix", substrate_mode: "shared-cache-backed", workflow: ".github/workflows/ci.yml", enrolled: false, bazel_cache_endpoint: "grpc://bazel-cache.nix-cache.svc.cluster.local:9092", ...}`. CAVEAT (verified against the validator at the pin): `ENROLLED_VIA = {"overlay-extra_runner_sets"}` is a closed enum and the anchor points at a PRIMARY lane, not an extra_runner_sets block. The same PR must extend the enum (e.g. `overlay-primary-scale-set`) + self-test fixture, or Codex rules otherwise (registry/eligibility is Codex-owned surface; coordinate, don't unilaterally reshape).

**Arm + prove**:
```bash
gh variable set FLYWHEEL_ENABLED --body true -R Great-Falls-Tool-Bus/great-falls-tool-bus.github.io
gh workflow run ci.yml -R Great-Falls-Tool-Bus/great-falls-tool-bus.github.io && gh run watch   # run 1: populates cache
gh workflow run ci.yml -R Great-Falls-Tool-Bus/great-falls-tool-bus.github.io && gh run watch   # run 2: the proof run
```
Proof criteria: (a) run 2's flywheel-check output shows remote cache HITs > 0 (not merely green: GREEN != cache-hit is the known systemic trap; read the Bazel remote-cache stats line, not the job status); (b) measure `createdAt -> conclusion` for run 2 via `gh run view <id> --json createdAt,updatedAt` and compare against tinyland-goo's 114 s dispatch->green benchmark; (c) `just flywheel-enroll-verify` from the overlay passes CHECKs 0-3 (CHECK 3 live Helm gate is what earns the registry `enrolled: true` flip in a follow-up GF PR).
