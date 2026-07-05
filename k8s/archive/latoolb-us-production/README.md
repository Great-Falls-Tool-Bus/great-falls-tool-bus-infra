# `k8s/archive/latoolb-us-production/` — public discuss@ archive route (TIN-2528)

**NOTHING IN THIS DIRECTORY IS APPLIED.** This is a declare-only design packet.
No `kubectl apply`, no `kustomize build | kubectl apply`, no DNS enable has been
run. Merging it changes nothing in any cluster.

## What this is

A second, independent Anubis proof-of-work gate — `anubis-archive` — that
fronts the HyperKitty web tier so the **public** `discuss@latoolb.us` archive
can be exposed over the shared honey-ingress Cloudflare Tunnel. It is a
faithful copy of the proven TIN-2420 forms edge pattern
(`k8s/form/latoolb-us-production/`), renamed so it never collides with the live
`anubis` forms gate in the same namespace.

```
tunnel(cloudflared ns) --8081--> anubis-archive --8000--> mailman-web tier
                                                          (HyperKitty, in the
                                                           mailman-core pod)
```

## Anubis's role here: anti-scrape, NOT authentication

Anubis taxes bulk bots on a surface that is **intentionally public to humans**.
It is not the privacy control. The privacy control is the per-list
`archive_policy` in Mailman core (`keyholders@` = `private`, `discuss@` =
`public`), which HyperKitty enforces for anonymous users. One HyperKitty
instance serves **both** lists path-based at the same host, so exposing this
route exposes the web tier that also serves the private `keyholders@` archive.
That is why the packet's **privacy pre-flight is a hard go-live gate**.

## The tunnel route is dashboard-managed (NOT in git)

The honey-ingress Cloudflare Tunnel is **token-managed**: the public-hostname →
`anubis-archive:8081` ingress map lives in the Cloudflare zero-trust
dashboard/API, **not** in this repo or any ConfigMap. There is no tunnel-route
resource here by design (same posture as the forms route; see
`k8s/form/.../service-anubis.yaml` and `docs/runbooks/form-intake.md`).

## Files

| File | Purpose |
| --- | --- |
| `deployment-anubis-archive.yaml` | The PoW gate. Image digest-pinned; `TARGET=http://mailman-web:8080`. |
| `service-anubis-archive.yaml` | ClusterIP :8081 the tunnel targets. |
| `configmap-anubis-policy.yaml` | Bot policy: browsers CHALLENGEd, crawlers allowlisted, mbox `/export/` CHALLENGEd to block bulk pulls. |
| `networkpolicy.yaml` | cloudflared ns → `anubis-archive:8081`; `anubis-archive` → `mailman-core:8000`; plus an additive reciprocal admission on the web tier. |
| `kustomization.yaml` | Overlay wiring + house labels. |

## Before anything is applied

See `docs/discuss-archive-packet.md` for the full decision packet and the
ordered, operator-gated go-live checklist. In short, all three must hold and
none is performed here: (1) the privacy pre-flight passes, (2) the Cloudflare
tunnel public-hostname route is added dashboard-side, (3)
`var.archives_dns_enabled` flips true in `tofu/stacks/edge` and a live
round-trip smoke passes.
