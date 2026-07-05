# Reaper / PR-env lane — PARKED note (TIN-2541)

> **Status: PARKED, not adopted. Nothing wired. No live token.** ADR
> [`docs/decisions/0001-pr-gated-ephemeral-preview-deploys.md`](../../docs/decisions/0001-pr-gated-ephemeral-preview-deploys.md)
> recommends **Cloudflare Pages managed previews** (Option A) and parks this
> on-cluster reaper (Option C) behind a live pod-headroom probe + TIN-991 route
> authority. This note records the parked contract; it authorizes nothing.

## Why parked (not built)

An on-cluster per-PR reaper inherits all three ADR-0003 blockers unchanged and
adds a fourth (redundancy):

1. **Pod cap.** Honey sits at ~103–104/110 pods with a deliberately conservative
   posture (nix max 4, no warm pool). ~6 pods of headroom. Each preview costs
   ≥ 1 web pod; N concurrent per-PR stacks **physically cannot fit**.
2. **Tunnel route is out-of-band.** Every `pr-<n>` hostname would be a manual
   Cloudflare dashboard action (TIN-991); there is no per-PR route automation.
3. **No preview-namespace precedent** on-cluster; net-new namespace + route +
   pods, with a sting-node SPOF in the reaper control path.
4. **Redundant.** CF Pages already gives Access-gated previews at zero pod cost.

The house reaper itself lives in `tinyland-inc/blahaj` and its own docs mark it
**legacy/transitional — do not clone** (TIN-2023/TIN-2027 successor contract).
GFTB has no reaper of its own, so this is not "reuse ours."

## The parked contract (declared, not wired)

Modeled on the blahaj/MI reaper lifecycle. The machine-readable form is
[`../../tofu/intent/great-falls-tool-bus/pr-env-lanes.schema.json`](../../tofu/intent/great-falls-tool-bus/pr-env-lanes.schema.json)
(`enabled: false`).

- **Per-PR namespace:** `greatfallstoolbus-org-pr-<n>` (regex-guarded; the
  production namespace `greatfallstoolbus-org-production` is structurally
  excluded from every reaper selector).
- **Label contract** stamped on each lane namespace:
  `app.tinyland.dev/lifecycle=pr-ephemeral`,
  `app.tinyland.dev/auto-expire=true`,
  `app.tinyland.dev/expires-epoch=<unix-ts>`,
  `app.tinyland.dev/pr-number=<n>`.
- **Three-leg defense-in-depth teardown** (all declared, none wired):
  1. PR-close `repository_dispatch` → delete the lane's workloads (pressure
     relief; frees pod slots without a runner).
  2. Scheduled GitHub Actions TTL reaper (default toggle `PREVIEW_REAPER_ENABLED=false`)
     selecting on the labels; destroys **only** on positive evidence
     (TTL passed **or** PR confirmed closed); `unknown` never destroys; bounded
     by `--max-destroys`.
  3. In-cluster system-critical backstop **CronJob** (`suspend: true` by
     default), runner-independent, tolerating the compute-expansion taint, so
     closed-PR lanes are reaped even when the runner pool saturates — models
     `blahaj:deploy/honey/massageithaca-pr-lane-backstop-reaper.yaml`.
- **Fail-safe:** a single ambiguous PR-state lookup falls back to TTL-only; a
  total GitHub API outage or a missing/placeholder token fails the reaper
  **loud** (never silently green).
- **Secrets:** referenced **by name only** — `github-pr-read-token` (fine-grained
  read-only Pull Requests PAT), `reaper-kubeconfig` (namespace-scoped SA). No
  value is inlined; nothing is stored in this repo.

## Un-parking checklist (future ADR, not this change)

- [ ] Live `kubectl` pod-headroom count proving room for a preview lane class.
- [ ] TIN-991 route authority under IaC so a `pr-<n>` hostname is not a manual
      dashboard op.
- [ ] A superseding ADR authorizing a *bounded* on-cluster preview lane
      (never per-PR-unbounded, given the pod cap).
- [ ] Provision the named secrets in protected environments.

Until all four clear, previews are the managed CF Pages channel and this lane
stays `enabled: false`.
