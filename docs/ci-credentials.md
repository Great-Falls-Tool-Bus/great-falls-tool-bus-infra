# CI Credentials

This overlay validates against the private signed GloriousFlywheel release at
one exact commit next to the overlay repo.

## Core Source Checkout

`GF_CORE_DEPLOY_KEY` is a read-only deploy key attached to
`tinyland-inc/GloriousFlywheel` and stored as a secret in this private overlay.
It grants source read only. It is not the ARC registration App, an apply
credential, or a general PAT.

Each core-consuming job supplies the exact `GF_CORE_REF`, explicit checkout
path, `ssh-key: ${{ secrets.GF_CORE_DEPLOY_KEY }}`, and
`persist-credentials: false`, then compares `HEAD` with the declared commit.
The checked-out local `#ci` devshell is used afterward, avoiding a second
private network fetch. The root Bazel contract test similarly passes
`--override_module=attic-iac=<verified-checkout>`; the tracked `git_override`
records release identity and is not the CI fetch path.

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

## Legacy ARC State Secrets

The existing ARC workflow can maintain the adopted shared-namespace release.
It is not the dedicated owner-plane activation path. Its manual apply remains
historical behavior and must not be used to bind the new group or create the
future owner release.

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

These secrets do not satisfy the dedicated owner-plane authority contract.
That future path needs distinct bootstrap/release state, identities,
credentials, and protected attended mutation after a suitable signed GF
release exists.

## Why It Exists

The overlay owns private implementation facts for the Great-Falls-Tool-Bus
organization boundary. The core repo owns reusable OpenTofu modules, runner
images, actions, and docs. CI therefore needs to check out both repos to prove
that the overlay still consumes the current core contract without copying core
product logic into this repo.

## Current Status

All eleven core-consuming workflows use the private exact-release checkout contract.
The repository contains a twelfth workflow without a core checkout; the finite
`.yml`/`.yaml` census deliberately covers it so a new source consumer cannot
hide under the alternate extension.

`just core-checkout` checks the finite workflow census, exact private checkout,
local devshell use, shared release pin, and group-plus-capability selectors. It
is intentionally small and is retired when the GF-generated front-door/overlay
projection emits these bindings.

The validation authority is signed GF release `v0.3.0`, exact commit
`f26b541d1d7600d56b2e78c87038415fa06b3622`. It is not owner-plane activation
authority because its owner root cannot project the required authenticated
front-door tuple.
