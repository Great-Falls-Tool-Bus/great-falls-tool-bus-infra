# CI Credentials

Hosted validation (`validate.yml`, the required status check) is
self-contained: it checks out only this public overlay and does not fetch
GloriousFlywheel or receive a cross-repository credential. The nine
core-consuming workflows below are different: GloriousFlywheel went private
(TIN-4015, 2026-08-22), so they credential their GloriousFlywheel checkout
with a read-only deploy key. `web-plan.yml` (rung 2) needs neither approach —
see its own section below.

## Core Source Checkout

The required `validate` workflow checks out only this public overlay with
`persist-credentials: false`; it has no GloriousFlywheel dependency and stays
secret-free. Exact GloriousFlywheel source-dependent ARC validation and all
ARC state plan/apply work are operator-local.

The other core-consuming workflows (`archive-stack.yml`, `edge-drift.yml`,
`edge-plan.yml`, `flywheel-cache-proof.yml`, `form-crs.yml`,
`k8s-stack-drift.yml`, `list-crs.yml`, `mail-crs.yml`, `web-crs.yml`) checkout
GloriousFlywheel at an exact pinned commit using the repository secret
`GF_CORE_DEPLOY_KEY` — a read-only SSH deploy key attached to
`tinyland-inc/GloriousFlywheel`, bound via `actions/checkout`'s `ssh-key:`
input. It grants `contents: read` on that one repository only: no package,
organization-admin, workflow-write, ARC state, or Kubernetes-apply privilege.
`scripts/validate-core-checkout.py` (`just core-checkout`) enforces that every
core-repository checkout binds exactly this credential — no `token:`, no
alternate secret name, no off-census checkout path escaping the check
entirely — and that the overlay/`validate`/`web-plan` checkouts remain
credential-free. No **credentialed job** runs on `pull_request` (each job
gates to `push`/`workflow_dispatch`, or declares no `pull_request` trigger at
all — see `config/organization.yaml`'s `runner_group` comment); note that
`flywheel-cache-proof.yml` does declare `on: pull_request` at the workflow
level, it is the job's own `if:` that keeps `GF_CORE_DEPLOY_KEY` off every PR
run. So the deploy key is never exposed to PR-authored content, fork or
same-repo. This is also, as of this credential, the first time a
`push`-triggered job with no protected `environment:` carries a
cross-repository credential in this repository — see
`config/organization.yaml`'s `runner_group` comment for that posture note.

Do not add an ARC kubeconfig, a broader ARC App credential, or any credential
beyond this one read-only deploy key to any of these declarations — they stay
source-checkout authority only, never ARC apply authority.

**History, for the next reviewer**: commit `91ed60ea` (2026-07-20) retired
`GF_CORE_DEPLOY_KEY`, added it to a `RETIRED_CORE_CREDENTIALS` guard, and
wrote "do not silently restore a deploy-key/PAT ladder ... **and do not reuse
the org-scoped ARC registration App**" here — correct at the time, because
GloriousFlywheel was public that day and no credential was needed at all. That
guidance assumed any future private-repo transition would stand up a
dedicated, per-overlay `contents:read` GitHub App installation token scoped
only to `tinyland-inc/GloriousFlywheel`. TIN-4015 supersedes that assumption:
GloriousFlywheel went private again the same day roster admission (PR #128)
gave every self-hosted workflow in this repository an actual runner for the
first time, no such dedicated App installation exists (a GFTB GitHub App
does exist — `config/organization.yaml`'s `github_app_secret_name`,
`docs/implementation-overlay.md`'s "ARC GitHub App Secret" — but it is the
org-scoped ARC registration App, and 91ed60ea's prohibition on reusing it for
this still holds; nothing here does), and the `GF_CORE_DEPLOY_KEY` secret
itself was never deleted (minted 2026-07-14, six days before its own
retirement) — so TIN-4015 reuses it rather than blocking on new credential
infrastructure. If GloriousFlywheel goes private a third time, or this
deploy key needs rotating, that is again a reviewed authority change, not a
silent edit.

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

Secret-free `validate` runs on the self-hosted `tinyland-nix` class (TIN-3914,
PR #116) — not a GitHub-hosted runner. `web-plan.yml` (rung 2,
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

The finite `.yml`/`.yaml` census covers 11 workflows. Eight are
`GF_CORE_REF`-pinned core-checkout consumers with 13 exact-SHA checkout
declarations. `flywheel-cache-proof.yml` checks out GloriousFlywheel too, but
at its own independent `GF_OIDC_PROFILE_REF` pin and to a distinct
`GloriousFlywheel-oidc-profile` path — it is validated on its own terms, not
counted in the 13. The other two workflows (`validate.yml`, `web-plan.yml`) do
not check out core at all; all eleven remain in the census so a new source
consumer cannot hide under the alternate extension.

`just core-checkout` validates checkout action immutability, canonical repository,
finite overlay/core paths, role pin, non-persistence, read-only workflow
permission, closed HEAD assertion, all 23 exact `GF_CORE_CI_PATH` devshell
sources, the pinned-and-hashed OIDC helper checkout, and that every
core-repository checkout (both pin families) binds exactly one credential —
the `GF_CORE_DEPLOY_KEY` deploy key, TIN-4015 — while the overlay/`validate`/
`web-plan` checkouts stay credential-free. `just core-checkout-selftest`
proves the guard rejects adversarial mutations. The pinned pre-#1208 GloriousFlywheel
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

## GloriousFlywheel credential helper: fleet-baked, no consumer credential (ruling 2026-08-31)

Operator ruling 2026-08-31 (TIN-4246 comment `7add7fd8`; TIN-4227): the released `gf-reapi-credhelper` binary is baked into the tinyland runner image by the GloriousFlywheel supply plane (the #1689 OIDC-helper pattern). Consumers on the fleet fetch nothing at job time and hold no GloriousFlywheel read credential. Two bridges were opened and retired the same night and must not return:

- `GF_RELEASE_READ_TOKEN` (fine-grained PAT, #153): never minted; the repository secret is deleted. Ruled as "completely circumventing the GH App pattern and skipping the intended -infra overlay repo".
- `TINYLAND_CI_DISPATCH_CLIENT_ID` + `TINYLAND_CI_DISPATCH_APP_PRIVATE_KEY` (App-pair per-run mint, #154): projection reverted and verified absent by name. App reach extension, if ever wanted, goes through declared overlay IaC plus a per-target readiness gate (the blahaj precedent), never a hand-set secret.

`flywheel-cache-proof.yml` now verifies the helper on the runner PATH and records its digest; provenance is the runner image digest. The `gf-credhelper-install` action remains only for external-org runners off the fleet. Follow-up in the same shape: the credentialed OIDC-profile checkout (`GF_CORE_DEPLOY_KEY`, TIN-4015) can retire once the baked image is proven on this lane, since #1689 bakes that helper too.
