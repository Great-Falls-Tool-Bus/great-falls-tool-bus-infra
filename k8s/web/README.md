# GFTB on-cluster web serving — DECLARE-ONLY skeleton (TIN-2541)

> **NOTHING IN THIS DIRECTORY IS APPLIED.** This is a plan-only skeleton that
> `kubectl kustomize` renders cleanly (the `just check` guard enforces that) but
> that serves nothing and mutates no cluster, DNS, or route. Every enablement
> axis is fail-closed. Bringing any of it live is an explicit, operator-gated
> action authorized by a *superseding* hosting ADR — not by this stack.

## What this is

A copyable skeleton for serving the GFTB web app **fully on-cluster**, mirroring
the proven MassageIthaca pattern: SvelteKit `adapter-node` → OCI image on GHCR →
K8s `Deployment` behind a `ClusterIP` `Service` → in-cluster `cloudflared` tunnel
edge (no Cloudflare Pages, no Vercel on the serving path). It materializes the
"DECLARE-ONLY skeleton note" of
[`docs/decisions/0001-pr-gated-ephemeral-preview-deploys.md`](../../docs/decisions/0001-pr-gated-ephemeral-preview-deploys.md)
and is grounded in the TIN-2537 research brief
(`docs/research/full-oncluster-web-serving-2026-07.md`, branch
`docs/oncluster-web-research`).

```
visitor -> greatfallstoolbus.org (Cloudflare edge, TLS terminates here)
        -> honey-ingress cloudflared tunnel   [dashboard/token-managed route — NOT in git]
        -> Service greatfallstoolbus-org:80  (ClusterIP)
        -> Deployment greatfallstoolbus-org  (adapter-node, :3000, /health probes)
```

## Files

| File | Role | Fail-closed posture |
|---|---|---|
| `greatfallstoolbus-org-production/deployment.yaml` | adapter-node web Deployment | `replicas: 0`; **placeholder** image (no digest, not on any registry); non-root 1001; read-only rootfs; `/health` probes on :3000 |
| `greatfallstoolbus-org-production/service.yaml` | ClusterIP 80→3000 | internal DNS only; never internet-exposed directly |
| `greatfallstoolbus-org-production/networkpolicy.yaml` | default-deny + explicit allows | ingress only from the `cloudflared` namespace (:3000) and prometheus; egress DNS only |
| `greatfallstoolbus-org-production/kustomization.yaml` | kustomize entrypoint | renders cleanly; creates **no** Namespace |
| `secrets.contract.yaml` | names-only three-plane secrets contract | no values, ever |
| `pr-env-lane.md` | reaper / PR-env lane note | parked (see below) |
| `../../tofu/intent/great-falls-tool-bus/web-oncluster-route.json` | cloudflared route intent | `applied:false`, `dns_enabled:false`, `route_enabled:false` |
| `../../tofu/intent/great-falls-tool-bus/pr-env-lanes.schema.json` | reaper lane contract | `enabled:false`; names-only |

## The three fail-closed axes (why an accidental apply is inert)

1. **`replicas: 0`** — no pod is scheduled from these manifests as-is.
2. **Placeholder image** — `…/greatfallstoolbus.org:PLACEHOLDER-DECLARE-ONLY-NOT-APPLIED`
   is deliberately non-resolvable and carries no digest. The real pin is an
   operator-gated **private-overlay** bump at cutover; the public app repo owns
   the image *build* (ambient `GITHUB_TOKEN`, same-org GHCR) but never the pin.
   `scripts/validate-web-stack.sh` **fails** if this becomes an `@sha256:` digest
   in-tree — the guard keeps the skeleton declare-only.
3. **No namespace** — `greatfallstoolbus-org-production` is not created by this
   stack. Nothing lands until an operator materializes it out of band.

## The tunnel route is dashboard-managed (not in git)

The public path rides the shared **honey-ingress** cloudflared connector
(`blahaj:deploy/honey/retained-cloudflared.yaml`). Its public-hostname routes
are **Cloudflare dashboard / token-managed** (TIN-991 route authority
unfinished); there is **no** route object in this repo and **no** live
`cfargotunnel` UUID inlined. The route intent JSON records the *shape* fail-closed
only. The zone token lives in the protected `edge` environment; the
`TUNNEL_TOKEN` is a live cluster Secret only. See `secrets.contract.yaml`.

## Reaper / PR-env lane: parked

Per-PR ephemeral previews are **parked**, not adopted — ADR 0001 recommends
Cloudflare Pages managed previews instead (already Access-gated, zero pod cost).
The on-cluster reaper contract is recorded fail-closed in
`pr-env-lane.md` + `pr-env-lanes.schema.json` (`enabled:false`) so a future ADR
has a grounded start. The binding blocker is honey's pod cap (~6 pods headroom);
resolving it needs a live headroom probe. **No reaper workflow or CronJob is
committed live** and **no live token is wired** (names only).

## Live probe — 2026-07-05 (honey rke2, read-only kubectl)

A read-only cluster probe re-grounded the feasibility assumptions this skeleton
was parked behind. Nothing below un-parks anything; it records evidence for the
superseding hosting ADR.

- **Headroom (obsoletes ADR 0003's "~6 free").** honey **138/150** (12 free —
  honey was **expanded to a 150 pod cap**, so ADR 0003's "~103–104/110, ~6 free"
  is now faulty), bumble **50/110** (60 free), sting **96/200** (104 free);
  **~176 free pod slots cluster-wide**. A `replicas:2` web Deployment fits
  easily — placed on bumble/sting (honey is tightest).
- **Reaper healthy.** The kube-system CronJob
  `massageithaca-pr-lane-backstop-reaper` is **Active** (`*/10`, ran ~5m ago,
  not suspended). Live `tinyland-dev-pr-*` lanes carry correct future-dated
  `expires-epoch` TTLs; one lane ~80 min past TTL but still Active is **within
  normal operation** (full GH reaper 4h cycle + 6h backstop hard-delete grace) —
  expected latency, **not** a leak. The label/TTL contract in `pr-env-lane.md`
  matches this live reaper.
- **Serving SPOF: none.** 3-node cluster; this overlay specs node-anti-affinity
  and `podAntiAffinity` (hostname spread) and cloudflared runs `replicas:2`, so
  node loss reschedules. The "sting SPOF" ADR 0003 cites is **CI-runner**
  concentration (all ARC/nix runners on sting) — a deploy-velocity concern,
  known/accepted/mitigated and already borne by the live MI/mail/form stacks;
  **not** a serving risk.
- **Site-level tradeoff (the honest one).** The whole cluster is **one physical
  on-prem location** (a single `/24`: honey 192.168.70.10, bumble .11,
  sting .12). That is the real availability tradeoff vs a global CDN. MI already
  accepts it for production; Cloudflare's proxy fronts+caches the origin; a warm
  **CF-Pages standby** (ties to ADR 0007) is the named mitigation.

ADR 0003 stays valid **only** as a static-production-era snapshot; its
pod-cap ("~110/~6-free"), "no house precedent" (MI now serves production fully
on-cluster: adapter-node → image → K8s → tunnel, with Vercel+Neon+Pages retired),
and "TIN-991 / sting SPOF" premises are retired above — routes are
dashboard-managed *process* (not infeasibility; MI proves it) and the sting SPOF
is CI-runner, not serving.

## Deploy path (reference — NOT wired by this change)

At cutover the intended path reuses MI's proven machinery unchanged; this
skeleton adds **no new deploy tooling**. Two supported routes:

1. **tofu CI/CD gitops (house pattern).** The GFTB overlay
   (`great-falls-tool-bus-infra`) is applied via `tinyland-inc/ci-templates`
   reusable workflows, following the MassageIthaca
   `repository_dispatch` → **blahaj `tofu-apply`** → **reaper** flow. GFTB
   on-cluster inherits MI's apply / promotion / reaper path verbatim — the app
   repo builds+pushes the image (ambient `GITHUB_TOKEN`, same-org GHCR) and
   dispatches; blahaj applies the overlay; the backstop reaper (above) governs
   any ephemeral lanes. Nothing here is wired: this is the reference shape only.
2. **Direct operator `kubectl`/`tofu`.** An authorized operator applies the
   overlay out of band.

Either route is **operator-gated and authorized by a superseding hosting ADR**.
A cutover still replaces the placeholder pin, creates the namespace, flips
`replicas`, and adds the tunnel route — none of which is in this change.

## Validate (parse-only; never applies)

```bash
just web-stack-validate     # invariant checks + `kubectl kustomize` render
just web-stack-render       # print the rendered manifests (still applies nothing)
```

There is intentionally **no** `web-stack-apply` recipe: applying this skeleton is
not a supported operation. A cutover replaces the placeholder pin, creates the
namespace, flips `replicas`, and adds the tunnel route — all operator-gated, all
authorized by a superseding hosting ADR, none of it in this change.
