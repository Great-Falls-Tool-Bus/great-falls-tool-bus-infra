# CI Credentials

This overlay validates by checking out the public GloriousFlywheel core repo at
an exact role-bound commit next to the overlay repo.

## Core Source Checkout

The core checkout needs no dedicated cross-repository deploy key, PAT, or
GitHub App secret. Each workflow supplies the canonical public repository,
exact `GF_CORE_REF`, explicit `GloriousFlywheel` path, and
`persist-credentials: false`, then compares the checked-out `HEAD` with the
declared ref before consuming any core action or devshell.

Pinned `actions/checkout` still defaults its `token` input to the workflow
repository's ephemeral per-run `github.token`. That token can fetch public
source but carries no private-GloriousFlywheel grant; the workflow neither
passes it explicitly nor persists it in Git configuration.

If GloriousFlywheel becomes private later, that is a new reviewed authority
change. Use a dedicated, per-overlay GitHub App installation token scoped only
to `contents:read` on that repository; do not silently restore a deploy-key/PAT
ladder and do not reuse the org-scoped ARC registration App.

## Optional Site-CI Metadata Token

`SITE_CI_READ_TOKEN` is an optional, purpose-bound override for the
`web-stack.yml` repository-dispatch gate that reads the public site repository's
Actions result. Its default is the workflow's ephemeral `github.token`. It is
not a GloriousFlywheel source credential and must not be named or reused as one.

## Optional Cache-Warming Secret

`ATTIC_TOKEN` may be configured as a repository Actions secret when trusted
push validation should read from and publish warmed Nix outputs into the shared
Attic cache. The workflow only exposes this token on `push` events.
Pull-request validation stays read-only and skips private Attic attachment
unless a separate authenticated read path is added.

## ARC Runner Deploy Secrets

The ARC runner deploy workflow plans on pull requests and pushes, but applies
only through manual `workflow_dispatch` with `action=apply`.

Required secrets:

- `ARC_RUNNERS_KUBECONFIG_B64`: base64-encoded Honey kubeconfig with access to
  plan and reconcile the `arc-runners` namespace.
- `ARC_RUNNERS_RUSTFS_ACCESS_KEY`: RustFS S3 backend access key for the
  `tofu-state` bucket.
- `ARC_RUNNERS_RUSTFS_SECRET_KEY`: RustFS S3 backend secret key for the
  `tofu-state` bucket.

If they are absent, pull-request and push runs skip ARC planning with notices;
manual `action=apply` fails closed.

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

BOOTSTRAP NOTE: these secrets only matter AFTER the GFTB scale set exists.
Overlay CI itself runs on `tinyland-nix`, which resolves through the scale set
this stack provisions. The first plan/apply always happens on the operator
machine (see docs/implementation-overlay.md).

## Why It Exists

The overlay owns private implementation facts for the Great-Falls-Tool-Bus
organization boundary. The core repo owns reusable OpenTofu modules, runner
images, actions, and docs. CI therefore needs to check out both repos to prove
that the overlay still consumes the current core contract without copying core
product logic into this repo.

## Current Status

All eleven core-consuming workflows use the public exact-SHA checkout contract.
The repository contains a twelfth workflow without a core checkout; the finite
`.yml`/`.yaml` census deliberately covers it so a new source consumer cannot
hide under the alternate extension.

`just core-checkout` validates checkout action immutability, public repository,
finite overlay/core paths, role pin, non-persistence, read-only workflow
permission, closed HEAD assertion, all 30 exact `GF_CORE_CI_PATH` devshell
sources, the pinned-and-hashed OIDC helper URL, and absence of dedicated
cross-repository credential inputs. `just core-checkout-selftest` proves the
guard rejects adversarial mutations. The pinned pre-#1208 GloriousFlywheel
`implementation-overlay-preflight.py` still reports its legacy source-key row;
that row is not authority for this public checkout and is not a reason to mint
a new credential.

The overlay's implementation authority remains
`2281b576bce0e8dd776a047b84e7464f5b508a62`, shared by
`config/organization.yaml`, `MODULE.bazel`, `Justfile`, and the non-ARC core
workflow consumers. The ARC runner and OIDC profile surfaces retain their
existing `df510574d17b85e7f15470caf3574fcabc4768f1` role pin. The
finite contract checks this mapping exactly. A future convergence must review
the executable core delta as its own adoption change.
