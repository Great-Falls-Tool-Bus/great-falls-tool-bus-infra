# great-falls-tool-bus-infra

Consumer-owned infrastructure overlay for the Great-Falls-Tool-Bus GitHub
organization.

## GloriousFlywheel v4 contract

GFTB adopts GloriousFlywheel without registering itself in the producer
repository:

1. the organization installs the GF GitHub App;
2. this repository publishes signed, immutable `OwnerInstallation/v1`,
   `TenantOverlay/v1`, and cumulative consumer `RevocationSet/v1` operands;
3. this repository applies one immutable `OwnerOverlayRevision/v1` that names
   those exact OCI artifacts;
4. application repositories carry exact ActionPlans and call the immutable
   `ci-templates` v4 entrypoint; and
5. the owner controller verifies GFTB demand and joins it to independently
   verified provider supply.

The overlay declares capabilities, policy, and application lifecycle. It does
not declare cluster endpoints, nodes, storage classes, namespaces, worker
pools, ARC scale sets, or runner labels. Those are provider supply. GF core
owns the types and controller contract, never GFTB instances or repository
rows.

Enrollment is fail closed. A missing App installation, signed operand,
revocation chain, owner revision, resolved binding catalog, OIDC identity, or
REAPI authority is a product defect to repair. It is not permission to use a
local build, cache-only profile, direct endpoint, producer registry, or
GitHub-hosted fallback.

The removed `flywheel-cache-proof`, `flywheel-enroll`, OIDC-profile, and local
Bazel wrapper surfaces were v3 attachment machinery. They are not v4 evidence
and must not return.

## Architecture

Grounded diagrams for the GFTB-owned mail, network, and application planes live
in [`docs/architecture/diagrams.md`](docs/architecture/diagrams.md). The GF v4
structural authority is `spec/flywheel/Core.dhall` in GloriousFlywheel; the
controller CRDs and Go types are owned by `owner-overlay-controller`.

Private credentials stay outside Git:

- the GFTB GitHub App private key and installation ID;
- RustFS/S3 backend access keys;
- kubeconfigs and operator tokens; and
- `.env` files and local backend configs with secrets.

## Edge/DNS apply plane (TIN-2360 row c, amended 2026-07-02)

This overlay is the canonical apply home for the GFTB edge. The live TIN-2385
stack is [`tofu/stacks/edge/`](tofu/stacks/edge/README.md): zones are added
console-side to the house Cloudflare account, looked up by name with a
zone-scoped token, and reconciled here. Console and registrar steps live in
[`docs/runbooks/edge-token-and-zones.md`](docs/runbooks/edge-token-and-zones.md).

[`tofu/stacks/edge-dns/`](tofu/stacks/edge-dns/README.md) is retained only as
the superseded pre-TIN-2385, fail-closed reference. It must not be applied
while the live edge stack owns the zone surface.

## Mail CR apply plane (TIN-2379)

Tenant-owned mail custom resources live in
[`k8s/mail/latoolb-us-production/`](k8s/mail/latoolb-us-production/). They
consume the namespace grant declared by the cluster provider; the declarations
do not move into that provider repository.

Use `just mail-cr-validate` for offline shape validation and
`just mail-cr-server-dry-run` / `just mail-cr-apply` only with a
namespace-scoped kubeconfig supplied through `GFTB_MAIL_KUBECONFIG`. See
[`docs/mail-cr-apply-runbook.md`](docs/mail-cr-apply-runbook.md).

Mailman list engine runbooks: bring-up in
[`docs/runbooks/list-bringup.md`](docs/runbooks/list-bringup.md); day-to-day
operation in [`docs/runbooks/list-operations.md`](docs/runbooks/list-operations.md).

## Boundary

This repository owns GFTB demand and application declarations. A provider may
host them on any conforming cluster, but its concrete topology stays opaque to
GFTB. The owner controller's verified binding catalog is the only join between
consumer demand and provider supply.
