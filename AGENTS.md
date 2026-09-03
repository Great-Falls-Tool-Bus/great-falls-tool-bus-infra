# great-falls-tool-bus-infra Agent Guidance

This repository is the public, consumer-owned Great-Falls-Tool-Bus (GFTB)
overlay for GloriousFlywheel v4. It is the only ownership home for GFTB's
signed immutable
`OwnerInstallation/v1`, `TenantOverlay/v1`, cumulative consumer
`RevocationSet/v1`, and `OwnerOverlayRevision/v1` instances. GloriousFlywheel
core owns their types and verifier, never their instances. Provider topology
is opaque to this repository.

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
warn-and-continue) and pass only on sanctioned hosted runners
(`GITHUB_ACTIONS=true` and `RUNNER_ENVIRONMENT` not `github-hosted` — the GF
admission shell, `tinyland-nix`/ARC). GF v4 is fail-closed with no
local-execution fallback; the REAPI action, not the runner, is the unit of
compute (R243). There is no override environment variable; the only non-CI
pass is a baked `(lane, recipe)` allowlist inside the guard script, which is
empty in this repository.

The verification route is: push the branch and read hosted CI — `gh pr
checks`, `gh run view`, `gh run watch`.

Ratified attended exceptions (unguarded by design):

- the ARC tofu ceremony (`arc-init` / `arc-plan` / `arc-plan-show` /
  `arc-plan-scope-check` / `arc-apply` / `arc-capacity-readback` /
  `arc-enrollment-plan` / `arc-app-secret-apply`, `arc-validate`,
  `enrollment-preflight*`, and their `_arc-*` / `_reviewed-*` /
  `_operator-apply-confirm` helpers) — confirm-gated, no CI caller,
  ratified per docs/runbooks and the implementation overlay
- the web-release ceremony (`web-release-*` and helpers; TIN-3899 /
  decisions/0016) — attended-operator-only, unreachable from every CI
  workflow by design
- the attended operator lanes: `edge-zones-lock`, `form-altcha-secret-apply`,
  `list-member-add`,
  `listsync-stack-server-dry-run` / `listsync-stack-apply`,
  `web-stack-health`, and the interlock-dead legacy carrier
  (`web-stack-server-dry-run` / `_web-stack-promotion-interlock` /
  `web-stack-apply`)
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
