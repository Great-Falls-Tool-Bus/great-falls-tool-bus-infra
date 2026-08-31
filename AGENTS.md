# great-falls-tool-bus-infra Agent Guidance

This repository is the public Great-Falls-Tool-Bus (GFTB) organization
implementation overlay for GloriousFlywheel. The required `validate` workflow
is secret-free and, per the 2026-08-19 operator ruling (TIN-3914), runs on the
GF cache-fronted ARC fleet -- GitHub-hosted runners are not permitted anywhere
in this org. The other self-hosted workflows hold one repository-scoped,
read-only source-checkout credential (`GF_CORE_DEPLOY_KEY`, TIN-4015,
2026-08-22: GloriousFlywheel went private and this repository's own
`validate-core-checkout.py` enforces that it is the only credential any core
checkout may carry) -- see docs/ci-credentials.md. ARC runtime mutation
requires the version-pinned protected canonical-main planner, exact saved-plan
executor, and independent observer/readback carrier. Kubernetes, Cloudflare,
and DreamHost credentials remain outside this source repository; the one
source-read credential is not plan, apply, or evidence authority. TIN-4072
remains source-only until that protected carrier exists.

Hard rules:

- do not commit secrets, `.env` files, kubeconfigs, private keys, or backend
  credentials
- keep the live tree current: delete superseded or historical docs, scripts,
  JSON, workflows, and stacks; use Git history and the changelog for recovery.
  Retain only live declarations and explicitly labelled state-continuity HOLDs
  whose external state still requires readback or a reviewed retirement plan
- do not introduce repo-specific or org-identity runner labels
- keep runner labels capability-shaped and aligned with GloriousFlywheel;
  workflows request shared `tinyland-*` labels only. No workflow in this
  repository may name a GitHub-hosted label (`ubuntu-*`, `macos-*`,
  `windows-*`) in `runs-on:` (TIN-3914). The `check-hosted` Just recipe keeps
  its name for compatibility; it now means "the checks CI runs", not "the
  checks a GitHub-hosted runner runs"
- ADMISSION HOLD RESOLVED (PR #128, operator ruling 2026-08-22, TIN-3914):
  this repository joined the `great-falls-tool-bus-infra` runner group's
  roster (see the roster rule below), so the `validate` workflow may request
  `tinyland-nix`. `validate` is the single required status check on `main`
  and, unlike every other self-hosted workflow here, runs unfiltered on
  every `pull_request` with no trusted-event gate (by design — a required
  check must run on every PR); its compensating control is staying
  secret-free rather than event-gated. That is a standing invariant, not a
  one-time review note: any future change to `validate.yml` that adds a
  credential or a protected `environment:` would need its own review against
  this exception
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
  sets at GitHub's `Default` group. Public repository admission
  (`allows_public_repositories: true`) is accepted by operator ruling
  2026-08-18 (TIN-3902) so the public `greatfallstoolbus.org` roster entry is
  effective; TIN-3209's cross-tenant concern is acknowledged and tracked
  there. Admission stays `visibility: selected` — this repository itself
  remains excluded. With public admission on, the roster is the ONLY control
  keeping this repository out (the public-repository flag is no longer a
  second lock), so adding id 1286829099 is a one-line edit and must stay an
  explicit operator decision; `just runner-group-contract` fails on that id
  unless an `infra_repo_admission_ruling:` field records the decision
- keep `config/organization.yaml` `runner_contract.runner_group` and the ARC
  tfvars `runner_group` / `runner_group_policy` in agreement; the
  GloriousFlywheel module never reads the roster, so
  `scripts/validate-runner-group-contract.py` (via `just check-hosted`) is the
  only thing holding the two halves of the admission boundary together
- keep the capacity posture conservative (nix lane only,
  `nix_max_runners = 1`, no warm pool, docker/dind off) unless an explicit
  operator decision raises it; TIN-4072 binds that first-proof width to the
  Sting 64/32/32 GiB generic-ephemeral package for `/nix`, `_work`, and
  `.cache`
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
