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

## Validate (parse-only; never applies)

```bash
just web-stack-validate     # invariant checks + `kubectl kustomize` render
just web-stack-render       # print the rendered manifests (still applies nothing)
```

There is intentionally **no** `web-stack-apply` recipe: applying this skeleton is
not a supported operation. A cutover replaces the placeholder pin, creates the
namespace, flips `replicas`, and adds the tunnel route — all operator-gated, all
authorized by a superseding hosting ADR, none of it in this change.
