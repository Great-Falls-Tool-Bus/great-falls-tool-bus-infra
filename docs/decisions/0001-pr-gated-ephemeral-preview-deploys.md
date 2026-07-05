# 0001 — PR-gated ephemeral preview deploys (reaper/on-cluster vs Cloudflare Pages)

- Status: **Proposed (operator decision required)**
- Date: 2026-07-05
- Ticket: TIN-2535
- Scope: **PREVIEW deploys only** — per-PR ephemeral review environments. This is
  NOT production serving; production hosting is already decided in the site repo's
  `docs/decisions/0003-hosting-and-remote-posture.md` and is not re-litigated here.
- Related: TIN-2515 (dev-default shadow deploy, site PR #71); site ADR 0003;
  site ADR 0007 (private-repos rollback gap, open on site PR #74).
- Applied: **NOTHING.** Declare-only packet. Any new toggle introduced by this
  decision ships fail-closed / default-off.
- Home note: this is the first ADR in `great-falls-tool-bus-infra`. It lands here,
  not in the public site repo, because any on-cluster apply is structurally an
  infra-overlay + operator action (site repo pins `owns_gitops_apply=false`,
  `owns_cloudflare_mutation=false`); this overlay owns the GFTB `k8s/` and
  edge/DNS apply plane (AGENTS.md). It cross-references the site ADR series
  (0003, 0007) rather than renumbering into it.

## Context — the problem, and what it is not

GFTB reviewers want a per-PR ephemeral **preview** so unmerged work is viewable at
a stable URL before it reaches production. The open question (TIN-2535) is *how* to
provide that preview: reuse the managed Cloudflare Pages preview channel, or build
an on-cluster "reaper"-style ephemeral-environment system on the Honey substrate.

Two facts bound the decision before options are weighed:

1. **This is not production serving.** ADR 0003 already **rejected** cluster-served
   static for production — *"no house precedent; honey at 103-104/110 pods per
   blahaj ADR 005; TIN-991 route authority unfinished; its same-origin-form
   advantage was already forfeited."* That decision stands. This ADR does not
   reopen it; it asks the narrower preview-only question and finds the same three
   blockers apply, plus a fourth (redundancy).
2. **GFTB has no internal reaper.** The org's ephemeral-preview / "reaper" pattern
   lives entirely in `tinyland-inc/blahaj` (the shared substrate receiver) and its
   two live consumers (tinyland.dev, MassageIthaca). It is explicitly documented
   there as **legacy/transitional — a receiver being migrated to a generic
   dispatch/managed-state contract (TIN-2023/TIN-2027), not a template to clone.**
   GFTB has no reaper of its own to extend. So the on-cluster option is not
   "reuse ours," it is "clone a pattern its own authors say not to clone."

## Options

### Option A — Cloudflare Pages branch/preview deploys (the TIN-2515 path)

Reuse the managed preview channel. `deploy-pages.yml` already deploys the
`greatfallstoolbus-org` Pages project; CF Pages natively produces per-branch and
per-PR preview deployments under `*.greatfallstoolbus-org.pages.dev`, and an
**account-level Cloudflare Access app already covers `*.greatfallstoolbus-org.pages.dev`**
under one allowlist — so previews are already Access-gated with **zero new Access
or tunnel work**. TIN-2515 (site PR #71) formalizes a `dev` branch shadow-deploy to
`dev.greatfallstoolbus-org.pages.dev` on the same project, needing no new gating.

- **Pro:** near-zero cost (0 pods, 0 new tunnel routes, 0 new Access apps);
  already Access-gated; reachable within a workflow-trigger delta; the CF Pages
  dual-URL model (a mutable branch/PR alias + an immutable commit-SHA-pinned URL)
  is the managed-preview UX the external research names as the target pattern;
  managed cache-header handling (hashed-asset immutable vs no-cache HTML) comes
  for free; teardown is the platform's problem.
- **Con:** enabling *per-PR* (not just the single `dev` branch) previews is a
  managed config flip on the Pages project; GitHub-Free gives no branch protection
  on private repos, so `dev -> main` promotion is **convention only** (TIN-2515);
  and CF Pages is effectively **single-publisher** — the 0007 rollback gap (GH
  Pages cold-standby broke when repos went private) is real, though it concerns
  *production* rollback, not previews.

### Option B — On-cluster reaper-style ephemeral previews on Honey

Per-PR namespace + pod, a cloudflared tunnel hostname, an Anubis gate, and a
reaper for teardown — cloning the house `k8s/form/latoolb-us-production/` serving
shape (a ConfigMap-mounted stdlib HTTP server on a digest-pinned base image, **no
org-built image**, `readOnlyRootFilesystem`, `runAsNonRoot`, single replica) and
the blahaj/MI reaper lifecycle (label-driven `lifecycle=pr-ephemeral` /
`auto-expire=true` / `expires-epoch`, TTL-or-PR-closed fail-safe destroy,
`unknown`-never-destroys, a 4h GitHub-Actions reaper backstopped by an in-cluster
system-critical CronJob).

- **Pro:** full same-origin control; a real house serving pattern exists to copy;
  the blahaj reaper is a battle-tested teardown design (defense-in-depth,
  fail-safe on positive evidence only).
- **Con:** the original pod-cap blocker was retired by the 2026-07-05 live probe
  (honey 138/150, bumble 50/110, sting 96/200), but the preview lane still carries
  three unresolved costs:
  1. **Tunnel route is out-of-band.** The only on-cluster public route rides the
     shared honey-ingress cloudflared tunnel whose public-hostname routes are
     **Cloudflare dashboard / token-managed, not in git**; TIN-991 route authority
     is unfinished. There is no per-PR automation to mint a `pr-<n>` hostname —
     every one would be a manual operator dashboard action.
  2. **No preview-namespace precedent.** The only namespace is
     `latoolb-us-production`; an on-cluster preview is net-new namespace + net-new
     route + net-new pods, with a sting-node SPOF (per house memory) in the reaper
     control path.
  3. **Redundant.** CF Pages already provides Access-gated previews at zero pod
     cost and zero authority conflict; an on-cluster preview must beat a free,
     already-shipping incumbent, and does not.

### Option C — Hybrid

CF Pages as the default preview channel for all PRs, **plus** a single long-lived,
operator-gated on-cluster **staging namespace** (explicitly *not* per-PR
ephemeral) reserved for the narrow case that genuinely needs same-origin / Anubis
behavior — e.g. reviewing a form-integration change against the live Anubis chain.
Only when the operator authorizes it. No per-PR on-cluster spin-up, so the
tunnel-route and lifecycle constraints are met by having exactly one,
hand-placed namespace.

## Decision (recommended) — **Option A**, with C's escape hatch parked

Adopt/extend the **Cloudflare Pages managed preview** (Option A): merge the
TIN-2515 `dev`-default shadow deploy and, on operator ruling, enable per-PR preview
deployments on the `greatfallstoolbus-org` Pages project, reusing the existing
account-level `*.pages.dev` Access gate. **Do not build an on-cluster per-PR
reaper.** The old honey pod-cap blocker is retired, but the
dashboard-managed tunnel-route constraint and missing preview/reaper ownership
remain, and the lane is redundant with the incumbent.

Because GFTB has **no internal reaper**, this ADR does not "adopt ours" — it
**adopts the external managed pattern** (CF Pages' dual-URL preview model) and
records the blahaj/MI on-cluster reaper as **the reference we deliberately decline
to clone**, consistent with blahaj's own "legacy/transitional, do not clone" note.

**Parked, not adopted (Option C):** if a same-origin/Anubis preview need is ever
*proven* AND TIN-991 route authority is brought under IaC so a hostname is not a
manual dashboard op, a *single* operator-gated staging namespace — never per-PR —
may be reconsidered in a future ADR. It is out of scope here.

## Phased, operator-gated rollout

- **Phase 0 (this ADR):** declare only. Nothing applied. Operator ruling requested.
- **Phase 1 (operator ruling):** merge TIN-2515 / site PR #71 (`dev`-default
  shadow deploy to `dev.*.pages.dev`); confirm the URL inherits the existing
  `*.pages.dev` Access app (no new gating).
- **Phase 2:** enable per-PR preview deployments on the `greatfallstoolbus-org`
  Pages project (managed config flip, operator-performed on the CF dashboard);
  verify each per-PR preview URL is covered by the same Access app.
- **Phase 3 (optional):** wire the GitHub Deployments API as a pure status plane
  (environment + `deployment_status`, `inactive` on PR close) so reviewers get the
  "View deployment" button UX. No compute change.
- **Phase 4 (only if C ever unblocks):** a *separate* ADR for a single on-cluster
  staging namespace — not authorized by this document.

## Reaper / teardown + cost model

- **Recommended (CF Pages) path.** Teardown is the platform's: previews are
  immutable deployments, the branch/PR alias moves to the latest commit, PR-close
  is handled by CF Pages. House reaper burden ≈ **nil** — the only optional
  obligation is marking the GitHub Deployment `inactive` on close for UI tidiness.
  **Cost:** 0 pods, 0 new tunnel routes, 0 new Access apps, and the single
  account-scoped `Pages:Edit` token already sanctioned in 0003 (no new secret).
- **On-cluster path (rejected), for the record.** Per preview ≥ Anubis + server
  pod; each per-PR hostname is a manual dashboard route (TIN-991 unfinished); a correct reaper would need the full blahaj
  triple-leg (PR-close dispatch → 4h GH-Actions TTL reaper → in-cluster
  system-critical backstop CronJob) plus exposure to the sting-node SPOF. Net:
  high operational cost for a capability CF Pages already provides for free.

## DECLARE-ONLY skeleton note (NOT applied)

If Option C is ever authorized in a future ADR, the **fail-closed** skeleton that
*would* be added **to this repo** (the infra overlay — the site repo cannot apply
it) is described here for completeness and is **not** committed as manifests:

- `k8s/preview/<ns>/` — a kustomization cloning the `k8s/form/latoolb-us-production`
  shape: a ConfigMap-mounted stdlib `http.server` on a **digest-pinned** base (no
  org-built image), `readOnlyRootFilesystem`, `runAsNonRoot`, drop ALL caps,
  single replica, `Recreate`; namespace stamped with the blahaj label contract
  (`lifecycle=pr-ephemeral`, `auto-expire=true`, `expires-epoch=<unix ts>`,
  `pr-number`, `deployment-style`).
- a **default-disabled** reaper (a GH workflow gated `if: false` / behind a
  `PREVIEW_REAPER_ENABLED=false` toggle) selecting on those labels, destroying only
  on positive evidence (TTL passed **or** PR confirmed closed), `unknown` never
  destroys, bounded by `--max-destroys`.
- a **default-suspended** in-cluster backstop CronJob (`spec.suspend: true`).
- **no** tunnel public-hostname route committed (it is dashboard-managed; TIN-991).
- every toggle ships **OFF**; nothing is `kubectl`/`tofu apply`-ed.

## Consequences

- No infrastructure is applied. Proceeding past Phase 0 requires an operator ruling.
- If A is ratified: previews are the managed CF Pages channel; the honey pod budget
  is untouched; house reaper burden is ~nil.
- CF Pages remains single-publisher — the **0007** rollback gap is unchanged by this
  ADR (previews are not a production rollback surface; noted, not solved here).
- The blahaj/MI on-cluster reaper remains the **reference-not-to-clone**; GFTB
  adopts the external managed pattern instead, honoring blahaj's own transitional
  status and this overlay's "never re-home into blahaj" boundary.
- The GitHub-Free branch-protection gap keeps `dev -> main` a convention
  (TIN-2515); this ADR neither worsens nor fixes it.

## References

- TIN-2535 (this decision); TIN-2515 (dev-default shadow deploy, site PR #71).
- Site `docs/decisions/0003-hosting-and-remote-posture.md` (production hosting;
  rejected on-cluster static — not re-litigated here).
- Site `docs/decisions/0007-private-repos-rollback-gap.md` (open on site PR #74;
  CF Pages single-publisher posture).
- `tinyland-inc/blahaj` reaper (per-PR ephemeral namespace system; **legacy/
  transitional per its own docs**, TIN-2023/TIN-2027 successor contract).
- `k8s/form/latoolb-us-production/` (the house on-cluster serving precedent).
- `AGENTS.md` (this overlay owns the GFTB `k8s/` + edge/DNS apply plane; never
  re-home into blahaj; applies are operator-gated).
