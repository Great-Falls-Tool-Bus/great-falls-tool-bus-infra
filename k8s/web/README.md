# GFTB on-cluster web serving — ATTENDED-ONLY declare-only (TIN-2541, ADR 0010, TIN-3899)

> **MERGING THIS DIRECTORY APPLIES NOTHING — and since TIN-3899 no workflow
> applies it either.** `greatfallstoolbus-org-production` carries `replicas: 2`
> and a digest-pinned production image, and `scripts/validate-web-stack.sh` (run
> by `just web-stack-validate`) *requires* exactly that: replicas `2`, a full
> `@sha256:<64 lowercase hex>` pin on this stack's own admitted repository, and a
> hard failure on any `PLACEHOLDER` marker. The legacy CD carrier
> `.github/workflows/web-stack.yml` — `workflow_dispatch` **and** the
> `repository_dispatch: web-image-published` the public site repo fired on every
> push to `main` — is **deleted**, together with the site-side signal job. No
> workflow in this repository can mutate `Deployment/greatfallstoolbus-org`, and
> no cross-repo dispatch can reach `kubectl`. The one surviving apply path is an
> attended operator running `just web-stack-apply` with an operator-custody
> kubeconfig, and `_web-stack-promotion-interlock` refuses even that once the
> gftb-site static origin is live. This stack creates **no** Namespace, ships
> **no** Secret, and changes **no** Cloudflare route or DNS record.

## What this is

The stack that serves the GFTB web app **fully on-cluster**, mirroring the proven
MassageIthaca pattern: the `gftb-site` SvelteKit `adapter-static` build served by
Caddy → OCI image on GHCR → K8s `Deployment` behind a `ClusterIP` `Service` →
in-cluster `cloudflared` tunnel edge (no Cloudflare Pages, no Vercel on the
serving path). The Deployment/Service/NetworkPolicy stack itself began as the
"DECLARE-ONLY skeleton note" of
[`docs/decisions/0001-pr-gated-ephemeral-preview-deploys.md`](../../docs/decisions/0001-pr-gated-ephemeral-preview-deploys.md)
and was promoted to the executing cutover shape by ADR 0010, grounded in the
TIN-2537 research brief
(`docs/research/full-oncluster-web-serving-2026-07.md`, branch
`docs/oncluster-web-research`); the `gftb-site` static-origin promotion (below)
later replaced what image runs on that same stack.

```
visitor -> greatfallstoolbus.org (Cloudflare edge, TLS terminates here)
        -> honey-ingress cloudflared tunnel   [dashboard/token-managed route — NOT in git]
        -> Service greatfallstoolbus-org:80  (ClusterIP)
        -> Deployment greatfallstoolbus-org  (gftb-site static Caddy origin, :3000, /health probes)
```

## Files

| File | Role | Fail-closed posture |
|---|---|---|
| `greatfallstoolbus-org-production/deployment.yaml` | gftb-site static-origin web Deployment | `replicas: 2`; **digest-pinned** `ghcr.io/great-falls-tool-bus/gftb-site@sha256:e95c9588…` (a tag, a truncated or uppercase digest, a foreign repository, or a `PLACEHOLDER` marker fails `just web-stack-validate`); non-root 65532; read-only rootfs; `/health` probes on :3000 |
| `greatfallstoolbus-org-production/service.yaml` | ClusterIP 80→3000 | internal DNS only; never internet-exposed directly |
| `greatfallstoolbus-org-production/networkpolicy.yaml` | default-deny + explicit allows | ingress only from the `cloudflared` namespace (:3000) and prometheus; no egress rules declared here — the static Caddy origin makes no outbound calls, and `web-release-render` additionally synthesizes a `default-deny-egress` NetworkPolicy at ceremony time (not yet git-tracked; see the Justfile `_k8s-drift-check` header) |
| `greatfallstoolbus-org-production/kustomization.yaml` | kustomize entrypoint | renders cleanly; creates **no** Namespace |
| `secrets.contract.yaml` | names-only three-plane secrets contract | no values, ever |
| `pr-env-lane.md` | reaper / PR-env lane note | parked (see below) |
| `../../tofu/intent/great-falls-tool-bus/web-oncluster-route.json` | cloudflared route intent | `applied:false`, `dns_enabled:false`, `route_enabled:false` |
| `../../tofu/intent/great-falls-tool-bus/pr-env-lanes.schema.json` | reaper lane contract | `enabled:false`; names-only |

## What actually holds this closed

1. **Nothing applies, from anywhere in CI.** `web-crs.yml` is validation-only,
   and TIN-3899 deleted the only apply plane there ever was
   (`.github/workflows/web-stack.yml`, reachable by `workflow_dispatch` with
   `confirm=apply` and by `repository_dispatch: web-image-published` from the
   public site repo). `scripts/validate-public-operator-surface.py` now fails
   `just public-surface` if that file reappears, if any workflow declares a
   `repository_dispatch` trigger, or if any workflow invokes `web-stack-apply` —
   the hosted Just allowlist is an exact census, so re-adding the call is a red
   check, not a silent regression.
2. **The declared shape is validated, not placeholder-parked.**
   `scripts/validate-web-stack.sh` asserts `replicas: 2`, derives the admitted
   container repository from the Deployment's **own** target namespace, and
   requires `ghcr.io/great-falls-tool-bus/gftb-site@sha256:<64
   lowercase hex>`. A `PLACEHOLDER` marker, a tag, a truncated or uppercase
   digest, or any other repository — including the retired legacy
   `ghcr.io/great-falls-tool-bus/greatfallstoolbus.org` adapter-node image —
   fails.
3. **No namespace, no Secret.** `greatfallstoolbus-org-production` is not created
   here (a `kind: Namespace` object fails validation) and the namespace-scoped
   `web-apply` SA cannot create one; the namespace, the SA/RBAC, and the GHCR
   pull Secret are operator-provisioned out of band.
4. **The surviving attended carrier is interlocked.** `just web-stack-apply`
   takes `_web-stack-promotion-interlock` as its FIRST dependency. The interlock
   reads the LIVE Deployment image and refuses when it is already a
   `ghcr.io/great-falls-tool-bus/gftb-site` reference. It was written to stop the
   unattended `repository_dispatch` path from reverting the in-place promotion;
   that path is now gone, and the interlock is retained as belt-and-braces on the
   attended one — an operator cannot revert the promotion by hand either. Its
   body is SHA-256-receipted in `WEB_RELEASE_CRITICAL_RECIPE_DIGESTS`, so
   removing, weakening, or demoting it fails `just public-surface`.

## The tunnel route is dashboard-managed (not in git)

The public path rides the shared **honey-ingress** cloudflared connector
(`blahaj:deploy/honey/retained-cloudflared.yaml`). Its public-hostname routes
are **Cloudflare dashboard / token-managed** (TIN-991 route authority
unfinished); there is **no** route object in this repo and **no** live
`cfargotunnel` UUID inlined. The route intent JSON records the *shape* fail-closed
only. The zone token lives in the protected `edge` environment; the
`TUNNEL_TOKEN` is a live cluster Secret only. See `secrets.contract.yaml`.

## Reaper / PR-env lane: parked

Per-PR ephemeral previews are **parked**, not adopted. ADR 0001's recommended
Option A — Cloudflare Pages managed previews — is now moot: that CF Pages
project was **deleted 2026-07-06**, so it is not an available channel to adopt.
The channel that actually exists today is the attended `web-release-*` /
`web-stack-apply` ceremony described above (an operator runs it by hand; there
is no per-PR automation). The **ratified target**, once the staging apply
sitting lands (infra PR #121, LAND-verdict, apply pending —
`staging.greatfallstoolbus.org`), is promote-on-PR against that staging host,
per `spec/member-v0-executable-slices-2026-08-18.md:399-403,1011`; that is a
separate, not-yet-built lane, not this parked reaper. The on-cluster reaper
contract is recorded fail-closed in
`pr-env-lane.md` + `pr-env-lanes.schema.json` (`enabled:false`) so a future ADR
has a grounded start. The old honey pod-cap blocker is retired by the live probe
below; this remains parked because GFTB has not adopted per-PR on-cluster route
automation or reaper ownership. **No reaper workflow or CronJob is committed
live** and **no live token is wired** (names only).

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

## Apply path (attended only; the CD carrier is retired)

There is no CI apply plane. The historical route — the public app repo builds
and pushes the image, fires `repository_dispatch: web-image-published`, and
`web-stack.yml` runs `just web-stack-server-dry-run` then `just web-stack-apply`
then `just web-stack-health` — was retired by TIN-3899 after the gftb-site
static origin was promoted in place. Both ends are gone: the workflow here and
the `signal-cd` job in the site repo's `container-ghcr.yml`.

What remains:

1. **The attended legacy carrier (belt-and-braces).** An authorized operator with
   an operator-custody `WEB_APPLY_KUBECONFIG` may still run
   `just web-stack-apply` by hand (promotion interlock → `web-stack-validate` →
   server dry-run → kustomization apply → pin the operator-supplied image → patch
   replicas → wait for the rollout). The interlock refuses while the promoted
   gftb-site origin is live, so in practice this path is closed until someone
   deliberately reopens it under review.
2. **The reviewed forward path.** The gftb-site static origin is promoted **in
   place** onto this same namespace and `Deployment/greatfallstoolbus-org` by the
   attended `web-release-*` chain — no second namespace, no Cloudflare change.
   Rollback is that same chain re-planned and re-applied with the previous
   `WEB_APPLY_IMAGE`/`WEB_APPLY_SHA`.

Neither creates the namespace, ships a Secret, or touches Cloudflare: the
honey-ingress tunnel route stays dashboard-managed and the apex/www DNS flip
belongs to the edge stack (runbook P6, executed 2026-07-06).

## Validate (parse-only; never applies)

```bash
just web-stack-validate     # invariant checks + `kubectl kustomize` render
```

`just web-stack-apply` (with `just web-stack-server-dry-run` and
`just web-stack-health`) is attended-operator-only: no workflow invokes it, and
no workflow may. This tree is **ATTENDED-ONLY declare-only**, not parked:
`scripts/validate-web-stack.sh` requires `replicas: 2` and a digest-pinned
`ghcr.io/great-falls-tool-bus/gftb-site` image here, and forbids a
`Namespace` object — the namespace and the `web-apply` SA/RBAC are minted by the
operator out of band (the SA cannot create namespaces), the tunnel route stays
dashboard-managed, and the DNS flip (P6) plus CF Pages decommission (P7) remain
separate operator steps. **Rung 1 tree honesty (2026-08-21):** this pin is now
the declarative record of what is actually served — an operator updates it here
at each `web-release-*` ceremony's pin step, it is not auto-reconciled, and
`just web-stack-drift-check` fails on a real diff. Two known gaps between this
base and what the ceremony actually produces, handled differently (see the
Justfile `_k8s-drift-check` header and `scripts/web-stack-diff.sh`): the
per-release `source-sha` annotation is stripped from both sides before
diffing (`KUBECTL_EXTERNAL_DIFF`), so it never shows up as drift; the
ceremony-synthesized `default-deny-egress` NetworkPolicy this file does not
declare can **never** show up as drift either way, because `kubectl diff -k`
has no prune awareness and is structurally blind to objects that exist only
on the cluster — a clean run of that gate is not evidence it is correct.

Because `web-stack-apply` mutates the same Deployment the gftb-site release chain
promotes, it is interlocked: `_web-stack-promotion-interlock` runs first, reads
the live image, and refuses when the promotion is already in place. See
[`../../docs/runbooks/oncluster-web-cutover.md`](../../docs/runbooks/oncluster-web-cutover.md)
section **S**, "Invariants this promotion must not break".

## Image admission is bound to THIS stack

`scripts/validate-web-stack.sh` derives the admitted container repository from
the Deployment's own target namespace, not from a shared list:

| Namespace | Admitted workload | Admitted image |
|---|---|---|
| `greatfallstoolbus-org-production` | `greatfallstoolbus-org` | `ghcr.io/great-falls-tool-bus/gftb-site@sha256:<64 lowercase hex>` |

Any other namespace fails closed, and any other repository — including the
retired legacy `ghcr.io/great-falls-tool-bus/greatfallstoolbus.org` adapter-node
image — is rejected in this stack. Tag references, truncated digests, and
uppercase digests are rejected too.

## The gftb-site static-origin release chain

The static `gftb-site` origin is promoted **in place**, on this same Deployment
and Service. It arrives as `WEB_APPLY_IMAGE`, is proved anonymously, is
rendered into the reviewed static-Caddy shape by the single renderer
`just web-release-render`, and is applied as recorded bytes; the operator also
updates `deployment.yaml`'s pin (above) as part of the same ceremony so the
declarative record and the served digest agree:

```bash
just web-release-candidate-proof   # PR #109 — anonymous registry proof (line 8)
just web-release-plan              # render once, record the bytes + carrier
just web-release-server-dry-run    # server-side dry-run of those bytes
GFTB_APPLY_CONFIRM=apply just web-release-apply
just web-release-pinned-running-proof   # PR #109 — PINNED + RUNNING (line 9)
just web-release-served-proof           # PR #109 — SERVED (line 10)
```

Nothing in that chain runs `kubectl set image`, `kubectl scale`, or a replicas
patch; `scripts/validate-public-operator-surface.py` scans the whole Justfile and
allows imperative pinning only in the attended legacy `web-stack-apply` carrier,
which no workflow may invoke. Full
procedure, inputs, rollback, and the thirteen-line release receipt:
[`../../docs/runbooks/oncluster-web-cutover.md`](../../docs/runbooks/oncluster-web-cutover.md)
section **S**.
