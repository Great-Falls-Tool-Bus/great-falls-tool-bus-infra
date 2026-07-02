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
