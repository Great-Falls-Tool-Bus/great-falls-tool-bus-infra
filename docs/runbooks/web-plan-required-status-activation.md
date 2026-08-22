# Activating `web-plan` as a required status check (rung 2 enforcement)

**Nothing in this document is applied by writing it.** This is the
operator-executed activation procedure for the `web-plan` workflow
(`.github/workflows/web-plan.yml`, TIN-3968-adjacent rung 2). No agent session
touches the branch ruleset; only an operator with GitHub org-admin/repo-admin
access can perform the steps below.

## Why this is a separate, later step

`web-plan` renders the committed `k8s/web` declare-only tree (`kubectl
kustomize`, nothing else) and validates it against its own jq/yq contract,
entirely offline (no kubeconfig, no cluster, no Tofu state credential, and no
reach into the reviewed `web-release-*` candidate-promotion family — see the
workflow's own header for why that boundary is deliberate). That makes it
*useful* the moment it merges. It does **not** make it *safe to require* the
moment it merges, for one hazard that is independent of this workflow's own
correctness — a runner-roster gap:

- `web-plan` runs on `tinyland-nix`, the same GF cache-fronted ARC class every
  other private-runner workflow in this repository uses.
- TIN-3902's roster (`config/organization.yaml`
  `runner_contract.runner_group.selected_repository_ids`) currently
  **excludes** this repository (id `1286829099`) from that runner group.
  DRAFT PR #116 (`ci/tin-3914-self-hosted-validate`) is the chain that would
  admit it, and it is explicitly **HELD** pending the operator's admission
  ruling.
- The live branch ruleset today (`main-reviewed-hosted-validate`, id
  `20930684`) requires exactly one status check: `validate`
  (`.github/workflows/validate.yml`, which deliberately still runs on a
  GitHub-hosted `ubuntu-24.04` runner precisely so it can never be starved).
  See `gh api repos/Great-Falls-Tool-Bus/great-falls-tool-bus-infra/rulesets/20930684`.

If `web-plan` were added to that ruleset's `required_status_checks` **before**
this repository is admitted to the `tinyland-nix` runner group, every future
PR would produce a required check that can never be claimed by a runner.
GitHub shows that state as `web-plan` sitting `Queued` forever — an
honestly-labeled state, not a silent failure, but a **permanently red gate**
all the same, because a required check that never completes blocks every
merge exactly as hard as one that fails. That is precisely the freeze PR #116
warns about for `validate`, and this document exists so `web-plan` does not
repeat it.

### Path-coverage rationale (why this hazard, and only this one, is what's left)

An earlier version of `web-plan.yml` path-filtered its `pull_request` trigger
and job-gated execution to trusted push/dispatch events only. Adversarial
review (PR #127, comment 5377515480) found that design **independently
broken as a required-status check**, for reasons that have nothing to do with
runner starvation: (a) a PR touching none of the five watched paths never
dispatched the workflow at all, so a required check would sit at "Expected —
waiting for status to be reported" forever — 13 of the last 30 commits on
`main` at review time touched none of them; (b) on a PR that *did* match, the
job-level `if:` skipped the job body, and GitHub counts a `skipped`
conclusion as **satisfying** a required check — so the original design would
have blocked the PRs it should pass and rubber-stamped the ones it should
actually check.

That defect is fixed in the workflow itself, not here: `web-plan.yml` now
triggers on every `pull_request` and every `push` to `main`, unfiltered, and
the job always runs and always reports a real `web-plan` conclusion. Path
relevance is detected *inside* the job (the "Detect changed web-stack paths"
step) and only gates whether the render/validate step executes — an
irrelevant change gets a real, reported "no web-stack paths touched" green,
never a `skipped` conclusion and never a silently-never-dispatched one. That
means the ONLY remaining reason `web-plan` cannot be required yet is the
runner-roster gap above — the check-semantics hazard is closed, the
starvation hazard is not, and the two preconditions below test only the
latter.

## Preconditions (both must be true before you touch the ruleset)

1. **Roster admission landed.** PR #116's chain has merged, and
   `config/organization.yaml`'s `runner_contract.runner_group.selected_repository_ids`
   carries `1286829099` with its required `infra_repo_admission_ruling:`
   field (`scripts/validate-runner-group-contract.py` enforces the field's
   presence for exactly that id). Confirm with:

   ```sh
   just runner-group-contract
   ```

2. **Scheduling actually works, not just the config.** Roster admission is a
   GitHub org-settings roster; it does not, by itself, prove a job on
   `tinyland-nix` will actually be claimed by a runner for *this* repository.
   Before requiring `web-plan`, manually dispatch it at least once after
   admission lands and confirm it completes (not just "starts") — the
   workflow always renders on `workflow_dispatch` regardless of path
   relevance, so this exercises the same runner-claim path a real PR would:

   ```sh
   gh workflow run web-plan.yml --repo Great-Falls-Tool-Bus/great-falls-tool-bus-infra
   gh run list --repo Great-Falls-Tool-Bus/great-falls-tool-bus-infra --workflow=web-plan.yml --limit 1
   ```

   A `Queued` run that never transitions to `In progress` means the roster
   change has not actually resolved scheduling for this repository — do not
   proceed to the ruleset change until a real run completes. (You do not
   additionally need to test a PR against a web-stack path specifically —
   that was only a distinct concern under the old, now-fixed path-filtered
   design.)

## Activation step (operator-only, GitHub UI path — preferred)

1. GitHub → this repository → **Settings → Rules → Rulesets** →
   `main-reviewed-hosted-validate`.
2. Under the **Require status checks to pass** rule, add `web-plan` to the
   existing `validate` requirement (do not remove `validate` — it stays the
   hosted, always-schedulable fallback check). GitHub's picker lists checks
   that have run at least once, which is why the manual dispatch in
   precondition 2 must happen first.
3. Save. The ruleset's `updated_at` timestamp is the activation record; no
   separate ticket is required, but note the change in the program board.

## Activation step (scripted alternative)

The ruleset API takes the full `required_status_checks` array, not a diff, so
read the current ruleset first and splice in the new entry rather than
hand-writing the whole body from scratch. Do this in one sitting close to the
GitHub UI verification step below — the rulesets API has no ETag/If-Match
concurrency guard, so a concurrent ruleset edit by anyone else between the GET
and the PUT is last-write-wins and would be silently discarded by this script.

```sh
export GH_TOKEN=$(cat "$GH_TOKEN_FILE" | tr -d '\n')
gh api repos/Great-Falls-Tool-Bus/great-falls-tool-bus-infra/rulesets/20930684 \
  > /tmp/main-ruleset-current.json

# Look up web-plan's own integration_id (the app that posted its check runs)
# from a recent completed run, rather than guessing or copying validate's
# 15368 (a DIFFERENT GitHub App / check source). Run precondition 2's manual
# dispatch first so a `web-plan` check run actually exists to look up.
web_plan_sha="$(gh run list --repo Great-Falls-Tool-Bus/great-falls-tool-bus-infra \
  --workflow=web-plan.yml --status=completed --limit 1 --json headSha --jq '.[0].headSha')"
web_plan_integration_id="$(gh api "repos/Great-Falls-Tool-Bus/great-falls-tool-bus-infra/commits/${web_plan_sha}/check-runs" \
  --jq '.check_runs[] | select(.name == "web-plan") | .app.id' | head -n1)"
test -n "${web_plan_integration_id}" || { echo "no completed web-plan check run found; run precondition 2 first" >&2; exit 1; }

python3 - "${web_plan_integration_id}" <<'PY'
import json
import sys

integration_id = int(sys.argv[1])

with open("/tmp/main-ruleset-current.json") as fh:
    ruleset = json.load(fh)

target_rule = next(
    (rule for rule in ruleset["rules"] if rule["type"] == "required_status_checks"),
    None,
)
if target_rule is None:
    raise SystemExit(
        "no required_status_checks rule found on ruleset 20930684 -- "
        "the ruleset shape changed since this script was written; do not "
        "silently PUT an unmodified body, stop and re-check by hand"
    )

contexts = target_rule["parameters"]["required_status_checks"]
if not any(c["context"] == "web-plan" for c in contexts):
    contexts.append({"context": "web-plan", "integration_id": integration_id})

with open("/tmp/main-ruleset-patched.json", "w") as fh:
    json.dump(
        {
            "name": ruleset["name"],
            "target": ruleset["target"],
            "enforcement": ruleset["enforcement"],
            "conditions": ruleset["conditions"],
            "bypass_actors": ruleset["bypass_actors"],
            "rules": ruleset["rules"],
        },
        fh,
    )
PY

gh api --method PUT \
  repos/Great-Falls-Tool-Bus/great-falls-tool-bus-infra/rulesets/20930684 \
  --input /tmp/main-ruleset-patched.json
rm -f /tmp/main-ruleset-current.json /tmp/main-ruleset-patched.json
```

Verify immediately afterward with
`gh api repos/Great-Falls-Tool-Bus/great-falls-tool-bus-infra/rulesets/20930684`
and confirm `required_status_checks` now lists both `validate` (unchanged,
`integration_id: 15368`) and `web-plan` (its own, looked-up `integration_id`),
and that `bypass_actors` still matches the pre-edit GET.

## What this does not authorize

Activating `web-plan` as a required check changes only what blocks a merge; it
does not add a Tofu plan surface, a kubeconfig, or any apply path. The
`web-release-*` chain's attended-apply gate (`_operator-apply-confirm`,
`_reviewed-clean-main`, the promotion interlock) is entirely unchanged by
this document or by the workflow it activates.
