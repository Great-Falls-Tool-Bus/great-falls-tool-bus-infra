# great-falls-tool-bus-infra

Implementation overlay for the Great-Falls-Tool-Bus (GFTB) GitHub
organization boundary, the third owner overlay on the shared Honey substrate.

This repository carries owner-specific deployment facts for GFTB org repo
enrollment while reusing the same GloriousFlywheel backend services, runner
types, and caches as the other overlays.

Because GFTB is an organization (not a personal account), ARC registers at the
ORG scope: `github_config_url = https://github.com/Great-Falls-Tool-Bus`.
Registration stays org-wide, while the non-Default owner group admits exact
private repositories. This overlay needs no repo-scoped `extra_runner_sets`
registration anchors.

## Architecture

Grounded mermaid diagrams (mail flow, network/ports, planes, Bazel/GF) live in
[`docs/architecture/diagrams.md`](docs/architecture/diagrams.md).

## Current Contract

- Core product repo: `tinyland-inc/GloriousFlywheel`
- ARC registration: `https://github.com/Great-Falls-Tool-Bus` (org-scoped, no
  repo anchors)
- Desired runner group: `great-falls-tool-bus-infra`, selected/private-only,
  admitting only repository id `1286829099`. An attended admin census must
  still determine whether that group already exists.
- Cluster context: `honey`; shared ARC controller owner: Tinyland overlay
- Workflow labels: shared `tinyland-*` capability labels. ONLY `tinyland-nix`
  is provisioned for this org today (conservative posture); a GFTB workflow
  requesting any other label will queue unpicked.
- Live compatibility scale set: `great-falls-tool-bus-nix` in shared namespace
  `arc-runners`, currently bound to `Default` at `min 0 / max 4`. This branch
  stages the future group-plus-`tinyland-nix` selector but does not rebind or
  replace that release. Its job payload selects Sting; the legacy listener's
  Bumble hostname pin is retained state drift, not target compute placement.
- Shared Nix cache: `http://attic.nix-cache.svc.cluster.local`
- Legacy Bazel cache: `grpc://bazel-cache.nix-cache.svc.cluster.local:9092`
  (unauthenticated compatibility only, not the owner-plane product default)
- GF cache/executor front door:
  `grpc://gf-reapi-cell.gf-rbe.svc.cluster.local:8980`. The live compatibility
  release carries the token-exchange/front-door environment. The released
  owner root cannot yet preserve that typed attachment, so migration is held.
- State: bucket `tofu-state`, key prefix `great-falls-tool-bus-infra`
  (`arc-runners/` and live `edge/` state keys; `edge-dns/` is a
  superseded fail-closed reference key)
- Validation release: signed tag `v0.3.0`, exact commit
  `f26b541d1d7600d56b2e78c87038415fa06b3622`. CI checks out that private
  release with the overlay's read-only deploy key, verifies `HEAD`, and uses
  the checked-out local `#ci` devshell. The root Bazel contract test overrides
  `attic-iac` to that verified checkout instead of fetching it again. The
  release is not owner-plane activation authority: it predates the current
  storage-only and authenticated-front-door contract.
- Capacity posture: preserve the live compatibility lane at `min 0 / max 4`.
  A dedicated owner Nix plane starts at `min 0 / max 0` after a suitable signed
  GF release exists; nonzero readiness is separate.

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

This branch stages CI selectors for the exact GFTB owner group plus
`tinyland-nix`. It must remain unmerged while the repository is public, group
existence is unproved, and no authenticated owner-plane release exists.
Merging early would park the repository; Default and hosted fallbacks remain
invalid. See
[docs/implementation-overlay.md](docs/implementation-overlay.md) for the
ordered runbook.

## Operator Flow

Use this overlay from a side-by-side checkout with GloriousFlywheel:

```bash
export GF_CORE_PATH=../GloriousFlywheel   # already the default here (the
                                          # template's ../GloriousFlywheel-infra-overlays
                                          # dead name is fixed in this overlay)
just check
just enrollment-preflight
just runner-group-test      # backend-disabled/mock source proof only
just flywheel-cache-proof   # live evidence only on admitted Actions capacity
```

`just enrollment-preflight` is read-only and reports ARC GitHub App secrets,
live runner-set registration, and recent workflow blockers.
`just core-checkout` is this overlay's fail-closed source-authority check.

CI checks out the private `tinyland-inc/GloriousFlywheel` signed release at the
exact declared commit using `GF_CORE_DEPLOY_KEY`, a read-only key dedicated to
this overlay. The key is not the ARC registration credential and is never
persisted. See [CI Credentials](docs/ci-credentials.md).

`.github/workflows/deploy-arc-runners.yml` remains a legacy-state maintenance
surface for the adopted shared-namespace release. It is not the owner-plane
activation path and must not be used to bind the new group. The future owner
plane requires separate bootstrap/release state, identity, credential, and
saved-plan evidence from a newer signed GF release.

Trusted push validation may also read from and publish warmed Nix outputs into
the shared Attic cache when an `ATTIC_TOKEN` repository secret is present.
Pull-request validation stays read-only.

## Boundary

This overlay targets the same Honey backend and cache substrate as the other
overlays. That is an owner/auth boundary. It is not a new runner product and
it does not justify labels such as `gftb-nix` or `great-falls-*` workflow
labels.

The current release still occupies shared namespace `arc-runners`; that is
legacy adoption evidence, not the target architecture. The target owner Nix
plane uses a dedicated namespace and per-plane credential while preserving
shared `tinyland-*` capability labels and the shared ARC controller. This
overlay never turns Bumble's storage role into runner compute placement.
