# CI Credentials

Hosted validation is self-contained. It does not fetch the private
GloriousFlywheel repository or receive a cross-repository credential.

## Core Source Checkout

The required `validate` workflow checks out only this public overlay with
`persist-credentials: false`. Exact GloriousFlywheel source-dependent ARC
validation and all ARC state plan/apply work are operator-local. The remaining
core-consuming workflows declare exact core pins; the public repository token
cannot fetch that private source. Do not add a PAT, deploy key, reused ARC App
credential, or ARC kubeconfig to turn those declarations into ARC authority.

## Optional Site-CI Metadata Token — RETIRED (TIN-3899)

`SITE_CI_READ_TOKEN` was an optional, purpose-bound override for the
`web-stack.yml` repository-dispatch gate that read the public site repository's
Actions result. That workflow and its `web-cd-ci-green-gate` recipe are deleted,
so nothing consumes the name any more: no workflow reads it and no recipe
requires it. If the secret is still provisioned, remove it. It was never a
GloriousFlywheel source credential and must not be named or reused as one.

## Edge Backend Secrets

The edge plan/drift workflows legitimately retain the existing RustFS backend
secret names `ARC_RUNNERS_RUSTFS_ACCESS_KEY` and
`ARC_RUNNERS_RUSTFS_SECRET_KEY`. The names are historical and shared with the
edge backend; their presence does not authorize ARC state planning or apply.
ARC uses the runtime AWS SDK access-key pair from operator custody. No ARC
kubeconfig belongs in Actions.

## Mail CR Apply Secret

`MAIL_APPLY_KUBECONFIG_B64` belongs only in the protected `mail` environment.
It is the base64-encoded namespace-scoped kubeconfig minted from the Blahaj
tenant namespace grant for `latoolb-us-production`. The workflow also accepts
`GFTB_MAIL_KUBECONFIG_B64` as a compatibility alias, but operators should not
set both names unless they intentionally hold the same value.

The kubeconfig may apply only `mail.tinyland.dev` `MailDomain`,
`MailAccount`, and `MailAlias` resources in that namespace. It must not carry
cluster-scoped rights, Secret rights, or access to other namespaces.

Local operator runs use a file path instead:

```bash
GFTB_MAIL_KUBECONFIG=/path/to/latoolb-us-production.kubeconfig just mail-cr-server-dry-run
GFTB_MAIL_KUBECONFIG=/path/to/latoolb-us-production.kubeconfig just mail-cr-apply
```

Secret-free `validate` runs on a GitHub-hosted runner. `web-plan.yml` (rung 2,
`.github/workflows/web-plan.yml`) is also secret-free — it renders the
committed `k8s/web` tree with `kubectl kustomize` and validates it with
`scripts/validate-web-stack.sh`, contacting no registry, cluster, or Tofu
state backend — but runs on the self-hosted `tinyland-nix` class like every
other apply/drift lane in this repo, not on a GitHub-hosted runner; it binds
no protected `environment:` because it needs none. It also does not check
out GloriousFlywheel core at all (fixed post-roster-admission, TIN-3914: the
core repository is private, and the default `GITHUB_TOKEN` scoped to this
repo cannot read it — every self-hosted workflow that touched it,
unauthenticated, failed the moment it actually got a runner). This repo's
own `flake.nix` devshell already provides everything `web-stack-validate`/
`web-stack-render` need, so `web-plan.yml` is simpler than the other
self-hosted lanes, not merely equivalent to them — one fewer moving part,
and one fewer private-repo dependency. Self-hosted workload and non-ARC
apply lanes remain separately gated. ARC plan/apply always happens on the
operator machine (see docs/implementation-overlay.md).

## Why It Exists

The overlay owns reviewed implementation declarations and public names for the
Great-Falls-Tool-Bus organization boundary; private values stay in operator
custody. The core repo owns reusable OpenTofu modules, runner images, actions,
and docs. Hosted CI proves this repo's own declarations. An operator-local
exact checkout supplies the additional ARC module validation without copying
core product logic into this repo.

## Current Status

The finite `.yml`/`.yaml` census covers 11 workflows. Eight are core-checkout
consumers with 13 exact-SHA checkout declarations. The other three workflows
(`validate.yml`, `flywheel-cache-proof.yml`, `web-plan.yml`) do not check out
core; they remain in the census so a new source consumer cannot hide under
the alternate extension.

`just core-checkout` validates checkout action immutability, canonical repository,
finite overlay/core paths, role pin, non-persistence, read-only workflow
permission, closed HEAD assertion, all 23 exact `GF_CORE_CI_PATH` devshell
sources, the pinned-and-hashed OIDC helper URL, and absence of dedicated
cross-repository credential inputs. `just core-checkout-selftest` proves the
guard rejects adversarial mutations. The pinned pre-#1208 GloriousFlywheel
`implementation-overlay-preflight.py` still reports its legacy source-key row;
that row is not hosted-CI authority and is not a reason to mint
a new credential.

The overlay's implementation authority remains
`2281b576bce0e8dd776a047b84e7464f5b508a62`, shared by
`config/organization.yaml`, `MODULE.bazel`, `Justfile`, and the non-ARC core
workflow consumers. The ARC runner and OIDC profile surfaces carry a separate
role pin, advanced by TIN-3902 from
`df510574d17b85e7f15470caf3574fcabc4768f1` to
`11ace397282ff89aeb1dfeb4a32fcbed3200c2ff` so the `arc-runners` stack exposes
the `runner_group` input. `scripts/flywheel-github-oidc-profile.sh` is
byte-identical at both commits, so `GF_OIDC_PROFILE_SHA256` is unchanged and
this workflow's fetched helper is the same file. The finite contract checks
this mapping exactly. A future convergence must review the executable core
delta as its own adoption change.
