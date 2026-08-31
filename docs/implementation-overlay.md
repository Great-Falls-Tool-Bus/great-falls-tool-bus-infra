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
- `allows_public_repositories: true`
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
   `web-crs.yml`, `web-plan.yml` — will not be admitted after the cutover.
   None of the ten can run on a fork pull request: eight carry a job-level
   `if: github.event_name == 'push' || github.event_name == 'workflow_dispatch'`,
   and the two drift lanes (`edge-drift.yml`, `k8s-stack-drift.yml`) declare
   only `schedule` + `workflow_dispatch` triggers. The hosted `validate.yml` job
   already runs on `ubuntu-24.04`, so no PR gate depends on this. What the
   cutover does cost is the scheduled drift lanes and the push/dispatch
   validate+apply lanes in this repository; they must be re-homed or accepted
   as manual before or shortly after cutover. Note that with
   `allows_public_repositories: true` (see 2), the roster is now the ONLY thing
   keeping this repository out — the public-repository flag is no longer a
   second lock. Adding id `1286829099` is therefore a one-line edit away and
   must stay an explicit operator decision, not a routine roster tidy-up.
2. **`greatfallstoolbus.org` is admitted, and that is a deliberate ruling.**
   That repository is public, so it can only be admitted with
   `allows_public_repositories: true`. Public repository admission is
   **accepted by operator ruling 2026-08-18 (TIN-3902)**: the roster entry is
   meant to be effective, not recorded-and-inert. TIN-3209's cross-tenant
   concern — a public repository's workflows reaching GF-substrate runners —
   is acknowledged and tracked in TIN-3209; it is not re-litigated here and it
   is not a reason to quietly flip the flag back. When TIN-3815 moves this CI
   into the private successor spoke, add that repository's id to the roster
   too; removing this entry afterwards is a separate operator decision.
3. **Both rostered repositories are unblocked by this change.** `gftb-site`
   (private) and `greatfallstoolbus.org` (public, admitted under the ruling)
   both become assignable once the cutover applies.

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

TIN-4072 binds the first proof to one Nix runner:

- nix lane only; docker/dind remain disabled
- `nix_min_runners = 0`, `nix_max_runners = 1`
- warm pool disabled
- the container writable-layer request/limit remains 8 GiB/16 GiB
- `/nix`, `_work`, and `.cache` mount per-runner
  generic-ephemeral PVCs on `local-path-sting-fast-ephemeral` at 64/32/32 GiB
- runner selector, compute-expansion toleration, runner group, image, labels,
  and cache endpoints remain unchanged

The one-slot package is 128 GiB against the measured 455,074,283,520 free bytes
on Sting fast-local. Four packages are 512 GiB and are refused. Any raise above
one is a separate operator decision and source carrier. This moves the measured
write paths off the container writable layer without raising that 8/16 GiB
envelope.

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

TIN-4072 grants no operator-local, attended, dispatch, or ad hoc runtime
authority. Its signed GF pin, tfvars, and storage declarations are source-only.
The only admitted runtime path is a version-pinned protected canonical-main
planner, a subordinate executor consuming the exact saved-plan bytes without
replanning, and an identity-separated independent observer/readback.

This repository does not yet contain that protected carrier. No source merge,
local plan, local apply, rollback command, or local readback releases
application PR #218. Kubernetes and backend credentials for the eventual
carrier remain external to this public source tree and do not create authority
by their presence.
## Enrollment Preflight

This read-only diagnostic is declaration troubleshooting only. It is not a
plan/apply precondition, a promoted receipt, or authority to run the retained
local mutation surface:

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

## TIN-4072 protected-carrier hold

The TIN-4072 desired delta is exact: max runners four to one plus the signed
e175a398 generic-ephemeral package for `/nix`, `_work`, and `.cache`.
Pure validators bind that declaration, the Sting StorageClass provisioner and
node path, the fixed initializer, and the unchanged runner envelope.

The retained local `arc-plan-scope-check` is deliberately restored to its
three historical shapes: capacity, runner-group cutover, and runner-group
rollback. A plan containing `storage-adoption`, `storage-rollback`, the
max-four-to-max-one delta, or the generic-ephemeral projection is refused.
Because local `arc-apply` depends on that exact guard, it cannot mutate the
TIN-4072 declaration. The retained local readback has no storage promotion or
storage rollback receipt and cannot release application PR #218.

Runtime adoption waits for the protected canonical-main planner, exact
saved-plan executor, and independent observer/readback carrier. That carrier
must pin its implementation version and identities, refuse replanning, and
emit the promoted receipt before #218 can be released. Until then live ARC
state remains unchanged.

## Historical runner-group boundary (TIN-3902)

TIN-3902 already moved `great-falls-tool-bus-nix` from GitHub's shared
`Default` group to the dedicated `great-falls-tool-bus-infra` group. The
executable plan/apply/readback procedure belongs to the signed source and
observed state that carried that cutover; Git history retains it. It is not a
current runbook.

Do not repoint that procedure at the e175a398 TIN-4072 source. Current tfvars
declare max one plus the three generic-ephemeral claims, while the retained
local plan guard and readback remain intentionally fixed to the historical
non-storage shapes and max-four live state. A current-source local plan is
refused and cannot become an adoption, rollback, promotion, or release receipt.
Any future recovery starts from a new signed carrier and current independently
observed state; it never reuses or relabels the historical command sequence.

The live GitHub-side boundary remains `visibility: selected`, public-repository
admission enabled by the recorded operator ruling, and the exact roster in
`config/organization.yaml`. The overlay's runner-group contract validates that
source declaration without performing an organization-settings mutation.

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

The ARC runner and OIDC profile surfaces carry a separate role pin. TIN-3902
advanced it from `df510574d17b85e7f15470caf3574fcabc4768f1` (2026-07-09) to
`11ace397282ff89aeb1dfeb4a32fcbed3200c2ff`. TIN-4072 now advances it to the
signed GloriousFlywheel #1594 merge
`e175a398c3c8f25f99c41eff8b584df6a360531e`. The 11ace commit was the head of
GloriousFlywheel `origin/main` when it was selected on 2026-08-18; `origin/main`
has advanced since, so it is precisely a reviewed **ancestor** of `origin/main`,
not `origin/main` itself.

What binds the `arc-runners` stack to that commit is the **Justfile**, not the
pin validators. `arc_core_default` and `arc_core_ci_default` select the checkout
and `#ci` devshell that `tofu -chdir=<core>/tofu/stacks/arc-runners` actually
runs from, and `_reviewed-arc-core` refuses to proceed unless that checkout is a
clean, signed, canonical GloriousFlywheel at exactly `arc_core_sha` with no
untracked Terraform inputs under `tofu/stacks/arc-runners` or `tofu/modules`.
`scripts/validate-core-checkout.py` `ARC_CORE_PIN` and
`scripts/validate-public-operator-surface.py` `ARC_CORE_SHA` only pin those
Justfile strings so they cannot drift silently — neither validator names the
`arc-runners` path, reads the stack, or executes anything.

The reason for the historical TIN-3902 advance was narrow and mandatory: `runner_group` and
`runner_group_policy` do not exist as `arc-runners` stack inputs before
GloriousFlywheel `f13f8ad9` (TIN-3209, PR #1303), so the runner-group binding
is unexpressible at the old pin.

Reviewed module surface between the df510 and 11ace ARC pins:

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

Nothing in that historical range was breaking for this overlay's `arc-runners`
stack, so TIN-3902 stopped at the then-current `origin/main` rather than an
earlier safe commit. Two changes in the df510-to-11ace range were affirmative
reasons not to stop earlier: `f1b8f362` (TIN-3601) advances the `actions-runner` image past
GitHub's rolling runner-deprecation minimum, and `6e52ff1d` / `66f67168` harden
listener placement and controller pinning after the 2026-08-09 estate-wide
outage.

The TIN-4072 11ace-to-e175 range is narrower at this overlay boundary: six
already-existing module inputs become top-level `arc-runners` stack inputs for
the storage class and size of `/nix`, `_work`, and `.cache`. Empty classes remain
inert; this overlay deliberately sets the Sting class and 64/32/32 GiB sizes.
The OIDC helper blob is byte-identical, so its pinned SHA-256 remains unchanged;
the exact plan-scope guard refuses any source effect outside the reviewed Helm
update.

The implementation pin is deliberately not advanced with the ARC role pin. It
governs the
edge/DNS, mail, list, form, archive, and web consumers, none of which are
involved in runner-group admission. Review any future pin convergence as a
separate executable-core adoption change.
