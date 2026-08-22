# 0002 — Preview-environment CD authority: the infra-side companion to site ADR 0010 §4

- **Status:** Proposed (adversarial review precedes merge; not operator-signature-only)
- **Date:** 2026-08-21
- **Decision owner:** Jess
- **Ticket:** TIN-2535 (reopens the preview question this ADR answers)
- **Supersedes:** this ADR's own `0001-pr-gated-ephemeral-preview-deploys.md`
  **Option A recommendation** ("Do not build an on-cluster per-PR reaper";
  Cloudflare Pages managed previews). Per 0001's own no-silent-rewrite
  convention, 0001's text is retained; this ADR is the ruling that supersedes
  it, not an edit to it.
- **Points CD authority at:** `meta` `decisions/0020-adopt-production-convergence-contract-2026-08-21.md`
  (Great-Falls-Tool-Bus/meta#34, DRAFT — operator merges)
- **Ratification basis:** operator interview 2026-08-21 (session register L72),
  executing `org-standard-cd-pattern-truth-20260821.md` §3.4 item 2 — "the
  infra-side companion decision that site ADR 0010 §4 called for and nobody
  wrote." Ratified inputs this ADR respects: Q1=A (tailnet preview lane
  formalized now via `tailscale serve`; `staging.greatfallstoolbus.org`
  promote-on-PR as the target after the infra apply sitting).

## 0. Why this ADR exists

`greatfallstoolbus.org:docs/decisions/0010-on-prem-is-the-production-host.md`
§4 ("Decision 3 — PR previews move to the on-cluster reaper pattern") ruled
on 2026-07-05 that PR previews should move from Cloudflare Pages managed
previews to the on-cluster reaper pattern, and said explicitly: *"This needs
an infra-side companion decision. Preview provisioning is overlay + blahaj
work (`owns_gitops_apply=false` [in the site repo]), so reviving the reaper
is a `great-falls-tool-bus-infra` decision. TIN-2535 is reopened in spirit."*
That companion decision was never written. Until now, this overlay's only
ratified-adjacent preview decision remained `0001`'s Option A, which
recommends the opposite of what the site repo's own ADR called for six weeks
ago — Cloudflare Pages previews and "the reference we deliberately decline to
clone" for the on-cluster reaper. This ADR is that companion decision.

## 1. What changed since 0001 (2026-07-05) and 0010 §4 (2026-07-05)

- **0001's premise no longer holds.** 0001's Option A rested explicitly on
  "production stays on Cloudflare Pages." Production moved on-cluster
  (site ADR 0010 §1-2, amended to adapter-node), and the Cloudflare Pages
  project was deleted outright (0010 Amendment 2, 2026-07-07; run
  `28801030150`). There is no Pages project left for a preview lane to be
  "managed" alongside.
- **The org-standard CD pattern is now adopted (by reference) as GFTB CD
  authority.** `meta` ADR 0020 adopts `site.scaffold`'s production-convergence
  contract + stateful-workload addendum. Its §7.2 data-lifecycle rules (own
  state key, own namespace, own durable data, fixture-or-anonymizer seed,
  overlay-owned reaper, PR-state-derived verb, unknown-never-destroys, TTL
  backstop, `ephemeral: true` at birth) now govern what a conformant preview
  lane looks like, superseding 0001's framing of "clone the blahaj/MI
  reaper or don't."
- **The interim is not the on-cluster reaper 0001 declined, and it is not
  the deleted Cloudflare Pages lane either.** It is `tailscale serve`
  (Q1=A, ratified L71) — a third option neither 0001 nor 0010 §4
  considered, because neither predates the tailnet-preview work.

## 2. Decision

**0001's Option A recommendation is superseded**, not merely narrowed: it
recommended Cloudflare Pages previews on the premise that Cloudflare Pages
remains the production host. That premise is gone (§1). **0001's declined
on-cluster reaper is also not simply revived as-is** — ADR 0020 governs its
shape now, and this ADR does not authorize building it yet (§4).

- **Ratified interim (now):** `tailscale serve`, per PR, via
  `just preview-tailnet PR=<n>` — a tailnet-only preview, no public exposure,
  no Cloudflare Access gate needed because it never leaves the tailnet. This
  retires the cleartext-exposure concern 0001 §"Redundant" implicitly
  accepted by defaulting to Cloudflare Pages' own gate.
- **Ratified target (after the infra apply sitting):**
  `staging.greatfallstoolbus.org` promote-on-PR, at the serving shape ADR
  0020 §7 requires: PR-scoped state key + namespace + its own durable data
  (fixture or reviewed-anonymizer seed, never a production clone), a reaper
  owned by this overlay, a destroy verb derived from live PR state (never
  caller-supplied), unknown-never-destroys, a TTL backstop independent of the
  CI fleet, and `ephemeral: true` declared at the stack's birth. This is the
  shape 0010 §4 asked for, corrected by ADR 0020's doctrine rather than by a
  copy of the blahaj/MI reaper implementation (which ADR 0020 §2 and the
  underlying truth doc both find retired/never-published, not a thing to
  clone).
- **Both stages are rung 1/rung 2 work under ADR 0020 §6** — honest tree and,
  where applicable, an offline-rendered plan as a required status. Neither
  stage runs `tofu plan`/`apply` against the real state key from a CI
  runner, and neither stage provisions a state-backend credential to a
  runner. This is the structural boundary that keeps a preview lane from
  becoming a second carrier the day GFTB declares a real one (ADR 0020 §6).

## 3. D26 — the staging blocker this ADR surfaces, not resolves

TIN-991 (tunnel-route mutation authority) was **cancelled without
reassigning that authority**. `k8s/web/README.md:88` and
`docs/runbooks/oncluster-web-cutover.md:245` both still describe public
hostname routes as "Cloudflare dashboard / token-managed" — a manual
operator action, not IaC. `staging.greatfallstoolbus.org` promote-on-PR
requires a `staging` hostname route to exist and be mutable per-generation
(even if the generation cadence is "once, at the apply sitting," not
per-PR); today that is a manual dashboard action with **no assigned owner**
since TIN-991's cancellation.

**This ADR does not reassign that authority.** It records the gap plainly:
until an operator decision names who (or what IaC surface) may mutate the
`staging` tunnel route, "staging promote-on-PR after the infra apply
sitting" has a named target and no named executor for the one manual step
that has to happen before automation can begin. Flagging this to the
operator is this ADR's job; resolving it is a separate, future decision.

## 4. What this ADR does not authorize

- No apply. `just preview-tailnet` already exists as a local recipe; nothing
  here mints new credentials, installs a carrier, or provisions the staging
  namespace.
- No revival of the on-cluster per-PR reaper 0001 declined, in the shape
  0001 described. If/when GFTB builds a PR-scoped on-cluster environment, it
  is built to ADR 0020 §7's data-lifecycle rules, in its own reviewed PR,
  not assumed to already exist because this ADR mentions it as the target
  shape.
- No route mutation. TIN-991's gap (§3) is named, not closed, by this
  document.
- No change to `0001`'s own text (no-silent-rewrite convention, §0 above).

## 5. A note on this ADR's own numbering — a finding, not a resolution

This repository already carries an **unmerged** branch,
`agent/production-convergence-prep-20260806` (commit `d8ff004b6027b1a`,
2026-08-06, "feat(convergence): BLOCKED prep — production-convergence
instantiation for the web serving stack"), which independently wrote its
own `docs/decisions/0002-production-convergence-conversion.md`. That draft
answers a **different question** than this ADR: it stages the conversion of
the already-serving **production web-stack's own CD carrier** (mechanism A,
the pull carrier) from the current push-shaped `repository_dispatch` +
`kubectl` mechanic to an in-cluster CronJob — explicitly BLOCKED on an
unpublished module and an operator enable ceremony, applying nothing. This
ADR answers the **preview-environment** authority question 0010 §4 asked.

Both branch from a `main` that only had `0001` in `docs/decisions/`, so both
independently claim `0002`. **This ADR does not resolve that collision.**
Whichever of the two branches lands second must renumber at merge time (most
likely this ADR becomes `0003`, since the other branch's content is the
more substantial, already-detailed engineering artifact — but that is the
operator's or the reviewing engineer's call, not a mechanical one made here).
Named so the collision is not discovered by surprise at merge.

## Authority

| Claim | Citation |
|---|---|
| Site ADR 0010 §4 asks for this companion decision | `greatfallstoolbus.org:docs/decisions/0010-on-prem-is-the-production-host.md`, "Decision 3" section |
| 0001's Option A and its premise | `great-falls-tool-bus-infra:docs/decisions/0001-pr-gated-ephemeral-preview-deploys.md:1-20,90-125` |
| Cloudflare Pages project deleted | site ADR 0010, Amendment 2 (2026-07-07, TIN-2560), run `28801030150` |
| CD authority pointer | `meta:decisions/0020-adopt-production-convergence-contract-2026-08-21.md` (Great-Falls-Tool-Bus/meta#34, DRAFT) |
| TIN-991 cancelled, route authority unassigned | `k8s/web/README.md:88`; `docs/runbooks/oncluster-web-cutover.md:245`; `k8s/web/pr-env-lane.md:15,84` |
| Prior-art numbering collision | `agent/production-convergence-prep-20260806` @ `d8ff004b6027b1a` (unmerged) |
