# Great-Falls-Tool-Bus Implementation Overlay

This repository is the Great-Falls-Tool-Bus (GFTB) owner overlay for the shared
Honey substrate. It is the organization counterpart to the older
personal-account overlay and the third owner overlay overall.

## What This Repo Owns

- GFTB GitHub App installation binding
- Honey ARC tfvars for org-scoped repo enrollment
- S3 backend state coordinates for this overlay
- reviewed non-secret operator metadata and cache namespace choices

## What GloriousFlywheel Owns

- reusable OpenTofu modules and ARC stack code
- runner images and shared capability labels
- cache-backed local and CI contract
- public and operator documentation

## Organization Boundary

GFTB is a GitHub organization, so ARC registers at the ORG scope:
`github_config_url = https://github.com/Great-Falls-Tool-Bus`. The GFTB GitHub
App is installed org-wide (all repositories). GitHub runner-group admission is
a separate selected-repository boundary, so registration alone does not make
the `great-falls-tool-bus-nix` scale set reachable from every GFTB repo. There
is no repo-scoped registration anchor and no per-repo `extra_runner_sets` entry.
The personal-account anchor pattern exists only because personal accounts lack
org-level registration.

Workflows use shared labels such as `tinyland-nix`. Reachability requires this
overlay's GitHub App installation, ARC registration, and the selected GitHub
runner-group admission; it is not solved by minting `gftb-*` or repo-shaped
labels. Only `tinyland-nix` is provisioned today.

## Shared Controller Boundary

The Tinyland overlay owns the shared ARC controller and namespaces for Honey.
This overlay attaches the GFTB runner scale set to that controller with
`deploy_arc_controller = false`, `create_controller_namespace = false`, and
`create_runner_namespace = false`.

Internal Helm release names and ARC `runnerScaleSetName` values use the
`great-falls-tool-bus-*` prefix to avoid cluster collisions. Those names are
not workflow labels; workflows continue to use shared `tinyland-*` capability
labels (the arc-runner module publishes `runner_label` explicitly alongside the
owner-distinct registration name).

## Conservative Capacity Posture

Honey/sting pod budget is the scarce resource (TIN-2165/TIN-2234):

- nix lane only (`deploy_docker_runner = false`, `deploy_dind_runner = false`)
- `nix_min_runners = 0`, `nix_max_runners = 4`
- `nix_warm_pool_enabled = false`
- each nix runner requests 8 GiB and is limited to 16 GiB of ephemeral storage;
  `/nix`, `_work`, and `.cache` remain on the container root filesystem while
  the optional volumes are disabled
- runner pods pinned to `sting` with the
  `dedicated.tinyland.dev/compute-expansion` toleration (the tinyland-goo-nix
  anchor shape)

Raising any of these is an explicit operator decision followed by
`just arc-plan` / `just arc-apply`.

The 8/16 GiB envelope is the bounded response to the 2026-08-17 site-CI evidence:
four independent build/test pods crossed the former 8 GiB limit and were
evicted, while the lightweight carrier validation completed. The source carrier
records max-runner node/quota fit first. After its attended apply and exact
state/live readback, a natural-fanout run and immediate warm rerun are recorded
on TIN-2299 and a reviewed follow-up before the envelope is accepted. Every
self-hosted check must receive a real runner, the runner container's combined writable-rootfs plus log peak
(`rootfs.usedBytes + logs.usedBytes`) must stay below 75% of its limit, and no
pod eviction, restart, or node `DiskPressure` may occur. A warm cache rerun must
also pass. Failure drains the scale set and requires a separate signed,
reviewed rollback carrier whose scope guard permits only the exact 8/16 GiB to
4/8 GiB reversal; the current promotion-only guard cannot perform that rollback.
It is not permission to raise the limit again without new evidence. Per-runner bounded volumes for `/nix`,
`_work`, and `.cache` remain the durable follow-up once the primary core stack
exposes storage-class inputs compatible with `sting`.

## Shared Substrate

- cluster: `honey`
- Attic: `http://attic.nix-cache.svc.cluster.local` (cache `main`)
- Attic public key: `main:eaUydxuDu7xBoy5cCo3MdknYAkVyTIASQ7DGuwxa+XA=`
- Bazel cache: `grpc://bazel-cache.nix-cache.svc.cluster.local:9092`
- Bazel executor: `grpc://gf-reapi-cell.gf-rbe.svc.cluster.local:8980`
  (substrate fact; the primary lane is cache-only until the deliberate
  executor flip, see the tfvars comment)
- state bucket: `tofu-state`, key prefix `great-falls-tool-bus-infra`
- public token mint: `https://gf-token-exchange.tinyland.dev/v1/token/exchange`

## ARC Apply Authority

Secret-free `validate.yml` runs on a GitHub-hosted runner. ARC state planning
and mutation do not run in GitHub Actions. They run attended on the operator
machine through the guarded Just surface, with exact reviewed source, runtime
RustFS credentials, and an external kubeconfig bound to the reviewed Honey
cluster and runner-set UIDs. Keep that kubeconfig's RBAC as narrow as the ARC
plan/readback operations permit; the current guard does not certify RBAC. Do not add a
repository ARC kubeconfig or cross-repository source credential to recreate a
CI deploy lane.

## Enrollment Preflight

Run this before `arc-plan` or `arc-apply`:

```bash
export GF_CORE_PATH=../GloriousFlywheel
export GFTB_ARC_KUBECONFIG=/operator/path/gftb-arc.kubeconfig
just enrollment-preflight
```

The preflight is read-only. Missing `github-app-secret-great-falls-tool-bus`,
an absent live `great-falls-tool-bus-nix` scale set, queued self-hosted ARC
runs, or core-pin drift are enrollment blockers, not reasons to create org- or
repo-specific labels. At the pinned pre-#1208 core revision, the shared preflight
still prints a legacy core-read-credential row. Do not provision a key solely
for that row; `just core-checkout` is the source-authority gate.

## ARC Runner Plan And Apply

The operator-local path is the only ARC deploy surface. Before beginning,
fetch canonical `main`, use a clean `main` worktree at the exact signed current
remote head, and prepare a clean, signed GloriousFlywheel checkout at
`df510574d17b85e7f15470caf3574fcabc4768f1`. Set
`GF_ARC_CORE_PATH` to that checkout and keep `GF_ARC_CORE_CI_PATH` on the same
exact pin.

Set `GFTB_ARC_KUBECONFIG` to an operator-owned regular file outside the repo,
mode 0600. It must contain exactly the `honey` context, use no credential exec
plugin, and reach the existing
`honey/arc-runners/great-falls-tool-bus-nix` AutoscalingRunnerSet. The plan
receipt binds the target's exact live UID, so a different cluster, namespace,
or replacement release refuses apply. Ambient `KUBECONFIG` and
`TF_VAR_k8s_config_path` are rejected.

The reviewed backend identity is bucket `tofu-state`, key
`great-falls-tool-bus-infra/arc-runners/terraform.tfstate`. `ARC_BACKEND` may
instead name an operator-owned mode-0600 file outside the repo for a temporary
port-forward, but that file must be byte-equivalent to the reviewed backend
except for an `http://127.0.0.1:<port>` S3 endpoint. State credentials remain
runtime operator inputs. The workspace must be `default`; ambient workspace,
backend, CLI, profile, logging, and credential indirection overrides are
rejected.

Run the finite sequence through Just:

```bash
GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive just arc-plan
just arc-plan-show
just arc-plan-scope-check
GFTB_APPLY_CONFIRM=apply GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive just arc-apply
GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive just arc-capacity-readback
```

`arc-plan` refuses non-main, dirty, stale, forked, or unsigned infra source and
records both the infra and core SHAs beside the mode-0600 binary plan.
`arc-apply` repeats both source guards, requires the target-specific attended
confirmation, checks the saved SHA markers, and deletes the plan and markers
only after a successful apply. Pending plans are sensitive local artifacts;
the binary plan and all source/backend/kubeconfig/target receipts are mode 0600.
Never upload, commit, or copy them into a shared location.

Apply remains guarded by OpenTofu JSON plan actions. For the 8/16 GiB runner
envelope, the only acceptable plan is one in-place
`module.gh_nix.helm_release.arc_runner` update with zero creates, deletes,
replacements, or unrelated drift. A broader or destructive plan is a stop
condition requiring a separate reviewed decision; this operator surface has no
delete bypass.

### Exclusive state window

The RustFS S3 backend has **no remote state lock**. Before planning, establish
an exclusive quiet window covering plan, human review, apply, and live/state
readback. Confirm that no other operator and no workflow is planning or
mutating this ARC stack, and keep that true for the whole window. Supply
`GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive` only as a one-shot value on each plan,
apply, and readback command after making that check; the value records an
operator fact and is not itself a lock.

When using the localhost backend override, loss of the port-forward is an
ambiguous failure if cluster mutation may have started but the state write did
not complete. Stop immediately. Read back the live
`great-falls-tool-bus-nix` release and the canonical remote state before any
new plan or retry. Do not assume a failed command means the cluster was
unchanged, and do not blindly reapply the saved plan. The apply-attempt marker
makes that saved plan non-retryable. After restoring backend connectivity, run
`GFTB_ARC_READBACK_MODE=reconcile GFTB_ARC_EXCLUSIVE_CONFIRM=exclusive just
arc-capacity-readback`. That mode accepts only matching state/live 4/8 GiB plus
the exact pending promotion plan, or matching state/live 8/16 GiB plus an empty
plan; it then invalidates the entire attempted bundle. A pre-change receipt
permits a fresh plan. A promoted receipt does not permit retry. Any other result
is a stop condition requiring a separate reviewed state/live reconciliation.

## ARC GitHub App Secret

After the GFTB GitHub App is created at
`https://github.com/organizations/Great-Falls-Tool-Bus/settings/apps/new`
(name `gf-arc-great-falls-tool-bus`; Organization self-hosted runners:
Read & write; Repository Actions: Read; Repository Metadata: Read), installed
org-wide, and the `.pem` private key downloaded by the human operator, rotate
the ARC secret through the overlay Just targets:

```bash
export GF_CORE_PATH=../GloriousFlywheel
export GITHUB_APP_ID=<APP_ID>
export GITHUB_APP_INSTALLATION_ID=<INSTALLATION_ID>
export GITHUB_APP_PRIVATE_KEY_PATH=<PATH_TO_PRIVATE_KEY>
export GFTB_ARC_KUBECONFIG=/operator/path/gftb-arc.kubeconfig

GFTB_APPLY_CONFIRM=apply just arc-app-secret-apply
just enrollment-preflight
```

The wrapper reads `github-app-secret-great-falls-tool-bus` and the `honey`
context from `config/organization.yaml`, then writes the same GitHub App secret
into `arc-systems` and `arc-runners`. Do not commit the private key,
kubeconfig, or derived secret material.

## Current Core Pin

This overlay's implementation authority pins GloriousFlywheel core at
`2281b576bce0e8dd776a047b84e7464f5b508a62`, `origin/main`, refreshed
2026-07-02 (PR #3) from the overlay-authoring pin `7072ce2e`. Tracking a merged
commit was chosen over the template's pin because GFTB needs the newer contracts
(extra-runner-set executor wiring, the consumer registry, the public
token-exchange front door), a fresh overlay has no live state to protect, and
the template's four internally divergent pins were a wart to fix, not
replicate. The same commit appears in `config/organization.yaml`,
`MODULE.bazel`, `Justfile`, and each non-ARC core workflow. The ARC runner and
OIDC profile surfaces retain the existing
`df510574d17b85e7f15470caf3574fcabc4768f1` role pin. Review any future pin
convergence as a separate executable-core adoption change.
