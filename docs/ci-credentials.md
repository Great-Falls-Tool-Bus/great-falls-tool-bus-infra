# CI Credentials

This overlay validates by checking out the private GloriousFlywheel core repo
next to the overlay repo.

## Required Secret

`GF_CORE_DEPLOY_KEY` must be available as a repository Actions secret for
`Great-Falls-Tool-Bus/great-falls-tool-bus-infra`. It is the private half of a
read-only deploy key attached to `tinyland-inc/GloriousFlywheel`.

Use a least-privilege credential:

- read-only access to `tinyland-inc/GloriousFlywheel`
- no package, organization-admin, workflow-write, or state/backend privileges
- rotation path recorded in the operator password manager or GitHub App secret
  store

`GF_CORE_READ_TOKEN` remains a compatibility fallback for a least-privilege
read token. Do not use a broad personal token by default. If a broad operator
token is used temporarily, record the exception and replace it before treating
the overlay CI as production authority.

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
this stack provisions — the first plan/apply always happens on the operator
machine (see docs/implementation-overlay.md).

## Why It Exists

The overlay owns private implementation facts for the Great-Falls-Tool-Bus
organization boundary. The core repo owns reusable OpenTofu modules, runner
images, actions, and docs. CI therefore needs to check out both repos to prove
that the overlay still consumes the current core contract without copying core
product logic into this repo.

## Current Status

The validation workflow is wired to use `GF_CORE_DEPLOY_KEY` for the core
checkout.

`just enrollment-preflight` checks whether the secret metadata exists without
reading the secret value. Missing owner GitHub App Kubernetes secrets, absent
GFTB-bound ARC runner scale sets, queued validation runs, or core-pin drift
are blockers.

The overlay validates against GloriousFlywheel main at
`7072ce2e0bf9d95db08add94b11123d93cd691a8` (origin/main HEAD at overlay
authoring, 2026-07-02) — the single pin shared by `config/organization.yaml`,
`MODULE.bazel`, and both workflows. Refresh this pin to a newer merged commit
or release before moving live ARC state when the core contract changes.
