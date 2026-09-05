# great-falls-tool-bus-infra Agent Guidance

This repository is the public, consumer-owned Great-Falls-Tool-Bus (GFTB)
overlay and the designated ownership home for GFTB's future signed immutable
`OwnerInstallation/v1`, `TenantOverlay/v1`, cumulative consumer
`RevocationSet/v1`, and `OwnerOverlayRevision/v1` instances. Those instances
and an installed controller catalog do not exist in this tree yet. The legacy
ARC declarations that remain are explicitly bounded state-continuity surfaces,
not v4 enrollment authority. GloriousFlywheel core owns the types and verifier,
never GFTB instances. Provider topology is opaque to the v4 interface.

Hard rules:

- do not commit secrets, `.env` files, kubeconfigs, private keys, or backend
  credentials
- keep the live tree current: delete superseded or historical docs, scripts,
  JSON, workflows, and stacks; use Git history and the changelog for recovery.
  Retain only live declarations and explicitly labelled state-continuity HOLDs
  whose external state still requires readback or a reviewed retirement plan
- do not add producer-owned consumer rows, callback/writeback paths, direct
  provider endpoints, node or storage placement, runner labels, or ARC scale
  sets to the v4 overlay
- do not add a local, hosted-runner, cache-only, unauthenticated, v1-token,
  profile, or direct-endpoint fallback. Missing v4 authority fails closed
- application repositories declare exact actions; the REAPI action is the
  unit of work. A GitHub runner may be a thin edge, never the compute or
  scheduling abstraction
- the legacy ARC and provider-shaped declarations still present in this tree
  are retirement inventory, not v4 enrollment authority. Do not extend them
- keep reusable OpenTofu modules, runner images, and product docs in
  `tinyland-inc/GloriousFlywheel`
- this overlay owns the GFTB edge/DNS **apply plane**
  (`tofu/stacks/edge/`, `docs/runbooks/edge-token-and-zones.md`) and the GFTB
  tenant sops lane (`secrets/`, repo-root `.sops.yaml`); the declarations
  SSOT is the public site repo's `tofu/{dns,mail}-intent/`, reconciled
  against the newer `docs/mvp-decision-packet.md` row (g) REVISED + REV-2
- this overlay owns the GFTB **GF v4 dispatch-edge apply plane**
  (`tofu/stacks/gf-v4-dispatch/`, `.github/workflows/gf-v4-dispatch.yml`,
  `docs/runbooks/gf-v4-dispatch-edge.md`; TIN-2611, operator ruling
  2026-09-05 RULING 3). It consumes the GloriousFlywheel root module
  `tofu/stacks/arc-owner-overlay-release` at the v4 dispatch role pin through
  the eight module inputs in the tfvars and the `dispatch_edge` record in
  `config/organization.yaml`; every other identity is module-derived. It is
  consumer demand, not the legacy ARC scale set, and never re-homes into GF
  core or `tinyland-inc/tinyland-infra`
- never re-home GFTB apply-plane content into `tinyland-inc/blahaj`.
  Blahaj is the house's logically replaceable IaC layer (reference
  backend, "never a required dependency"); consumer overlays live with
  the consumer org, the same no-re-homing doctrine that governs runner
  attach (TIN-2360 row c, amended 2026-07-02)
- Cloudflare/DreamHost credentials by NAME only (`secrets/README.md`);
  the DreamHost API is never used for registration-NS mutation, and no
  agent session mutates Cloudflare or DreamHost (applies are
  operator-gated)

## Remote-only execution (operator ruling 2026-09-01)

Heavy toolchain execution (tofu, kubectl/kustomize, gitleaks, actionlint,
bazelisk — anything that launches a build or validation toolchain) is
remote-only on this estate. Guarded Justfile recipes refuse locally via
`scripts/remote-only-guard.sh` (`REFUSE` to stderr, exit 3, never
warn-and-continue) and currently pass only on the protected self-hosted CI
edge (`GITHUB_ACTIONS=true` and `RUNNER_ENVIRONMENT` not `github-hosted`). That
ARC edge is continuity, not the v4 compute abstraction or proof. The v4 target
is fail-closed and action-granular: the image-custodied client sends the named
ActionPlan action to REAPI; missing authority does not enable local execution.
There is no override environment variable; the only non-CI pass is a baked
`(lane, recipe)` allowlist inside the guard script, which is empty in this
repository.

Until the v4 instance/catalog rung exists, source verification runs through the
protected CI edge; that is source evidence only, not remote-execution or
enrollment evidence.

Ratified attended exceptions (unguarded by design):

- the ARC tofu ceremony (`arc-init` / `arc-plan` / `arc-plan-show` /
  `arc-plan-scope-check` / `arc-apply` / `arc-capacity-readback` /
  `arc-enrollment-plan` / `arc-app-secret-apply`, `arc-validate`,
  `enrollment-preflight*`, and their `_arc-*` / `_reviewed-*` /
  `_operator-apply-confirm` helpers) — confirm-gated, no CI caller,
  bound to the current `Justfile` and
  `tofu/stacks/arc-runners/great-falls-tool-bus.tfvars` state-continuity
  surface; it has no v4 authority
- the web-release ceremony (`web-release-*` and helpers; TIN-3899 /
  decisions/0016) — attended-operator-only, unreachable from every CI
  workflow by design
- the attended operator lanes: `edge-zones-lock`, `form-altcha-secret-apply`,
  `list-member-add`,
  `listsync-stack-server-dry-run` / `listsync-stack-apply`,
  and read-only `web-stack-health`
- the GF v4 dispatch App Secret ceremony (`gf-v4-dispatch-app-secret-apply`
  and its `_gf-v4-dispatch-core-contract` / `_gf-v4-dispatch-core-signature`
  helpers; TIN-2611 ceremony 0d row 4) — confirm-gated, signature-verified,
  no CI caller, receipted in the ARC family of
  `scripts/validate-public-operator-surface.py`. Every other
  `gf-v4-dispatch-*` recipe is hosted-only and guarded
- `web-stack-validate` — deliberately unguarded: it is the receipt-pinned
  web-release validation callee, and the reviewed `web-release-render`
  invokes it under `env -i`, which strips `GITHUB_ACTIONS`; a guard there
  would break the ratified attended ceremony while every recipe-level
  entrypoint that reaches it is already guarded

`just check` locally now refuses at its `check-hosted` dependency; run
`just arc-validate` for the attended portion. The local-only history-mode
gitleaks recipe (`secrets-scan`) is removed — its `gitleaks git` scan now
runs as a step inside `check-hosted` on the hosted runner.
`core-checkout-bazel` (the sole local bazelisk launcher) is removed; the
`//:core_checkout_contract_tests` Bazel targets remain.
