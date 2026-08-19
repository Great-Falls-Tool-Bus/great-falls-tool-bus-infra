# GFTB on-cluster web serving — phased cutover runbook (EXECUTED — kept as apply-wiring reference)

> **STATUS (2026-07-07): this runbook's cutover has fully executed, and its
> Pages-decommission phase (P7) is DONE, not a future decision.** ADR
> [`greatfallstoolbus.org:docs/decisions/0010-on-prem-is-the-production-host.md`](https://github.com/Great-Falls-Tool-Bus/greatfallstoolbus.org/blob/main/docs/decisions/0010-on-prem-is-the-production-host.md)
> (executed 2026-07-06, Amendment 2 2026-07-07) supersedes ADR 0008's
> operator-gated framing below and ADR 0007's open-ended warm-standby framing:
> the operator ruled to decommission Cloudflare Pages **now** rather than hold
> it warm pending "a separate deliberate decision" (P7's original wording,
> below). The `greatfallstoolbus-org` Cloudflare Pages project is **deleted**
> (site PR #122/#123, TIN-2560, workflow run 28801030150 — see P7 for the full
> account). This header and P1–P6 are kept as accurate wiring/apply reference
> (the mechanics did not change); P7 is rewritten to state what actually
> happened instead of what was originally deferred.

Tracking: **TIN-2543**. Authorizing decision: **ADR
[`greatfallstoolbus.org:docs/decisions/0008-oncluster-production-hosting.md`](https://github.com/Great-Falls-Tool-Bus/greatfallstoolbus.org/blob/main/docs/decisions/0008-oncluster-production-hosting.md)**
(the superseding on-cluster hosting ADR; lives in the SITE repo, not this
overlay), itself executed and its Pages-decommission timing overridden by
**ADR
[`greatfallstoolbus.org:docs/decisions/0010-on-prem-is-the-production-host.md`](https://github.com/Great-Falls-Tool-Bus/greatfallstoolbus.org/blob/main/docs/decisions/0010-on-prem-is-the-production-host.md)**
(also site repo — ruled the cutover 2026-07-06, then Amendment 2 ruled the
Pages decommission 2026-07-07). Warm-standby mitigation, now closed out by ADR
0010 Amendment 2: **ADR
[`greatfallstoolbus.org:docs/decisions/0007-private-repos-rollback-gap.md`](https://github.com/Great-Falls-Tool-Bus/greatfallstoolbus.org/blob/main/docs/decisions/0007-private-repos-rollback-gap.md)**.
Superseded snapshot: ADR
[`greatfallstoolbus.org:docs/decisions/0003-hosting-and-remote-posture.md`](https://github.com/Great-Falls-Tool-Bus/greatfallstoolbus.org/blob/main/docs/decisions/0003-hosting-and-remote-posture.md).
Declare-only skeleton this operates: the
[`k8s/web/`](../../k8s/web/README.md) overlay landed in **PR #48**
(TIN-2541).

> **NOTHING IN THIS RUNBOOK IS APPLIED BY WRITING IT.** This is the
> operator-executed cutover procedure and the apply-wiring reference for moving
> `greatfallstoolbus.org` from Cloudflare Pages (static production, ADR 0003) to
> **fully on-cluster serving** (SvelteKit `adapter-node` → OCI image on GHCR →
> K8s `Deployment` behind a `ClusterIP` `Service` → in-cluster `cloudflared`
> honey-ingress tunnel), mirroring the proven MassageIthaca pattern.
>
> The `k8s/web/` overlay is **no longer parked** — the cutover executed
> (`replicas: 2`, a real digest pinned, the namespace and route live, apex/www
> DNS on the tunnel). This section is retained as reference for how the wiring
> works (e.g. a future rollback re-dispatch), not as a pending plan.

## Who does what

Every step is tagged **[OPERATOR]** (a human with custody of the protected
environment secrets / cluster / Cloudflare dashboard / DreamHost panel) or
**[AGENT]** (a read-only or validate-only session that never mutates the
cluster, DNS, or a route). No agent session applies a manifest, mutates
Cloudflare/DreamHost, pins an image digest in the public tree, or flips DNS.
Each phase records its **rollback**.

The cutover, end to end, does four things the parked skeleton deliberately does
not: (1) pins a **real image digest** in the private overlay, (2) creates the
`greatfallstoolbus-org-production` **namespace**, (3) flips **`replicas` 0 → 2**,
(4) adds the **tunnel public-hostname route** and flips DNS. Each is a distinct,
gated phase below.

---

## Phase gate summary

| Phase | What | Owner | Un-parks |
| --- | --- | --- | --- |
| P1 | Confirm live pod-headroom | [AGENT] read-only probe → [OPERATOR] go/no-go | nothing |
| P2 | Build + pin the GHCR image | [OPERATOR] (public CI builds; operator pins) | nothing in public tree |
| P3 | Apply the k8s/web overlay (digest, replicas 0→2, namespace) | [OPERATOR] | the workload |
| P4 | Verify in-cluster `/health` + Prometheus | [AGENT] read-only | nothing |
| P5 | Add the cloudflared honey-ingress route | [OPERATOR] (dashboard/token) | the edge hop |
| P6 | Flip apex + www DNS Pages → tunnel (~~keep Pages warm~~ DONE 2026-07-06) | [OPERATOR] | public traffic |
| P7 | ~~Soak, then later decommission Pages~~ **Pages project DELETED 2026-07-06** (TIN-2560, ADR 0010 Amendment 2 — soak-then-decide was overridden) | [OPERATOR] | retired standby |

Phases are strictly ordered. Do not start a phase until the prior phase's
verify step is green. P5/P6 are the only phases that change public posture;
**all seven phases, including P7, are now complete** — the description below
of P5/P6 as "the only phases that change public posture" describes the
original plan's phase boundaries, not a claim that P7 is still pending.

---

## P1 — Confirm live pod-headroom (go/no-go)

**[AGENT] read-only.** Re-ground the placement assumptions with a read-only
`kubectl` probe against honey rke2 (context `honey`). Confirm the 2026-07-05
probe still holds before scheduling anything:

```bash
kubectl --context honey get nodes -o wide
# Per-node running-pod counts vs capacity:
for n in honey bumble sting; do
  echo "== $n =="
  kubectl --context honey get pods -A --field-selector spec.nodeName="$n" \
    --no-headers 2>/dev/null | wc -l
  kubectl --context honey get node "$n" \
    -o jsonpath='{.status.allocatable.pods}{"\n"}'
done
```

**Expected (2026-07-05 probe, obsoletes ADR 0003's "~6 free"):**

- **honey 138/150** (12 free — honey was **expanded to a 150 pod cap**; ADR
  0003's "~103–104/110, ~6 free" is faulty and retired).
- **bumble 50/110** (60 free).
- **sting 96/200** (104 free).
- **~176 free pod slots cluster-wide.**

A `replicas: 2` web Deployment fits trivially. **honey is the tightest node**,
so the overlay's `nodeAffinity` prefers **bumble/sting** for the serving pods
(honey stays spillover) and `podAntiAffinity` spreads the two replicas across
distinct hosts — no node-SPOF. The only genuine SPOF is **site-level** (one
on-prem `/24`: honey `.70.10`, bumble `.11`, sting `.12`), the honest
availability tradeoff vs a global CDN, already accepted by MI in production and
fronted+cached by the Cloudflare proxy; the named mitigation is the warm
CF-Pages standby (ADR 0007). The "sting SPOF" ADR 0003 cites is **CI-runner**
concentration (all ARC/nix runners on sting) — a deploy-velocity concern, not a
serving risk.

**[OPERATOR] go/no-go.** If free headroom on bumble+sting has dropped below
~2 pods of margin, **stop**: rebalance or reclaim before proceeding. Otherwise
authorize P2.

**Rollback:** none — read-only. A no-go simply does not proceed.

---

## P2 — Build + pin the GHCR image

**[OPERATOR].** Two authority planes, kept split
([`k8s/web/secrets.contract.yaml`](../../k8s/web/secrets.contract.yaml)):

1. **The public app repo owns the image _build_, never the pin.**
   `Great-Falls-Tool-Bus/greatfallstoolbus.org` builds and publishes the
   multi-stage `adapter-node` OCI image to same-org GHCR via the **ambient
   `GITHUB_TOKEN`** (no long-lived PAT, no cross-org secret), exactly as MI's
   `docker-ghcr.yml` publishes a same-owner GHCR image.
   The GFTB image is
   `ghcr.io/great-falls-tool-bus/greatfallstoolbus.org:sha-<commit>`. Trigger
   the site's container-GHCR build for the commit you intend to serve.

2. **The private overlay owns the operator-gated _pin_.** Resolve the published
   tag to an immutable digest and record it for the P3 overlay bump:

   ```bash
   # Resolve the tag you built to an @sha256: digest (operator, read-only).
   crane digest ghcr.io/great-falls-tool-bus/greatfallstoolbus.org:sha-<commit>
   # or: docker buildx imagetools inspect ...:sha-<commit>
   ```

   The digest is pinned **only** in the **private overlay** at P3 — never in the
   public app tree. The declare-only guard (`scripts/validate-web-stack.sh`)
   **fails** if an `@sha256:` digest appears on the parked
   `k8s/web/.../deployment.yaml` `image:` line, which keeps the skeleton
   declare-only; the real pin belongs in the operator's private-overlay cutover
   branch, reviewed like MI's canonical-pin PR (MI deliberately rejected an
   auto-writer; GFTB inherits that — the app repo does **not** auto-write prod
   pins).

**Rollback:** none applied — building and resolving a digest mutates nothing on
cluster or DNS. Discard the branch / digest note.

---

## P3 — Apply the k8s/web overlay (digest, replicas 0→2, namespace)

**[OPERATOR].** This is the first phase that touches the cluster. The parked
overlay is fail-closed on three axes; a cutover flips exactly those three, in
the private overlay, reviewed:

1. **Pin the image** — replace the
   `…/greatfallstoolbus.org:PLACEHOLDER-DECLARE-ONLY-NOT-APPLIED` reference with
   the P2 `@sha256:` digest.
2. **Flip replicas 0 → 2** — the MI production shape; the overlay already specs
   `nodeAffinity` (prefer bumble/sting) + `podAntiAffinity` (hostname spread).
3. **Create the namespace** — `greatfallstoolbus-org-production` is intentionally
   **not** created by the parked stack. Materialize it first (the two-stack
   split MI uses: a thin namespace apply, then the workload), then apply the
   `Deployment` + `Service` + `NetworkPolicy` set.

Apply via one of the two supported paths in
[**§ Apply path**](#apply-path--how-p3p6-actually-run) below (house tofu CI/CD
gitops, **or** direct operator `kubectl`/`tofu` with the namespace-scoped
`web-apply-kubeconfig`). The default-deny `NetworkPolicy` set admits ingress
**only** from the `cloudflared` namespace (:3000) and Prometheus, and egress
DNS-only — so even once pods are Running, nothing is publicly reachable until P5
adds the route.

Order:

```bash
# 1. namespace (thin apply, operator-gated path of choice)
# 2. workload objects (Deployment[replicas:2, digest] + Service + NetworkPolicy)
# 3. confirm the rollout WITHOUT exposing anything public yet:
kubectl --context honey -n greatfallstoolbus-org-production \
  rollout status deploy/greatfallstoolbus-org --timeout=120s
kubectl --context honey -n greatfallstoolbus-org-production \
  get pods -o wide   # expect 2 Running, spread across bumble/sting
```

**Rollback:** scale back to zero and/or remove the namespace through the
private cluster operations lane — nothing public depends on it yet (P5 has not
run). Do not copy destructive cluster commands out of this public runbook.

The parked overlay in git is unchanged by a rollback; re-park by discarding the
private-overlay cutover branch.

---

## P4 — Verify in-cluster `/health` + Prometheus

**[AGENT] read-only.** Prove the workload serves before any public traffic
rides it. The app answers on container port `3000` at **`/health`** (liveness +
readiness); the `Service` fronts it at `:80`.

```bash
# In-cluster HTTP smoke from an ephemeral pod (no port-forward needed):
kubectl --context honey -n greatfallstoolbus-org-production run curl-smoke \
  --rm -it --restart=Never --image=curlimages/curl -- \
  curl -s -o /dev/null -w '%{http_code}\n' \
  http://greatfallstoolbus-org.greatfallstoolbus-org-production.svc.cluster.local/health
# expect: 200

# Probe status straight from the pods:
kubectl --context honey -n greatfallstoolbus-org-production \
  get pods -l app.kubernetes.io/name=greatfallstoolbus-org \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].ready}{"\n"}{end}'
```

**Prometheus.** The `allow-prometheus-scrape` NetworkPolicy admits the
`tinyland-dev-production` Prometheus on `:3000`. Confirm the target is up
(read-only) via the Prometheus UI/API in-cluster: the
`greatfallstoolbus-org-production` endpoints should show `up == 1`. Do **not**
expose Prometheus publicly to check this.

Green gate: both replicas `Ready`, `/health` returns `200` over the Service,
Prometheus target `up`. Only then proceed to P5.

**Rollback:** none — read-only. A red gate returns to P3 rollback.

---

## P5 — Add the cloudflared honey-ingress public-hostname route

**[OPERATOR].** The public path rides the shared **honey-ingress** `cloudflared`
connector (`blahaj:deploy/honey/retained-cloudflared.yaml`, `replicas: 2`). Its
public-hostname routes are **Cloudflare dashboard / token-managed** (TIN-991
route authority is unfinished) — there is **no** route object in this repo and
**no** live `cfargotunnel` UUID inlined anywhere. The route intent JSON
([`tofu/intent/great-falls-tool-bus/web-oncluster-route.json`](../../tofu/intent/great-falls-tool-bus/web-oncluster-route.json))
records the **shape** fail-closed (`applied:false`, `route_enabled:false`) only.

Add the route out of band (Cloudflare Zero Trust dashboard → the `honey-ingress`
tunnel → Public Hostnames, or via the tunnel-config token):

- **Public hostname:** `greatfallstoolbus.org` (and `www.greatfallstoolbus.org`).
- **Service (origin):**
  `http://greatfallstoolbus-org.greatfallstoolbus-org-production.svc.cluster.local:80`.

TLS terminates at the Cloudflare edge (proxied); the origin hop
tunnel → Service is plain in-cluster HTTP, exactly as MI. The `TUNNEL_TOKEN` is
a **live cluster Secret only** (namespace `cloudflared`), never in git; the
zone-scoped Cloudflare token `cloudflare-api-token-gftb-zones` lives only in the
protected `edge` environment + SOPS (names-only in the secrets contract).

At this point the route exists but DNS still points at CF Pages, so no visitor
reaches the tunnel yet. Optionally verify the origin resolves through the tunnel
by sending the tunnel hostname a request with the eventual host header from an
operator machine, without moving DNS.

**Rollback:** delete the public-hostname route from the tunnel in the dashboard.
No DNS has moved, so removing the route fully backs out P5.

---

## P6 — Flip apex + www DNS: CF Pages → tunnel (kept Pages warm at the time; DONE 2026-07-06)

**[OPERATOR].** This is the public cutover. `greatfallstoolbus.org` /
`www.greatfallstoolbus.org` DNS authority for the serving records is owned by
**this overlay's edge stack** (`tofu/stacks/edge*`, zone-scoped token per
TIN-2385) — **not** blahaj. Flip the apex + www records from the CF Pages CNAME
to the tunnel CNAME target (`<honey-ingress-tunnel-id>.cfargotunnel.com`,
proxied), following the live edge apply flow in
[`docs/runbooks/edge-token-and-zones.md`](edge-token-and-zones.md) and
`edge-plan.yml` `workflow_dispatch action=apply` (protected `edge`
environment).

Per **ADR 0007**, **keep the CF Pages project as a warm standby** — do **not**
delete it at P6. Leave the Pages build wired and green; only the DNS records
move to the tunnel. If the on-cluster origin degrades during soak, rollback is a
single DNS flip back to the Pages CNAME (below), because Pages is still built
and serving-ready.

Because apex+www are proxied, keep the records **proxied (orange cloud)**;
Cloudflare fronts and caches the origin (the site-level SPOF mitigation).

Verify after propagation:

```bash
dig +short greatfallstoolbus.org @1.1.1.1        # proxied → Cloudflare IPs
curl -sSI https://greatfallstoolbus.org/ | head  # 200 from the on-cluster origin
curl -sS  https://greatfallstoolbus.org/health   # 200 from adapter-node
```

**Rollback (fast, single action) — HISTORICAL, no longer available:** at the
time P6 executed, the documented rollback was to repoint the apex+www CNAME
back to the CF Pages target via the edge stack (`workflow_dispatch
action=apply` with the reverted record), because Pages was still warm and
would have served immediately. **That rollback path does not exist anymore**:
P7 below records that the operator deleted the Pages project on 2026-07-06,
overriding the original "defer decommission until after soak" plan this
sentence used to justify. See P7 for the current, real rollback.

---

## P7 — Pages decommissioned 2026-07-06 (was: "soak, then decommission later")

**[OPERATOR].** This phase's original plan was: soak the on-cluster origin
under real traffic for at least a full weekly cycle, watching Prometheus
`up`/latency/error-rate for the `greatfallstoolbus-org-production` targets and
pod restart counts, keep CF Pages **warm** for the entire soak (ADR 0007's
mitigation held only while Pages could still take the apex back in one DNS
flip), and only *after* a clean soak — as **"a separate deliberate
decision"** — retire the Pages project.

**The operator overrode that plan (ADR 0010 Amendment 2, TIN-2560, ruled
2026-07-07: *"decommission now, align docs"*).** Rather than holding Pages warm
through the originally-bounded ~2026-07-08 window, the project was deleted
immediately once on-cluster serving was verified live, closing the window
roughly a day early:

- Site PR #122 added a one-off, dispatch-only, name-confirm-gated GitHub
  Actions workflow whose sole job was the deletion (fail-closed without the
  repo's `Pages:Edit`-scoped secret).
- Workflow run **28801030150** (2026-07-06T14:58Z) executed it: the Cloudflare
  API `DELETE .../pages/projects/greatfallstoolbus-org` call returned
  `{"success":true}` (job log: `Pages project greatfallstoolbus-org
  deleted.`).
- Site PR #123 removed the one-off workflow immediately after and recorded the
  verification: `greatfallstoolbus-org.pages.dev` no longer resolves in DNS at
  all; apex/`www` are healthy on the tunnel origin.
- The public app repo's one live Cloudflare credential (the account-scoped
  `Pages:Edit` token, ADR 0003 token doctrine) is retired along with the
  project — the authority split (app repo owns behavior+image; private overlay
  owns pin+apply; blahaj is substrate) now keeps every privileged surface out
  of the public repo, the load-bearing TIN-2537 invariant.

**Rollback, corrected:** the P6 rollback (repoint DNS back to the CF Pages
target) **no longer applies — there is no Pages project to repoint to.** The
current, real rollback is the on-cluster re-pin primitive: re-dispatch this
repo's `web-stack.yml` workflow (`workflow_dispatch`, `confirm=apply`,
`image=<prior known-good
ghcr.io/great-falls-tool-bus/greatfallstoolbus.org@sha256:<digest>>`) to roll
the Deployment back to a previously-served image — "the manual
`workflow_dispatch` path... preserved intact for rollback/override to an
arbitrary prior digest" per that workflow's own header comment. **Qualifier
(TIN-3816):** that re-dispatch holds only while the live image is *not* a
`ghcr.io/great-falls-tool-bus/gftb-site` reference — once section S's
promotion has landed, `_web-stack-promotion-interlock` refuses the carrier
and rollback follows section S's "Rollback" instead. Re-standing-up
a Pages project from scratch is *not* the rollback story anymore; that option
was deliberately foreclosed by this phase.

---

## Apply path — how P3/P6 actually run

The cutover reuses the house apply machinery **unchanged**; it adds **no new
deploy tooling**. Two supported routes; both are operator-gated and authorized
only by ADR 0008.

### Route A — house tofu CI/CD gitops (the MI pattern)

The GFTB overlay is applied via **`tinyland-inc/ci-templates`** reusable
workflows, following the MassageIthaca flow: a **`repository_dispatch`** (the
public app repo dispatches after it builds+pushes the image) →
**blahaj `tofu-apply`** (the substrate applies the overlay through
`just tofu-apply STACK CLUSTER='honey'` → `scripts/tofu-apply.sh`, RustFS state
backend) → the in-cluster **reaper** governs any ephemeral lanes. GFTB
on-cluster inherits this path verbatim: the app repo builds the image (ambient
`GITHUB_TOKEN`, same-org GHCR) and dispatches; the apply plane applies the
overlay; the backstop reaper governs lanes.

In **this overlay** the concrete chassis mirrors the existing
`.github/workflows/mail-crs.yml` / `edge-plan.yml` exactly: `runs-on:
tinyland-nix`, a protected **environment** gate, PR/push = validate-only, and a
manual **`workflow_dispatch` with `action` choice** (`plan`/`server-dry-run`
then `apply`), fail-soft skip-green when the environment secret is absent,
destructive-plan guard, and a namespace kubeconfig materialized only inside the
protected environment. That cutover workflow now exists as
[`.github/workflows/web-stack.yml`](../../.github/workflows/web-stack.yml)
(TIN-2543): the same chassis, but **apply-only**. It triggers ONLY on
`workflow_dispatch` with a required `confirm=apply` sentinel (no push/PR), gates
fail-closed on the protected `web-apply` environment holding
`web-apply-kubeconfig`. Its retained private-core checkout is not executable
from this public repo without a separately governed source grant, so it is not
the current release authority. It takes the operator-resolved
image as a dispatch `image` input (never a committed pin), and runs `just web-stack-apply`
(promotion interlock, workload apply, imperative image pin, `replicas` patch)
followed by an in-cluster `/health` readiness gate. It does **not** un-park the overlay: the `k8s/web/`
tree stays DISPATCH-GATED declare-only and `scripts/validate-web-stack.sh` guards
that shape — `replicas: 2`, a digest-pinned
`ghcr.io/great-falls-tool-bus/greatfallstoolbus.org` image, no `Namespace`
object, and no in-tree apply path. The
`greatfallstoolbus-org-production` namespace and the `web-apply` SA/RBAC are
minted by the operator out of band first (the SA is namespace-scoped and cannot
create namespaces).

The public app repo's `tinyland.repo.json` boundaries will need
`owns_container_image_production=true` while `owns_gitops_apply=false` and
`owns_cloudflare_mutation=false` stay false (the overlay still owns the pin +
apply). That boundary-schema change is made explicitly by ADR 0008 (research
brief OQ-4), not silently drifted.

### Route B — direct operator `kubectl`/`tofu`

An authorized operator applies the overlay out of band with the
**namespace-scoped `web-apply-kubeconfig`**. This is the same RBAC pattern the
list and form stacks already use — read those apply runbooks for the mechanics:

- [`docs/runbooks/list-bringup.md`](list-bringup.md) — see **Pre-apply gates**
  (esp. gate 2, *Apply RBAC scope*): the existing `mail` environment kubeconfig
  is scoped to `MailDomain`/`MailAccount`/`MailAlias` **only** and **cannot**
  apply Deployments/Services/NetworkPolicies; a workload apply needs a broadened
  namespace grant or a dedicated namespace-scoped kubeconfig.
- [`docs/mail-cr-apply-runbook.md`](../mail-cr-apply-runbook.md) — the
  kubeconfig custody + `server-dry-run` → `apply` flow (`GFTB_MAIL_KUBECONFIG`
  local / `*_KUBECONFIG_B64` protected-environment secret; materialize, then
  `just …-server-dry-run` before `just …-apply`).
- [`docs/runbooks/list-operations.md`](list-operations.md) — the post-apply
  read-only `kubectl --kubeconfig … -n <ns> get deploy,svc,pvc,networkpolicy`
  verification idiom.

**`web-apply-kubeconfig` is named-only.** It is enumerated **by name** in
[`k8s/web/secrets.contract.yaml`](../../k8s/web/secrets.contract.yaml)
(`status: not-yet-provisioned`) — a namespace-scoped SA kubeconfig able to apply
the `greatfallstoolbus-org-production` workload objects, in a protected
environment, explicitly **not** the mail CR-only kubeconfig (which cannot apply
workloads). **Provisioning it is an operator step** (mint the SA + RBAC grant,
base64 into the protected `web-apply` environment / operator keychain); the
apply **fails closed on RBAC until it is minted** — the same gate the list/form
stacks sit behind. No kubeconfig value, token, or digest appears in this repo.

### DNS leg (P6) belongs to the edge stack

For both routes, the P6 DNS flip is **not** a blahaj action: apex+www records
are owned by this overlay's `tofu/stacks/edge*` (zero-scoped token
`cloudflare-api-token-gftb-zones`, `edge` environment). It runs through the
`edge-plan.yml` `workflow_dispatch action=apply` lane, independent of the
workload apply. blahaj declares only the in-cluster Service + tunnel-ingress
NetworkPolicy; the public-hostname route (P5) is dashboard/token-managed
(TIN-991).

---

## Invariants this cutover must not break

- **Public repo holds zero secrets.** On-cluster serving does not weaken
  TIN-2537 — it lets the public repo **retire** its CF Pages-Edit token. No
  kubeconfig, image digest, tunnel route, DNS record, or Cloudflare token ever
  lands in `Great-Falls-Tool-Bus/greatfallstoolbus.org`.
- **The overlay is declared and validated, and applying it stays gated.** ADR
  0010 moved `k8s/web/` from a parked skeleton to the executing cutover shape:
  the default branch carries `replicas: 2` and a digest-pinned
  `ghcr.io/great-falls-tool-bus/greatfallstoolbus.org` image, and
  `scripts/validate-web-stack.sh` *requires* both. What stays closed is the apply
  gate plus the namespace and route axes — no `Namespace` object, no Secret, no
  route in git — so merging still applies nothing and routes no public traffic.
- **Names-only, always.** Credentials are referenced by name and resolve from
  the tenant SOPS lane / protected GitHub environments / live cluster Secrets —
  never from this file, never committed.

## Exit criteria — MET (2026-07-06/07)

On-cluster origin serving apex+www through the honey-ingress tunnel; both
replicas `Ready` and spread across bumble/sting; `/health` `200` in-cluster and
at the edge; Prometheus targets `up`. **Superseded from the original
criteria:** "CF Pages retained warm and DNS-reversible through soak" and "the
public app repo's CF Pages-Edit token retired only after Pages decommission"
described the *plan*; ADR 0010 Amendment 2 overrode it — Pages is deleted and
the token is retired as of 2026-07-06/07 (P7), not held pending a later
decommission decision. The standing safety net is no longer "single-DNS-flip
rollback to CF Pages" (that target no longer exists) — it is the on-cluster
re-pin-previous-digest primitive via `web-stack.yml` (see P7's corrected
rollback), which holds only while the live image is not a gftb-site reference
(section S "Rollback" governs after the promotion).

---

# S — gftb-site static origin promotion (NOT executed)

Everything above is the **executed** adapter-node cutover, retained as
apply-wiring reference. This section is the separate, not-yet-run promotion of
the static `gftb-site` origin. Tracking: **TIN-3816** (prove interim apex
served), under the **TIN-2543** web stack.

## Topology: the cutover is IN PLACE, not into a second namespace

The static origin replaces the adapter-node workload **inside the existing
`greatfallstoolbus-org-production` namespace**, on the existing
`Deployment/greatfallstoolbus-org` and behind the existing
`Service/greatfallstoolbus-org`. Nothing about the public path changes: the apex
and www already resolve to the honey-ingress tunnel, and the tunnel already
routes to that Service. There is **no** Cloudflare change in this promotion and
**no** second namespace, which is precisely why the landed proofs
(`web-release-pinned-running-proof`, `web-release-served-proof`) can observe the
result at all — they read that namespace and that external URL.

## One renderer, one set of bytes

`just web-release-render` (landed in PR #109) is the **only** renderer in this
repository. It reads the committed adapter-node manifests, transforms them into
the reviewed static-Caddy shape for `${WEB_APPLY_IMAGE}`, asserts the rendered
object census and the NetworkPolicy semantic digest, and writes YAML to stdout.
The mutation chain added here never renders anything of its own:

- `just web-release-plan` runs that renderer once and records the exact bytes,
  their SHA-256, the selected image and source SHA, and the infra carrier commit
  under the operator-private `.k8s-plans/` root (0700; artifacts 0600, gitignored).
- `just web-release-apply` re-runs the renderer and **refuses** unless the
  re-render is byte-identical to the recorded plan and the carrier commit and
  inputs are unchanged — then applies *the recorded bytes*.

No step in the chain resolves an image, runs `kubectl set image`, or patches
replicas. `web-release-render` bakes `${WEB_APPLY_IMAGE}` and `replicas: 2` into
the bytes, so the live pod template can only ever be a render of reviewed inputs.
`scripts/validate-public-operator-surface.py` scans the **whole** Justfile for
imperative pinning and allows it in exactly one legacy recipe
(`web-stack-apply`, the adapter-node carrier).

## Inputs (the contract is PR #109's, unchanged)

`_web-release-candidate-inputs` is the single input guard for both the proofs
and the mutation chain:

| Variable | Contract |
|---|---|
| `WEB_APPLY_IMAGE` | exactly `ghcr.io/great-falls-tool-bus/gftb-site@sha256:<64 lowercase hex>` |
| `WEB_APPLY_SHA` | exactly 40 lowercase hex (the `gftb-site` source commit built into that image) |
| `WEB_APPLY_REPLICAS` | must be exactly `2` if set at all |
| `HTTP(S)_PROXY`/`ALL_PROXY`/`NO_PROXY` | must be empty — release work does not transit an ambient proxy |
| `WEB_APPLY_KUBECONFIG` | operator-custody regular file, mode `0600`, outside every repository tree; ambient `KUBECONFIG` is refused |

The committed manifests are **not** where the gftb-site digest lives.
`scripts/validate-web-stack.sh` binds image admission to the stack under
validation: `greatfallstoolbus-org-production` admits
`ghcr.io/great-falls-tool-bus/greatfallstoolbus.org` and nothing else, so
substituting the gftb-site candidate into `deployment.yaml` **fails `just
check`** rather than widening the guard.

## S1 — Prove the candidate (read-only, no cluster)

```bash
export WEB_APPLY_IMAGE=ghcr.io/great-falls-tool-bus/gftb-site@sha256:<64 hex>
export WEB_APPLY_SHA=<40 hex gftb-site commit>

just web-release-candidate-proof
```

Anonymous, credential-free `crane` readback: the digest resolves to itself, the
manifest is a single OCI/Docker image, the config carries the reviewed
static-Caddy runtime identity, and `org.opencontainers.image.revision` equals
`WEB_APPLY_SHA`. Produces **receipt line 8** (package name, tag, digest).

## S2 — Plan (offline, no cluster, no registry)

```bash
just web-release-plan
```

Records the rendered bytes and their receipt. Review them before applying:

```bash
just web-release-render | less
```

## S3 — Dry-run and apply (attended)

```bash
export WEB_APPLY_KUBECONFIG=/operator/path/web-apply.kubeconfig

just web-release-server-dry-run
GFTB_APPLY_CONFIRM=apply just web-release-apply
```

Before S3, **quiesce the `greatfallstoolbus.org` repository**: no pushes to its
`main` while this promotion is in flight (see the legacy-CD invariant below).

`web-release-apply` refuses unless the worktree is a clean, signed checkout equal
to canonical `main` (`_reviewed-clean-main`), `GFTB_APPLY_CONFIRM=apply` is set,
the kubeconfig satisfies its custody contract **and passes an authorization
preflight**, and the plan still reproduces byte-for-byte. It server-dry-runs,
applies the recorded bytes, deletes the two legacy adapter-node egress policies
the render deliberately omits (`allow-egress-dns`,
`allow-egress-discuss-archive` — `kubectl apply` does not prune omissions), and
waits for the rollout.

The authorization preflight lives in `_web-release-apply-kubeconfig-contract` and
runs `kubectl auth can-i` for every verb the chain needs in
`greatfallstoolbus-org-production` — `get`/`list`/`watch`/`create`/`update`/`patch`
on `deployments.apps`, `get`/`create`/`update`/`patch` on `services` and
`networkpolicies.networking.k8s.io`, and **`delete networkpolicies`** — refusing
before anything is touched if any answer is not `yes` or if the review emits any
diagnostic. `apply --dry-run=server` authorizes only the objects it applies; it
does not authorize the delete. Without the preflight the realistic failure is a
green dry-run, a successful apply, a denied delete, and a half-done promotion
running the new image with `allow-egress-dns` still additively permitting egress.

**Rollback** has two shapes, and only one of them runs through the chain:

- **gftb-site → gftb-site** (every promotion after the first): the same chain
  with the previous `WEB_APPLY_IMAGE` / `WEB_APPLY_SHA` — re-plan, re-apply.
  The previous digest is receipt line 12 and must be recorded *before* S3 so
  the rehearsal is possible.
- **First promotion, back to the adapter-node origin**: **not executable
  through the chain.** `_web-release-candidate-inputs` accepts only
  `ghcr.io/great-falls-tool-bus/gftb-site@sha256:…`, so the receipt-line-12
  `greatfallstoolbus.org@sha256:…` digest is refused as a candidate, and the
  standing P7 primitive (re-dispatch `web-stack.yml` with a prior
  `greatfallstoolbus.org` digest) is refused by `_web-stack-promotion-interlock`
  the moment the live image is a gftb-site reference — i.e. from the end of S3,
  *before* S4 SERVED is proven. Between S3 and a passing S4 there is therefore
  **no repo-carried path back to the adapter-node origin.** The rollback is
  out-of-band, attended, with the web-apply kubeconfig:
  `kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" --namespace
  greatfallstoolbus-org-production set image deployment/greatfallstoolbus-org
  greatfallstoolbus-org=<receipt-line-12 greatfallstoolbus.org@sha256:…>`.
  Once the live image is no longer gftb-site the interlock reopens, and a
  `web-stack.yml` `workflow_dispatch` (`confirm=apply`, `image=<that digest>`)
  restores the two egress NetworkPolicies (`allow-egress-dns`,
  `allow-egress-discuss-archive`) that the promotion deleted. Record the
  imperative `set image` in the release notes as an out-of-band mutation; the
  receipt-line-12 "rollback rehearsal" **cannot** be rehearsed through the chain
  for the first promotion, and the receipt must say so rather than claim a
  rehearsal that did not happen.

## S4 — PINNED → RUNNING → SERVED

Each stage is a landed proof recipe, not a prose assertion:

| Stage | Recipe | What it establishes |
|---|---|---|
| **PINNED** | `just web-release-pinned-running-proof` | the live Deployment's pod template is the reviewed static-Caddy shape carrying `${WEB_APPLY_IMAGE}` and the `${WEB_APPLY_SHA}` source annotation; yields the deployment generation for **receipt line 9** |
| **RUNNING** | `just web-release-pinned-running-proof` (same run) | exactly one active ReplicaSet at `2/2`, old ReplicaSets fully scaled down, both pods `Ready` with an `imageID` ending in the selected digest, the Service EndpointSlice binding exactly those two pods, and the NetworkPolicy census + semantic digest intact; yields the pod `imageID` for **receipt line 9** |
| **SERVED** | `just web-release-served-proof` | the external URL returns `200` for `/`, `/health`, `/health.sha`, and the QR asset, the homepage marker is present, and `/health.sha` equals `${WEB_APPLY_SHA}`; yields **receipt line 10** |

`web-release-pinned-running-proof` requires `WEB_RELEASE_KUBECONFIG` — the
**proof-only** identity, which `_web-release-kubeconfig-inputs` proves cannot
mutate any release object. It is deliberately not the apply identity.

Receipt line 11 (real-device / QR / member-flow) stays a human observation: a
clean desktop and mobile browser, and a physical phone camera against the
rendered QR. No curl replaces it.

## S5 — Record the receipt

The release note records **exactly** the thirteen lines below. This list is
reproduced from the **private launch spec §9** (operator-held, operator plane);
that spec, not this runbook, is the authority for their wording and order, and
no public reader needs to resolve it to run this procedure. Every value is
non-secret by construction — never add cookies, tokens, kubeconfig
data, addresses, or any other private-plane material.

```text
1  issue and milestone
2  source repository and exact head SHA
3  tree hash and diff hash
4  reviewer identity, verdict, and reviewed SHA
5  required check names, run IDs, conclusions, and completion time
6  human ship authorization and author
7  merge SHA and time
8  package name, tag, and digest
9  infra pin commit, deployment generation, pod imageID
10 external URL, served SHA/marker, observation time
11 real-device/QR or member-flow result
12 previous digest and rollback rehearsal/result
13 Linear receipt link
```

Where each line comes from in this chain:

| Line | Source |
|---|---|
| 1, 4, 6, 13 | Linear + the reviewing human; not machine-derived |
| 2, 3 | the `gftb-site` source repository at `${WEB_APPLY_SHA}` |
| 5 | the `gftb-site` required checks (`gh run list`). `web-cd-ci-green-gate` is **not** part of this release: it gates the LEGACY adapter-node CD path (`web-stack.yml`), which this promotion must be protected from — see the invariants below |
| 7 | the `gftb-site` merge commit |
| 8 | `just web-release-candidate-proof` |
| 9 | the infra carrier commit recorded by `just web-release-plan`, plus `just web-release-pinned-running-proof` |
| 10 | `just web-release-served-proof` |
| 11 | operator observation (S4) |
| 12 | the previous `WEB_APPLY_IMAGE` digest and the S3 rollback rehearsal result |

## Invariants this promotion must not break

- **The legacy CD path must not be allowed to revert this.** THIS IS THE ONE
  THAT BITES. `.github/workflows/web-stack.yml` still carries
  `repository_dispatch: types: [web-image-published]`, which the PUBLIC site repo
  `greatfallstoolbus.org` fires from its own `container-ghcr.yml` on **every push
  to `main`**. That dispatch runs `just web-stack-apply` against
  `Deployment/greatfallstoolbus-org` in `greatfallstoolbus-org-production` — the
  same object this promotion cuts over. Unchecked it would (a) imperatively
  re-pin the adapter-node digest back over the gftb-site static origin and (b)
  re-apply the committed kustomization, which **recreates** `allow-egress-dns`
  and `allow-egress-discuss-archive` that `web-release-apply` just deleted --
  omissions are not pruned -- undoing the empty-egress invariant. The next green
  push to the site repo would silently falsify the SERVED proof.

  Two things hold it:

  1. **Mechanical (this repo).** `just web-stack-apply` now takes
     `_web-stack-promotion-interlock` as its FIRST dependency. The interlock
     reads the LIVE Deployment's container image and exits non-zero if it already
     carries a `ghcr.io/great-falls-tool-bus/gftb-site` reference — i.e. exactly
     when the promotion is in place. **It precedes every mutation**: it is the
     first dependency of the only recipe that mutates this workload, so the
     dispatched CD job fails loudly instead of reverting. It does NOT gate the
     workflow's *separate, earlier* `just web-stack-server-dry-run` step — that
     step is `apply --dry-run=server` and changes nothing, so a green dry-run
     step followed by an interlock refusal in the apply step is the expected
     shape, not a bypass. `scripts/validate-public-operator-surface.py` fails
     `just public-surface` if the interlock is removed, weakened, demoted out of
     first position, or edited: its body is pinned by SHA-256 in
     `WEB_RELEASE_CRITICAL_RECIPE_DIGESTS` like the rest of the chain.
  2. **Operator (the other repo).** *Do not push to `greatfallstoolbus.org`
     `main` during or after this promotion until the legacy CD dispatch is
     retired.* Quiesce it before S3 and keep it quiesced. The interlock turns a
     silent revert into a red workflow run, but a red run on every site push is
     still noise the operator has to own.

  Retiring the `web-image-published` dispatch (and with it `web-stack-apply`,
  `web-cd-ci-green-gate`, and the adapter-node image entirely) is **Phase-5**
  work and is deliberately NOT in this change: the adapter-node workload is still
  the live origin until S3 succeeds, and removing its only apply path before the
  static origin is proven SERVED would leave no way to roll forward.

- **The pin is rendered, never patched.** Writing `kubectl set image`, a
  `scale`, a replicas patch, a `rollout undo`, a `replace -f`, a `delete …
  deployment`, a `delete -f`/`delete --filename`, a `kubectl edit deployment`, a
  JSON patch of the container image path, or a **merge** patch that carries the
  image through `spec.template.spec.containers[]` (`--type merge -p
  '{"spec":{"template":{"spec":{"containers":[{"image":…`) — literally, on one
  logical line, including through a `kubectl…` wrapper such as `kubectl_clean`
  and across backslash line continuations — anywhere in the Justfile outside the
  allowlisted legacy `web-stack-apply` fails `just public-surface`. The same
  scan refuses a `kubectl` tree-apply (`-k`, `-f`, `--kustomize`, `--filename`)
  aimed at `{{ web_stack_dir }}` (or its literal path) from any recipe other than
  `web-stack-apply` and `web-stack-server-dry-run`, because a fresh
  tree-apply would recreate `allow-egress-dns`/`allow-egress-discuss-archive`
  and re-pin the tree's adapter-node digest without ever passing through
  `_web-stack-promotion-interlock` (only `web-stack-apply` is bound to it).
  Both scans are textual and do **not** see shell *variable indirection*
  (`KC=kubectl; "${KC}" … set image`, a patch body assembled into a variable
  on a previous line, or the tree directory bound to a variable first and the
  variable passed to the tree-apply on the next line).
  What makes an edit to a reviewed release recipe fail closed is the recipe-body
  SHA-256 in `WEB_RELEASE_CRITICAL_RECIPE_DIGESTS`, not this scan.
- **One renderer.** A second renderer in the plan or apply path changes the
  recipe body digest and fails `just public-surface`.
- **The chain is proved behaviorally, not only by digest.** `just
  public-surface-selftest` runs `web-release-plan` → `_web-release-plan-preflight`
  → `web-release-server-dry-run` → `web-release-apply` and
  `_web-stack-promotion-interlock` as real child processes against mocked
  `kubectl`/`just`/`git`, and asserts the exact `kubectl` argument order, that the
  authorization preflight is the first thing that touches the cluster, that the
  egress prune carries `--ignore-not-found` and runs AFTER the apply and BEFORE
  the rollout wait, that a denied verb refuses with nothing applied, and that the
  interlock refuses on a promoted live image and proceeds otherwise.
- **The committed manifests never carry the gftb-site digest.** Image admission
  is bound to the stack under validation.
- **No namespace, no Secret, no Cloudflare.** The package is anonymously
  pullable, so the namespace needs no registry credential, and the tunnel route
  is untouched.
- **Names-only, always.** Same rule as the executed cutover above.
