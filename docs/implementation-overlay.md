# Great-Falls-Tool-Bus Implementation Overlay

This repository is the Great-Falls-Tool-Bus (GFTB) owner overlay for the shared
Honey substrate. It is the organization counterpart to the older
personal-account overlay and the third owner overlay overall.

## What This Repo Owns

- GFTB GitHub App installation binding
- Honey ARC tfvars for org-scoped repo enrollment
- S3 backend state coordinates for this overlay
- reviewed non-secret operator metadata and cache namespace choices

## What GloriousFlywheel Owns

- reusable OpenTofu modules and ARC stack code
- runner images and shared capability labels
- cache-backed local and CI contract
- public and operator documentation

## Organization Boundary

GFTB is a GitHub organization, so ARC registers at the ORG scope:
`github_config_url = https://github.com/Great-Falls-Tool-Bus`. The GFTB GitHub
App is installed org-wide (all repositories). GitHub runner-group admission is
a separate selected-repository boundary, so registration alone does not make
the `great-falls-tool-bus-nix` scale set reachable from every GFTB repo. There
is no repo-scoped registration anchor and no per-repo `extra_runner_sets` entry.
The personal-account anchor pattern exists only because personal accounts lack
org-level registration.

Workflows use shared labels such as `tinyland-nix`. Reachability requires this
overlay's GitHub App installation, ARC registration, and the selected GitHub
runner-group admission; it is not solved by minting `gftb-*` or repo-shaped
labels. Only `tinyland-nix` is provisioned today.

TIN-3902 makes the runner-group half of that boundary an explicit declaration
instead of an inherited default. The reviewed group is:

- name `great-falls-tool-bus-infra`
- `visibility: selected`
- `allows_public_repositories: false`
- `restricted_to_workflows: false`
- selected repositories: `Great-Falls-Tool-Bus/gftb-site` (id `1336591141`)
  and `Great-Falls-Tool-Bus/greatfallstoolbus.org` (id `1287399122`)

declared in `config/organization.yaml` `runner_contract.runner_group` and bound
to the scale sets by `runner_group = "great-falls-tool-bus-infra"` plus
`runner_group_policy = "organization-restricted"` in
`tofu/stacks/arc-runners/great-falls-tool-bus.tfvars`.

Three consequences are load-bearing and must not be discovered later:

1. **This repository is excluded.** `great-falls-tool-bus-infra` is public
   (repository id `1286829099`) and is deliberately not on the roster. Its own
   self-hosted `runs-on: tinyland-nix` jobs — `archive-stack.yml`,
   `edge-drift.yml`, `edge-plan.yml`, `flywheel-cache-proof.yml`,
   `form-crs.yml`, `k8s-stack-drift.yml`, `list-crs.yml`, `mail-crs.yml`,
   `web-crs.yml`, `web-stack.yml` — will not be admitted after the cutover.
   None of the ten can run on a fork pull request: eight carry a job-level
   `if: github.event_name == 'push' || github.event_name == 'workflow_dispatch'`
   (`web-stack.yml` uses `workflow_dispatch` / `repository_dispatch`), and the
   two drift lanes (`edge-drift.yml`, `k8s-stack-drift.yml`) declare only
   `schedule` + `workflow_dispatch` triggers. The hosted `validate.yml` job
   already runs on `ubuntu-24.04`, so no PR gate depends on this. What the
   cutover does cost is the scheduled drift lanes and the push/dispatch
   validate+apply lanes in this repository; they must be re-homed or accepted
   as manual before or shortly after cutover. Re-admitting the public repo is
   an explicit operator decision that reverses the TIN-3209 posture, not a
   routine roster edit.
2. **`greatfallstoolbus.org` is selected but not yet effective.** That
   repository is still public, and `allows_public_repositories: false` gates
   public repositories out of the group regardless of the roster. Its CI stays
   unadmitted until TIN-3815 moves that CI into the private successor spoke
   (add the successor repository id to the roster once it exists), or until an
   explicit operator decision changes the public-repository posture. Confirm at
   group-creation time whether GitHub accepts a public repository in the
   selected set at all; if it refuses, add the id after TIN-3815 lands.
3. **`gftb-site` is the repository this fix actually unblocks today.** It is
   private, so nothing else gates it.

The group is an owner/tenancy identity, not a runner capability. The
`forbidden` list in `config/organization.yaml` still holds: no workflow may
request `great-falls-tool-bus-infra` as a label, and no `gftb-*` or
`great-falls-*` label may be minted.

## Shared Controller Boundary

The Tinyland overlay owns the shared ARC controller and namespaces for Honey.
This overlay attaches the GFTB runner scale set to that controller with
`deploy_arc_controller = false`, `create_controller_namespace = false`, and
`create_runner_namespace = false`.

Internal Helm release names and ARC `runnerScaleSetName` values use the
`great-falls-tool-bus-*` prefix to avoid cluster collisions. Those names are
not workflow labels; workflows continue to use shared `tinyland-*` capability
labels (the arc-runner module publishes `runner_label` explicitly alongside the
owner-distinct registration name).

## Conservative Capacity Posture

Honey/sting pod budget is the scarce resource (TIN-2165/TIN-2234):

- nix lane only (`deploy_docker_runner = false`, `deploy_dind_runner = false`)
- `nix_min_runners = 0`, `nix_max_runners = 4`
- `nix_warm_pool_enabled = false`
- each nix runner requests 8 GiB and is limited to 16 GiB of ephemeral storage;
  `/nix`, `_work`, and `.cache` remain on the container root filesystem while
  the optional volumes are disabled
- runner pods pinned to `sting` with the
  `dedicated.tinyland.dev/compute-expansion` toleration (the tinyland-goo-nix
  anchor shape)

Raising any of these is an explicit operator decision followed by
`just arc-plan` / `just arc-apply`.

The 8/16 GiB envelope is the bounded response to the 2026-08-17 site-CI evidence:
four independent build/test pods crossed the former 8 GiB limit and were
evicted, while the lightweight carrier validation completed. The source carrier
records max-runner node/quota fit first. After its attended apply and exact
state/live readback, a natural-fanout run and immediate warm rerun are recorded
on TIN-2299 and a reviewed follow-up before the envelope is accepted. Every
self-hosted check must receive a real runner, the runner container's combined writable-rootfs plus log peak
(`rootfs.usedBytes + logs.usedBytes`) must stay below 75% of its limit, and no
pod eviction, restart, or node `DiskPressure` may occur. A warm cache rerun must
also pass. Failure drains the scale set and requires a separate signed,
reviewed rollback carrier whose scope guard permits only the exact 8/16 GiB to
4/8 GiB reversal; the current promotion-only guard cannot perform that rollback.
It is not permission to raise the limit again without new evidence. Per-runner bounded volumes for `/nix`,
`_work`, and `.cache` remain the durable follow-up once the primary core stack
exposes storage-class inputs compatible with `sting`.

## Shared Substrate

- cluster: `honey`
- Attic: `http://attic.nix-cache.svc.cluster.local` (cache `main`)
- Attic public key: `main:eaUydxuDu7xBoy5cCo3MdknYAkVyTIASQ7DGuwxa+XA=`
- Bazel cache: `grpc://bazel-cache.nix-cache.svc.cluster.local:9092`
- Bazel executor: `grpc://gf-reapi-cell.gf-rbe.svc.cluster.local:8980`
  (substrate fact; the primary lane is cache-only until the deliberate
  executor flip, see the tfvars comment)
- state bucket: `tofu-state`, key prefix `great-falls-tool-bus-infra`
- public token mint: `https://gf-token-exchange.tinyland.dev/v1/token/exchange`

## ARC Apply Authority

Secret-free `validate.yml` runs on a GitHub-hosted runner. ARC state planning
and mutation do not run in GitHub Actions. They run attended on the operator
machine through the guarded Just surface, with exact reviewed source, runtime
RustFS credentials, and an external kubeconfig bound to the reviewed Honey
cluster and runner-set UIDs. Keep that kubeconfig's RBAC as narrow as the ARC
plan/readback operations permit; the current guard does not certify RBAC. Do not add a
repository ARC kubeconfig or cross-repository source credential to recreate a
CI deploy lane.

## Enrollment Preflight

Run this before `arc-plan` or `arc-apply`:

```bash
export GF_CORE_PATH=../GloriousFlywheel
export GFTB_ARC_KUBECONFIG=/operator/path/gftb-arc.kubeconfig
just enrollment-preflight
```

The preflight is read-only. Missing `github-app-secret-great-falls-tool-bus`,
an absent live `great-falls-tool-bus-nix` scale set, queued self-hosted ARC
runs, or core-pin drift are enrollment blockers, not reasons to create org- or
repo-specific labels. At the pinned pre-#1208 core revision, the shared preflight
still prints a legacy core-read-credential row. Do not provision a key solely
for that row; `just core-checkout` is the source-authority gate.

## ARC Runner Plan And Apply

The operator-local path is the only ARC deploy surface. Before beginning,
fetch canonical `main`, use a clean `main` worktree at the exact signed current
remote head, and prepare a clean, signed GloriousFlywheel checkout at
`11ace397282ff89aeb1dfeb4a32fcbed3200c2ff`. Set
`GF_ARC_CORE_PATH` to that checkout and keep `GF_ARC_CORE_CI_PATH` on the same
exact pin.

Set `GFTB_ARC_KUBECONFIG` to an operator-owned regular file outside the repo,
mode 0600. It must contain exactly the `honey` context, use no credential exec
plugin, and reach the existing
`honey/arc-runners/great-falls-tool-bus-nix` AutoscalingRunnerSet. The plan
receipt binds the target's exact live UID, so a different cluster, namespace,
or replacement release refuses apply. Ambient `KUBECONFIG` and
`TF_VAR_k8s_config_path` are rejected.

The reviewed backend identity is bucket `tofu-state`, key
`great-falls-tool-bus-infra/arc-runners/terraform.tfstate`. `ARC_BACKEND` may
instead name an operator-owned mode-0600 file outside the repo for a temporary
port-forward, but that file must be byte-equivalent to the reviewed backend
except for an `http://127.0.0.1:<port>` S3 endpoint. State credentials remain
runtime operator inputs. The workspace must be `default`; ambient workspace,
backend, CLI, profile, logging, and credential indirection overrides are
rejected.

Run the finite sequence through Just:

```bash
GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive just arc-plan
just arc-plan-show
just arc-plan-scope-check
GFTB_APPLY_CONFIRM=apply GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive just arc-apply
GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive just arc-capacity-readback
```

`arc-plan` refuses non-main, dirty, stale, forked, or unsigned infra source and
records both the infra and core SHAs beside the mode-0600 binary plan.
`arc-apply` repeats both source guards, requires the target-specific attended
confirmation, checks the saved SHA markers, and deletes the plan and markers
only after a successful apply. Pending plans are sensitive local artifacts;
the binary plan and all source/backend/kubeconfig/target receipts are mode 0600.
Never upload, commit, or copy them into a shared location.

Apply remains guarded by OpenTofu JSON plan actions. For the 8/16 GiB runner
envelope, the only acceptable plan is one in-place
`module.gh_nix.helm_release.arc_runner` update with zero creates, deletes,
replacements, or unrelated drift. A broader or destructive plan is a stop
condition requiring a separate reviewed decision; this operator surface has no
delete bypass.

The TIN-3902 runner-group carrier is exactly such a broader plan: it also
creates the state-only `terraform_data.runner_group_policy` and changes
Helm values beyond `ephemeral-storage`. `just arc-plan-scope-check` refuses it
until a separate reviewed change advances the allowlist. See
"Runner group cutover" below for the enumerated expected shape.

### Exclusive state window

The RustFS S3 backend has **no remote state lock**. Before planning, establish
an exclusive quiet window covering plan, human review, apply, and live/state
readback. Confirm that no other operator and no workflow is planning or
mutating this ARC stack, and keep that true for the whole window. Supply
`GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive` only as a one-shot value on each plan,
apply, and readback command after making that check; the value records an
operator fact and is not itself a lock.

When using the localhost backend override, loss of the port-forward is an
ambiguous failure if cluster mutation may have started but the state write did
not complete. Stop immediately. Read back the live
`great-falls-tool-bus-nix` release and the canonical remote state before any
new plan or retry. Do not assume a failed command means the cluster was
unchanged, and do not blindly reapply the saved plan. The apply-attempt marker
makes that saved plan non-retryable. After restoring backend connectivity, run
`GFTB_ARC_READBACK_MODE=reconcile GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive just
arc-capacity-readback`. That mode accepts only matching state/live 4/8 GiB plus
the exact pending promotion plan, or matching state/live 8/16 GiB plus an empty
plan; it then invalidates the entire attempted bundle. A pre-change receipt
permits a fresh plan. A promoted receipt does not permit retry. Any other result
is a stop condition requiring a separate reviewed state/live reconciliation.

## Runner group cutover

TIN-3902. Moves `great-falls-tool-bus-nix` off GitHub's shared `Default`
runner group onto the dedicated, selected-repository
`great-falls-tool-bus-infra` group. This is an admission fix, not a capacity
change: `nix_min_runners = 0` / `nix_max_runners = 4` are unchanged.

### Why source alone is not enough

The GloriousFlywheel `arc-runners` stack declares only the `kubernetes` and
`helm` providers and owns no `github_actions_runner_group` resource. It sets
the group NAME on the ARC release; it does not create, name-check, or
reconcile the group on GitHub. **The GitHub-side group must already exist when
the first plan runs.** If it does not, `tofu` will still plan and apply
happily, and the scale set will simply register into a group GitHub does not
have — the same silent-idle failure this ticket is closing.

### Step 0 — attended GitHub org-settings action (prerequisite)

GitHub → organization `Great-Falls-Tool-Bus` → Settings → Actions → Runner
groups. Create (or confirm) a group matching
`config/organization.yaml` `runner_contract.runner_group` exactly:

- name `great-falls-tool-bus-infra`
- access: **selected repositories** (`visibility: selected`)
- **do not** allow public repositories (`allows_public_repositories: false`)
- **do not** restrict to selected workflows (`restricted_to_workflows: false`)
- selected repositories: `gftb-site` (id `1336591141`) and
  `greatfallstoolbus.org` (id `1287399122`)

`greatfallstoolbus.org` is still a public repository, so with public
repositories disallowed its jobs stay unadmitted even though it is on the
roster; see "Organization Boundary" above. If the GitHub UI or API refuses to
add a public repository to the selected set, leave it off and add the TIN-3815
private successor spoke's id when that repository exists.

This repository (`great-falls-tool-bus-infra`, id `1286829099`) is public and
is deliberately NOT selected. Its own self-hosted apply/drift jobs stop being
admitted at cutover; that is the intended TIN-3209 posture, not a regression.

Record the group as an operator receipt: source convergence proves nothing
about the live GitHub configuration.

### Step 1 — source review, offline

```bash
just core-checkout
just arc-fmt-check
just arc-validate
```

`arc-validate` is the one that proves the tfvars still matches the pinned
module surface, so it must run against the advanced ARC role pin
(`11ace397282ff89aeb1dfeb4a32fcbed3200c2ff`).

### Step 2 — plan-scope contract (hard prerequisite, not yet landed)

`just arc-plan-scope-check` currently admits exactly one plan: an in-place
`module.gh_nix.helm_release.arc_runner` update whose only Helm-values
difference is the runner container's `ephemeral-storage`
`4Gi -> 8Gi` request and `8Gi -> 16Gi` limit. The TIN-3902 carrier's plan is a
strict superset of that, so the guard refuses it by design and
`just arc-apply` cannot run until a separate reviewed change advances the
allowlist to the shape in Step 4.

Do not work around the guard. Advancing it is the reviewed decision point.

### Step 3 — quiet window and plan

The RustFS S3 backend has no remote state lock; hold the exclusive window
described in "Exclusive state window" across every command below.

```bash
export GF_ARC_CORE_PATH=/operator/path/GloriousFlywheel-arc-11ace
export GF_ARC_CORE_CI_PATH=path:/operator/path/GloriousFlywheel-arc-11ace#ci
export GFTB_ARC_KUBECONFIG=/operator/path/gftb-arc.kubeconfig
# Export the RustFS access-key pair from operator custody.
just enrollment-preflight
GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive just arc-plan
just arc-plan-show
just arc-plan-scope-check
GFTB_APPLY_CONFIRM=apply GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive just arc-apply
```

### Step 4 — expected plan shape

Review `just arc-plan-show` against this exactly. Anything else is a stop
condition.

**One in-place update, one state-only create, zero deletes, zero replacements,
zero drift:**

- `module.gh_nix.helm_release.arc_runner` — **update in place**. Helm-values
  deltas only:
  - `runnerGroup`: `default` -> `great-falls-tool-bus-infra`
  - runner container `resources.requests.ephemeral-storage` `4Gi` -> `8Gi` and
    `resources.limits.ephemeral-storage` `8Gi` -> `16Gi` (the still-unapplied
    2026-08-17 eviction response already committed in the tfvars)
  - runner image digest advanced to the pinned
    `ghcr.io/tinyland-inc/actions-runner-nix` digest carried by the new ARC
    role pin
  - new env var `GF_FLYWHEEL_PROFILE_STATE=shared-cache-backed`
  - new `template.spec.priorityClassName: arc-runner`
- `terraform_data.runner_group_policy` — **create**. This is the one
  unavoidable create and it materializes nothing: it is a state-only policy
  receipt whose preconditions reject any scale set left in `default` under
  `runner_group_policy = "organization-restricted"`. It exists in the module
  from GloriousFlywheel `f13f8ad9` onward and is new to this overlay only
  because the ARC role pin advanced.

Everything else that appeared in the module between the old and new ARC role
pins is gated off by inputs this overlay does not set
(`create_runner_priority_classes`, `runner_sigkill_collector_*`,
`tofu_plan_identity_*`, `overlay_tenant_legacy_shared_grants`,
`runner_namespace_policy_enabled`, warm pool, docker/dind, longhorn), so it
must not appear in the plan. `moved` blocks in the module (`arc_controller`,
the priority classes) are no-ops here because this overlay owns none of those
objects; any `moved`/`import` metadata in the plan JSON is a stop condition
the scope guard already rejects.

The `arc-runner` PriorityClass is cluster-scoped and already exists on `honey`
(owned by the GF-primary state, value `-50`). This overlay consumes it and
must not create it.

### Step 5 — readback

```bash
GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive just arc-capacity-readback
```

`arc-capacity-readback` proves capacity convergence and listener health; it
does NOT look at the runner group. Add the group and admission readbacks
explicitly:

```bash
kubectl --context honey -n arc-runners \
  get autoscalingrunnersets great-falls-tool-bus-nix \
  -o jsonpath='{.spec.runnerGroup}'
```

Must print `great-falls-tool-bus-infra`. Printing `default` means the apply did
not land the group, and no amount of GitHub-side configuration will fix it.

Then confirm admission actually resumed, by watching the listener decide it has
work:

```bash
kubectl --context honey -n arc-systems logs \
  -l actions.github.com/scale-set-name=great-falls-tool-bus-nix,actions.github.com/scale-set-namespace=arc-runners,app.kubernetes.io/component=runner-scale-set-listener \
  --tail=50 | grep 'Calculated target runner count'
```

While a real `gftb-site` CI run is queued, `"assigned job"` must go above `0`.
A healthy, connected listener that keeps logging `"assigned job"=0` against
live queued demand is the exact pre-cutover symptom and means admission is
still broken — check the GitHub-side group roster from Step 0 before touching
this stack again.

### Rollback

The cutover is source-reversible. There is no destroy path and none is needed.

1. Revert the tfvars change (`runner_group`, `runner_group_policy`) and the
   ARC role pin advance (`Justfile` `arc_core_default` / `arc_core_sha` /
   `arc_core_ci_default`, `scripts/validate-core-checkout.py` `ARC_CORE_PIN`,
   `scripts/validate-public-operator-surface.py` `ARC_CORE_SHA` and the
   `arc_core_default` fixture, `.github/workflows/flywheel-cache-proof.yml`
   `GF_OIDC_PROFILE_REF`, and the pin prose in `README.md`,
   `docs/implementation-overlay.md`, `docs/ci-credentials.md`). Reverting the
   tfvars WITHOUT reverting the pin is not a valid state: `runner_group` is a
   required input at the new pin and has no default.
2. Land the revert on canonical `main` (every guarded ARC recipe requires a
   clean, signed, current `main`).
3. Restore the reverted-pin ARC core checkout and re-plan:
   `GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive just arc-plan`, then
   `just arc-plan-show`. The reverse plan is again one in-place
   `module.gh_nix.helm_release.arc_runner` update plus the **destroy** of the
   state-only `terraform_data.runner_group_policy`; the committed scope guard
   does not admit that shape either, so a rollback needs its own reviewed
   scope contract exactly as the forward change does.
4. Leaving the GitHub-side group in place after a rollback is harmless — an
   unused runner group admits nobody and starves nothing.

## ARC GitHub App Secret

After the GFTB GitHub App is created at
`https://github.com/organizations/Great-Falls-Tool-Bus/settings/apps/new`
(name `gf-arc-great-falls-tool-bus`; Organization self-hosted runners:
Read & write; Repository Actions: Read; Repository Metadata: Read), installed
org-wide, and the `.pem` private key downloaded by the human operator, rotate
the ARC secret through the overlay Just targets:

```bash
export GF_CORE_PATH=../GloriousFlywheel
export GITHUB_APP_ID=<APP_ID>
export GITHUB_APP_INSTALLATION_ID=<INSTALLATION_ID>
export GITHUB_APP_PRIVATE_KEY_PATH=<PATH_TO_PRIVATE_KEY>
export GFTB_ARC_KUBECONFIG=/operator/path/gftb-arc.kubeconfig

GFTB_APPLY_CONFIRM=apply just arc-app-secret-apply
just enrollment-preflight
```

The wrapper reads `github-app-secret-great-falls-tool-bus` and the `honey`
context from `config/organization.yaml`, then writes the same GitHub App secret
into `arc-systems` and `arc-runners`. Do not commit the private key,
kubeconfig, or derived secret material.

## Current Core Pin

This overlay's implementation authority pins GloriousFlywheel core at
`2281b576bce0e8dd776a047b84e7464f5b508a62`, `origin/main`, refreshed
2026-07-02 (PR #3) from the overlay-authoring pin `7072ce2e`. Tracking a merged
commit was chosen over the template's pin because GFTB needs the newer contracts
(extra-runner-set executor wiring, the consumer registry, the public
token-exchange front door), a fresh overlay has no live state to protect, and
the template's four internally divergent pins were a wart to fix, not
replicate. The same commit appears in `config/organization.yaml`,
`MODULE.bazel`, `Justfile`, and each non-ARC core workflow.

The ARC runner and OIDC profile surfaces carry a separate role pin, advanced by
TIN-3902 from `df510574d17b85e7f15470caf3574fcabc4768f1` (2026-07-09) to
`11ace397282ff89aeb1dfeb4a32fcbed3200c2ff` (GloriousFlywheel `origin/main`,
2026-08-18). The reason is narrow and mandatory: `runner_group` and
`runner_group_policy` do not exist as `arc-runners` stack inputs before
GloriousFlywheel `f13f8ad9` (TIN-3209, PR #1303), so the runner-group binding
is unexpressible at the old pin.

Reviewed module surface between those two ARC pins:

- no `arc-runners` stack variable was removed, and no pre-existing variable's
  default changed
- exactly one new REQUIRED input: `runner_group` (no default, rejects empty)
- `runner_group_policy` already defaults to `organization-restricted`; the
  `legacy-default` escape is a stack-coded roster of nine `tinyland-*`
  scale sets with a fixed 2026-08-15 expiry, has never included
  `great-falls-tool-bus-nix`, and is now expired at both plan and apply time
- every other new input defaults off or empty:
  `create_runner_priority_classes`, the `runner_sigkill_collector_*` family,
  the `tofu_plan_*` identity family, `overlay_tenant_legacy_shared_grants`,
  `nix_runner_secret_mounts`, `listener_resources`,
  `listener_topology_spread_constraints`, `shared_nix_runner_tolerations`,
  `shared_nix_runner_affinity`, `docker_runner_host_path_mounts`,
  `docker_runner_container_security_context`, `nix_warm_pool_suspended`, and
  the `dind_*_volume_*` classes
- `runner_namespace` remains pinned to the shared `arc-runners` namespace, so
  nothing about this change moves or recreates the live scale set. The
  per-owner isolated planes introduced by TIN-2770/TIN-123 were moved OUT of
  this root into the separate `arc-owner-overlay-plan-bootstrap` /
  `arc-owner-overlay-release` roots (the GF-primary source now actively forbids
  declaring tenant planes here), and this overlay uses neither. Migrating GFTB
  onto that isolated owner-overlay plane — its own `arc-runners-<owner>`
  namespace and per-plane App secret — is the separate, larger TIN-3209 Path B
  step and is explicitly out of scope for TIN-3902
- the `arc-runner` module's resource shape is unchanged (one optional
  `kubernetes_persistent_volume_claim_v1`, one `helm_release`), so the change
  reaches this overlay as Helm values, not as replacements
- the `nixpkgs-opentofu` flake input is byte-identical at both pins, so the
  plan-scope guard's exact `terraform_version` 1.11.6 assertion still holds
- `scripts/flywheel-github-oidc-profile.sh` is byte-identical at both pins, so
  the pinned `GF_OIDC_PROFILE_SHA256` content hash is unchanged

Nothing in that range is breaking for this overlay's `arc-runners` stack, so
the pin advance stops at current `origin/main` rather than at an earlier safe
commit. Two changes in the range are affirmative reasons not to stop earlier:
`f1b8f362` (TIN-3601) advances the `actions-runner` image past GitHub's rolling
runner-deprecation minimum, and `6e52ff1d` / `66f67168` harden listener
placement and controller pinning after the 2026-08-09 estate-wide outage.

The implementation pin is deliberately not advanced with it. It governs the
edge/DNS, mail, list, form, archive, and web consumers, none of which are
involved in runner-group admission. Review any future pin convergence as a
separate executable-core adoption change.
