# great-falls-tool-bus-infra Agent Guidance

This repository is the public Great-Falls-Tool-Bus (GFTB) organization
implementation overlay for GloriousFlywheel. Secret-free validation may run on
GitHub-hosted runners; credentials and apply authority remain operator-owned.

Hard rules:

- do not commit secrets, `.env` files, kubeconfigs, private keys, or backend
  credentials
- keep the live tree current: delete superseded or historical docs, scripts,
  JSON, workflows, and stacks; use Git history and the changelog for recovery.
  Retain only live declarations and explicitly labelled state-continuity HOLDs
  whose external state still requires readback or a reviewed retirement plan
- do not introduce repo-specific or org-identity runner labels
- keep runner labels capability-shaped and aligned with GloriousFlywheel;
  self-hosted workflows request shared `tinyland-*` labels only. The public
  validation workflow uses a GitHub-hosted runner
- ARC registration for this org is org-scoped
  (`https://github.com/Great-Falls-Tool-Bus`); do not add repo-scoped
  registration anchors. Org-scoped registration does not override the
  separately selected GitHub runner-group admission policy
- the scale sets bind to the dedicated `great-falls-tool-bus-infra` GitHub
  runner group (`runner_group` / `runner_group_policy` in the ARC tfvars,
  roster in `config/organization.yaml` `runner_contract.runner_group`,
  TIN-3902). That group name is an owner/tenancy admission identity, NOT a
  runner label and NOT an org-identity label — it does not violate the label
  rule above and must not be removed as if it did. Never re-point these scale
  sets at GitHub's `Default` group, and never admit a public repository to the
  group
- keep the capacity posture conservative (nix lane only,
  `nix_max_runners = 4`, no warm pool, docker/dind off) unless an explicit
  operator decision raises it; the honey/sting pod budget is the scarce
  resource (TIN-2165/TIN-2234)
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
