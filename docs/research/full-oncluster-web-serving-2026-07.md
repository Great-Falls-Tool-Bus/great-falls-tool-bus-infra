# Full on-cluster web serving for GFTB — corrections / research brief (TIN-2537)

Status: **RESEARCH BRIEF, not a decision** (authored 2026-07-05 under the
operator's standing drive/decide/adversarially-review delegation). This document
does **not** reverse ADR 0003. It assembles the grounded evidence a
*superseding* hosting ADR would need, reassesses ADR 0003's original rejection
blockers against a now-existing house precedent (MassageIthaca), and states
where the operator's own 2026-07-05 posture already resolves the framing. Every
claim is cited to a repo path read READ-ONLY; nothing here is applied.

Scope anchor (TIN-2537): the operator is weighing moving GFTB web serving FULLY
on-cluster and retiring the Cloudflare Pages split-brain, citing (1) MI already
has the full on-cluster web pattern down; (2) on-cluster gated web I/O is
already load-bearing here — the contact form is live and the `discuss@` archive
is next (TIN-2528 / TIN-2535); (3) the CF Pages rollback recommendation is
inviable under private repos (ADR 0007 / site PR #74).

## 0. Bottom line up front

- **Technical feasibility is settled, not hypothetical.** MassageIthaca serves
  its *public* web app FULLY on-cluster with **no** Cloudflare Pages and **no**
  Vercel — SvelteKit `adapter-node` → OCI image on GHCR → K8s Deployment behind
  a ClusterIP Service → in-cluster `cloudflared` tunnel edge. This is a clean,
  copyable house reference. The ADR 0003 blocker "**no house precedent**" is
  **dissolved**.
- **The gating constraint is NOT technical — it is the public-repo secret
  boundary, and it stays satisfied.** Moving serving on-cluster keeps ZERO
  secrets in the soon-public `greatfallstoolbus.org` repo, and in fact *removes*
  the one live Cloudflare credential that repo carries today. The authority
  split (app repo owns the image; private overlay owns the pin + apply) is
  exactly MI's model and exactly the three-layer boundary GFTB already ships.
- **The operator's own latest posture (TIN-2535 comment, 2026-07-05) already
  frames this correctly:** static/prerendered production → CF Pages (ADR 0003
  stands, scoped to static production); PoW-gated dynamic (form, and next the
  archive) → on-cluster via Anubis. That is *coherent*, not split-brain. The
  live decision this brief informs is narrower than TIN-2537's title suggests:
  it is whether to *also* move the **static production** surface on-cluster, not
  whether on-cluster web serving is viable (it already is, and is load-bearing).
- **Recommendation (§7): do NOT retire CF Pages by fiat.** Keep ADR 0003 as the
  standing production-static ruling; adopt the MI pattern as the *sanctioned*
  path for every gated/dynamic surface (already true for the form); and treat a
  full static-production migration as an operator-gated, phased, reversible
  option that a superseding ADR — grounded on a live pod-headroom probe — would
  authorize. This brief is that ADR's evidence base.

## 1. The MI proven full-on-cluster web pattern, and how GFTB adopts it

### 1a. What MI actually does (cited)

MassageIthaca is a two-source-of-truth system — `Jesssullivan/MassageIthaca`
(app + container) and `tinyland-inc/blahaj` (infra/tofu/k8s/tunnel) — and it is
the clean reference for full on-cluster web serving:

| Layer | Mechanism | Citation |
|---|---|---|
| Adapter | SvelteKit `@sveltejs/adapter-node` (a long-running Node HTTP server, **not** `adapter-static`); build emits `build/index.js` | `Jesssullivan/MassageIthaca:svelte.config.js` |
| Artifact | multi-stage OCI image: builder runs `pnpm run build` (`CONTAINER=1`); prod stage copies `build/` + `static/`, installs `--prod`, runs non-root uid/gid 1001 under dumb-init, `EXPOSE 3000`, `CMD ["node","build/index.js"]`, HEALTHCHECK on `/`. Published `ghcr.io/jesssullivan/massageithaca:sha-<commit>` | `MassageIthaca:ContainerFile`, `.github/workflows/docker-ghcr.yml` |
| Deployment | `kubernetes_deployment_v1` in **blahaj** (not the app repo): containerPort 3000, RollingUpdate, liveness+readiness HTTP `GET /api/health`:3000, runAsNonRoot 1001, anti-affinity + topology-spread, PDB, prod `replicas=2` | `blahaj:tofu/stacks/massageithaca/main.tf`, `tofu/config/massageithaca-prod-honey.tfvars.json` |
| Service | plain **ClusterIP** port 80 → targetPort 3000; internal DNS only, never internet-exposed | `blahaj:tofu/stacks/massageithaca/main.tf` (~L587) |
| Public edge | in-cluster `cloudflared` named-token tunnel (`honey-ingress`, id `da3ffda2-68ee-46d1-aa55-ec8dae2bd471`), apex+www are PROXIED CNAMEs → `<id>.cfargotunnel.com`, forwarding to `http://massageithaca.massageithaca-prod.svc.cluster.local:80` | `blahaj:deploy/honey/retained-cloudflared.yaml`, `tofu/intent/massageithaca/public-edge-routes.json` (`active_production_routes`) |
| TLS | terminates at Cloudflare edge (`proxied: true`); origin hop tunnel→Service is plain in-cluster HTTP. cert-manager is used ONLY for tailnet-only `test-*`/`prod-*` ingress-nginx hosts, **not** the public apex | `blahaj:tofu/stacks/massageithaca/main.tf` |
| Caching | no dedicated in-cluster HTTP cache tier; edge cache is whatever the Cloudflare proxy gives. Static assets ship *inside the image* (`/app/static` + built client bundle) and are emitted by the Node process. Redis exists but caches the schedule/data layer, not page HTML | `blahaj:tofu/config/…tfvars.json` (`enable_app_redis`), MI `Caddyfile` (dev-only) |
| Promotion | operator-gated in blahaj, decoupled from app CI: live pin `image_tag: "sha-05ba728"`; promotion = a reviewed canonical-pin PR + protected OpenTofu apply. App repo deliberately does NOT auto-write prod pins (PR #505 auto-writer rejected) | `blahaj:tofu/config/massageithaca-prod-honey.tfvars.json`, MI `docs/deployment/ci-cd-pipeline.md` |
| Security | `default-deny-ingress` NetworkPolicy + explicit allows (tailscale, cloudflared ns, ingress-nginx, prometheus, cron→app, app→db:5432, app→redis:6379); a hard "no cron may send email" invariant | `blahaj:tofu/stacks/massageithaca/main.tf`, `tofu/intent/massageithaca/prod.intent.json` |

MI's own doctrine is explicit: "Production public traffic is served by the
Blahaj-managed massageithaca-prod Kubernetes lane. Cloudflare Tunnel routes apex
and www traffic to the in-cluster Service. Vercel is no longer the active
production scheduler…" (`MassageIthaca:docs/deployment/overview.md`). Vercel envs
drained 2026-05-16; Neon closed 2026-07-03. **MI is a clean full-on-cluster
reference with Cloudflare used ONLY as tunnel edge — no Pages, no Vercel.**

### 1b. The fundamental divergence from a static spoke

site.scaffold / GFTB static today = `adapter-static` → prerendered files → CF
Pages CDN. MI = `adapter-node` → a running Node pod. The migration is not a
config toggle: it swaps the artifact from *object storage* to a *pod that must
stay alive* — liveness/readiness on `/api/health`, RollingUpdate, PDB,
`replicas=2`, and (if it lands on `sting`) the `compute-expansion` toleration.
This is strictly heavier than a static spoke and is the honest cost side of the
ledger.

### 1c. Concrete GFTB adoption map

The app repo `Great-Falls-Tool-Bus/greatfallstoolbus.org` (soon public) and this
private overlay `great-falls-tool-bus-infra` map onto MI's two-repo split
one-for-one:

| MI element | GFTB equivalent | Owner repo |
|---|---|---|
| `svelte.config.js` adapter swap to `adapter-node` | same swap in the GFTB site | **public** `greatfallstoolbus.org` (behavior only) |
| `ContainerFile` → `node build/index.js`:3000, `/api/health`, non-root 1001 | copy verbatim, adjust static/ + routes | **public** `greatfallstoolbus.org` |
| `docker-ghcr.yml` → `ghcr.io/…:sha-<commit>` | `ghcr.io/great-falls-tool-bus/greatfallstoolbus.org:sha-<commit>`, published by the **ambient `GITHUB_TOKEN`** (same-org GHCR — no cross-org secret) | **public** `greatfallstoolbus.org` CI |
| `blahaj:tofu/stacks/massageithaca/main.tf` Deployment+Service | a GFTB app stack under **this overlay** `tofu/stacks/…` (or an extension of the existing `k8s/…/latoolb-us-production/` apply-plane) | **private overlay** |
| `tofu/config/…tfvars.json` image pin | operator-gated pin bump in the overlay | **private overlay** |
| `public-edge-routes.json` route intent | a GFTB route-contract JSON mirroring `blahaj:tofu/intent/great-falls-tool-bus/forms-intake-route.json` (TIN-2420) | **private overlay** intent; route applied operator-side |

Note the authority-split is *already* how GFTB serves the live form: this repo
already carries on-cluster web-I/O manifests at
`k8s/form/latoolb-us-production/` (Anubis PoW → form-handler → Mailman LMTP; see
`docs/runbooks/form-intake.md`). The "on-cluster web serving muscle" is not
hypothetical for GFTB — it is load-bearing today.

## 2. The blahaj / tofu apply model + state backend GFTB reuses

The apply substrate is `tinyland-inc/blahaj` (honey RKE2). Reusable pieces:

- **Apply entrypoint:** never invoke tofu directly. `just tofu-init TARGET`,
  `just tofu-plan STACK CLUSTER='honey'`, `just tofu-apply STACK CLUSTER='honey'`
  (`blahaj:Justfile` group `tofu`, L59-72 → `scripts/tofu-*.sh`). This overlay
  already mirrors the shape with `just arc-*`, `just edge-*`, `just form-stack-*`.
- **State backend = RustFS (S3-compatible), NOT AWS.** Per-stack backend HCL:
  `bucket="tofu-state"`, `key="<repo>/<stack>/terraform.tfstate"`, endpoint
  `http://tofu-state-rustfs.nix-cache.svc:9000`, `use_path_style` + all `skip_*`
  true (`blahaj:tofu/backend/netbox.honey.s3.hcl`). This overlay's own coords
  live at `great-falls-tool-bus-infra:tofu/backend/honey.s3.hcl` +
  `honey-edge.s3.hcl` (key prefix `great-falls-tool-bus-infra/`). **RustFS-only
  is a hard invariant** (never Garage/MinIO). State access = a
  `kubectl port-forward svc/tofu-state-rustfs` in `nix-cache` with SOPS-decrypted
  `rustfs_access/secret_key` exported as `AWS_ACCESS_KEY_ID/SECRET`
  (`blahaj:scripts/lib/tofu-backend.sh`).
- **Free safety rails a GFTB stack inherits by living under `tofu/stacks/`:**
  `tofu-apply.sh` refuses (1) `TOFU_APPLY_BLOCKED_STATES`, (2) stacks resolving
  outside `tofu/stacks/`, (3) any stack whose `tofu state list` is EMPTY
  (split-brain / wrong-backend guard). Override flags are deliberate operator
  choices.
- **Canonical on-cluster web-service template = `blahaj:tofu/stacks/tinyland-dev/main.tf`**
  (ConfigMap + Secret + Deployment[non-root 1001, `/api/health`:3000,
  config/secret checksum annotations, ghcr pull secret, tolerations] + ClusterIP
  80→3000 + Ingress + CF DNS + NetworkPolicies). **Tunnel-only variant =
  `blahaj:tofu/stacks/mi-portal-deploy/main.tf`** ("tunnel-only: no tailscale
  expose, no ingress-nginx"; bare ClusterIP:3000, the only public-ingress
  NetworkPolicy allows the `cloudflared` namespace, gated by
  `enable_cloudflare_tunnel_ingress` flipped true at cutover). This is the
  closest template for a GFTB public site fronted by `honey-ingress`.
- **Two-stack split:** a thin `<name>-deploy` stack owning only
  `kubernetes_namespace_v1` (`blahaj:tofu/stacks/tinyland-dev-deploy/main.tf`),
  applied first, then the full app stack.
- **DNS authority is split and NOT blahaj's for GFTB.** `latoolb.us` /
  `greatfallstoolbus.org` zones are owned by the **`edge` stack in THIS overlay**
  (`tofu/stacks/edge*`, zone-scoped token per TIN-2385), not blahaj. blahaj
  declares only the in-cluster Service + tunnel-ingress NetworkPolicy + optional
  route-intent JSON. So a GFTB on-cluster host needs its CNAME→`cfargotunnel`
  created in **this overlay's edge stack**, and the tunnel ingress rule applied
  operator-side.
- **Off-cluster alternative for pure-static:** `blahaj:tofu/stacks/scheduling-bridge-pages/main.tf`
  is the CF Pages custom-domain binding (declare DNS + proxied CNAME only; the
  site never runs on-cluster). This is the *current* GFTB static posture and the
  lower-effort path if a surface is genuinely static and needs no in-cluster gate.

## 3. THE PUBLIC-REPO SECRET-MANAGEMENT MODEL (the gating constraint)

This is the hard constraint TIN-2537 must satisfy: keep ZERO secrets in the
soon-public `greatfallstoolbus.org` repo while serving on-cluster. **It is fully
satisfiable, and on-cluster serving does not weaken it — it strengthens it** (the
public repo drops its one live CF credential). The model is the existing
three-layer boundary (site
`docs/decisions/0002-blahaj-substrate-boundary.md`), unchanged by moving serving
on-cluster because the authority split (image vs pin) keeps every privileged
surface out of the public repo.

### 3a. What lives where (explicit table)

| Artifact | PUBLIC `greatfallstoolbus.org` (Layer 3, declare-only) | PRIVATE `great-falls-tool-bus-infra` (Layer 2, apply-plane) | `blahaj` (Layer 1, substrate) | GitHub Actions store |
|---|---|---|---|---|
| App source + `svelte.config.js` (`adapter-node`) + `ContainerFile` | **YES** (behavior only) | — | — | — |
| Built OCI image | published to GHCR by public CI via **ambient `GITHUB_TOKEN`** | consumes the image by pin | — | (no long-lived secret) |
| K8s Deployment / Service / NetworkPolicy manifests | **NO** | **YES** (`tofu/stacks/…` or `k8s/…/latoolb-us-production/`) | Service+tunnel-ingress NetworkPolicy declared here for the tunnel hop | — |
| Image pin (`sha-<commit>`) + promotion | **NO** | **YES** (operator-gated reviewed pin bump) | — | — |
| tofu state + backend coordinates | **NO** | **YES** (`tofu/backend/*.s3.hcl`, RustFS coords; creds env-delivered, never baked) | RustFS service itself | RustFS keys as overlay env/repo secrets |
| Ciphertext (`*.enc.yaml`, age secret keys) | **NEVER** (zero) | **YES** — `.sops.yaml` → GFTB recipient `age1maaym…` | first-match tenant rule (DKIM only, below) | — |
| Cloudflare tokens | ONLY a **Pages-Edit-only, account-scoped, zero-zone** token as repo secret `CLOUDFLARE_API_TOKEN` (today's CF Pages deploy) | **zone-scoped** token `CLOUDFLARE_API_TOKEN_GFTB_ZONES` (DNS/Access/redirect) in the protected `edge` env | — | both in GitHub store, never in tree |
| Cluster kubeconfig | **NEVER** | `MAIL_APPLY_KUBECONFIG_B64` (namespace-scoped SA, CR-only) + `ARC_RUNNERS_KUBECONFIG_B64` in protected envs | mints the namespace-scoped SA (`deploy/tenants/great-falls-tool-bus/rbac.yaml` → `latoolb-us-production`, TIN-2382) | overlay Actions secrets |
| DKIM private key | recorded **by name only** (`latoolbus-dkim-private-key`); publishes only the public TXT half | — | **the one ciphertext that stays blahaj-side** — `blahaj:tenants/great-falls-tool-bus/secrets/dkim-latoolb-us-mail.yaml` (dual-recipient, DNS-pinned/unrotatable, transport-consumed) | — |
| Names-only inventory | `secrets.contract.yaml` (5 named secrets, plane/owner/rotation, **no values**) | private-side `secrets/README.md` inventory | — | — |
| Boundary pins | `tinyland.repo.json` `boundaries` block: all `owns_*` **false** except `owns_static_projection_ingest=true`; `enrollment.operatorOverlay=great-falls-tool-bus-infra` | — | `authorities.gitops_receiver=tinyland-inc/blahaj` | — |
| Gitleaks enforcement | `.gitleaks.toml` (allowlists `age1…` public recipients; blocks `AGE-SECRET-KEY-1`, `cfat_`, etc.); wired into `just check` + conformance | same `.gitleaks.toml` + `dreamhost-api-key` rule | — | — |

### 3b. Why on-cluster serving keeps the public repo secret-free

1. **The authority split does the work.** The app repo owns *behavior + image*;
   the overlay owns *every manifest + the pin + apply*. This is MI's model
   verbatim (`blahaj:tofu/config/massageithaca-prod-honey.tfvars.json`; MI
   `docs/deployment/ci-cd-pipeline.md`) and GFTB's existing three-layer
   contract (site `0002`). Nothing in "build an image" requires a privileged
   credential in the public repo.
2. **GHCR publish uses the ambient `GITHUB_TOKEN`.** MI publishes
   `ghcr.io/jesssullivan/massageithaca` from its own same-org CI; GFTB publishes
   `ghcr.io/great-falls-tool-bus/greatfallstoolbus.org` the same way. No
   cross-org secret, no long-lived PAT in the tree.
3. **On-cluster serving lets the public repo RETIRE its one live CF credential.**
   Today the public repo carries the Pages-Edit token to drive CF Pages. If
   static production moves on-cluster, that token is removed from the public repo
   entirely; the only privileged CF surface (zone/DNS/tunnel-route) already lives
   in the overlay's protected `edge` env (TIN-2385). Net posture: **more**
   publish-safe, not less.
4. **Cross-org secret gotcha is already solved.** `secrets: inherit` does NOT
   cross GitHub orgs (proved by PR #54: the CF Pages deploy silently no-op'd
   until secrets were mapped explicitly to the `tinyland-inc/ci-templates`
   reusable workflow). Any on-cluster image-publish workflow that stays
   *same-org* (public repo → GHCR under its own org) avoids this class entirely.
5. **The `owns_*` pins must be re-examined, not assumed.** Today
   `owns_static_projection_ingest=true` describes a static spoke that ingests a
   projection. A container-producing spoke is a different shape — see Open
   Question OQ-4: the pins likely need an explicit `owns_container_image_production`
   (true) while `owns_gitops_apply` / `owns_cloudflare_mutation` stay false
   (the overlay still owns the pin + apply). This is a boundary-schema change a
   superseding ADR must make, not a silent drift.

## 4. Reassessment of ADR 0003's rejection blockers

ADR 0003 (site repo) rejected on-cluster **production static** serving and chose
CF Pages, citing three blockers. Reassessed against MI reality + the fact that
gated-dynamic web I/O is already on-cluster (form live, archive next — TIN-2535
comment 2026-07-05):

| ADR 0003 blocker | Reassessment | Grounding |
|---|---|---|
| **No house precedent** for full on-cluster web serving | **DISSOLVED.** MI serves its public app fully on-cluster (`adapter-node` → image → Deployment → ClusterIP → tunnel), retired Vercel *and* Pages. It is a clean, copyable reference. | `MassageIthaca:svelte.config.js`, `ContainerFile`, `docs/deployment/overview.md`; `blahaj:tofu/stacks/massageithaca/main.tf` |
| **Honey pod-cap headroom** (~103-104/110) | **PARTIALLY DISSOLVED, gated on a live probe.** MI runs `replicas=2` on-cluster comfortably, so a 2-pod GFTB web workload is clearly *shaped* to fit. BUT the binding constraint is real: max-pods 110/node, /24 podCIDR ceiling 234, 3 nodes (~330 slots), honey `quota_pods=200`. Exact *live* headroom is NOT determinable from any repo (OQ-5) — a superseding ADR must cite a live `kubectl` count. Adding a 2-replica web Deployment (+PDB surge) is a handful of pods, plausible but not free. | `blahaj:ansible/…rke2_agent_config.j2` (max-pods 110), `rke2-kubelet-max-pods.yml` (234 ceiling), `dhall/fragments/cluster-defaults/honey.dhall` (quota_pods 200), `tofu/config/massageithaca-prod-honey.tfvars.json` (replicas=2) |
| **TIN-991 route authority** (tunnel token / route mutation) | **REFRAMED to a settled governance constraint, not a feasibility blocker.** MI proves the route pattern works end-to-end. For GFTB, public route mutation is *deliberately* operator-gated with a protected Cloudflare credential — there is NO CI auto-applier for durable single-service routes; the tunnel `TUNNEL_TOKEN` lives only in the live `cloudflared-token` Secret (SOPS follow-up TIN-991). This is a persistent *process* constraint (an operator applies the route out-of-band), not a reason the pattern cannot work. GFTB already lives inside it for the live form route. | `blahaj:deploy/honey/retained-cloudflared.yaml`, `tofu/intent/great-falls-tool-bus/forms-intake-route.json`; overlay `docs/runbooks/form-intake.md` |

Net: of the three original blockers, **one is fully dissolved (no precedent)**,
**one is reframed to a standing governance constraint that GFTB already operates
inside (route authority)**, and **one survives only as a capacity question that
a live pod-headroom probe resolves (pod-cap)**. None is a categorical bar to
on-cluster serving; the honest residual is capacity headroom, verifiable in
minutes with cluster access.

**Crucial scoping correction (operator, TIN-2535, 2026-07-05):** ADR 0003's
rejection must stay "scoped precisely to STATIC PRODUCTION serving, and do not
conflate it with gated-dynamic I/O, which is a different (and already-chosen)
thing." The form (`forms.latoolb.us → cloudflared → Anubis:8081 → form-handler`)
and the coming `discuss@` archive (`cloudflared → Anubis → mailman-web`,
TIN-2528) are "dynamic web I/O the CF Pages CDN cannot serve" — on-cluster for
those is **not** an ADR 0003 reversal; it is the already-decided path. This
brief therefore does not claim ADR 0003 was wrong; it claims its *no-precedent*
premise no longer holds and its scope must be read narrowly.

## 5. Reconciliation with the preview ADR (TIN-2535) and the rollback gap (ADR 0007 / PR #74)

### 5a. TIN-2535 (PR-gated ephemeral preview / on-cluster caching, PR #46)

TIN-2535 is explicitly **EPHEMERAL PREVIEW**, distinct from ADR 0003's
production-static ruling. The operator's posture there is the reconciling frame
this brief adopts: static/prerendered production → CF Pages; PoW-gated dynamic →
on-cluster via Anubis; and an on-cluster preview/reaper path "reuses an
established capability rather than introducing a new one." A full
static-production migration (this brief's TIN-2537 question) and an ephemeral
preview lane (TIN-2535) share the **same** MI machinery (adapter-node image +
Deployment + tunnel), so adopting the MI pattern for one lowers the marginal
cost of the other. They should share the app `ContainerFile`, the GHCR publish,
and the overlay stack template; only the route-intent + lifecycle (reaper TTL
vs durable pin) differ.

### 5b. ADR 0007 / PR #74 — the CF-Pages single-publisher rollback gap

ADR 0007 recommended a CF-Pages single-publisher rollback posture; that
recommendation is inviable under private repos (site PR #74). **If a surface
moves on-cluster, ADR 0007's rollback concern for that surface is dissolved and
replaced by a strictly better primitive:** on-cluster rollback = re-pin the
previous `sha-<commit>` in the overlay tfvars and run the reviewed, protected
OpenTofu apply. Image-pin promotion is already decoupled, operator-gated, and
trivially reversible (MI's exact model — `blahaj:tofu/config/…tfvars.json`,
MI PR #505 rejected the auto-writer to *keep* it operator-gated). So:

- For any surface that goes **on-cluster**, the CF-Pages-single-publisher
  rollback recommendation is **moot** — rollback becomes a pin revert, which
  works identically under public *or* private repos (the pin lives in the
  private overlay regardless).
- For any surface that **stays on CF Pages** (per the operator's scoped posture,
  static production may well stay), ADR 0007's gap **still applies** and its
  private-repo rollback problem remains open and must be solved on its own terms.

Consequence: moving production on-cluster would *retire* the ADR 0007 rollback
problem for the migrated surface rather than inherit it — a point in favor of
migration, but only for surfaces actually moved.

## 6. Constraints an ADR must carry forward (not re-litigate)

- Public production served on-cluster needs a **running pod**, not object
  storage: `/api/health` probes, RollingUpdate, PDB, `replicas=2`, and the
  `dedicated.tinyland.dev/compute-expansion` toleration if it lands on `sting`
  (untainted `honey`/`bumble` otherwise).
- Public edge depends on the single `honey-ingress` tunnel; GFTB needs its own
  route-intent file + the operator-applied ingress rule (no CI auto-applier).
- Origin hop tunnel→Service is plain in-cluster HTTP; TLS is Cloudflare-edge-only
  (`proxied: true`). No cert-manager on the public apex path.
- `latoolb.us` / `greatfallstoolbus.org` DNS is **this overlay's** edge stack,
  not blahaj — the CNAME→`cfargotunnel` is minted here.
- Secret NAMES stay byte-identical across a substrate swap; only VALUES +
  endpoint coordinates may change (site `0002` §c replaceability test).
- age has no revocation: the DKIM private key must NEVER appear as public
  ciphertext anywhere; it stays the one blahaj-side carve-out.

## 7. Recommendation and phased, operator-gated path

**Recommendation.** Do **not** retire CF Pages by fiat, and do **not** treat this
brief as reversing ADR 0003. Instead:

1. **Ratify the scoped reading of ADR 0003** (per the TIN-2535 operator comment):
   ADR 0003 governs **static production** only; **gated-dynamic** serving (form
   live, archive next) is already on-cluster and is NOT within ADR 0003's
   rejection. Record this scoping so "split-brain" stops being the frame — the
   current posture is *coherent* (CDN for static, cluster for gated-dynamic).
2. **Sanction the MI pattern as the house standard** for every on-cluster GFTB
   web surface (it already is, de facto, for the form). Capture the adoption map
   (§1c) + the overlay stack template (§2) so the next surface is a copy, not a
   design.
3. **Gate any *static-production* migration behind a superseding ADR** whose
   single open dependency is a **live pod-headroom probe** (OQ-5). This brief is
   that ADR's evidence base; it deliberately stops short of the decision.

**Phased path (nothing applied; each phase operator-gated):**

- **P0 — Decision hygiene (docs only).** Land this brief; add the ADR-0003
  scoping note; keep CF Pages for static production for now.
- **P1 — Probe.** Operator runs a live `kubectl` pod-count on honey/bumble/sting
  vs the 110/node cap + `quota_pods=200`; record actual headroom. This is the
  one fact no repo can supply.
- **P2 — App-repo container readiness (public repo, no apply).** In
  `greatfallstoolbus.org`: add the `adapter-node` build behind a flag, the
  `ContainerFile`, and a same-org GHCR publish workflow (ambient `GITHUB_TOKEN`).
  Verify the image serves `/api/health` locally. Still zero secrets in the repo;
  Pages deploy stays the live path.
- **P3 — Overlay stack (private, plan-only).** Add a `great-falls-tool-bus` app
  stack under `tofu/stacks/` (or extend `k8s/…/latoolb-us-production/`) modeled
  on `blahaj:tofu/stacks/mi-portal-deploy/main.tf` + `tinyland-dev/main.tf`; add
  the RustFS backend HCL; `just tofu-plan` only. Add the route-intent JSON
  mirroring `forms-intake-route.json`.
- **P4 — Superseding ADR.** With P1 headroom in hand, author the ADR that
  *supersedes* ADR 0003 for the static-production surface (or explicitly retains
  it). Include the `owns_*` pin change (OQ-4). Operator adjudicates.
- **P5 — Cutover (only if P4 authorizes).** Operator applies the overlay stack,
  flips `enable_cloudflare_tunnel_ingress`, applies the tunnel route out-of-band,
  bumps the image pin. Rollback = re-pin previous `sha-<commit>` (this retires
  the ADR 0007 rollback gap for the migrated surface). Retire the public repo's
  Pages-Edit CF token last.

## 8. Open questions (carried from research; a superseding ADR must close)

- **OQ-1 (live tunnel ruleset):** the `honey-ingress` ingress ruleset is remotely
  managed (token tunnel) and not committed; desired routes in
  `public-edge-routes.json` + the applier were read, but live Cloudflare-side
  state was not proven. Verify via the applier dry-run / Cloudflare API before
  cutover.
- **OQ-2 (Anubis vs bare origin):** does a GFTB *static/marketing* on-cluster
  surface sit behind the Anubis PoW gate (like `forms.latoolb.us`, whose tunnel
  points at `anubis:8081`, not the app Service) or a bare ClusterIP origin? The
  gated-dynamic surfaces use Anubis; a plain page probably wants bare origin —
  unconfirmed.
- **OQ-3 (edge-tofu location):** the `gftb-infra-edge-tofu` authority for the
  `latoolb.us` zone is referenced but its stack was not located in the clones —
  confirm it is this overlay's `tofu/stacks/edge*` vs a separate repo.
- **OQ-4 (boundary-pin schema):** a container-producing public spoke needs an
  explicit `owns_container_image_production` flag; `owns_gitops_apply` /
  `owns_cloudflare_mutation` stay false. The pins must be updated deliberately,
  not drift.
- **OQ-5 (live pod headroom):** exact running pod count vs the 110/node cap on
  the 3-node cluster is not determinable from any repo — the single hard
  dependency for a static-production migration decision. Needs a live `kubectl`
  read.
- **OQ-6 (`.sops.yaml` guard drift):** both the overlay `.sops.yaml` and the
  public `secrets.contract.yaml` assert the GFTB age *recipient* is pinned as a
  guard in the public repo's `.sops.yaml`, but no such file exists in the public
  repo. Pinning a public age *recipient* there is publish-safe (gitleaks
  allowlists `age1…`); the guard file is currently missing.

## Sources (all read READ-ONLY)

- Linear: TIN-2537 (this brief's issue), TIN-2535 (preview ADR + operator
  scoping comment 2026-07-05), TIN-2528 (archive), ADR 0003 + ADR 0007
  (referenced), TIN-2385 / TIN-2382 / TIN-991 / TIN-2420.
- `Jesssullivan/MassageIthaca`: `svelte.config.js`, `ContainerFile`,
  `.github/workflows/docker-ghcr.yml`, `docs/deployment/overview.md`,
  `docs/deployment/ci-cd-pipeline.md`, `Caddyfile`,
  `scripts/check-k8s-prod-canary.mjs`.
- `tinyland-inc/blahaj`: `tofu/stacks/massageithaca/main.tf`,
  `tofu/stacks/tinyland-dev/main.tf`, `tofu/stacks/tinyland-dev-deploy/main.tf`,
  `tofu/stacks/mi-portal-deploy/main.tf`, `tofu/stacks/scheduling-bridge-pages/main.tf`,
  `tofu/config/massageithaca-prod-honey.tfvars.json`,
  `tofu/intent/massageithaca/{prod.intent.json,public-edge-routes.json}`,
  `tofu/intent/great-falls-tool-bus/forms-intake-route.json`,
  `tofu/intent/gloriousflywheel/public-token-exchange-route.json`,
  `deploy/honey/retained-cloudflared.yaml`, `tofu/backend/netbox.honey.s3.hcl`,
  `scripts/tofu-{init,apply}.sh`, `scripts/lib/tofu-backend.sh`,
  `tofu/common/{provider-kubernetes.tf,variables-common.tf}`,
  `ansible/roles/liqo-cluster/templates/rke2_agent_config.j2`,
  `ansible/playbooks/rke2-kubelet-max-pods.yml`,
  `dhall/fragments/{honey-cluster.dhall,cluster-defaults/honey.dhall}`,
  `Justfile` (group `tofu` L59-72),
  `tenants/great-falls-tool-bus/secrets/dkim-latoolb-us-mail.yaml`, `.sops.yaml`,
  `deploy/tenants/great-falls-tool-bus/rbac.yaml`.
- `Great-Falls-Tool-Bus/greatfallstoolbus.org` (public spoke):
  `secrets.contract.yaml`, `tofu/dns-intent/`, `tofu/mail-intent/`,
  `tofu/dynamic-spoke-deploy-target.tf`, `.github/workflows/{deploy-pages.yml,ci.yml}`
  (PR #54), `.gitleaks.toml`, `tinyland.repo.json`,
  `docs/decisions/0002-blahaj-substrate-boundary.md`.
- `great-falls-tool-bus-infra` (this overlay): `.sops.yaml`, `secrets/README.md`,
  `.gitleaks.toml`, `docs/ci-credentials.md`, `tofu/backend/{honey.s3.hcl,honey-edge.s3.hcl}`,
  `tofu/stacks/edge*`, `k8s/{form,list,mail}/latoolb-us-production/`,
  `docs/runbooks/form-intake.md`, `docs/mvp-decision-packet.md`,
  `docs/implementation-overlay.md`.
- `tinyland-inc/site.scaffold`: `tinyland.repo.json` + `.gitleaks.toml`
  (source of the boundaries schema + gitleaks rules the spoke inherits).
