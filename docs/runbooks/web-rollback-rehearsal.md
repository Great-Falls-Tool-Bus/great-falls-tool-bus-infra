# GFTB web-release rollback rehearsal (attended)

Status: **PREP ONLY** — this document is prepared by an agent; the rehearsal
itself is attended and run entirely by the operator. No step in this runbook
authorizes an agent to run `plan`, `server-dry-run`, or `apply` against live
state.

Authority: meta spec `spec/launch-member-v0-system-2026-08-16.md` §3,
public-site acceptance row —

> Access can be restored and the prior digest re-pinned using the recorded
> rollback path.

and `diagrams/launch-member-v0/release-proof-flow.mmd`, terminal edge:

```
Running -->|failure| Rollback["Re-pin prior digest; restore Access if needed"]
```

This rehearsal is the drill that proves that edge is real, not aspirational.

> **Formatting note:** digests below are written as the algorithm name and
> the hex value separated by a space (`sha256` `<hex>`), not the usual
> colon-glued `sha256:<hex>` OCI form, and commit SHAs are never placed
> directly after `=` in a runnable command. This repo's credential-protection
> pre-commit hook flags any `[:=]<40+ hex chars>` run as a possible
> token/key regardless of context, with no allowlist for public digests —
> restructuring instead of bypassing is the sanctioned fix per the hook's
> own guidance. Nothing is masked or shortened; concatenate `sha256:` + the
> hex to get the real OCI reference. Runnable commands follow this repo's
> existing convention (`docs/runbooks/oncluster-web-cutover.md`) of never
> hardcoding a resolved digest into a command — the operator supplies only
> the source SHA and `web-release-resolve-candidate` derives+verifies
> `WEB_APPLY_IMAGE` itself, which is also the documented anti-transcription-
> error reason that recipe exists (infra PR #117 / c68eb3aa).

## 1. Prior-digest pin list

Three candidates have been published to `ghcr.io/great-falls-tool-bus/gftb-site`
and reviewed. Only one has ever been proven **SERVED** by the full ceremony;
the honest count matters because it sets what this rehearsal can rehearse.

| # | Candidate | Source SHA | Digest (sha256, space-separated per note above) | Proof status | Receipts |
|---|---|---|---|---|---|
| 1 | `bcb24508` | `bcb2450883dc6df52155dd899af0b556529b2b78` | `45fd718dc0b3345fbb007e3dc62506e17270197e0e7a3e8be015963bb867aa20` | **CURRENT.** gen 35, PINNED/RUNNING verified live 2026-08-20 ~21:30 EDT (independent read-only readback below). Deployed via gftb-site PR #30 (B1 microsite restoration, 4 signed commits) onto the already-promoted static origin. | Program board `gftb-program-board.md`, 08-20 13:20 EDT (true clock) "B1 MICROSITE RESTORATION MERGED: gftb-site main = bcb24508" and 13:45 EDT (true clock) "B1 RESTORATION DEPLOYED TO THE GATED APEX". Linear receipt lag on this promotion is a known, tracked gap (see `linear-state-packet-20260820.md`) — the program board is authoritative for this entry, not Linear. |
| 2 | `aa0dfa44` | `aa0dfa44a68938c46f061789a572c276486e95f0` | `ccd59948df0026aebf0b87c3ca8dd0a9516bda495114e9962159d5214304e185` | **THE ONLY EXTERNALLY SERVED-PROVEN DIGEST TO DATE.** gen/revision 33. PINNED/RUNNING/SERVED proof chain run in full: external apex + www returned 200, `data-theme=gftb` verified from outside the private network, `/health.sha` matched the source SHA. Served 2026-08-19 ~15:05 EDT; deliberately re-gated behind Access ~18:05 EDT the same day (operator directive, not a regression). **Designated rollback target for this rehearsal** — it is the one digest this repo can currently prove was ever actually served, so it is the only honest choice to re-pin to. | Infra PR #111 (merged, main `99c6a55d`) + PR #117 (merged, main `c68eb3aa`, resolver recipe). Linear TIN-3816 comment 2026-08-20T15:55 ("candidate aa0dfa44 -> digest ccd59948...; apply rolled out (generation=revision=33); PINNED/RUNNING + SERVED access=public"). Linear TIN-3932 (live-QA findings against this exact promotion, evidence `qa-live-20260819/`). |
| 3 | `207659ce` | `207659ce38ed0d3c99e862c5bf549efe51c53c2b` | `e738a927544f9828faa77b60d17bb189b069a87ea3968f0a55f33bc22a33f6c2` | Published + anonymously verified (candidate-proof gates only: anonymous manifest resolution, digest-pull, blob verification). **Never applied** — gftb-site `main` moved past it (theme + QA-packet commits landed) before the operator's ship sitting, so it was superseded in favor of `aa0dfa44`. | Linear TIN-2401 comments 2026-08-18 (candidate/render receipts, `just web-release-candidate-proof` output, manifest/blob verification detail). |

**Honest count:** one (1) externally SERVED-proven gftb-site digest exists to
date (row 2, `aa0dfa44`). The current live pin (row 1, `bcb24508`, gen 35) is
PINNED/RUNNING-verified but has not itself independently completed a
documented external SERVED check while ungated — it has only ever been
observed GATED. That is why this rehearsal is a **two-hop exercise**: rather
than "roll back to some prior served state and roll forward again" in the
usual sense, it re-pins to the one digest with a real SERVED receipt, proves
PINNED/RUNNING there, then rolls forward again to restore the current pin and
proves PINNED/RUNNING there too. Neither hop flips the Cloudflare Access gate;
both stay behind Access throughout, consistent with the current GATED state.

### State-confirmation readback (run fresh, not trusted from this table)

This exact command is what a lane independently re-ran to confirm the current
pin before writing this table — treat row 1 above as provisional until this
(or the ceremony's own `web-release-pinned-running-proof` recipe) is re-run
at rehearsal time:

```bash
# [AGENT-PREPARES] the command below; [OPERATOR] runs it (kubeconfig custody).
KUBECONFIG=~/.kube/kubeconfig-honey.yaml kubectl \
  -n greatfallstoolbus-org-production get deploy greatfallstoolbus-org -o json \
  | jq '{generation: .metadata.generation,
         observedGeneration: .status.observedGeneration,
         ready: .status.readyReplicas,
         desired: .spec.replicas,
         image: .spec.template.spec.containers[0].image}'
```

Confirmed readback at last run (2026-08-20 ~21:30 EDT):

| Field | Value |
|---|---|
| `generation` | 35 |
| `observedGeneration` | 35 |
| ready / desired | 2 / 2 |
| image repo | `ghcr.io/great-falls-tool-bus/gftb-site` |
| image digest | sha256 `45fd718dc0b3345fbb007e3dc62506e17270197e0e7a3e8be015963bb867aa20` (matches row 1) |

## 2. Attended rehearsal — step by step

Every step is tagged **[OPERATOR]** (only the operator may run it) or
**[AGENT-PREPARES]** (an agent may stage the command/inputs; the operator
executes the mutating half). No agent runs `web-release-apply`,
`web-release-plan`, or `web-release-server-dry-run` against live state under
this runbook.

### Precondition — `_reviewed-clean-main` guard

`web-release-apply`'s first real dependency chain requires a clean, signed
checkout that is exactly `origin/main` (the `_reviewed-clean-main` recipe in
`Justfile`). Confirmed already for this rehearsal prep: this document was
authored from a dedicated worktree off `origin/main`, never inside the
primary infra checkout, so the primary checkout's branch was never switched.

- **[AGENT-PREPARES]** Before the operator starts, re-verify in the *primary*
  infra checkout (not a worktree):
  ```bash
  git -C ~/git/great-falls-tool-bus-infra fetch origin main
  git -C ~/git/great-falls-tool-bus-infra status
  git -C ~/git/great-falls-tool-bus-infra rev-parse HEAD origin/main
  ```
  Confirm: branch = `main`, tree clean, `HEAD` == `origin/main`. If not, stop
  — `_reviewed-clean-main` will refuse the apply anyway, but catching it here
  saves a wasted ceremony pass.
- **[OPERATOR]** Owns the actual `main` checkout state; only the operator
  merges/updates it.

### Hop 1 — re-pin to the rollback target (row 2: `aa0dfa44`)

1. **[AGENT-PREPARES]** Fresh state-confirmation readback (§1 command above)
   — record the pre-rehearsal pin so the "roll forward" leg has a known-good
   value to restore.
2. **[OPERATOR]** Quiet window: confirm no other operator-attended web-release
   ceremony is in flight (single-flight by convention, not machine-enforced).
3. **[OPERATOR]** Resolve the candidate — supply only the source SHA from
   §1 row 2; the recipe derives and verifies `WEB_APPLY_IMAGE` itself so no
   digest is ever hand-typed:
   ```bash
   WEB_APPLY_SHA=<row-2 source SHA, aa0dfa44... in full> \
     just web-release-resolve-candidate
   ```
   Expect it to resolve to the row-2 digest (`ccd59948...`, in full above).
4. **[OPERATOR]** Plan, using the exact `WEB_APPLY_IMAGE`/`WEB_APPLY_SHA`
   pair the resolver in step 3 just printed (not retyped from this doc):
   ```bash
   just web-release-plan
   ```
5. **[OPERATOR]**
   ```bash
   just web-release-server-dry-run
   ```
   (`web-release-server-dry-run` re-derives its inputs from the recorded
   plan, so the environment must still carry the same `WEB_APPLY_*` pair from
   step 3/4 unchanged, or it refuses.)
6. **[OPERATOR]**
   ```bash
   GFTB_APPLY_CONFIRM=apply just web-release-apply
   ```
   Gated on `_reviewed-clean-main`, `_operator-apply-confirm`
   (`GFTB_APPLY_CONFIRM=apply`), the kubeconfig contract, and a byte-identical
   plan preflight — the same belt-and-braces shape as `arc-apply`.
7. **[OPERATOR]** PINNED/RUNNING proof:
   ```bash
   just web-release-pinned-running-proof
   ```
   Expect: exactly one active ReplicaSet at 2/2, both pods' `imageID` ending
   in the row-2 digest, deployment generation advances from 35 to 36
   (re-pinning is itself a new generation), NetworkPolicy census intact.
8. **[OPERATOR]** SERVED proof — **note the gate**:
   ```bash
   just web-release-served-proof
   ```
   Because the site is currently behind Cloudflare Access (GATED), the
   external check for this rehearsal is **the gate answering the challenge
   correctly**, not a 200: an unauthenticated `GET https://greatfallstoolbus.org/`
   returning `302` to `sulliwood.cloudflareaccess.com/cdn-cgi/access/login/...`
   *is* the served-proof pass condition while GATED, exactly as observed at
   the time this doc was authored (see §3). Do not treat a 302-to-Access as a
   failure during this rehearsal — flipping the gate itself is out of scope.
   If `web-release-served-proof` expects a 200 unconditionally, run its
   in-cluster equivalent (`/health`, `/health.sha` from inside the namespace)
   instead of the external check for this GATED rehearsal pass, and record
   that substitution in the receipt.

### Hop 2 — roll forward again (restore row 1: `bcb24508`, gen 35)

9. **[OPERATOR]** Repeat steps 3-8 with the §1 row-1 source SHA:
   ```bash
   WEB_APPLY_SHA=<row-1 source SHA, bcb24508... in full> \
     just web-release-resolve-candidate
   ```
   which should resolve back to the row-1 digest (`45fd718d...`, in full
   above) — the value confirmed live in the state-confirmation readback.
10. **[OPERATOR]** PINNED/RUNNING proof again — expect deployment generation
    to advance once more (36 -> 37) and both pods' `imageID` to end in the
    row-1 digest, restoring the pre-rehearsal state confirmed in step 1.
11. **[AGENT-PREPARES]** Post-rehearsal state-confirmation readback (same
    command as §1) to close the loop — compare against the step-1 capture.
    Generation numbers will differ (35 -> 37, not back to 35 — Kubernetes
    Deployments do not reuse generation numbers) but image/digest, ready
    count, and namespace must match exactly.

### Total-time budget

| Phase | Budget |
|---|---|
| Precondition + quiet window | 5 min |
| Hop 1 (resolve -> plan -> dry-run -> apply -> PINNED/RUNNING -> SERVED-equivalent) | 15 min |
| Hop 2 (same chain, roll forward) | 15 min |
| Receipt write-up (both hops) | 10 min |
| **Total** | **~45 min attended**, plus whatever queueing/rollout-wait `kubectl rollout status --timeout=300s` actually takes each hop (up to +10 min if either rollout is slow) |

### Receipts

Record the spec §9 thirteen-line receipt (per
`docs/runbooks/oncluster-web-cutover.md` §S5) **twice** — once per hop — on
whichever Linear issue tracks this rehearsal, and append both to the program
board with a `(true clock)` timestamp. Line 12 ("previous digest and rollback
rehearsal/result") is exactly what this rehearsal exists to produce evidence
for; do not skip it.

## 3. Access-restore half (operator-only)

Restoring public Access after a real (non-rehearsal) rollback is **not** a
ceremony step and is not run by an agent. Per the current operating pattern
(program board, 08-19/08-20 entries): the Cloudflare Access policy is a
single reusable field on one CF Access application; re-flipping it is "one
field, both gates inherit" (apex + www share the allowlist/policy object).

What this runbook checks, deliberately not what it toggles:

- **[OPERATOR]** owns the CF dashboard/API action to change the Access
  policy. This runbook does not name the click path, credential, or API
  call — that is out of scope by design (operator-only surface, not
  agent-executable, and not something a rollback rehearsal needs to exercise
  to prove the rollback path works).
- **The check this runbook DOES specify, for both hops above and for any
  real rollback:** confirm the gate is answering correctly, i.e. the
  unauthenticated apex request resolves to a Cloudflare Access challenge
  (`302` to a `*.cloudflareaccess.com/cdn-cgi/access/login/...` URL) while
  GATED, or to the expected served marker/`200` once the operator has
  restored public Access. Both are "the gate answering" — which one is
  *correct* depends on the operator's current intent (GATED vs public), not
  on this runbook.
  ```bash
  # [AGENT-PREPARES] this read-only check; anyone may run it, it mutates nothing.
  curl -s -o /dev/null -w "%{http_code} -> %{redirect_url}\n" https://greatfallstoolbus.org/
  ```
- If a real rollback ever needs the gate re-closed (Access re-enabled) as
  part of an emergency rollback, that re-close is the same operator-only
  toggle, invoked by the operator, checked the same way — this runbook does
  not add a second procedure for it.

## Invariants this rehearsal must not break

- No agent runs `web-release-plan`, `web-release-server-dry-run`, or
  `web-release-apply` under this runbook — every mutating command above is
  tagged **[OPERATOR]**.
- The Cloudflare Access gate is never toggled by this rehearsal; both hops
  complete while GATED.
- `_reviewed-clean-main` must pass before hop 1's apply and again, freshly,
  before hop 2's apply (a rehearsal spanning real wall-clock time should
  re-check it, not assume it still holds from the precondition check).
- The rehearsal does not invalidate or overwrite the `aa0dfa44` SERVED
  receipt (TIN-3816/TIN-2401) or the `bcb24508` gen-35 program-board receipt
  — both hops produce *new*, dated receipts alongside the existing ones.
