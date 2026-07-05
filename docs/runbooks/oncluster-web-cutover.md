# GFTB on-cluster web serving — phased cutover runbook

Tracking: **TIN-2543**. Authorizing decision: **ADR
[`docs/decisions/0008-oncluster-web-serving.md`](../decisions/0008-oncluster-web-serving.md)**
(the superseding on-cluster hosting ADR). Warm-standby mitigation: **ADR
[`docs/decisions/0007-cf-pages-warm-standby.md`](../decisions/0007-cf-pages-warm-standby.md)**.
Superseded snapshot: ADR
[`docs/decisions/0003-static-production-cf-pages.md`](../decisions/0003-static-production-cf-pages.md).
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
> The `k8s/web/` overlay stays **parked** (`replicas: 0`, placeholder image, no
> namespace, no route) until an operator runs the phases below. Executing this
> runbook is authorized **only** by ADR 0008; nothing here un-parks the overlay
> in git.

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
| P6 | Flip apex + www DNS Pages → tunnel; keep Pages warm | [OPERATOR] | public traffic |
| P7 | Soak, then later decommission Pages | [OPERATOR] | retires standby |

Phases are strictly ordered. Do not start a phase until the prior phase's
verify step is green. P5/P6 are the only phases that change public posture; up
to and including P4 the site is still served by CF Pages and nothing public has
moved.

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

## P6 — Flip apex + www DNS: CF Pages → tunnel (keep Pages warm)

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

**Rollback (fast, single action):** repoint the apex+www CNAME back to the CF
Pages target via the edge stack (`workflow_dispatch action=apply` with the
reverted record) — Pages is still warm and serves immediately. This is the
reason P7 defers Pages decommission until after soak.

---

## P7 — Soak, then decommission Pages later

**[OPERATOR].** Soak the on-cluster origin under real traffic (recommend at
least one full weekly cycle). Watch: Prometheus `up`/latency/error-rate for the
`greatfallstoolbus-org-production` targets, pod restart counts, and Cloudflare
edge analytics. Keep CF Pages **warm** (built, green, DNS-reversible) for the
entire soak — ADR 0007's mitigation only holds while Pages can still take the
apex back in one DNS flip.

Only after a clean soak, and as a **separate deliberate decision**, retire the
CF Pages production project (and its account-scoped Pages-Edit token per the
ADR 0003 token doctrine). Retiring Pages also lets the **public app repo retire
its one live CF Pages-Edit token** — the authority split (app repo owns
behavior+image; private overlay owns pin+apply; blahaj is substrate) then keeps
every privileged surface out of the public repo, which is the load-bearing
TIN-2537 invariant.

**Rollback:** until Pages is decommissioned, P6 rollback still applies. After
decommission, rollback means re-standing-up a Pages project from the public repo
(minutes, not instant) — hence do not decommission until soak is clean.

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
fail-closed on the GF core read credential **and** the protected `web-apply`
environment holding `web-apply-kubeconfig`, takes the operator-resolved image as
a dispatch `image` input (never a committed pin), and runs `just web-stack-apply`
(workload apply, image pin, `replicas` flip 0 to N) followed by an in-cluster
`/health` readiness gate. It does **not** un-park the overlay: the `k8s/web/`
tree stays declare-only and `scripts/validate-web-stack.sh` still guards
`replicas: 0` + placeholder image + no namespace. The
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
- **The parked overlay stays parked in git.** The pin/replicas/namespace/route
  changes live in an operator private-overlay cutover branch, reviewed; the
  `k8s/web/` skeleton on the default branch keeps `replicas: 0` + placeholder
  image + no namespace + no route. `scripts/validate-web-stack.sh` guards the
  declare-only posture.
- **Names-only, always.** Credentials are referenced by name and resolve from
  the tenant SOPS lane / protected GitHub environments / live cluster Secrets —
  never from this file, never committed.

## Exit criteria

On-cluster origin serving apex+www through the honey-ingress tunnel; both
replicas `Ready` and spread across bumble/sting; `/health` `200` in-cluster and
at the edge; Prometheus targets `up`; CF Pages retained warm and DNS-reversible
through soak (ADR 0007); the public app repo's CF Pages-Edit token retired only
after Pages decommission (P7). Until every phase is green and soaked, the
single-DNS-flip rollback to CF Pages is the standing safety net.
