# great-falls-tool-bus-infra Agent Guidance

This repository is the private Great-Falls-Tool-Bus (GFTB) organization
implementation overlay for GloriousFlywheel.

Hard rules:

- do not commit secrets, `.env` files, kubeconfigs, private keys, or backend
  credentials
- do not introduce repo-specific or org-identity runner labels
- keep runner labels capability-shaped and aligned with GloriousFlywheel;
  workflows request shared `tinyland-*` labels only
- ARC registration for this org is org-scoped
  (`https://github.com/Great-Falls-Tool-Bus`); do not add repo-scoped
  registration anchors — org-level registration already reaches every GFTB
  repo, so the personal-account anchor pattern does not apply here
- keep the capacity posture conservative (nix lane only,
  `nix_max_runners = 4`, no warm pool, docker/dind off) unless an explicit
  operator decision raises it; the honey/sting pod budget is the scarce
  resource (TIN-2165/TIN-2234)
- keep reusable OpenTofu modules, runner images, and product docs in
  `tinyland-inc/GloriousFlywheel`
- this overlay owns the GFTB edge/DNS **apply plane**
  (`tofu/stacks/edge-dns/`, `docs/edge-apply-runbook.md`) and the GFTB
  tenant sops lane (`secrets/`, repo-root `.sops.yaml`); the declarations
  SSOT is the public site repo's `tofu/{dns,mail}-intent/`, reconciled
  against the newer `docs/mvp-decision-packet.md` row (g) REVISED + REV-2
- never re-home GFTB apply-plane content into `tinyland-inc/blahaj` —
  blahaj is the house's logically replaceable IaC layer (reference
  backend, "never a required dependency"); consumer overlays live with
  the consumer org, the same no-re-homing doctrine that governs runner
  attach (TIN-2360 row c, amended 2026-07-02)
- Cloudflare/DreamHost credentials by NAME only (`secrets/README.md`);
  the DreamHost API is never used for registration-NS mutation, and no
  agent session mutates Cloudflare or DreamHost — applies are
  operator-gated
