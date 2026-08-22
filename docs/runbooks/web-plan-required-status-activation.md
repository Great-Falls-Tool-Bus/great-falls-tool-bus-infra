# The `web-plan` rung-2 topology, and why there is no activation step to run

**Nothing in this document is applied by writing it, and nothing here needs
operator action to become effective — that is the point of this document.**
Earlier drafts of this file (round 1/round 2 of PR #127) described an
"activation" procedure for wiring a `web-plan` context into the branch
ruleset. Adversarial review (comment 5377613179) found the mechanism that
would have made that necessary — running the render job on untrusted
`pull_request` events on the `tinyland-nix` self-hosted runner — reversed a
reviewed control (PR #110, `ae7cb63a`, "keep public PRs off private
runners") and proved the exposure real (`kubectl kustomize` fetches remote
`resources`/`bases`/`components`/`generators` entries over the network with
no flag required; a scratch PoC produced a real outbound connection attempt
from a one-line kustomization edit). Round 3 fixes that by never running the
render on an untrusted event in the first place, which is why there is no
activation step left to document: PR coverage already rides an *existing,
already-required* check, and the private render is *never* a PR-required
check at all, by design, not pending activation.

## The topology, precisely

Two workflows, two runner classes, two roles:

| | `validate.yml` `validate` job | `web-plan.yml` `web-plan` job |
|---|---|---|
| Runner | `ubuntu-24.04` (GitHub-hosted) | `tinyland-nix` (GF cache-fronted ARC, self-hosted) |
| Triggers | `pull_request` (unfiltered), `push` to `main`, `workflow_dispatch` | `pull_request` (path-filtered, PR #110 job-gate skips the body), `push` to `main` (path-filtered), `workflow_dispatch` |
| Runs on an untrusted PR? | Yes — always has; this is the repo's declared PR validation authority (PR #110's own commit message) | No — the job body only executes on `push`/`workflow_dispatch`, exactly like the other seven self-hosted workflows in this repo |
| Carries the web-stack render? | Yes, as of round 3 — an additional step after `just check-hosted`, using the same `web-stack-render` recipe | Yes — this is where the render was born; still the source of truth for the recipe and its residual-list wording |
| Reported check name | `validate` (already required — `main-reviewed-hosted-validate`, ruleset id `20930684`) | `web-plan` (**not required, never will be as designed** — see below) |
| Secrets / `environment:` | None | None |

**PR-side coverage is complete today, requires no activation, and freezes
nothing.** `validate.yml`'s `validate` job already runs, unfiltered, on
every `pull_request`, and it is already the sole required status check on
this branch's ruleset. The round-3 addition — a "Detect web-stack path
relevance" step (wording only, never gates execution) followed by an
always-executing "Render web stack plan" step — rides that existing,
already-required job. There is no `skipped`-satisfies-required hazard here
(the step can be skipped-in-wording without ever skipping-in-fact; the job
itself, and therefore the `validate` check, always actually runs and always
reports a real conclusion), and there is no path-filter freeze hazard either
(`validate.yml` has never been path-filtered).

**`web-plan.yml`'s own `web-plan` check is, and will remain, NOT a required
status check — this is a design decision, not a pending activation.** It
cannot meaningfully be one: the job is job-gated to `push`/`workflow_dispatch`
(the restored PR #110 invariant), so on a PR it only ever reports `skipped`
— exactly like `web-crs.yml`'s existing `validate` job (declare-only) does
today, and exactly why *that* job was never required either. Adding a
`skipped`-only check to a required-status list would be pure rubber-stamp
theater, not enforcement, so it is never added. `web-plan.yml`'s actual role
is the rung-2 "main-side honesty" record the truth docs describe (*"every
push to main renders the exact plan... and posts a required status"* —
satisfied by the fact that a check DOES post on every push to main, visible
in the Checks tab and as a workflow artifact; "required" in the ruleset
sense was always about blocking merges, which is `validate.yml`'s job, not
this one's).

## If this topology ever needs to change

- **If DRAFT PR #120 (TIN-3914 Phase B) migrates `validate.yml` onto
  `tinyland-nix`:** the web-stack render step moves with it automatically —
  no separate migration needed, since it already lives inside that job. At
  that point PR #120's own review is the place to re-confirm the PR-content
  execution tradeoff, because the migration changes what runner class
  untrusted PR content touches for the *entire* validate lane, not just this
  render (a strictly larger question than this document's scope).
- **If `web-plan.yml`'s own roster exclusion (TIN-3902,
  `config/organization.yaml:94-103`) is ever lifted (PR #116, currently
  HELD):** that only means the push-to-main render actually gets a runner
  promptly instead of sitting `Queued`. It does not change whether
  `web-plan`'s check should be required — it still shouldn't, for the reason
  above, independent of runner availability.
- **If someone proposes making `web-plan.yml` run on untrusted PRs again to
  get a distinct `web-plan` required context:** re-read comments 5377613179,
  5380010266, and 5380172269 first. The specific, proven failure mode was
  `kubectl kustomize`'s remote-resource fetch; `scripts/guard-no-remote-kustomize-resources.sh`
  is now an allowlist covering every reference-carrying field kustomize's
  loader resolves (round 4 -- a round-3 denylist version of this same guard
  was proven leaky three separate ways). But the PR #110 control is about
  the runner CLASS (shared substrate with real kubeconfigs and the Tofu
  state backend), not about any single script's specific behavior, and a
  guard closing every known vector today is not evidence there is no other
  one tomorrow.

## What this does not authorize

None of the above adds a Tofu plan surface, a kubeconfig, or any apply path.
The `web-release-*` chain's attended-apply gate (`_operator-apply-confirm`,
`_reviewed-clean-main`, the promotion interlock) is entirely unchanged by
this document or by either workflow it describes.
