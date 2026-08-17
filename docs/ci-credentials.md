# CI Credentials

Hosted validation is self-contained. It does not fetch the private
GloriousFlywheel repository or receive a cross-repository credential.

## Core Source Checkout

The required `validate` workflow checks out only this public overlay with
`persist-credentials: false`. Exact GloriousFlywheel source-dependent ARC
validation is operator-local. Ten retained legacy self-hosted workflows still
declare exact core pins, but the public repository token cannot fetch that
private source; those declarations are not hosted validation or release
authority and are scheduled for contraction rather than receiving a new PAT,
deploy key, or reused ARC registration credential.

## Optional Site-CI Metadata Token

`SITE_CI_READ_TOKEN` is an optional, purpose-bound override for the
`web-stack.yml` repository-dispatch gate that reads the public site repository's
Actions result. Its default is the workflow's ephemeral `github.token`. It is
not a GloriousFlywheel source credential and must not be named or reused as one.

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
Secret-free `validate` runs on a GitHub-hosted runner; self-hosted and apply
lanes remain separately gated. The first plan/apply always happens on the
operator machine (see docs/implementation-overlay.md).

## Why It Exists

The overlay owns reviewed implementation declarations and public names for the
Great-Falls-Tool-Bus organization boundary; private values stay in operator
custody. The core repo owns reusable OpenTofu modules, runner images, actions,
and docs. Hosted CI proves this repo's own declarations. An operator-local
exact checkout supplies the additional ARC module validation without copying
core product logic into this repo.

## Current Status

Ten legacy core-consuming workflows retain the exact-SHA checkout declaration.
The repository contains two workflows without a core checkout; the finite
`.yml`/`.yaml` census deliberately covers them so a new source consumer cannot
hide under the alternate extension.

`just core-checkout` validates checkout action immutability, canonical repository,
finite overlay/core paths, role pin, non-persistence, read-only workflow
permission, closed HEAD assertion, all 29 exact `GF_CORE_CI_PATH` devshell
sources, the pinned-and-hashed OIDC helper URL, and absence of dedicated
cross-repository credential inputs. `just core-checkout-selftest` proves the
guard rejects adversarial mutations. The pinned pre-#1208 GloriousFlywheel
`implementation-overlay-preflight.py` still reports its legacy source-key row;
that row is not hosted-CI authority and is not a reason to mint
a new credential.

The overlay's implementation authority remains
`2281b576bce0e8dd776a047b84e7464f5b508a62`, shared by
`config/organization.yaml`, `MODULE.bazel`, `Justfile`, and the non-ARC core
workflow consumers. The ARC runner and OIDC profile surfaces retain their
existing `df510574d17b85e7f15470caf3574fcabc4768f1` role pin. The
finite contract checks this mapping exactly. A future convergence must review
the executable core delta as its own adoption change.
