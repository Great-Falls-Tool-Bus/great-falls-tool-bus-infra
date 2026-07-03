# great-falls-tool-bus-infra

Private implementation overlay for the Great-Falls-Tool-Bus (GFTB) GitHub
organization boundary — the third owner overlay on the shared Honey substrate,
after `tinyland-inc/tinyland-infra` and `Jesssullivan/jesssullivan-infra`.

This repository carries owner-specific deployment facts for GFTB org repo
enrollment while reusing the same GloriousFlywheel backend services, runner
types, and caches as the other overlays.

Because GFTB is an organization (not a personal account), ARC registers at the
ORG scope: `github_config_url = https://github.com/Great-Falls-Tool-Bus`. One
scale set serves every repo in the org, so this overlay needs **no** per-repo
`extra_runner_sets` registration anchors — the biggest structural difference
from the personal-account jesssullivan template.

## Current Contract

- Core product repo: `tinyland-inc/GloriousFlywheel`
- ARC registration: `https://github.com/Great-Falls-Tool-Bus` (org-scoped, no
  repo anchors)
- Cluster context: `honey`; shared ARC controller owner: Tinyland overlay
- Workflow labels: shared `tinyland-*` capability labels. ONLY `tinyland-nix`
  is provisioned for this org today (conservative posture); a GFTB workflow
  requesting any other label will queue unpicked.
- Scale set: `great-falls-tool-bus-nix` (ARC registration identity only;
  workflows use `runs-on: tinyland-nix`)
- Shared Nix cache: `http://attic.nix-cache.svc.cluster.local`
- Shared Bazel cache: `grpc://bazel-cache.nix-cache.svc.cluster.local:9092`
- Shared Bazel executor: `grpc://gf-reapi-cell.gf-rbe.svc.cluster.local:8980`
  (documented substrate fact; NOT wired into the primary lane yet — see the
  executor-flip note in the tfvars)
- State: bucket `tofu-state`, key prefix `great-falls-tool-bus-infra`
  (`arc-runners/` and `edge-dns/` state keys)
- Core pin: `7072ce2e0bf9d95db08add94b11123d93cd691a8` — GloriousFlywheel
  `origin/main` HEAD at overlay authoring (2026-07-02). Chosen over the
  template's pin because (a) GFTB depends on contracts that postdate it
  (extra-runner-set executor wiring, consumer registry, token-exchange front
  door) and (b) the template carried four divergent pins across its own files
  — a drift wart. This overlay uses ONE pin everywhere:
  `config/organization.yaml`, `MODULE.bazel`, and both workflow `GF_CORE_REF`s.
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
GFTB edge**: [`tofu/stacks/edge-dns/`](tofu/stacks/edge-dns/README.md)
consumes the public site repo's declare-only intent
(`greatfallstoolbus.org` `tofu/{dns,mail}-intent/`), the tenant sops+age
lane lives under [`secrets/`](secrets/README.md) (distinct GFTB
recipient, row d), and the CF/DreamHost apply steps are
[`docs/edge-apply-runbook.md`](docs/edge-apply-runbook.md). The DNS
cutover chain (TIN-2378 → TIN-2379 → TIN-2380) executes from sessions in
this repo — not from `tinyland-inc/blahaj`, which stays the house's
replaceable IaC layer consumed as a service (`relay.tinyland.dev`, honey
mail stack, ARC controller). Fail-closed default: the stack's `manage_*`
toggles are off (packet row g REVISED + REV-2 — DreamHost stays DNS
authority; only the gated apex may move to CF), so `just edge-plan` is
empty until the operator picks the REV-2 path.

The TIN-2385 realization of that path is
[`tofu/stacks/edge/`](tofu/stacks/edge/README.md): zones added
**console-side** to the house CF account, looked up by name with a
**zone-scoped** token (protected `edge` environment secret
`CLOUDFLARE_API_TOKEN_GFTB_ZONES`, name only), managing the proxied
apex/www records, the REV-2 Access gate, and the `latoolb.us` 301
redirects — no mail records (TIN-2379). Console/registrar steps:
[`docs/runbooks/edge-token-and-zones.md`](docs/runbooks/edge-token-and-zones.md);
CI plan/apply chassis: `.github/workflows/edge-plan.yml` (skip-green
until the token secret exists). The two edge stacks never both apply —
see the stack README's reconciliation rules.

## Mail CR apply plane (TIN-2379)

Tenant-owned mail custom resources live in
[`k8s/mail/latoolb-us-production/`](k8s/mail/latoolb-us-production/).
They consume the namespace grant declared in `tinyland-inc/blahaj`
`deploy/tenants/great-falls-tool-bus/rbac.yaml`; the CR declarations do not
move into Blahaj.

Use `just mail-cr-validate` for offline shape validation and
`just mail-cr-server-dry-run` / `just mail-cr-apply` only with a
namespace-scoped kubeconfig supplied through `GFTB_MAIL_KUBECONFIG`.
The protected CI secret name is `GFTB_MAIL_KUBECONFIG_B64` in the `mail`
environment. See [`docs/mail-cr-apply-runbook.md`](docs/mail-cr-apply-runbook.md).

## Bootstrap (read first)

This overlay's own CI runs on `tinyland-nix`, which for GFTB resolves ONLY
through the scale set this overlay provisions. Until the first
operator-machine `just arc-apply` succeeds, overlay CI jobs queue unpicked.
The FIRST plan and FIRST apply run from the operator machine (kubectl context
`honey`). Runs queued from the initial push are picked up once the listener
registers; re-dispatch if they have expired. See
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
just arc-app-secret-dry-run
just arc-app-secret-apply
just arc-init
just arc-plan
just arc-plan-show
just arc-apply    # operator gate; destroy-checked, ALLOW_ARC_DESTROY-gated
```

`just arc-plan` runs the GloriousFlywheel ARC stack with this repo's
`tofu/stacks/arc-runners/great-falls-tool-bus.tfvars` and backend config.
`just enrollment-preflight` is read-only and reports missing core-read
credentials, ARC GitHub App secrets, live runner-set registration, and recent
workflow blockers before any plan or apply.
`just arc-app-secret-*` writes the configured
`github-app-secret-great-falls-tool-bus` secret into both `arc-systems` and
`arc-runners` by calling the GloriousFlywheel core wrapper; it requires
`GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, and
`GITHUB_APP_PRIVATE_KEY_PATH`.

CI also needs a repository Actions secret named `GF_CORE_DEPLOY_KEY` with read
access to `tinyland-inc/GloriousFlywheel` so the private core repo can be
checked out next to this overlay. Use a read-only deploy key by default and
keep `GF_CORE_READ_TOKEN` only as a least-privilege compatibility fallback.
See [CI Credentials](docs/ci-credentials.md).

ARC runner plan/apply uses `.github/workflows/deploy-arc-runners.yml`
(plan-only on PR/push; apply only via manual `workflow_dispatch` with
`action=apply`). It requires `ARC_RUNNERS_KUBECONFIG_B64`,
`ARC_RUNNERS_RUSTFS_ACCESS_KEY`, and `ARC_RUNNERS_RUSTFS_SECRET_KEY`.

Trusted push validation may also read from and publish warmed Nix outputs into
the shared Attic cache when an `ATTIC_TOKEN` repository secret is present.
Pull-request validation stays read-only.

`just arc-apply` runs a destructive-plan guard backed by OpenTofu's JSON plan
actions. If a recorded state rehome or teardown window intentionally allows
destruction, set `ALLOW_ARC_DESTROY=1` for that one apply.

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
