# Activating `web-plan` as a required status check (rung 2 enforcement)

**Nothing in this document is applied by writing it.** This is the
operator-executed activation procedure for the `web-plan` workflow
(`.github/workflows/web-plan.yml`, TIN-3968-adjacent rung 2). No agent session
touches the branch ruleset; only an operator with GitHub org-admin/repo-admin
access can perform the steps below.

## Why this is a separate, later step

`web-plan` renders the committed `k8s/web` declare-only tree (`kubectl
kustomize`, nothing else) and validates it against its own jq/yq contract on
every push to `main`, entirely offline (no kubeconfig, no cluster, no Tofu
state credential, and no reach into the reviewed `web-release-*` candidate-
promotion family -- see the workflow's own header for why that boundary is
deliberate). That makes it *useful* the moment it merges. It does **not**
make it *safe to require* the moment it merges, because of a runner-roster fact
that is independent of this workflow's own correctness:

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
push to `main` would produce a required check that can never be claimed by a
runner. GitHub shows that state as `web-plan` sitting `Queued` forever — an
honestly-labeled state, not a silent failure, but a **permanently red gate**
all the same, because a required check that never completes blocks every
merge exactly as hard as one that fails. That is precisely the freeze PR #116
warns about for `validate`, and this document exists so `web-plan` does not
repeat it.

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
   admission lands and confirm it completes (not just "starts"):

   ```sh
   gh workflow run web-plan.yml --repo Great-Falls-Tool-Bus/great-falls-tool-bus-infra
   gh run list --repo Great-Falls-Tool-Bus/great-falls-tool-bus-infra --workflow=web-plan.yml --limit 1
   ```

   A `Queued` run that never transitions to `In progress` means the roster
   change has not actually resolved scheduling for this repository — do not
   proceed to the ruleset change until a real run completes.

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
hand-writing the whole body from scratch:

```sh
export GH_TOKEN=$(cat "$GH_TOKEN_FILE" | tr -d '\n')
gh api repos/Great-Falls-Tool-Bus/great-falls-tool-bus-infra/rulesets/20930684 \
  > /tmp/main-ruleset-current.json

python3 - <<'PY'
import json
with open("/tmp/main-ruleset-current.json") as fh:
    ruleset = json.load(fh)
for rule in ruleset["rules"]:
    if rule["type"] == "required_status_checks":
        contexts = rule["parameters"]["required_status_checks"]
        if not any(c["context"] == "web-plan" for c in contexts):
            contexts.append({"context": "web-plan"})
with open("/tmp/main-ruleset-patched.json", "w") as fh:
    json.dump(
        {
            "name": ruleset["name"],
            "target": ruleset["target"],
            "enforcement": ruleset["enforcement"],
            "conditions": ruleset["conditions"],
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

Verify afterward with `gh api repos/Great-Falls-Tool-Bus/great-falls-tool-bus-infra/rulesets/20930684`
and confirm `required_status_checks` now lists both `validate` and
`web-plan`.

## What this does not authorize

Activating `web-plan` as a required check changes only what blocks a merge; it
does not add a Tofu plan surface, a kubeconfig, or any apply path. The
`web-release-*` chain's attended-apply gate (`_operator-apply-confirm`,
`_reviewed-clean-main`, the promotion interlock) is entirely unchanged by
this document or by the workflow it activates.
