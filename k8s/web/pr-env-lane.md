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

## Live probe — 2026-07-05 (annotates the blockers; un-parks nothing)

A read-only `kubectl` probe of the honey rke2 cluster re-grounded the blockers
above. This is annotation, **not** a rewrite of ADR 0003 and **not** an un-park:

- **Blocker 1 (pod cap) is now stale.** honey is **138/150** (12 free — the pod
  cap was **expanded to 150**, so the "~103–104/110, ~6 free" figure is
  obsolete), bumble **50/110** (60 free), sting **96/200** (104 free);
  **~176 free cluster-wide**. Room for a bounded preview lane class now exists —
  but adopting one still needs a superseding ADR (the un-park checklist below).
- **Reaper confirmed healthy.** The in-cluster backstop this lane models —
  kube-system CronJob `massageithaca-pr-lane-backstop-reaper` — is **Active**
  (`*/10`, ran ~5m ago, **not** suspended). Live `tinyland-dev-pr-*` lanes carry
  correct **future-dated `expires-epoch` TTLs**; one lane ~80 min past TTL but
  still Active is **within normal operation** (full GH reaper 4h cycle + 6h
  backstop hard-delete grace) — expected latency, **not** a leak.
- **Label/TTL contract matches live.** The label set and `expires-epoch` TTL
  semantics declared below are exactly what the live blahaj reaper
  (`blahaj:deploy/honey/massageithaca-pr-lane-backstop-reaper.yaml`) stamps and
  selects on — so this parked contract is a faithful mirror, not a guess.

Blockers 2 (out-of-band tunnel route / TIN-991) and 3/4 (namespace precedent,
CF-Pages redundancy) are unchanged; the lane stays `enabled: false`.

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
