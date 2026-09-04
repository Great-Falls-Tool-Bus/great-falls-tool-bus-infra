# GFTB v4 demand operands (TIN-2611)

These files are the consumer-owned inputs for Great-Falls-Tool-Bus v4 demand.
They are not canonical payloads, published artifacts, enrollment evidence, or
runtime state. The unresolved values deliberately make the complete assembly
invalid, so no component may publish or consume it yet.

The executable wire is the `gf-operand-publisher` implementation added to
GloriousFlywheel protected main by `bbc7e4cdb8258590b244e9ece5c3a2c40ceaf97f`.
Its `assembly` command validates all three inputs together, requires
`OwnerInstallation/v1` to bind the exact canonical `TenantOverlay/v1` payload
digest, and emits GF-authored manifest, descriptor, and reference bytes. This
repository does not copy that codec or wrap it in a local workflow or script.

## Consumer boundary

- `tenant-overlay.json` declares only organization-wide abstract demand.
- `owner-installation.json` binds one all-repositories product App
  installation to the exact overlay digest.
- `revocation-set.json` is the cumulative consumer revocation authority.
- Application repositories own their exact ActionPlans. The current GFTB site
  plan establishes `rbe-linux-x86_64`; it does not establish an organization
  concurrency or invocation policy.
- Provider endpoints, nodes, namespaces, storage, workers, ARC identities, and
  placement are not consumer inputs and never belong here.

All three future artifacts use one tag-free, lower-case OCI repository derived
from this source repository:

```text
source:     Great-Falls-Tool-Bus/great-falls-tool-bus-infra
lower-case: great-falls-tool-bus/great-falls-tool-bus-infra
artifact:   oci://ghcr.io/great-falls-tool-bus/great-falls-tool-bus-infra/gf-owner-demand
```

The same repository is passed once to GF `assembly`; operand kind is carried
by the exact GF artifact and payload media types, not by three ad-hoc package
names.

## Values already grounded in source

- `ownerId` is GitHub organization id `297983955`.
- `generation` is `1`; no earlier GFTB v4 demand operand exists.
- `allRepositories` is `true`, the only admitted v4 installation selection.
- capability `rbe-linux-x86_64` is present in the GFTB site's checked-in
  `.github/lanes.json` on protected main.
- `trustedWorkflows` names the immutable reusable workflow actually invoked by
  GFTB site CI:
  `tinyland-inc/ci-templates/.github/workflows/spoke-ci-v4.yml@32e39ced0008edf4564ebeb173a5e8fbf069e28f`.
- only trusted `refs/heads/main` pushes may deposit an ActionCache entry. Pull
  requests may execute and read but never receive ActionCache write authority.
- the current public GFTB site image needs no private registry projection.

## Unresolved authority

The following values remain `<TO-FILL: ...>` because no source-derived value
or ratified carrier exists:

| File | Field | Required authority |
| --- | --- | --- |
| `tenant-overlay.json` | `authorizationPolicyDigest` | exact canonical GFTB authorization policy |
| `tenant-overlay.json` | `capabilityPolicies[0].maxConcurrentActions` | ratified consumer demand bound |
| `tenant-overlay.json` | all `subjectPolicy` members | ratified organization invocation policy |
| `owner-installation.json` | `installationId` | installed GFTB product App, never ARC installation `143981297` |
| `owner-installation.json` | `tenantOverlayDigest` | GF canonical payload digest after every overlay policy value is final |
| `revocation-set.json` | `scope.installationId` | same product App installation |
| `revocation-set.json` | `activeSetRootAuthorityDigest` | ratified publication signer authority |
| `revocation-set.json` | `issuedAtEpochSeconds` | actual genesis publication time |

No publisher identity is inferred from a filename, repository token, or
planned workflow. The signer must publish GF assembly's exact config, layer,
and manifest bytes, prove the registry descriptor equals `manifest.digest`,
produce the required Cosign Bundle-v0.3 evidence bound to the exact source
tree, and verify the package remains private before any reference is eligible.
There is currently no released, image-custodied operand-publication carrier
that does all of those things, so the missing path is a product gap rather
than permission to add a bespoke workflow here.

## Owner controller input

No `RevocationSetRevision` object exists in the released controller schema; it
was fictitious and is removed. OOC #19 currently carries a draft
`OwnerOverlayRevision/v1` schema that names the three exact GF-generated
artifact references. Because #19 is not protected main and no references
exist, this repository intentionally carries no `OwnerOverlayRevision`
instance yet. The whole controller input remains unavailable rather than
inventing reference bytes or a CRD.

There is no local, hosted-runner, cache-only, direct-endpoint, registry-row,
callback, or v3 fallback. Missing App, policy, publication authority,
references, or released controller schema is a refusal to repair.
