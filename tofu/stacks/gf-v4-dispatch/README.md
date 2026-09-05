# `tofu/stacks/gf-v4-dispatch/` — GFTB v4 GitHub dispatch edge (TIN-2611, RULING 3)

Operator ruling 2026-09-05 (TIN-2611): the `gf-v4-dispatch` edge for the
Great-Falls-Tool-Bus organization is the consumer's own installation fact and
lives in this `-infra` overlay. GloriousFlywheel core keeps the reusable root
module; this directory carries only what the consumer declares.

The edge is a thin organization-scoped ARC scale set that carries the GitHub
protocol and invokes `gf-action-client`. Bazel actions are scheduled by the
pooled REAPI fabric. The runner pod is never the compute or scheduling unit.

## What is here

| Path | Role |
| --- | --- |
| `great-falls-tool-bus.tfvars` | The module's eight inputs and nothing else |
| `tests/great-falls-tool-bus.tftest.hcl` | Mock-provider proof of the derived identities, run from the pinned core stack with this tfvars |
| `../../backend/honey-gf-v4-dispatch.s3.hcl` | State coordinates under the consumer prefix |

There is no `.tf` file here. The root module is
`tofu/stacks/arc-owner-overlay-release` in `tinyland-inc/GloriousFlywheel` at
the exact v4 dispatch role pin `82c96f5ce290bc768062782e911ed66a3527b941`,
consumed the way every GloriousFlywheel stack is consumed in this repository:
a pinned, verified core checkout run with `-chdir` plus this overlay's
`-var-file` and `-backend-config`. A `git::` module source is not used because
the root carries its own backend and provider blocks and the core repository is
private. The pin is bound in four places that `just gf-v4-dispatch-contract`
and `just core-checkout` join: the `Justfile` globals, the workflow
`GF_CORE_REF`, `config/organization.yaml` `dispatch_edge.core_pin`, and the
validator constants.

## Identities the module derives (recorded, not declared)

| Identity | Value |
| --- | --- |
| Namespace | `arc-runners-great-falls-tool-bus` (bootstrapped separately; the root only exact-reads it) |
| Scale set and Helm release | `great-falls-tool-bus-gf-v4-dispatch` |
| Runner label | `gf-v4-dispatch` |
| GitHub App Secret | `github-app-secret-great-falls-tool-bus-gf-v4-dispatch` |
| Action-resolution sink | ConfigMap `gf-v4-action-resolution-endpoint`, key `endpoint`, mounted at `/etc/tinyland/gf-action-resolution-endpoint` |
| Controller | `arc-systems/arc-controller-gha-rs-controller` |
| Chart | vendored `gha-runner-scale-set` 0.14.0, Helm driver `configmap`, atomic, cleanup-on-fail |

## Boundary

The tfvars carries `cluster_context`, `owner_slug`, `github_config_url`,
`runner_group`, `runner_image`, `pod_security_version`, `min_runners`, and
`max_runners`. It carries no provider endpoint, cache, executor, storage class,
node selector, toleration, affinity, namespace, runner label, or repository
roster, and never the transaction kubeconfig (`k8s_config_path` is passed by the
recipes through `TF_VAR_k8s_config_path`). `just gf-v4-dispatch-contract` fails
closed on any other key.

- `runner_group = "great-falls-tool-bus-infra"` is **TO-RATIFY**: it reuses the
  admitted tenancy group declared in `config/organization.yaml`. The
  operator's fork is a dedicated `great-falls-tool-bus-infra-gf-v4-dispatch`
  group with a gftb-site-only canary roster.
- `runner_image` is the Honey fleet pin `7bf301a6…`. Re-pin to the
  GloriousFlywheel #1766 publisher-baked digest in one reviewed PR (tfvars,
  validator constant, tftest digest) once its publication receipt exists.

## How it is validated, planned, and applied

Justfile recipes only; no raw OpenTofu anywhere in workflows or docs.

- Pull requests: `just check-hosted` runs `gf-v4-dispatch-fmt-check`,
  `gf-v4-dispatch-contract-selftest`, and `gf-v4-dispatch-contract` (secret-free,
  offline).
- Trusted push to `main` and `workflow_dispatch action=plan`
  (`.github/workflows/gf-v4-dispatch.yml`, protected environment
  `gf-v4-dispatch`): `gf-v4-dispatch-validate` (init without backend, validate,
  tftest), then `gf-v4-dispatch-init` / `gf-v4-dispatch-plan` /
  `gf-v4-dispatch-plan-show`. Only the redacted plan text leaves the runner.
- `workflow_dispatch action=apply` from `refs/heads/main` only:
  `gf-v4-dispatch-apply`, whose dependency `gf-v4-dispatch-plan-scope-check`
  admits exactly a create-only first install or an in-place Helm update of
  `module.dispatch.helm_release.arc_runner`, then a text-only post-apply plan
  that must read `No changes.`.
- Attended, operator-local, confirm-gated: `gf-v4-dispatch-app-secret-apply`
  writes the v4 product App Secret into the dispatch namespace only. It is
  unreachable from every CI workflow.

Refusals: apply off `main`; apply with any secret absent; any delete, replace,
import, move, deposed object, or drift in the plan; a core checkout that is not
exactly the pin; a non-`default` workspace; a retired kubeconfig name; any
credentialed job on `pull_request`.

Procedure, prerequisites, and the ceremony 0d ledger:
[`docs/runbooks/gf-v4-dispatch-edge.md`](../../../docs/runbooks/gf-v4-dispatch-edge.md).
