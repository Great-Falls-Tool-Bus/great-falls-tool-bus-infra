# `k8s/archive/latoolb-us-production/` — public discuss@ archive route (TIN-2528)

**THIS STACK IS LIVE.** The `anubis-archive` PoW gate is applied and running in
`latoolb-us-production`, and the public `discuss@` archive is served over the
honey-ingress Cloudflare Tunnel at `lists.latoolb.us` (real challenges solved,
tunnel routed). These manifests are the declared source of truth for that live
route. Changes here are NOT auto-applied on merge: apply is a manual
`workflow_dispatch` (`action=apply`) on `.github/workflows/archive-stack.yml`
into the protected `mail` environment (i.e. `just archive-stack-apply`), which
runs the offline validate plus a server dry-run first. PR and push runs are
offline validation only. Do not trust any leftover "nothing is applied" wording
in this tree over this note.

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
| `configmap-anubis-policy.yaml` | Bot policy: browsers CHALLENGEd, crawlers allowlisted, mbox `/export/` CHALLENGEd to block bulk pulls, discuss@ list overview + thread permalinks + `/static/*` ALLOWed (read-path exemption, TIN-2559) scoped away from keyholders@. |
| `networkpolicy.yaml` | cloudflared ns → `anubis-archive:8081`; `anubis-archive` → `mailman-core:8000`; plus an additive reciprocal admission on the web tier. |
| `kustomization.yaml` | Overlay wiring + house labels. |

## Go-live gates (satisfied)

See `docs/discuss-archive-packet.md` for the full decision packet and the
ordered, operator-gated go-live checklist. Go-live required all three, which now
hold: (1) the privacy pre-flight passed, (2) the Cloudflare tunnel
public-hostname route was added dashboard-side, (3) the archive DNS is enabled
(`var.archives_dns_enabled` in `tofu/stacks/edge`) and a live round-trip smoke
passed. Re-verify these before any change that could widen exposure.
