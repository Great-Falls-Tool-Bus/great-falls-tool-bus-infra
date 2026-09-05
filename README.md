# great-falls-tool-bus-infra

Consumer-owned infrastructure overlay for the Great-Falls-Tool-Bus GitHub
organization.

## GloriousFlywheel v4 target and current gap

The only target adoption path is one-way from released GF types and binaries
into GFTB-owned declarations. It requires no GFTB row or callback in the
producer repository:

1. the organization owns an all-repositories GF GitHub App installation;
2. this repository carries signed, immutable `OwnerInstallation/v1`,
   `TenantOverlay/v1`, and cumulative consumer `RevocationSet/v1` operands;
3. this repository carries one immutable `OwnerOverlayRevision/v1` that names
   those exact OCI artifacts;
4. application repositories carry exact ActionPlans and call the immutable
   `ci-templates` v4 entrypoint; and
5. the owner controller verifies GFTB demand, joins it to independently
   verified provider supply, and publishes the catalog consumed by the v4
   action client.

That path is not installed here yet. This tree currently carries none of the
four signed v4 instance types above and no installed controller catalog. The
remaining ARC declarations describe external state that still exists; they are
an explicit state-continuity hold until the v4 canary proves and one protected
main change retires the ARC resources and their inputs together. They are not
v4 enrollment evidence.

In the target shape, the overlay declares capabilities, policy, and
application lifecycle. It does not declare cluster endpoints, nodes, storage
classes, namespaces, worker pools, ARC scale sets, or runner labels. Those are
provider supply. GF core owns the types and controller contract, never GFTB
instances or repository rows. Provider-shaped fields retained for legacy ARC
readback must be deleted with that external state, not copied into the v4
operands.

Enrollment is fail closed. A missing App installation, signed operand,
revocation chain, owner revision, resolved binding catalog, OIDC identity, or
REAPI authority is a product defect to repair. It is not permission to use a
local build, cache-only profile, direct endpoint, producer registry, or
GitHub-hosted fallback.

This preparatory cut removes the `flywheel-cache-proof`, `flywheel-enroll`,
OIDC-profile, and local Bazel wrapper surfaces. They were v3 attachment
machinery, are not v4 evidence, and must not return.

## Architecture

Grounded diagrams for the GFTB-owned mail and network planes, plus the target
application flow, live in
[`docs/architecture/diagrams.md`](docs/architecture/diagrams.md). The GF v4
structural authority is `spec/flywheel/Core.dhall` in GloriousFlywheel; the
controller CRDs and Go types are owned by `owner-overlay-controller`. Source
presence in either upstream repository does not make the missing GFTB instance
or catalog rung live.

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

## GF v4 dispatch edge (TIN-2611, RULING 3)

Operator ruling 2026-09-05: the `gf-v4-dispatch` GitHub dispatch edge for this
organization is the consumer's own installation fact and lives here, in
[`tofu/stacks/gf-v4-dispatch/`](tofu/stacks/gf-v4-dispatch/README.md). It
consumes the GloriousFlywheel root module `arc-owner-overlay-release` at an
exact v4 role pin through eight module inputs; the namespace, scale set, label,
App Secret name, and action-resolution sink are module-derived. The governed
plan/apply lane is `.github/workflows/gf-v4-dispatch.yml` (plan on trusted
push, apply only on `workflow_dispatch action=apply` from `main` under the
protected `gf-v4-dispatch` environment). Prerequisites, credentials by name,
and the ceremony 0d ledger:
[`docs/runbooks/gf-v4-dispatch-edge.md`](docs/runbooks/gf-v4-dispatch-edge.md).
A Ready listener is dispatch capacity, not enrollment evidence; the v4 gap
described above still holds until the operand, catalog, and controller rungs
exist.

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
