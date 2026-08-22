# great-falls-tool-bus-infra

Implementation overlay for the Great-Falls-Tool-Bus (GFTB) GitHub
organization boundary, the third owner overlay on the shared Honey substrate.

This repository carries owner-specific deployment facts for GFTB org repo
enrollment while reusing the same GloriousFlywheel backend services, runner
types, and caches as the other overlays.

Because GFTB is an organization (not a personal account), ARC registers at the
ORG scope: `github_config_url = https://github.com/Great-Falls-Tool-Bus`. One
scale set serves every repo in the org, so this overlay needs **no** per-repo
`extra_runner_sets` registration anchors (the biggest structural difference
from the older personal-account overlay template).

## Architecture

Grounded mermaid diagrams (mail flow, network/ports, planes, Bazel/GF) live in
[`docs/architecture/diagrams.md`](docs/architecture/diagrams.md).

## Current Contract

- Core product repo: `tinyland-inc/GloriousFlywheel`
- ARC registration: `https://github.com/Great-Falls-Tool-Bus` (org-scoped, no
  repo anchors)
- Cluster context: `honey`; shared ARC controller owner: Tinyland overlay
- Workflow labels: shared `tinyland-*` capability labels. ONLY `tinyland-nix`
  is provisioned for this org today. Per the 2026-08-19 operator ruling
  (TIN-3914) no workflow here may name a GitHub-hosted label; the secret-free
  `validate` job requests `tinyland-nix` like everything else -- see the
  runner-group admission note below for why it's the one job here that runs
  unfiltered on every `pull_request`.
- Scale set: `great-falls-tool-bus-nix` (ARC registration identity only;
  workflows use `runs-on: tinyland-nix`)
- Runner group: `great-falls-tool-bus-infra` (TIN-3902). GitHub-side admission
  boundary, `visibility: selected`, `allows_public_repositories: true`. The
  roster is `gftb-site` and `greatfallstoolbus.org`, declared in
  `config/organization.yaml` `runner_contract.runner_group`; the scale set
  binds to it through `runner_group` /
  `runner_group_policy = "organization-restricted"` in the ARC tfvars. This is
  not a runner label and not an ARC registration anchor. Public repository
  admission is accepted by operator ruling 2026-08-18 (TIN-3902) so the
  `greatfallstoolbus.org` roster entry is effective rather than inert;
  TIN-3209's cross-tenant concern is acknowledged and tracked there. This
  repository itself remains excluded — and with public admission on, the roster
  is the ONLY control keeping it out; the public-repository flag is no longer a
  second lock. Adding id `1286829099` is a one-line edit and must stay an
  explicit operator decision. `just runner-group-contract` fails on that id
  unless an `infra_repo_admission_ruling:` field records the decision.
- Shared Nix cache: `http://attic.nix-cache.svc.cluster.local`
- Shared Bazel cache: `grpc://bazel-cache.nix-cache.svc.cluster.local:9092`
- Shared Bazel executor: `grpc://gf-reapi-cell.gf-rbe.svc.cluster.local:8980`
  (documented substrate fact, NOT wired into the primary lane yet; see the
  executor-flip note in the tfvars)
- State: bucket `tofu-state`, key prefix `great-falls-tool-bus-infra`
  (`arc-runners/` and live `edge/` state keys; `edge-dns/` is a
  superseded fail-closed reference key)
- Core pin: `2281b576bce0e8dd776a047b84e7464f5b508a62` (GloriousFlywheel
  `origin/main`, refreshed 2026-07-02 from the overlay-authoring pin
  `7072ce2e`, PR #3, preflight next-action #1). A merged commit was chosen over
  the template's pin because (a) GFTB depends on contracts that postdate it
  (extra-runner-set executor wiring, consumer registry, token-exchange front
  door) and (b) the template carried four divergent pins across its own files,
  a drift wart. `config/organization.yaml`, `MODULE.bazel`, `Justfile`, and the
  non-ARC workflow consumers share this implementation pin.
- ARC/OIDC role pin: `11ace397282ff89aeb1dfeb4a32fcbed3200c2ff`. It was the
  head of GloriousFlywheel `origin/main` when selected on 2026-08-18;
  `origin/main` has advanced since, so the accurate statement is that this pin
  is a reviewed **ancestor** of `origin/main`, not `origin/main` itself. What
  binds the `arc-runners` stack to it is the Justfile — `arc_core_default` /
  `arc_core_ci_default` select the checkout and `#ci` devshell that
  `tofu -chdir=<core>/tofu/stacks/arc-runners` runs from, and
  `_reviewed-arc-core` refuses unless that checkout is clean, signed,
  canonical, and exactly `arc_core_sha`. `validate-core-checkout.py`
  `ARC_CORE_PIN` and `validate-public-operator-surface.py` `ARC_CORE_SHA` pin
  those Justfile strings against drift; neither names the `arc-runners` path
  nor executes anything. Advanced by TIN-3902 from
  `df510574d17b85e7f15470caf3574fcabc4768f1` (2026-07-09) because the
  `runner_group` / `runner_group_policy` inputs did not exist in the
  `arc-runners` stack before GloriousFlywheel `f13f8ad9` (TIN-3209, PR #1303).
  Reviewed surface between the two pins: no `arc-runners` stack variable was
  removed and **no pre-existing default changed**; the only new REQUIRED input
  is `runner_group`; every other new input is **inert for this overlay** —
  proven by the plan below, not by inspection. (Inert is the accurate claim,
  not "defaults off": `helm_storage_driver` defaults to `secret`,
  `tofu_plan_token_secret_enabled` and `tofu_plan_create_namespace` default to
  `true`, and `dind_work_volume_size` / `dind_docker_volume_size` default to
  `40Gi` / `80Gi`. Each is gated behind another input this overlay leaves off,
  or reproduces the behaviour already in state, so none of them reaches the
  plan.) `runner_namespace` stays `arc-runners`, the `arc-runner` module's
  resource shape is unchanged, and the `nixpkgs-opentofu` flake input is
  byte-identical, so the pinned OpenTofu 1.11.6 plan schema still holds. The
  value-level deltas that do reach this overlay's Helm release are: the
  `runnerGroup` value, the `ghcr.io/tinyland-inc/actions-runner-nix` digest
  (advanced past GitHub's rolling runner-deprecation minimum by `f1b8f362`,
  TIN-3601), a new `GF_FLYWHEEL_PROFILE_STATE` env var mirroring
  `GF_BAZEL_SUBSTRATE_MODE`, and `priorityClassName: arc-runner` (the
  cluster-scoped class already exists on `honey`; this overlay does not create
  it). The implementation pin is deliberately NOT advanced with it; pin
  convergence remains a separate adoption change.
- Capacity posture (TIN-2165/TIN-2234 pod-cap crunch): nix only, `min 0 / max
  4`, no warm pool, docker/dind off, sting placement + the dedicated
  `compute-expansion` toleration.

Private credentials stay outside Git:

- GFTB GitHub App private key and installation ID
- RustFS/S3 backend access keys
- kubeconfigs and operator tokens
- `.env` files and local backend configs with secrets

## Edge/DNS apply plane (TIN-2360 row c, amended 2026-07-02)

Beyond ARC tenancy, this overlay is the **canonical apply home for the
GFTB edge**. The live TIN-2385 stack is
[`tofu/stacks/edge/`](tofu/stacks/edge/README.md): zones added
**console-side** to the house CF account, looked up by name with a
**zone-scoped** token (protected `edge` environment secret
`CLOUDFLARE_API_TOKEN_GFTB_ZONES`, name only), managing the proxied
apex/www records, the REV-2 Access gate, and the `latoolb.us` 301
redirects (no mail records, TIN-2379). Console/registrar steps:
[`docs/runbooks/edge-token-and-zones.md`](docs/runbooks/edge-token-and-zones.md);
CI plan/apply chassis: `.github/workflows/edge-plan.yml` (skip-green
until the protected edge secrets exist).

[`tofu/stacks/edge-dns/`](tofu/stacks/edge-dns/README.md) is retained only
as the superseded pre-TIN-2385, fail-closed reference. It is not in the
Justfile operator menu and must not be applied while the live edge stack
owns the zone surface.

## Mail CR apply plane (TIN-2379)

Tenant-owned mail custom resources live in
[`k8s/mail/latoolb-us-production/`](k8s/mail/latoolb-us-production/).
They consume the namespace grant declared in `tinyland-inc/blahaj`
`deploy/tenants/great-falls-tool-bus/rbac.yaml`; the CR declarations do not
move into Blahaj.

Use `just mail-cr-validate` for offline shape validation and
`just mail-cr-server-dry-run` / `just mail-cr-apply` only with a
namespace-scoped kubeconfig supplied through `GFTB_MAIL_KUBECONFIG`.
The protected CI secret name is `MAIL_APPLY_KUBECONFIG_B64` in the `mail`
environment; `GFTB_MAIL_KUBECONFIG_B64` remains a compatibility alias. See
[`docs/mail-cr-apply-runbook.md`](docs/mail-cr-apply-runbook.md).

Mailman list engine runbooks: bring-up in
[`docs/runbooks/list-bringup.md`](docs/runbooks/list-bringup.md); day-to-day
operation (members, moderation, settings, stack) in
[`docs/runbooks/list-operations.md`](docs/runbooks/list-operations.md).

## Bootstrap (read first)

Secret-free pull-request validation runs on `tinyland-nix` (TIN-3914) and
therefore depends on this repository's ARC runner-group admission -- see the
note below on why this is the one job here left `pull_request`-unfiltered.
Cluster plans and applies remain operator-local; the
first ARC plan and apply run from the operator machine (kubectl context
`honey`). See
[docs/implementation-overlay.md](docs/implementation-overlay.md) for the
ordered runbook.

Self-hosted admission has two independent gates, and satisfying only one is the
failure mode TIN-3902 exists to close:

1. **ARC registration** — org-scoped, provisioned by this overlay's
   `arc-runners` state. It makes the scale set exist and connect.
2. **GitHub runner-group admission** — a GitHub organization setting, not a
   tofu resource in the module this overlay consumes. It decides which
   repositories may be assigned that scale set's jobs.

A registered scale set with no admitting group is a healthy, connected,
permanently idle listener while its org's jobs sit queued. Create or confirm
the `great-falls-tool-bus-infra` group in GitHub org settings **before** the
cutover plan; the ordered steps are in
[docs/implementation-overlay.md](docs/implementation-overlay.md) under
"Runner group cutover".

## Operator Flow

ARC plan/apply is an attended, operator-local operation. It must start from a
clean, signed checkout of the current canonical `main` and the clean, signed
role-specific GloriousFlywheel checkout at
`11ace397282ff89aeb1dfeb4a32fcbed3200c2ff`:

```bash
export GF_CORE_PATH=/operator/path/GloriousFlywheel-implementation-2281
export GF_ARC_CORE_PATH=/operator/path/GloriousFlywheel-arc-11ace
export GF_ARC_CORE_CI_PATH=path:/operator/path/GloriousFlywheel-arc-11ace#ci
export GFTB_ARC_KUBECONFIG=/operator/path/gftb-arc.kubeconfig
# Export the RustFS access-key pair from operator custody.
just enrollment-preflight
GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive just arc-plan
just arc-plan-show
just arc-plan-scope-check
GFTB_APPLY_CONFIRM=apply GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive just arc-apply
GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive just arc-capacity-readback
```

`just arc-plan` runs the GloriousFlywheel ARC stack with this repo's
`tofu/stacks/arc-runners/great-falls-tool-bus.tfvars` and backend config.
`just enrollment-preflight` is read-only and reports ARC GitHub App secrets,
live runner-set registration, and recent workflow blockers before any plan or
apply. The pinned pre-#1208 GloriousFlywheel implementation still emits a legacy
core-read-credential row; do not provision a key solely to satisfy that row.
`just core-checkout` is this overlay's fail-closed source-authority check. App
secret rotation remains a separate operator-local action through
`just arc-app-secret-apply`; it is not part of ARC state plan/apply.

`validate` is self-contained and does not fetch the private
`tinyland-inc/GloriousFlywheel` repository. Source-dependent ARC module
validation remains operator-local against an exact reviewed checkout. The other
workflow declarations retain exact pins but are not the required validation
authority; see [CI Credentials](docs/ci-credentials.md).

ADMISSION HOLD RESOLVED (TIN-3914, PR #128, operator ruling 2026-08-22):
`validate` requests `tinyland-nix`. For this org that label is published only
by the `great-falls-tool-bus-nix` scale set, which binds to the
`great-falls-tool-bus-infra` runner group; this repository (id `1286829099`)
joined that group's roster in `config/organization.yaml` with the required
`infra_repo_admission_ruling:` field. `validate` is also the only required
status check in the `main` ruleset, and the one job in this repository that
runs unfiltered on every `pull_request` with no trusted-event gate (every
other self-hosted workflow here either carries the PR #110 gate or declares
no `pull_request` trigger at all) -- its compensating control is staying
secret-free, not event-gated. See `config/organization.yaml`'s
`runner_group` comment for the full standing-invariant rationale.

There is no ARC plan/apply workflow and no repository ARC kubeconfig. The
guarded Just recipes, an external operator-owned mode-0600 kubeconfig, and
runtime RustFS credentials are the only ARC state-mutation path.

`just arc-apply` runs an exact plan-scope guard backed by OpenTofu's JSON plan
actions. The allowlist is keyed on resource address plus action plus the
enumerated attribute paths that may change, and it fails closed: it admits
exactly three plans and refuses every other update, create, delete, and
replacement.

1. **capacity** — one in-place `module.gh_nix.helm_release.arc_runner` update
   whose only Helm-values delta is the runner container's `ephemeral-storage`
   `4Gi -> 8Gi` request and `8Gi -> 16Gi` limit; the Helm `set` block is
   compared whole here, so this shape cannot smuggle a `runnerGroup` move.
   It requires live/state still at `4Gi`/`8Gi`. (This shape applied on
   2026-08-17 as helm revision 6, decomposing the cutover below.)
2. **cutover** — the TIN-3902 runner-group move: the `runnerGroup` Helm `set`
   entry `default -> great-falls-tool-bus-infra`, the pinned runner image
   digest, the new `GF_FLYWHEEL_PROFILE_STATE` runner env var, and
   `template.spec.priorityClassName: arc-runner`; plus one create of the
   state-only `terraform_data.runner_group_policy` and the nine new
   source-derived root outputs the advanced ARC role pin adds. Its storage
   transition is either `4Gi/8Gi -> 8Gi/16Gi` (the original combined shape)
   or byte-identical `8Gi/16Gi` on both sides (the decomposed shape — the
   live posture since the capacity apply).
3. **rollback** — the byte-exact reverse of the cutover in either posture:
   the group, image, env, and priorityClassName reversal plus the
   `terraform_data.runner_group_policy` destroy, with storage retained at
   `8Gi`/`16Gi` (the decomposed group-move reversal, the ratified fallback
   from the post-cutover state) or demoted back to `4Gi`/`8Gi` (the combined
   reversal — a deliberate capacity revert, never a rollback side effect); see
   [docs/implementation-overlay.md](docs/implementation-overlay.md) "Rollback".

The guard therefore no longer blocks the TIN-3902 carrier, and a rollback does
not need an emergency contract change. It stays pinned to today's reviewed
capacity and roster: a **future capacity change** — `nix_max_runners` 4 -> 8, a
memory or CPU envelope move, a further `ephemeral-storage` step — or any
roster, image-digest, or module-pin move needs its own reviewed scope-contract
update before `just arc-apply` will run. The enumerated shapes are in
[docs/implementation-overlay.md](docs/implementation-overlay.md) "Runner group
cutover".

The ARC S3 backend has no remote state lock. Hold an exclusive quiet window
from before `arc-plan` through post-apply readback: no concurrent operator and
no workflow may plan or mutate the same ARC state. Supply
`GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive` as a one-shot value on each plan, apply,
and readback command only after checking that condition. The normal promoted
readback passes only when canonical state and the live scale set both report
8Gi/16Gi in runner group `great-falls-tool-bus-infra`, the listener is one
Ready zero-restart pod, and a refreshed plan is empty. If a
localhost RustFS port-forward is lost after cluster mutation may have begun but
before state is written, stop; the apply-attempt marker prevents blind reuse.
Restore connectivity and reconcile the ambiguous attempt directly with
`GFTB_ARC_READBACK_MODE=reconcile GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive just
arc-capacity-readback`. Reconciliation is keyed on the refreshed plan and the
runner group, not the storage level: a pending plan the scope guard admits —
in any admitted posture, including live 8/16 GiB with the decomposed
runner-group cutover pending — is re-reviewed by `arc-plan-scope-check` and
yields the pre-change receipt, while an empty refreshed plan certifies the
landed state (promoted at the dedicated group; a converged group-`default`
state requires an explicit `rolled-back` re-run). Every mode also requires
canonical state and the live scale set to agree on `.spec.runnerGroup`, and
`promoted` / `rolled-back` require it to be `great-falls-tool-bus-infra` /
`default` respectively; `rolled-back` certifies convergence at either
`4Gi`/`8Gi` (combined reversal) or the capacity-retained `8Gi`/`16Gi`
(decomposed group-move reversal). It
consumes the attempted plan bundle; only the pre-change outcome permits
creating and reviewing a fresh plan.

## Boundary

This overlay targets the same Honey backend and cache substrate as the other
overlays. That is an owner/auth boundary. It is not a new runner product and
it does not justify labels such as `gftb-nix` or `great-falls-*` workflow
labels.

The `great-falls-tool-bus-infra` runner group is the same kind of boundary
expressed on the GitHub side: an owner/tenancy admission list, deliberately
named after this overlay rather than after a capability, and deliberately not
a label. Naming it does not weaken the label rule above — no workflow may
request `great-falls-tool-bus-infra` as a label, and `runs-on:` keeps naming
shared `tinyland-*` capability labels.

Because all overlays attach to the same physical `arc-runners` namespace, this
overlay uses owner-distinct internal Helm release and ARC `runnerScaleSetName`
values (`great-falls-tool-bus-*`) while preserving the shared `tinyland-*`
runner labels. The GFTB overlay does not deploy the shared ARC controller or
shared namespaces (`deploy_arc_controller = false`).
