# GFTB discuss@ public-archive decision packet (TIN-2528)

Status: **DESIGN PACKET — DECLARE-ONLY. NOTHING APPLIED.** No `kubectl`, no
`tofu apply`, no DNS enablement. Every new toggle defaults false / fail-closed.
This branch is a branch + draft PR only. Go-live is gated on the **privacy
pre-flight** below, which is a hard operator-gated step, not a formality.

Tracking: TIN-2528. References: TIN-2498 (`discuss@` source/transport
reconciliation, in progress), TIN-2493 (mailman-core/web co-location),
TIN-2420 (the forms Anubis edge pattern being reused), TIN-2380 (HyperKitty
archive URL shape / `lists.latoolb.us`), TIN-2378 (apex-gate privacy
constraint).

## 1. Context

GFTB runs **one** GNU Mailman 3 stack in `latoolb-us-production` hosting **two**
lists on the same engine (`docs/runbooks/list-operations.md` §1):

| List | Role | `archive_policy` | Advertised |
| --- | --- | --- | --- |
| `keyholders@latoolb.us` | Private access-gating role list (LIVE 2026-07-04) | `private` | `false` |
| `discuss@latoolb.us` | Public community board (TIN-2498, in progress) | `public` | `true` |

Non-member posts to `keyholders@` are **accepted**, so first-contact access
requests — which carry names, contact details, tool needs, scheduling context
— fan out to every keyholder and land in that list's archive. That archive is
`private` and **must stay that way** (`list-operations.md` §1;
`list-bringup.md` "Archive: private/members-only, or disabled. Never public.").

The ask on this packet: expose the **public** `discuss@` archive to the
internet so the community board is readable without an account, behind an
Anubis proof-of-work gate for anti-scrape, reusing the proven forms edge
pattern. The wrinkle that makes this non-trivial: **one HyperKitty web tier
serves both lists path-based off one host**, so any public exposure of the
archive host is also an exposure of the tier that serves the private
`keyholders@` archive. HyperKitty is supposed to enforce per-list visibility
for anonymous users — this packet's job is to make that enforcement a
**verified precondition**, not an assumption.

## 2. Reuse the forms pattern (TIN-2420 Path B), don't reinvent it

The contact-form route already proved the exact edge shape we need
(`k8s/form/latoolb-us-production/`, `docs/runbooks/form-intake.md`,
`docs/architecture/diagrams.md`):

```
cloudflared (ns cloudflared, non-host-networked, flannel pod IPs)
   --8081--> Anubis PoW gate (only pod the tunnel reaches)
      --backend--> in-cluster service
```

We replicate it verbatim for the archive, changing only the backend target and
the names so the two instances never collide:

- `anubis-archive` Deployment/Service/ConfigMap — a **second, independent**
  Anubis instance, same digest-pinned image
  (`ghcr.io/techarohq/anubis:v1.13.0@sha256:7fd4c947…`), same env-var config
  convention (`BIND=:8081`, `DIFFICULTY=4`, `POLICY_FNAME`), `TARGET=
  http://mailman-web:8080`.
- NetworkPolicy legs mirroring the forms netpol's **TUNNEL-SOURCE FINDING**:
  `namespaceSelector` on `kubernetes.io/metadata.name: cloudflared` for the
  ingress leg (no ipBlock/SNAT workaround needed — cloudflared pods carry real
  flannel pod IPs under rke2-canal), egress scoped to the backend only.
- A `lists.latoolb.us` proxied CNAME to the **same** shared honey-ingress
  tunnel cname target (`da3ffda2-…cfargotunnel.com`), gated by a new
  fail-closed variable — the same shape as `var.forms_dns_enabled`.

The **tunnel public-hostname route** (`lists.latoolb.us` →
`anubis-archive:8081`) is **NOT in git**: the honey-ingress tunnel is
token-managed and its ingress map lives in the Cloudflare zero-trust
dashboard/API (`k8s/form/.../service-anubis.yaml`, `form-intake.md` gate 3).
This packet declares no tunnel-route resource by design.

This leg **extends Diagram 5** (edge path) added on branch
`docs/edge-path-diagram` / PR #44. That branch is **not touched here**; when it
lands, the archive leg is a second Anubis box off the same cloudflared source.

### One real difference from the forms stack: the backend port

The forms `anubis` egresses to `form-handler:8080`, whose Service port and
container targetPort are both `8080`. The archive backend is the `mailman-web`
Service (`k8s/list/.../service-mailman-web.yaml`), which is **ClusterIP 8080 →
targetPort 8000** and selects the **mailman-core** pod (the web container is
co-located there, TIN-2493). NetworkPolicy egress evaluates the **post-DNAT**
destination — the real pod IP and container port `8000`, not the Service's
`8080` — so the archive netpol's egress rule targets the `mailman-core`
podSelector on **8000**, even though Anubis dials `http://mailman-web:8080`.
The reciprocal admission on the web tier is declared as an **additive**
NetworkPolicy in the archive stack (`mailman-core-archive-ingress`), so the
list stack's own `networkpolicy.yaml` is not edited by this declare-only
packet. See §7 for the placeholder it implies tightening.

## 3. Hostname choice: `lists.latoolb.us` (recommended) over `archives.latoolb.us`

**Decision: `lists.latoolb.us`.** Rationale, in order of weight:

1. **It is already the documented archive host.** `list-bringup.md`
   "HyperKitty private archive URL shape" (TIN-2380) fixes the archive URL as
   `https://lists.latoolb.us/archives/list/keyholders@latoolb.us/`. Picking
   `archives.` would contradict a URL already written into the runbook and any
   links that follow it.
2. **One host serves the whole engine, not one archive.** HyperKitty routes
   every list path-based under `/archives/list/<list>@latoolb.us/` off a single
   web tier. `discuss@` and `keyholders@` are two paths on the **same** host.
   `lists.` names the engine honestly; `archives.` implies a per-archive host
   that does not exist and would mis-suggest that `discuss@` is isolated from
   `keyholders@` at the host boundary (it is not — see the pre-flight).
3. **Postorius shares the host.** The same web tier serves the Postorius admin
   UI. `lists.` covers "the lists web surface" (archive + list index);
   `archives.` under-describes it.

The honest downside is exactly what forces the pre-flight: `lists.` correctly
signals that this host is the whole lists engine, private archive included.
`archives.` would paper over that — a reason to reject it, not prefer it.

## 4. THE PRIVACY PRE-FLIGHT — a hard go-live gate

> **This is the load-bearing control of the entire packet. Anubis is NOT it
> (see §5). The private `keyholders@` archive is protected by Mailman's
> per-list `archive_policy` and HyperKitty's anonymous-visibility
> enforcement — and go-live is BLOCKED until an operator has VERIFIED that
> enforcement read-only against the live stack.**

Two things must both be true and both must be checked, not assumed:

**(a) `keyholders@` is `private` (or `never`) in Mailman core — the
authoritative source.** `archive_policy` is a Mailman **core** database
attribute (not a repo manifest, not a HyperKitty setting), so it cannot be
asserted from git; it must be read from the running list config. HyperKitty
keeps a *cached copy* of visibility that it syncs from core — after any archive
import that cache can lag (CVE-2021-33038, §6), so verify the live HyperKitty
behavior, not just the core value.

**(b) HyperKitty actually denies anonymous access to the private list —
across every surface, not just the HTML page.** Research finding that changes
the plan: below **HyperKitty 1.3.8** the RSS/Atom **feeds API shipped without
authn/authz and leaked private-list archives** even though the HTML view 403s
(fixed in 1.3.8, MR !362). So the version floor is a **hard gate**:
**HyperKitty must be ≥ 1.3.8.** Additionally, `HYPERKITTY_HIDE_PRIVATE_LISTS`
defaults to `False`, so `keyholders@`'s **name/description** is disclosed on the
archives index to anonymous users (content still 403s); set it `True` if the
list's existence is sensitive.

### The verification command (read-only — describe, do not run)

The HyperKitty web tier binds HTTP on container port **8000** and is
`kubectl port-forward`-able (unlike the mailman **REST** API on 8001, which
binds the pod IP and refuses port-forward — `list-operations.md` §2). An
operator runs, from a machine with read-only `kubectl --context honey`:

```sh
# 1. Forward the web tier locally (read-only; no cluster mutation).
kubectl -n latoolb-us-production port-forward svc/mailman-web 8080:8080 &

# 2. Probe the PRIVATE list as a fully anonymous client across EVERY surface.
#    Every one of these MUST be 403/404/redirect-to-login (NOT 200):
for u in \
  "archives/list/keyholders@latoolb.us/" \
  "archives/list/keyholders@latoolb.us/latest" \
  "archives/list/keyholders@latoolb.us/feed/" \
  "archives/list/keyholders@latoolb.us/export/keyholders@latoolb.us.mbox.gz" \
  "archives/list/keyholders@latoolb.us/search/?q=access" ; do
    printf '%-72s ' "$u"
    curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: lists.latoolb.us' \
      "http://127.0.0.1:8080/$u"
done

# 3. Confirm the PUBLIC list DOES render anonymously (expect 200):
curl -s -o /dev/null -w 'discuss html  %{http_code}\n' -H 'Host: lists.latoolb.us' \
  "http://127.0.0.1:8080/archives/list/discuss@latoolb.us/"

# 4. Confirm the version floor: HyperKitty >= 1.3.8 (the RSS-feed leak fix).
kubectl -n latoolb-us-production exec deploy/mailman-core -c mailman-web -- \
  python -c "import hyperkitty; print(hyperkitty.__version__)"

# 5. Tear down the forward.
kill %1
```

**Pass criteria:** step 2 = all non-200 (403/404/login redirect) on *every*
surface including `feed/`, `export/`, and `search/`; step 3 = 200; step 4 ≥
1.3.8. **Any 200 in step 2, or a version < 1.3.8, is a STOP.** Do not add the
tunnel route and do not flip `var.archives_dns_enabled` until all pass. (The
`Host:` header is set so HyperKitty resolves the site the same way it will
behind the tunnel; adjust the container name in step 4 if the co-located web
container differs from `mailman-web`.)

## 5. Anubis's role: anti-scrape, NOT authentication

Anubis is a proof-of-work **anti-bulk-bot** gate on a surface that is
**intentionally public to humans**. It is not authentication and it is not the
privacy control (§4 is). Its job on this route:

- Tax bulk crawlers / AI scrapers so an open, full-text-searchable archive does
  not become free crawl fodder or a search-cost amplifier.
- Keep the browsing surface behind a browser PoW challenge exactly as founding
  packet row `f` decided (`docs/mvp-decision-packet.md`).

Policy differences from the forms gate (`configmap-anubis-policy.yaml`):

- **No `/api/contact` ALLOW carve-out** — the archive is a pure browsing
  surface with no JSON API caller, so every human-browser request is
  CHALLENGEd.
- **Search-engine crawlers stay ALLOWed** (Googlebot/Bingbot/Qwant): the
  `discuss@` archive is meant to be public and discoverable. Crawlers can never
  reach the private `keyholders@` archive regardless — HyperKitty 403s a
  private list for any anonymous client. An operator who does **not** want the
  public archive indexed flips those three to DENY (and see the robots.txt note
  in §6).
- **`/export/*.mbox(.gz)` is CHALLENGEd for ALL user agents**, ordered before
  the crawler ALLOWs, so even an allowlisted crawler must solve a PoW to bulk-
  pull the mbox — which a headless crawler cannot. This shapes the single
  biggest cost/abuse vector on an open archive.

Note that Anubis does **not** substitute for HyperKitty's own access control:
it front-proxies the *whole* web tier, so a mis-set `keyholders@` policy would
be equally reachable through the gate. That is why §4 gates on HyperKitty
behavior, not on the Anubis policy.

## 6. Django / HyperKitty hardening list (operator, on the mailman-web side)

Anonymous **read** of a `public` list needs no setting — it works out of the
box. The hardening is about closing everything *else* on a now-public tier.
Applied via the maxking image's documented `settings_local.py` hook
(`/opt/mailman/web/settings_local.py`, auto-imported at the end of
`settings.py`) unless noted. This list is **advisory for the operator** — it is
substrate/image config, not part of this repo's declare-only manifests.

1. **Version floor: HyperKitty ≥ 1.3.8** — the RSS/Atom feeds private-list
   leak fix (MR !362). Also picks up the CVE-2021-33038 / -35057 / -35058
   cluster (all fixed ≤ 1.3.8). **Hard gate — verified in the §4 pre-flight.**
2. **`HYPERKITTY_HIDE_PRIVATE_LISTS = True`** — remove `keyholders@` from the
   anonymous archives index so even its name/description is not disclosed
   (default `False` only 403s the *content*).
3. **Disable new-account signup** — set a custom `ACCOUNT_ADAPTER` whose
   `is_open_for_signup()` returns `False`. There is no single env var for this;
   the adapter is the supported way. Anonymous read is unaffected.
4. **Leave all `SOCIALACCOUNT` providers unconfigured** (GitHub/GitLab/Google/
   OpenID) so social self-registration is impossible; keep
   `ACCOUNT_EMAIL_VERIFICATION = "mandatory"` for any residual account flow.
5. **`HYPERKITTY_MBOX_EXPORT = False`** (HyperKitty ≥ 1.3.6) unless anonymous
   mbox download is a required feature — defense in depth behind the Anubis
   export-challenge, since it removes the endpoint entirely.
6. **robots.txt is NOT built in** — HyperKitty removed its shipped robots.txt
   in 1.2.0. If the public archive should be un-indexed, serve `robots.txt`
   at the reverse proxy / a HyperKitty static override; do **not** assume
   HyperKitty emits `noindex`. (The Anubis policy ALLOWs `/robots.txt` to pass
   through, so a served file will reach clients.)
7. **Rate-limit `/search` and `/export`** at the edge — anonymous full-text
   search (Whoosh/Xapian backend) is an unauthenticated, potentially expensive
   query surface.
8. **Baseline Django hygiene (maxking defaults, verify not regressed):**
   `DEBUG = False` (never flip on — leaks tracebacks/settings); a strong unique
   `SECRET_KEY` (not the example value); `ALLOWED_HOSTS` / `SERVE_FROM_DOMAIN`
   set to include `lists.latoolb.us`; the `MAILMAN_ARCHIVER_KEY` /
   `HYPERKITTY_API_KEY` shared secret strong and never passed in a URL
   (CVE-2021-35058).

**Interaction with the Anubis policy (defense in depth):** the archive Anubis
policy ALLOWs feed paths (`*.rss|*.xml|*.atom|*.json`) so legitimate RSS
readers work. On a HyperKitty **< 1.3.8** that ALLOW would pass anonymous feed
requests straight to the vulnerable feeds API and leak `keyholders@`. Because
§4 gates on ≥ 1.3.8 this is safe — but if for any reason the tier ships <
1.3.8, the feed ALLOW rule MUST be changed to CHALLENGE (or the route not
exposed). Belt and suspenders; the version floor is the real fix.

## 7. Resource + topology notes

- **~1 new pod** (`anubis-archive`, `replicas: 1`), requests `25m` CPU / `64Mi`
  memory, limits `500m` / `256Mi` — same envelope as the forms gate. Fits the
  honey pod-cap headroom; no new node, no PVC, no persistent state (Anubis
  auto-generates an ephemeral ed25519 key per start).
- **No new load on mailman-core/-web at rest** — the web tier already runs
  (TIN-2493 co-location). The archive route adds anonymous read/search traffic
  *when exposed*; the search backend (Whoosh/Xapian) is the cost to watch, hence
  the export-challenge (§5) and the `/search` rate-limit advice (§6.7).
- **NetworkPolicy admission:** the list stack's `mailman-core` policy admits
  web-tier `8000` from the house `cloudflared` namespace for the tunnel leg.
  This packet declares the tight reciprocal
  (`mailman-core-archive-ingress`, admits `anubis-archive` pod → `8000`) as an
  additive policy, so the archive PoW gate remains reachable without reopening
  the web tier to every namespace.

## 8. Ordered go-live checklist (OPERATOR-GATED steps marked ⛔)

Nothing below is performed by this packet. Order matters; each gate is
fail-closed.

1. **[declare]** Merge this packet (branch → draft PR → review). Changes
   nothing: `var.archives_dns_enabled` default `false`, no manifests applied.
2. ⛔ **[operator]** Land the `discuss@` list itself (TIN-2498) with
   `archive_policy=public`, `subscription_policy=confirm`, non-member action
   `hold`, `advertised=true` per `list-operations.md` §1.
3. ⛔ **[operator]** Confirm / set HyperKitty hardening §6 items 1–8 on the
   mailman-web tier (version ≥ 1.3.8; hide-private-lists; signup disabled;
   mbox-export off; robots/search rate-limit at edge; Django hygiene).
4. ⛔ **[operator]** Apply the `k8s/archive/...` stack. The list stack already
   admits only the cloudflared namespace for the tunnel leg; the additive
   reciprocal declared here keeps `anubis-archive -> 8000` open.
5. ⛔ **[operator]** Add the Cloudflare tunnel **public-hostname route**
   `lists.latoolb.us` → `anubis-archive:8081` (dashboard/API, out of band).
6. ⛔ **[operator — HARD PRIVACY GATE]** Run the §4 privacy pre-flight
   read-only. **STOP** on any 200 for a `keyholders@` surface or version
   < 1.3.8. Record the evidence (like the list-bringup private-archive
   evidence bar).
7. ⛔ **[operator]** Flip `var.archives_dns_enabled = true`; PR-plan via
   `edge-plan.yml`, then `workflow_dispatch action=apply` (D6 dispatch-apply —
   no direct apply).
8. ⛔ **[operator]** Live round-trip smoke: anonymous `https://lists.latoolb.us/
   archives/list/discuss@latoolb.us/` renders behind the Anubis challenge;
   re-run the §4 private probes against the **public** hostname (belt and
   suspenders — private surfaces must still 403 from the internet). Canary the
   Anubis pod + search latency.

## 9. Rollback

- **Fastest kill (edge):** remove the `lists.latoolb.us` tunnel public-hostname
  route dashboard-side — instantly stops all inbound to `anubis-archive`
  (mirrors `form-intake.md` "Removing the Cloudflare public-hostname route
  instantly stops all…").
- **DNS:** flip `var.archives_dns_enabled` back to `false`; PR-plan/apply. The
  record disappears; `lists.latoolb.us` stops resolving to the tunnel.
- **Workloads:** delete the `anubis-archive` Deployment (and, if desired, the
  whole `k8s/archive/...` overlay). The list engine and the private
  `keyholders@` archive are untouched — they were never the thing exposed; the
  gate + tunnel route were.
- **Netpol:** removing the archive stack removes the additive
  `mailman-core-archive-ingress`; re-widen the list stack placeholder only if
  some other route needs it (it should not).

---

### Appendix — files in this packet (all declare-only)

- `docs/discuss-archive-packet.md` — this packet.
- `k8s/archive/latoolb-us-production/` — `deployment-anubis-archive.yaml`,
  `service-anubis-archive.yaml`, `configmap-anubis-policy.yaml`,
  `networkpolicy.yaml`, `kustomization.yaml`, `README.md`.
- `tofu/stacks/edge/` — `var.archives_dns_enabled` (default `false`) +
  `cloudflare_dns_record.alias_archives` (count-gated) in `main.tf` /
  `variables.tf`; enable sequence in `README.md`.
