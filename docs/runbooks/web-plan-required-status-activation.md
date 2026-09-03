# Activating `web-plan` as a PR-required status check (W17 / TIN-4256)

**This document now describes a real, attended activation procedure.** That
is a reversal of this file's previous central claim ("`web-plan` is not
required, never will be as designed"), so read the history first — the
*reasoning* behind the old claim is not reversed; it is exactly what shaped
the W17 trigger design.

## History: why the old answer was "never", and what changed

Round 3 of PR #127 (adversarial review comment 5377613179) gated
`web-plan.yml`'s job body to `push`/`workflow_dispatch` (the PR #110 "keep
public PRs off private runners" invariant), because the round-2 attempt to
run it on untrusted PRs exposed a real vector: `kubectl kustomize` fetches
remote `resources`/`bases`/`components`/`generators` entries over the
network with no flag required, from PR-controlled content, on the runner
class that carries real kubeconfigs and shares substrate with the Tofu
state backend. A gated job reports `skipped` on PRs, and `skipped`
*satisfies* a required status check — so requiring it would have been
rubber-stamp theater, hence "never".

Two things changed after that ruling:

1. **The vector was closed structurally, not by denylist.** Round 4
   (comments 5380010266, 5380172269) replaced a proven-leaky denylist with
   `scripts/guard-no-remote-kustomize-resources.sh`: an ALLOWLIST over
   every reference-carrying field kustomize's loader resolves, accepting
   only real, contained local paths. Both `just web-stack-render` and
   `scripts/validate-web-stack.sh` run it before any `kubectl kustomize`
   call.
2. **The invariant gained a reviewed exception class.** PR #116 put
   `validate.yml`'s `validate` job — secret-free, `contents: read` only —
   unfiltered on every `pull_request` on `tinyland-nix`, and adversarial
   review (comment 5381265081) ruled that compensating control acceptable
   (class (3) in `config/organization.yaml`'s `runner_group` standing
   invariant).

W17 / TIN-4256 applies both facts to `web-plan.yml` itself: it drops the
#110 gate and the `pull_request` path filter, and runs its credential-free
render+validate body on **every** PR as the second sanctioned class-(3)
exception. `validate.yml` keeps its own copy of the PR-side render as
defense in depth (removing that copy is a separate operator call).

## The topology, precisely (post-W17)

| | `validate.yml` `validate` job | `web-plan.yml` `web-plan` job |
|---|---|---|
| Runner | `tinyland-nix` (GF cache-fronted ARC) | `tinyland-nix` (same class) |
| Triggers | `pull_request` (unfiltered), `push` to `main`, `workflow_dispatch` | `pull_request` (unfiltered), `push` to `main` (path-filtered), `workflow_dispatch` |
| Runs on an untrusted PR? | Yes — class-(3) exception #1 (PR #116) | Yes — class-(3) exception #2 (W17 / TIN-4256) |
| Carries the web-stack render? | Yes (defense in depth) | Yes — the authoritative `web-plan` context |
| Reported check name | `validate` (required — `main-reviewed-hosted-validate`, ruleset id `20930684`) | `web-plan` (**required once the operator runs the activation step below**) |
| Secrets / `environment:` | None | None |

Why the W17 trigger shape is mandatory for a required check:

- **No `paths:` filter on `pull_request`.** A path-filtered required check
  freezes every PR outside its filter — GitHub reports the context
  "Expected" forever and the PR can never merge.
- **No event-gate `if:` on the job.** A gated job reports `skipped` on
  PRs, and `skipped` satisfies required status checks.

## Activation procedure (attended, operator-only)

Ruleset wiring is deliberately not automated and not performed by any
agent: this runbook exists precisely so that no one silently makes a check
required. **Sequencing is mandatory** — wiring the context before the
unfiltered trigger is on `main` freezes every open PR on a check that
cannot run.

1. Merge the W17 workflow change to `main`.
2. Confirm `web-plan` reports `success` on a real PR opened after the
   merge: `gh pr checks <n>` must list both `validate` and `web-plan`.
3. Read the current ruleset (dry read, and re-verify the payload below is
   still current — `PUT` replaces the **whole** ruleset):

   ```sh
   gh api repos/Great-Falls-Tool-Bus/great-falls-tool-bus-infra/rulesets/20930684
   ```

4. `PUT` the full ruleset back with `web-plan` added to
   `required_status_checks` (integration id 15368 = GitHub Actions, same
   as `validate`):

   ```sh
   gh api -X PUT repos/Great-Falls-Tool-Bus/great-falls-tool-bus-infra/rulesets/20930684 \
     --input - <<'JSON'
   {
     "name": "main-reviewed-hosted-validate",
     "target": "branch",
     "enforcement": "active",
     "conditions": { "ref_name": { "exclude": [], "include": ["refs/heads/main"] } },
     "bypass_actors": [],
     "rules": [
       { "type": "deletion" },
       { "type": "non_fast_forward" },
       { "type": "required_signatures" },
       { "type": "pull_request", "parameters": {
           "required_approving_review_count": 0,
           "dismiss_stale_reviews_on_push": true,
           "required_reviewers": [],
           "require_code_owner_review": false,
           "dismissal_restriction": { "enabled": false, "allowed_actors": [] },
           "require_last_push_approval": false,
           "required_review_thread_resolution": true,
           "require_extra_approval_for_unattributed_changes": true,
           "allowed_merge_methods": ["squash"] } },
       { "type": "required_status_checks", "parameters": {
           "strict_required_status_checks_policy": true,
           "do_not_enforce_on_create": false,
           "required_status_checks": [
             { "context": "validate", "integration_id": 15368 },
             { "context": "web-plan", "integration_id": 15368 } ] } }
     ]
   }
   JSON
   ```

5. Verify:

   ```sh
   gh api repos/Great-Falls-Tool-Bus/great-falls-tool-bus-infra/rulesets/20930684 \
     --jq '.rules[] | select(.type == "required_status_checks").parameters.required_status_checks'
   ```

Rollback is the same `PUT` with the `web-plan` entry removed.

## If someone proposes widening this further

Re-read comments 5377613179, 5380010266, and 5380172269 first. The PR #110
control is about the runner CLASS (shared substrate with real kubeconfigs
and the Tofu state backend), not about any single script's behavior. The
class-(3) exception covers **secret-free, `contents: read`-only** jobs
whose render paths sit behind the allowlist guard — a
`pull_request`-unfiltered job with a protected `environment:` or a
`secrets.*` reference is NOT covered and needs its own review
(`config/organization.yaml`, `runner_group` comment). The known open item
— no egress NetworkPolicy on the ARC runner namespace — remains tracked
there as well.

## What this does not authorize

None of the above adds a Tofu plan surface, a kubeconfig, or any apply
path. `web-plan.yml` and `validate.yml` touch no cluster, no registry, no
Tofu state backend, and bind no `environment:`. The `web-release-*`
chain's attended-apply gate (`_operator-apply-confirm`,
`_reviewed-clean-main`, the promotion interlock) is entirely unchanged.
