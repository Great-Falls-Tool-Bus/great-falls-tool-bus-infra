# GFTB GF v4 dispatch edge — procedure and ceremony 0d ledger

Carrier for TIN-2611 (RULING 3, operator ruling 2026-09-05): the
`gf-v4-dispatch` GitHub dispatch edge for the Great-Falls-Tool-Bus organization
lives in this overlay. Stack: [`tofu/stacks/gf-v4-dispatch/`](../../tofu/stacks/gf-v4-dispatch/README.md).
Workflow: `.github/workflows/gf-v4-dispatch.yml`. Recipes: the `gf-v4-dispatch-*`
section of the `Justfile`.

The repository contains names and declarations only. App identifiers, private
keys, kubeconfigs, and backend keys stay in operator custody
([`secrets/README.md`](../../secrets/README.md)). This runbook authorizes no
mint, no dispatch, and no apply by itself; each step below names who acts and
what receipt proves it.

## What this edge is and is not

- One organization-scoped ARC scale set (`great-falls-tool-bus-gf-v4-dispatch`,
  label `gf-v4-dispatch`, min 0 / max 4) registered at
  `https://github.com/Great-Falls-Tool-Bus`. It carries the GitHub protocol and
  invokes `gf-action-client`; the pooled REAPI fabric schedules the actions.
- It is consumer demand. The overlay declares no provider endpoint, placement,
  storage, cache, executor, namespace, runner label, or roster. The module
  derives every identity from `owner_slug`.
- It is not a canary until the GF adoption quickstart's observation chain is
  measured (contribution, catalog, binding, remote Execute or cache hit,
  attribution). A Ready listener is rung 3 of the critical path on TIN-4251,
  not enrollment evidence.
- Apex, preview, and production convergence are untouched by this carrier
  (R13: no interim attended apply; the v4 controller path is awaited).

## Credentials, by name

| Name | Scope | Holder | Used by |
| --- | --- | --- | --- |
| `GF_CORE_DEPLOY_KEY` | repository secret | exists | read-only core checkout at the v4 pin |
| `ARC_RUNNERS_RUSTFS_ACCESS_KEY` / `ARC_RUNNERS_RUSTFS_SECRET_KEY` | repository secrets | exist | state backend `tofu-state/great-falls-tool-bus-infra/gf-v4-dispatch/terraform.tfstate` |
| `GF_V4_DISPATCH_KUBECONFIG_B64` | environment `gf-v4-dispatch` | to mint (step 3) | namespace-scoped plan/apply transaction |
| `github-app-gf-v4-dispatch` | GFTB sops lane `secrets/gf-v4-dispatch.enc.yaml` | to mint (ceremony 0c) | attended `gf-v4-dispatch-app-secret-apply` only |

The App private key is never an Actions secret. The ARC registration App
(installation id 143981297) is never reused for the v4 edge.

## Ceremony 0d ledger

Each row: who acts / exact action / receipt / refusal that stays in force.
Rows 0 and 1 to 4 precede the merge of this carrier's apply capability; the
pull request itself is DRAFT and unarmed until rows 0c and 0 are satisfied.

0. **Prerequisites owed elsewhere (this carrier cannot satisfy them).**
   - O-1: the GFTB product GitHub App is created and installed
     organization-wide with `repository_selection=all` (only the ARC
     registration App exists today). Receipt: the installation listing shows a
     second installation. Refusal: the ARC App is never reused.
   - Ceremony 0c: App id, installation id, private key, and webhook secret enter
     the GFTB sops lane as `secrets/gf-v4-dispatch.enc.yaml` (encrypted under
     the repo-root `.sops.yaml`; names in `secrets/README.md`). Receipt: the
     ciphertext file lands in a reviewed PR.
   - GloriousFlywheel core carries a v4-shaped namespace bootstrap for
     `arc-runners-great-falls-tool-bus`: the labels the release root's
     namespace postcondition requires (`app.kubernetes.io/name=
     gloriousflywheel-v4-dispatch`, `component=thin-dispatch`,
     `tinyland.dev/capability=gf-v4-dispatch`, `tinyland.dev/status=bound`,
     Pod Security `baseline`/`v1.33`), the plan identity, and the fixed-name
     `gf-v4-action-resolution-endpoint` ConfigMap sink. The current core
     bootstrap (`arc-owner-overlay-plan-bootstrap`) derives legacy
     `tinyland-<type>` labels that contradict those, so the edge cannot plan
     until core lands a v4 bootstrap. Provider projection of the `endpoint`
     key is provider-side. Refusal: this overlay never creates the namespace or
     the sink.
1. **Operator: runner group.** Default (TO-RATIFY): confirm that the admitted
   `great-falls-tool-bus-infra` group (org Settings, Actions, Runner groups)
   admits the `great-falls-tool-bus-gf-v4-dispatch` scale set. Fork: create
   `great-falls-tool-bus-infra-gf-v4-dispatch` with selected repositories =
   gftb-site only for the canary, then amend the tfvars,
   `config/organization.yaml` `dispatch_edge.runner_group`, the tftest, and
   `scripts/validate-gf-v4-dispatch-contract.py` in one reviewed PR. Receipt:
   the group page. Refusal: `Default` is rejected by the module and by the
   contract.
2. **Operator: protected environment.** Create environment `gf-v4-dispatch`
   with `deployment_branch_policy: protected_branches` (`gh api -X PUT
   repos/Great-Falls-Tool-Bus/great-falls-tool-bus-infra/environments/gf-v4-dispatch
   --input -` with that JSON body). Receipt: `gh api
   repos/Great-Falls-Tool-Bus/great-falls-tool-bus-infra/environments/gf-v4-dispatch`.
   Note: required-reviewer rules are a paid feature; the TIN-4004 ruling
   rejects a human approval gate on principle. The effective gate is
   `workflow_dispatch action=apply` on `refs/heads/main`.
3. **Operator: transaction kubeconfig.** After the bootstrap (row 0), mint a
   namespace-scoped kubeconfig for `arc-runners-great-falls-tool-bus` with one
   context named `honey` (embedded credentials, TLS-verified, no exec plugin)
   that can read the namespace, and manage the Helm `configmap` driver
   records, the AutoscalingRunnerSet, and the chart's namespaced RBAC objects.
   Bind it with `gh secret set GF_V4_DISPATCH_KUBECONFIG_B64 --env
   gf-v4-dispatch --repo Great-Falls-Tool-Bus/great-falls-tool-bus-infra`
   (value from stdin, never argv). Receipt: `gh secret list --env
   gf-v4-dispatch`. Refusal: the recipe contract refuses any other context
   shape, an ambient `KUBECONFIG`, or a kubeconfig inside the repository.
4. **Operator (attended, on `main`, clean, signed): App Secret.** With the
   ARC operator kubeconfig in `GFTB_ARC_KUBECONFIG` and the 0c material
   exported from the sops lane (`GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`
   via `sops exec-env secrets/gf-v4-dispatch.enc.yaml`; the PEM decrypted to a
   caller-owned mode-0600 file outside the repository and named by
   `GITHUB_APP_PRIVATE_KEY_PATH`), run
   `GFTB_APPLY_CONFIRM=apply just gf-v4-dispatch-app-secret-apply`. It writes
   `github-app-secret-great-falls-tool-bus-gf-v4-dispatch` into
   `arc-runners-great-falls-tool-bus` ONLY (the core script's default namespace
   list applies only when no `--namespace` is given; ARC copies the Secret to
   the controller namespace for the listener itself). Receipt: the recipe's
   `get secret ... -o name` readback. Refusal: the recipe verifies the core
   pin's signature, requires a clean signed `main`, and has no CI caller.
5. **Merge this carrier (unarmed today).** The push-to-main run validates and
   plans; it skips green with a notice while `GF_V4_DISPATCH_KUBECONFIG_B64`
   is absent.
6. **Operator: plan.** `gh workflow run gf-v4-dispatch.yml --ref main -f
   action=plan`; read the plan text artifact and the step summary. Expected
   shape: create-only `module.dispatch.helm_release.arc_runner` plus a read of
   `data.kubernetes_namespace_v1.dispatch`. Refusal: any other address,
   delete, replace, import, move, or drift fails the scope check.
7. **Operator: apply.** `gh workflow run gf-v4-dispatch.yml --ref main -f
   action=apply`. The job re-plans in the same run, runs the scope check,
   applies the exact plan, then asserts a text-only post-apply plan reads
   `No changes.`. Receipts: the run id; the non-secret `dispatch_edge` output
   in the plan text; a read-only `kubectl get autoscalingrunnerset -n
   arc-runners-great-falls-tool-bus` readback showing
   `great-falls-tool-bus-gf-v4-dispatch`; the listener
   `great-falls-tool-bus-gf-v4-dispatch` Ready. Record the MEASURED@UTC tuple
   on TIN-2611.
8. **Re-pin the runner image.** When `deploy/gf-rbe/published-digests.log` in
   GloriousFlywheel carries the #1766 publisher-baked digest, move
   `runner_image`, the validator constant, and the tftest digest together in
   one reviewed PR, then repeat rows 6 and 7 (in-place Helm update shape).
9. **Not a canary yet.** Rung 3 is proved when a gftb-site job that requests
   `runs-on: gf-v4-dispatch` is picked up and fails with anything other than
   exit 127. Rungs 4 and 5 (first remote Execute, AC hit) are measured on the
   GFTB site repository, not here.

Refusals baked into the carrier: apply off `main`; apply with any secret
missing; any delete, replace, import, move, or drift in the plan; a core
checkout that is not exactly the pin; a non-`default` workspace; retired
kubeconfig names; PR-triggered credentialed jobs.

## Verification receipts pending the first authorized run

The remote-only ruling (2026-09-01) keeps OpenTofu off operator machines, and
TIN-2611 forbids workflow dispatch from agent sessions. The offline validators
run on every pull request; the `tofu fmt`, `validate`, and `tftest` receipts
come from the first push-to-main run of `gf-v4-dispatch.yml` after rows 0 to 3
exist, or from a one-time operator-ruled validate-only branch dispatch.
