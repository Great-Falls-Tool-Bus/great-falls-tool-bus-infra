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
- Self-hosted workflow labels: shared `tinyland-*` capability labels. ONLY
  `tinyland-nix` is provisioned for this org today; the public repository's
  secret-free `validate` job runs on GitHub-hosted infrastructure instead.
- Scale set: `great-falls-tool-bus-nix` (ARC registration identity only;
  workflows use `runs-on: tinyland-nix`)
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
  non-ARC workflow consumers share this implementation pin. The ARC runner and
  OIDC profile surfaces retain their existing
  `df510574d17b85e7f15470caf3574fcabc4768f1` role pin; pin convergence is a
  separate adoption change, not part of the source-checkout repair.
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

Secret-free pull-request validation runs on a GitHub-hosted runner and does not
depend on ARC admission. Cluster plans and applies remain operator-local; the
first ARC plan and apply run from the operator machine (kubectl context
`honey`). See
[docs/implementation-overlay.md](docs/implementation-overlay.md) for the
ordered runbook.

## Operator Flow

ARC plan/apply is an attended, operator-local operation. It must start from a
clean, signed checkout of the current canonical `main` and the clean, signed
role-specific GloriousFlywheel checkout at
`df510574d17b85e7f15470caf3574fcabc4768f1`:

```bash
export GF_CORE_PATH=/operator/path/GloriousFlywheel-implementation-2281
export GF_ARC_CORE_PATH=/operator/path/GloriousFlywheel-arc-df510
export GF_ARC_CORE_CI_PATH=path:/operator/path/GloriousFlywheel-arc-df510#ci
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

Hosted `validate` is self-contained and does not fetch the private
`tinyland-inc/GloriousFlywheel` repository. Source-dependent ARC module
validation remains operator-local against an exact reviewed checkout. The
legacy self-hosted workflow declarations retain exact pins but are not the
required hosted validation authority; see [CI Credentials](docs/ci-credentials.md).

There is no ARC plan/apply workflow and no repository ARC kubeconfig. The
guarded Just recipes, an external operator-owned mode-0600 kubeconfig, and
runtime RustFS credentials are the only ARC state-mutation path.

`just arc-apply` runs an exact plan-scope guard backed by OpenTofu's JSON plan
actions. The current carrier accepts only one in-place `gh_nix` Helm update;
other updates, creates, deletes, and replacements refuse until a separate
reviewed contract changes the allowlist.

The ARC S3 backend has no remote state lock. Hold an exclusive quiet window
from before `arc-plan` through post-apply readback: no concurrent operator and
no workflow may plan or mutate the same ARC state. Supply
`GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive` as a one-shot value on each plan, apply,
and readback command only after checking that condition. The normal promoted
readback passes only when canonical state and the live scale set both report
8Gi/16Gi, the listener is one Ready zero-restart pod, and a refreshed plan is empty. If a
localhost RustFS port-forward is lost after cluster mutation may have begun but
before state is written, stop; the apply-attempt marker prevents blind reuse.
Restore connectivity and reconcile the ambiguous attempt directly with
`GFTB_ARC_READBACK_MODE=reconcile GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive just
arc-capacity-readback`. Reconciliation succeeds only for matching state/live
4/8 GiB plus the exact pending 8/16 GiB plan, or matching promoted 8/16 GiB plus
an empty refreshed plan. It consumes the attempted plan bundle; only the
pre-change outcome permits creating and reviewing a fresh plan.

## Boundary

This overlay targets the same Honey backend and cache substrate as the other
overlays. That is an owner/auth boundary. It is not a new runner product and
it does not justify labels such as `gftb-nix` or `great-falls-*` workflow
labels.

Because all overlays attach to the same physical `arc-runners` namespace, this
overlay uses owner-distinct internal Helm release and ARC `runnerScaleSetName`
values (`great-falls-tool-bus-*`) while preserving the shared `tinyland-*`
runner labels. The GFTB overlay does not deploy the shared ARC controller or
shared namespaces (`deploy_arc_controller = false`).
