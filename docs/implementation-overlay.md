# Great-Falls-Tool-Bus Implementation Overlay

This repository is the Great-Falls-Tool-Bus (GFTB) owner overlay for the shared
Honey substrate. It is the organization counterpart to the older
personal-account overlay and the third owner overlay overall.

## What This Repo Owns

- GFTB GitHub App installation binding
- Honey ARC tfvars for org-scoped repo enrollment
- S3 backend state coordinates for this overlay
- private operator metadata and cache namespace choices

## What GloriousFlywheel Owns

- reusable OpenTofu modules and ARC stack code
- runner images and shared capability labels
- cache-backed local and CI contract
- public and operator documentation

## Organization Boundary

GFTB is a GitHub organization, so ARC registers at the ORG scope:
`github_config_url = https://github.com/Great-Falls-Tool-Bus`. The GFTB GitHub
App is installed org-wide (all repositories), which makes the single
`great-falls-tool-bus-nix` scale set reachable from every GFTB repo. There is
no repo-scoped registration anchor and no per-repo `extra_runner_sets` entry.
The personal-account anchor pattern exists only because personal accounts lack
org-level registration.

Workflows use shared labels such as `tinyland-nix`. Reachability is solved by
this overlay's GitHub App installation and ARC registration, not by minting
`gftb-*` or repo-shaped labels. Only `tinyland-nix` is provisioned today.

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
- runner pods pinned to `sting` with the
  `dedicated.tinyland.dev/compute-expansion` toleration (the tinyland-goo-nix
  anchor shape)

Raising any of these is an explicit operator decision followed by
`just arc-plan` / `just arc-apply`.

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

## Bootstrap Circularity And First Apply

Overlay CI (`deploy-arc-runners.yml`, `validate.yml`) runs on `tinyland-nix`,
which for GFTB resolves ONLY through the scale set this stack provisions, and
needs `ARC_RUNNERS_KUBECONFIG_B64` / RustFS keys / `GF_CORE_DEPLOY_KEY`
secrets. That is fine for steady-state PLAN once secrets exist, but the FIRST
plan and FIRST apply must run from the operator machine, where the `honey`
kubectl context works. Order: create App -> install App -> write App secret ->
preflight -> `arc-init`/`arc-plan` (with RustFS creds exported) -> operator
review -> `arc-apply` -> verify listener -> only then does overlay CI pick up.

## Enrollment Preflight

Run this before `arc-plan` or `arc-apply`:

```bash
export GF_CORE_PATH=../GloriousFlywheel
just enrollment-preflight
```

The preflight is read-only. The preferred core-read credential is
`GF_CORE_DEPLOY_KEY`, backed by a read-only deploy key on
`tinyland-inc/GloriousFlywheel`. Missing
`github-app-secret-great-falls-tool-bus`, an absent live
`great-falls-tool-bus-nix` scale set, queued validation runs, or core-pin
drift are enrollment blockers, not reasons to create org- or repo-specific
labels.

## ARC Runner Plan And Apply

The steady-state deploy surface is `.github/workflows/deploy-arc-runners.yml`.
Pull requests and pushes run a plan against the GFTB overlay state key only.
Live apply requires manual `workflow_dispatch` with `action=apply`. If the
scoped `ARC_RUNNERS_*` deploy secrets are absent, plan runs skip with notices
and manual apply fails closed.

The workflow uses the same GloriousFlywheel stack as the local Just targets:

```bash
just arc-init
just arc-plan
just arc-plan-show
just arc-plan-destroy-check
just arc-apply
```

Apply remains guarded by OpenTofu JSON plan actions. In-place Helm release
updates, such as raising `maxRunners`, are allowed. Any delete action is
blocked unless the operator explicitly sets `allow_destroy=true` on the manual
workflow dispatch or `ALLOW_ARC_DESTROY=1` for local apply.

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

just arc-app-secret-dry-run
just arc-app-secret-apply
just enrollment-preflight
```

The wrapper reads `github-app-secret-great-falls-tool-bus` and the `honey`
context from `config/organization.yaml`, then writes the same GitHub App secret
into `arc-systems` and `arc-runners`. Do not commit the private key,
kubeconfig, or derived secret material.

## Current Core Pin

This overlay pins GloriousFlywheel core at
`2281b576bce0e8dd776a047b84e7464f5b508a62`, `origin/main`, refreshed
2026-07-02 (PR #3) from the overlay-authoring pin `7072ce2e`. Tracking main
was chosen over the template's pin because GFTB needs the newer contracts
(extra-runner-set executor wiring, the consumer registry, the public
token-exchange front door), a fresh overlay has no live state to protect, and
the template's four internally divergent pins were a wart to fix, not
replicate. The same commit appears in `config/organization.yaml`,
`MODULE.bazel`, and every workflow `GF_CORE_REF`; refresh them all together.
