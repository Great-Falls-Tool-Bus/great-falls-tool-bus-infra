# Archive-gate network enforcement + tunnel-ingress-into-spec plan (TIN-2528 / TIN-991)

Status: **DESIGN NOTE + GATED PLAN, not a change** (authored 2026-07-07 under
the operator's drive/decide/adversarially-review delegation). This document
does **not** modify any NetworkPolicy, does **not** apply anything to any
cluster, and does **not** flip any flag. It (1) states the current
archive-gate enforcement gap (the PoW gate is enforced by Cloudflare tunnel
routing, not by NetworkPolicy), (2) records the tunnel-management reality
established by a read-only live investigation and what it implies, (3)
specifies a concrete plan to netpol-enforce the archive gate, carried here as a
diff that is **gated on first confirming the tunnel ingress map**, and (4)
specifies a concrete plan to migrate the shared tunnel's public-hostname
ingress map out of the Cloudflare dashboard and into repo/tofu-managed spec so
`lists.latoolb.us -> anubis-archive:8081` is **declared in source**, not held
only in the dashboard. Every claim is grounded in a repo path or a read-only
observation cited in section 8.

**Secret/endpoint hygiene:** this doc carries **no** tokens, no tunnel
credential, and no literal `cfargotunnel` target. The shared connector is named
by role only (`honey-ingress`); its live UUID and credential live in the
operator-gated edge stack and the Cloudflare dashboard, never reproduced here.
This repo is public-bound; the design must stay publish-safe by construction.

---

## 0. Bottom line up front

- **The archive PoW gate is enforced at the edge, not at the network layer.**
  `lists.latoolb.us` reaches the in-cluster `anubis-archive:8081` PoW gate only
  because the Cloudflare tunnel's public-hostname map points that hostname at
  the gate Service. Nothing in the cluster's NetworkPolicy set forces the
  browsing surface through Anubis. The list stack's `mailman-core` policy
  **independently** admits the `cloudflared` namespace straight to the web tier
  on port 8000 (`k8s/list/latoolb-us-production/networkpolicy.yaml`), so a
  tunnel route pointed at `mailman-web:8080` would reach the HyperKitty web tier
  **without** solving a proof of work. The gate is a routing choice, not a
  network invariant.
- **That routing choice lives in a place the cluster cannot read.** The
  investigation confirmed (live, read-only) that the house `cloudflared`
  Deployment runs `tunnel run --token $(TUNNEL_TOKEN)` with **no** local
  `config.yaml`, **no** config ConfigMap, and **no** volume mount. The
  public-hostname -> service ingress map is pulled from the Cloudflare edge
  (dashboard/API), a **remote** source of truth. There is no tunnel-config
  resource anywhere in `tofu/` (a grep for `zero_trust_tunnel|cloudflared_config`
  is empty). This is exactly the TIN-991 condition.
- **The belt-and-suspenders fix (drop the direct `cloudflared -> mailman-web:8000`
  leg) is correct but is NOT yet provably safe, so it is NOT applied here.**
  Dropping that leg makes any dashboard route pointed at `mailman-web` fail
  closed at the network layer while leaving the legitimate archive path
  (`anubis-archive` pod -> `mailman-core:8000`, admitted by the additive
  `mailman-core-archive-ingress` policy) open. But proving it safe requires
  positive evidence that **no** tunnel hostname targets `mailman-web:8080/8000`
  today, and that map is dashboard-managed and unreadable from the cluster while
  the `mailman-web` Service still exists and is wireable. The investigation
  therefore returned `dropLegSafe = unconfirmed`, not `yes`. Per the stated bar,
  the drop is specified below as a **gated** change (section 3), not made.
- **The durable fix is to move the ingress map into spec (TIN-991).** Two
  routes exist (section 4). Both are subject to a hard **shared-tunnel caveat**:
  `honey-ingress` is a blahaj-owned substrate connector serving many tenants, so
  taking its ingress under a single `*_config` resource captures **every**
  tenant hostname at once and must be a coordinated blahaj change (or GFTB must
  stand up its own dedicated tunnel). Only once the map is confirmed or
  IaC-managed to contain **no** direct `mailman-web` route does the section-3
  netpol drop become provably safe to land.

---

## 1. The enforcement gap today

### 1a. What is actually enforcing the gate

The intended archive read path is:

```
tunnel (cloudflared ns) --8081--> anubis-archive (PoW gate)
                                    --8000--> mailman-core pod (HyperKitty web tier)
```

Two independent network facts make that path work, and a third makes it
**bypassable**:

1. **Ingress to the gate is netpol-enforced.** The archive stack's
   `anubis-archive` NetworkPolicy admits the `cloudflared` namespace to the gate
   on 8081 only (`k8s/archive/latoolb-us-production/networkpolicy.yaml`). Good.
2. **The gate's egress to the web tier is netpol-enforced and reciprocated.**
   `anubis-archive` egress is scoped to `mailman-core:8000`, and the additive
   `mailman-core-archive-ingress` policy admits **only** the `anubis-archive`
   pod to the web tier on 8000. So the *gate-to-web* hop is tight. Good.
3. **But the web tier ALSO admits the tunnel namespace directly.** The list
   stack's `mailman-core` policy carries a port-8000 ingress rule whose peers
   are the `cloudflared`, `arc-runners`, and `greatfallstoolbus-org-production`
   namespaces (`k8s/list/latoolb-us-production/networkpolicy.yaml`). The
   `cloudflared` peer means: **if any tunnel public-hostname is pointed at the
   `mailman-web` Service (ClusterIP 8080 DNATs to the same `mailman-core` pod on
   8000), the request reaches HyperKitty without touching Anubis.** The PoW gate
   is skipped entirely, at the network layer, with no policy violation.

So the archive gate is enforced by **which Service the tunnel hostname points
at**, a Cloudflare-side routing decision, not by any in-cluster invariant. The
`mailman-web` Service still exists and still selects the `mailman-core` pod
(`k8s/list/latoolb-us-production/service-mailman-web.yaml`), so it remains a
live, wireable bypass target.

### 1b. Why this is load-bearing, not cosmetic

One HyperKitty instance serves **both** lists path-based off the one web tier:
`discuss@` is public and `keyholders@` is private, with visibility enforced by
HyperKitty for anonymous users. The Anubis gate is anti-scrape, not
authentication (the privacy control is the per-list `archive_policy`). But the
whole point of routing the public archive through `anubis-archive` is to keep
the browsing surface behind a proof-of-work tax; a dashboard misconfiguration
that points `lists.latoolb.us` (or any hostname) at `mailman-web` instead of
`anubis-archive` silently removes that tax with no code change and no netpol
denial. The gap is precisely that a **routing edit cannot be caught by the
network policy** as the policy stands today.

---

## 2. The tunnel-management reality and what it implies

The investigation established the following, all read-only, kube-context
`honey`:

- **The tunnel is token-managed, not config-file-managed.** The `cloudflared`
  Deployment in namespace `cloudflared` runs
  `["tunnel","--metrics","0.0.0.0:2000","--no-autoupdate","run","--token","$(TUNNEL_TOKEN)"]`
  with an empty command, no `volumeMounts`, no `volumes`, and no config
  ConfigMap (the only ConfigMap in the namespace is the default
  `kube-root-ca.crt`). `run --token` means the ingress rules are pulled from the
  Cloudflare edge, i.e. a **remote** source of truth, never a local file. This
  is corroborated verbatim by `docs/runbooks/form-intake.md` (the tunnel note:
  "the `cloudflared` Deployment runs `tunnel run --token $(TUNNEL_TOKEN)`, no
  local `config.yaml`"), by `k8s/archive/latoolb-us-production/README.md` ("The
  tunnel route is dashboard-managed (NOT in git)"), and by
  `tofu/intent/great-falls-tool-bus/web-oncluster-route.json`
  (`"management": "cloudflare-dashboard-token-managed"`, TIN-991).
- **It is the SHARED honey-ingress connector.** The same tunnel serves many
  tenants (`blahaj:deploy/honey/retained-cloudflared.yaml`); GFTB is one tenant
  among MassageIthaca, the GFTB apex/www, forms, lists, and per-PR previews.
- **No tunnel-config resource exists in this repo.** A grep of `tofu/` for
  `zero_trust_tunnel_cloudflared_config` / `cloudflared_config` is empty. The
  repo declares the **DNS** side of the edge (the proxied CNAMEs for
  forms/lists/apex in `tofu/stacks/edge/main.tf`) but **not** the tunnel's
  hostname -> service ingress map. That map exists only in the dashboard.

**What this implies:**

1. **The routing that enforces the gate is un-reviewed and un-versioned.** A
   change to `lists.latoolb.us`'s origin is a dashboard action with no PR, no
   diff, and no CI. The gate's correctness depends on an artifact that lives
   outside the repo's guarantees.
2. **The cluster cannot self-verify the gate.** Because the map is not readable
   from inside the cluster, no in-cluster check (and no `just check` assertion)
   can prove `lists.latoolb.us` currently points at `anubis-archive:8081` rather
   than `mailman-web:8080`. The live-behavior probe in the investigation
   (browser-UA GET to `https://lists.latoolb.us/` returns an Anubis PoW
   interstitial and a `within.website-x-cmd-anubis-auth` cookie; a curl-UA GET
   is passed straight through to a Postorius 301) proves the hostname is Anubis
   fronted **right now**, but a live probe is a point-in-time observation, not a
   spec.
3. **Therefore the gate needs two independent reinforcements**, neither of which
   depends on trusting the dashboard: a **network-layer** control that fails the
   bypass closed (section 3), and a **spec-layer** control that puts the ingress
   map under review so the intended origin is declared, not dashboard-held
   (section 4).

---

## 3. Plan to netpol-enforce the archive gate (GATED; not applied here)

### 3a. The change

Make the network layer, not the tunnel routing, the thing that keeps the web
tier reachable **only** through the PoW gate. Concretely: remove the
`cloudflared` namespace peer from the `mailman-core` policy's port-8000 ingress
rule in `k8s/list/latoolb-us-production/networkpolicy.yaml`, keeping the two
legitimate read consumers (`arc-runners` for the build-time prerender fetch and
`greatfallstoolbus-org-production` for the request-time site data plane). The
archive read path is unaffected, because it does **not** use the
`cloudflared -> 8000` leg: it flows `anubis-archive` pod -> `mailman-core:8000`,
admitted by the additive `mailman-core-archive-ingress` policy the archive stack
already declares.

Proposed diff (single peer removed; the rule stays one rule so the list-stack
validator's port assertion stays exact):

```diff
     - from:
-        - namespaceSelector:
-            matchLabels:
-              kubernetes.io/metadata.name: cloudflared
         - namespaceSelector:
             matchLabels:
               kubernetes.io/metadata.name: arc-runners
         - namespaceSelector:
             matchLabels:
               kubernetes.io/metadata.name: greatfallstoolbus-org-production
       ports:
         - protocol: TCP
           port: 8000
```

After this change, the **only** admitted path to the web tier on 8000 from the
tunnel side is via the `anubis-archive` pod. A dashboard route pointed at
`mailman-web` would connect from the `cloudflared` namespace, match no ingress
peer, and fail closed. The gate becomes a network invariant.

### 3b. The validator flip this change requires

`scripts/validate-list-stack.sh` currently **requires** the `cloudflared` peer
on the list netpol (it asserts `grep -q "kubernetes.io/metadata.name: cloudflared"`
with the failure message "mailman web ingress must admit only the cloudflared
namespace for the tunnel leg"). Dropping the leg therefore also inverts that
assertion: it must change from *require cloudflared on the 8000 rule* to
*forbid cloudflared on the 8000 rule; the tunnel reaches the web tier only via
the `anubis-archive` pod*. The `namespaceSelector: {}` all-namespaces guard
(`validate-list-stack.sh`, the "must not admit every namespace" check) stays as
is. `validate-archive-stack.sh` is unaffected (it already pins the archive
gate's own ingress/egress and the reciprocal `mailman-core-archive-ingress`).

### 3c. Why it is NOT applied in this PR (the gate on the gate)

Dropping the leg is provably safe **only** with positive proof that the shared
tunnel has no hostname pointed at `mailman-web:8080/8000`. That map is
dashboard-managed and not readable from the cluster; the `mailman-web` Service
still exists and is wireable; and no tofu tunnel-config resource enumerates the
routes. Absent that proof, the drop **could** fail closed a legitimate route
that someone added dashboard-side and that the repo does not know about (for
example, a direct `mailman-web` route used by some other consumer). The
investigation therefore graded this `dropLegSafe = unconfirmed`, not `yes`, and
the operator bar is explicit: perform the drop **only** once the tunnel map is
confirmed or IaC-managed to contain no direct `mailman-web` route. Section 4 is
how that precondition is satisfied. Until then this diff stays in the design
note, unlanded.

**Confirmation options that would flip `unconfirmed -> yes`:**

1. Enumerate the shared tunnel's public-hostname map via the Cloudflare API
   (operator credential, out of band) and prove no ingress entry has an origin
   Service of `mailman-web` (8080 or 8000). This is a point-in-time proof and
   must be paired with section 4 to stay durable.
2. Or complete section 4 first: once the ingress map is declared in spec, the
   map is reviewable and the "no direct `mailman-web` route" property becomes a
   spec assertion, at which point the drop is safe to land in the same or a
   follow-up change.

---

## 4. Plan to migrate the tunnel ingress into repo/tofu-managed spec (TIN-991)

The tunnel is dashboard-managed, so this section is required, not optional. The
goal: make `lists.latoolb.us -> anubis-archive:8081` (and every other GFTB
hostname) **declared in source**, reviewable, and diffable, so the gate's
routing is no longer a dashboard secret.

### 4a. What the repo already has vs what is missing

The repo already uses the Cloudflare provider v5 and its **DNS** records are
tofu-managed: the proxied CNAMEs for `forms`, `lists`, and the apex/www live in
`tofu/stacks/edge/main.tf` (`cloudflare_dns_record`), and Access apps/policies
use `cloudflare_zero_trust_access_application` / `_policy`. The **missing**
piece is the tunnel's hostname -> origin-service ingress map, which today exists
only in the dashboard/API. Declaring the CNAME gets traffic **to** the tunnel;
it does not say **where the tunnel sends it**. That second half is the gap.

### 4b. Route A - declare a tunnel-config resource

Add a `cloudflare_zero_trust_tunnel_cloudflared_config` resource whose
`config.ingress` list maps each GFTB hostname to its in-cluster origin Service
by role, for example:

- `lists.latoolb.us` -> the `anubis-archive` gate Service on 8081
  (`http://anubis-archive.latoolb-us-production.svc.cluster.local:8081`)
- `forms.latoolb.us` -> the forms `anubis` gate Service on 8081
- apex / www -> the GFTB web Service
- a terminal catch-all rule returning `http_status: 404`
- and, load-bearing for this whole note, **no** ingress entry whose origin is
  `mailman-web` (8080 or 8000)

With the map declared, "the archive hostname points at the PoW gate, and nothing
points directly at the web tier" becomes a reviewable spec fact, and the
section-3 netpol drop becomes provably safe.

### 4c. Route B - move cloudflared off `run --token` to a mounted config

Alternatively, switch the `cloudflared` Deployment from `run --token` to a
credentials-file plus a ConfigMap-mounted `config.yaml` carrying the same
`ingress:` rules. This puts the map in a Kubernetes object the cluster can read
and CI can assert, at the cost of managing the tunnel credential as a Secret and
owning the `cloudflared` Deployment spec (today a substrate concern). Route A
keeps the map in tofu alongside the existing DNS records and is the smaller
blast radius for GFTB; Route B is the option if the operator wants the map to be
a cluster-local artifact rather than a Cloudflare-API artifact.

### 4d. The shared-tunnel caveat (hard constraint on both routes)

`honey-ingress` is a **blahaj-owned substrate connector** shared across tenants.
A `cloudflare_zero_trust_tunnel_cloudflared_config` resource (Route A) or a
mounted `config.yaml` (Route B) takes over the **entire** tunnel ingress for
**all** tenants at once. So either route must:

- be a **coordinated blahaj change** that enumerates every tenant hostname on
  the shared tunnel (MassageIthaca, the GFTB apex/www, forms, lists, and the
  per-PR preview hosts) so nothing is dropped when the map moves from
  dashboard-held to spec-held, **or**
- **stand up a dedicated GFTB tunnel** so GFTB owns its own complete ingress map
  and the shared connector is left untouched.

This is why the migration is a genuine cross-repo coordination item and not a
one-file GFTB edit. It is the substance of TIN-991.

### 4e. Sequencing (net effect of sections 3 and 4)

1. **Land this design note** (declare-only; changes nothing).
2. **Bring the tunnel ingress map into spec** via Route A or Route B, as a
   coordinated blahaj change or a dedicated GFTB tunnel (section 4d). Prove the
   declared map has no direct `mailman-web` origin.
3. **Then, and only then, land the section-3 netpol drop** plus the
   `validate-list-stack.sh` assertion flip (section 3b). At that point the gate
   is enforced twice over: the tunnel map declares the gate origin in source,
   and the network layer fails any direct-to-web-tier route closed.

Steps 2 and 3 are independent reinforcements: even before the map is in spec, an
operator who has enumerated the live map out of band (section 3c option 1) may
land step 3 on that evidence, but step 2 is what makes the property **durable**.

---

## 5. Live drift observed (read-only; recorded, not acted on)

The investigation surfaced repo-vs-cluster drift adjacent to this work. It is
recorded here for the operator; **nothing in this PR changes any of it.**

1. **The archive stack is applied despite its README saying it is not.**
   `k8s/archive/latoolb-us-production/README.md` states "NOTHING IN THIS
   DIRECTORY IS APPLIED," but `anubis-archive` (Deployment 1/1, Service :8081)
   and the `mailman-core-archive-ingress` policy were observed live, and
   `lists.latoolb.us` is serving behind Anubis now. The declare-only doc and the
   live cluster disagree.
2. **`var.archives_dns_enabled` default contradicts its own description.** In
   `tofu/stacks/edge/variables.tf` the variable has `default = true`, while its
   description says "Defaults FALSE (fail-closed) ... Merging the record changes
   nothing." The `lists` CNAME is live and resolves to Cloudflare. This is a
   real code-vs-doc contradiction and, given the unique privacy pre-flight this
   route carries, the fail-closed default the description promises is the safer
   posture; the mismatch should be reconciled deliberately.
3. **An orphan `mailman-web` NetworkPolicy still exists in-cluster.** The repo
   removed it under TIN-2493, but a live policy named `mailman-web` remains. Its
   ingress is `namespaceSelector: {}` (ALL namespaces) on port 8000, wide open,
   but its `podSelector` (`app.kubernetes.io/name=mailman-web`) matches **no**
   pod (the co-located pod is `mailman-core`), so it is **inert today**. Latent
   hazard: labeling any pod `app.kubernetes.io/name=mailman-web` would open port
   8000 to every namespace. Recommend deleting it to match the repo.
4. **The `mailman-web` Service is the exact bypass target.** It is live
   (8080 -> targetPort 8000, selector `mailman-core`) and is precisely the
   object a dashboard route could point at to skip Anubis (section 1). It cannot
   be removed (the co-located web tier is fronted by it), which is why the
   section-3 network control matters.

---

## 6. Doctrine anchors

- **TIN-2528** - the public `discuss@` HyperKitty archive route and its
  declare-only packet (`docs/discuss-archive-packet.md`,
  `k8s/archive/latoolb-us-production/`). This note extends its enforcement story
  from edge-routing to network-plus-spec.
- **TIN-991** - the tunnel public-hostname map is dashboard/token-managed and
  not in spec. Section 4 is the concrete plan to close it.
- **TIN-2420** - the forms edge pattern (`k8s/form/latoolb-us-production/`) the
  archive gate faithfully copies; the same `cloudflared -> Anubis:8081` shape
  and the same tunnel-source netpol reasoning apply.
- **TIN-2493** - the mailman-web/mailman-core co-location that makes the web tier
  a container in the `mailman-core` pod and folds web-tier admission into the
  `mailman-core` policy (the rule section 3 edits).
- **TIN-2385** - the zone-scoped edge token in the protected `edge` environment;
  the Cloudflare credential that a Route-A tunnel-config apply would use, never
  in tree.
- **D6 dispatch-apply** - activation stays an operator-reviewable plan/apply,
  never a merge side effect; this note applies nothing.

## 7. What this PR does and does not do

- **Does:** add this design note. Nothing else.
- **Does not:** modify any NetworkPolicy, edit any validator, touch any tofu
  stack, add any tunnel-config resource, flip any flag, or apply anything to any
  cluster. The section-3 diff is a proposal gated on section 4; it is not
  applied because `dropLegSafe` is `unconfirmed`.

## 8. Sources (all read READ-ONLY)

- **Live read-only investigation (2026-07-07, kube-context `honey`):** the
  `cloudflared` Deployment args (`tunnel run --token $(TUNNEL_TOKEN)`, no
  `config.yaml`, no config ConfigMap, no volume mounts); `anubis-archive`
  Deployment 1/1 and Service :8081 live; the live netpols `anubis-archive`
  (ingress 8081 from `cloudflared`) and `mailman-core-archive-ingress` (ingress
  8000 from `anubis-archive` podSelector); the `mailman-core` netpol's 8000 rule
  admitting `cloudflared` + `arc-runners` + `greatfallstoolbus-org-production`;
  the browser-UA vs curl-UA probe of `https://lists.latoolb.us/` (Anubis PoW
  interstitial + `within.website-x-cmd-anubis-auth` cookie vs a straight-through
  Postorius 301); the orphan `mailman-web` NetworkPolicy
  (`namespaceSelector: {}`, inert podSelector); the live `mailman-web` Service.
- **This overlay (`great-falls-tool-bus-infra`):**
  `k8s/archive/latoolb-us-production/{networkpolicy.yaml,deployment-anubis-archive.yaml,service-anubis-archive.yaml,kustomization.yaml,README.md}`;
  `k8s/list/latoolb-us-production/{networkpolicy.yaml,service-mailman-web.yaml,service-mailman-core.yaml}`;
  `k8s/form/latoolb-us-production/networkpolicy.yaml`;
  `scripts/{validate-archive-stack.sh,validate-list-stack.sh}`;
  `tofu/stacks/edge/{main.tf,variables.tf,README.md}`;
  `tofu/intent/great-falls-tool-bus/web-oncluster-route.json`;
  `docs/discuss-archive-packet.md`; `docs/runbooks/form-intake.md`; `Justfile`
  (`check`, `archive-stack-validate`, `list-stack-validate`).
- **`tinyland-inc/blahaj`:** `deploy/honey/retained-cloudflared.yaml` (the
  shared `honey-ingress` connector serving all tenants). Named by role only; no
  UUID, token, or `cfargotunnel` target is reproduced in this note.
- **Peer briefs (house style + adjacent posture):**
  `docs/research/full-oncluster-web-serving-2026-07.md` (OQ-1 live tunnel
  ruleset is dashboard-managed; OQ-2 gated-dynamic sits behind Anubis, not bare
  origin) and `docs/research/gloriousflywheel-overlay-leverage-2026-07.md`
  (endpoint-free, publish-safe doc discipline).
