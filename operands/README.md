# GFTB v4 demand operands (TIN-2611)

**Nothing in this directory is live.** These are the authored, unpublished
inputs for the three consumer-owned GloriousFlywheel v4 operands, plus the
carrier that will publish them. Every file carries `<TO-FILL: …>` or
`<derived: …>` placeholders that block publication by design, and the
publisher refuses to run until the three operator ceremonies below have
replaced them. Until then there is no signed operand, no reference, no
revocation head, and no enrollment evidence here.

Wire authority: `services/gf-reapi-cell/pkg/operand` in
`tinyland-inc/GloriousFlywheel` at `8d428cb83015205ec8e26354e9f9baf479b9a81b`
(the `GF_CORE_REF` pinned by the publisher workflow). Decoding is closed:
unknown fields, noncanonical bytes, and a string where the wire expects a
number are refused. That is what makes a placeholder block landing.

## Files

| Path | What it is |
| --- | --- |
| `tenant-overlay.json` | Authored `TenantOverlay/v1` payload: organization-wide abstract demand only (`capabilityPolicies`, `subjectPolicy`, `trustedWorkflows`, `writerPolicy`, `registryPullProjection`, `authorizationPolicyDigest`, `generation`). No repository rows, no runner labels, no endpoints, no placement. |
| `owner-installation.json` | Authored `OwnerInstallation/v1` fields: `ownerId` (297983955, the Great-Falls-Tool-Bus organization id), `installationId`, `allRepositories`, `generation`. The wire's `tenantOverlayDigest` is **derived** at publication (see order below) and is deliberately not authored here. |
| `revocation-set.json` | Authored genesis consumer `RevocationSet/v1`: consumer scope, generation 1, `predecessor.kind: genesis`, floors `{ownerInstallation: 1, tenantOverlay: 1, providerCapability: 0}`, empty revocation lists, the active root authority digest, and `issuedAtEpochSeconds`. |
| `references/` | Absent until the first publication. `operand-references-pr.yml` writes `tenant-overlay.reference.json`, `owner-installation.reference.json`, `revocation-set.reference.json` (the three `ArtifactReference` JSONs) and `publication.json` (the run receipt) here through a bounded pull request. |
| `../k8s/gf/revocation-set-revision.yaml` | The `RevocationSetRevision` declaration that will name the published revocation-set artifact. OOC #19 currently ships no `RevocationSetRevision` CRD (AMEND pending on TIN-2609); nothing applies it. |
| `../.github/workflows/publish-operands.yml` | The publisher. Its identity at `refs/heads/main` is the O-2 signer authority. |
| `../.github/workflows/operand-references-pr.yml` | The commit-back. Opens the reference pull request; never touches main, an operand, or a registry. |

The `TenantOverlay/v1` payload carries no `schema_version` field: the closed
wire has none, and "schema 3" is the ActionPlan/v4 `.github/lanes.json`
grammar that application repositories check in, not an overlay field.

## What is deliberately absent

- No provider placement anywhere: no node, storage, namespace, worker pool,
  ARC scale set, runner label, or endpoint literal. A consumer asks for
  `rbe-linux-x86_64`; it never names a cluster.
- `config/organization.yaml` is a legacy ARC runner-group roster. The roster
  ban forbids reading it into any operand; the publisher does not open it.
- No v3 registry path. `flywheel-enroll`, `flywheel-enroll-verify`,
  `scripts/flywheel-enroll-verify.sh`, and the producer-side
  `config/consumer-registry.json` they read were deleted from this tree in
  #104 (`07cc49e9`); GloriousFlywheel deleted the registry validator in #1739.
  None of it returns as a Justfile recipe, script, or doc line.
- No local canonicalizer, shape validator, fallback signer, or interim
  bridge. The GloriousFlywheel publisher is the only validator, and its
  absence is a refusal, not a substitution.

## Publication order and digest binding

`publish-operands.yml` runs on a push to `main` that changes one of the three
authored inputs (and only then; a README or reference change never
republishes). It:

1. checks out this repository at the exact pushed revision and refuses unless
   the ref is `refs/heads/main`;
2. refuses if any `<TO-FILL:` / `<derived:` placeholder remains in the three
   inputs (before any registry write);
3. checks out GloriousFlywheel at `GF_CORE_REF` with the read-only deploy key
   (`docs/ci-credentials.md`) and refuses unless
   `services/gf-reapi-cell/cmd/gf-operand-publisher` exists there;
4. canonicalizes, in order, `TenantOverlay/v1`, then `OwnerInstallation/v1`
   with `tenantOverlayDigest` bound to the SHA-256 of the canonical
   tenant-overlay payload bytes (the controller compares exactly that:
   `pkg/operand/catalog.go`, `ownerPayload.TenantOverlayDigest !=
   overlay.payloadDigest`), then the consumer `RevocationSet/v1`;
5. pushes each canonical payload with `oras` as one OCI manifest with one
   layer to `oci://ghcr.io/great-falls-tool-bus/gf-{tenant-overlay,
   owner-installation,revocation-set}` by digest, with no operand tag,
   recomputes the manifest digest from the exported manifest bytes, and
   confirms it resolves;
6. signs each manifest keyless with `cosign` under the workflow's GitHub OIDC
   identity and immediately verifies the signature against the exact O-2
   identity and issuer;
7. emits the three `ArtifactReference` JSONs with the publisher and uploads
   them, with `publication.json`, as the `gftb-operand-references` run
   artifact.

The only tags left in those repositories are the `sha256-<digest>.sig` tags
cosign uses to attach signatures; the operands themselves are never tagged
and a reference never carries one.

## The publisher identity (ceremony O-2)

```text
certificateIdentity  https://github.com/Great-Falls-Tool-Bus/great-falls-tool-bus-infra/.github/workflows/publish-operands.yml@refs/heads/main
oidcIssuer           https://token.actions.githubusercontent.com
sourceRepository     Great-Falls-Tool-Bus/great-falls-tool-bus-infra
```

`activeSetRootAuthorityDigest` is the SHA-256 over that three-field tuple in
GF Canonical JSON v1 (`MarshalCanonicalVerificationAuthorityIdentity`:
lexicographic keys, no whitespace, printable ASCII, one trailing LF). Computed
from the tuple above it is
`sha256:04096c0fdf94e56930234eab40380acf2b2697ae993cfc0ecfffc7602089e752`.
That value is an expectation, not a fill: O-2 recomputes it independently and
ratifies it before writing it into `revocation-set.json`.

## Operator ceremonies

Nothing here is live until all three have run and their outputs are merged.

| Ceremony | Output | Fills |
| --- | --- | --- |
| **O-1 — App installation** | The product GloriousFlywheel GitHub App installed on Great-Falls-Tool-Bus with all-repositories scope, and its installation id. It is **never** the ARC registration App `143981297`. | `owner-installation.json` `installationId`; `revocation-set.json` `scope.installationId`; `k8s/gf/revocation-set-revision.yaml` `spec.scope.installationId` and the derived `metadata.name`. |
| **O-2 — Publisher identity and root digest** | Ratification of the identity tuple above, the recomputed `activeSetRootAuthorityDigest`, the 40-hex `main` commit that carries `publish-operands.yml`, and the genesis issue time. | `revocation-set.json` `activeSetRootAuthorityDigest` and `issuedAtEpochSeconds`; `tenant-overlay.json` `trustedWorkflows[0].jobWorkflowRef` (`…@<40-hex>`) and `jobWorkflowSha`. |
| **O-3 — Authorization policy digest** | The SHA-256 of the ratified organization authorization policy. | `tenant-overlay.json` `authorizationPolicyDigest`. |

Complete TO-FILL index:

| File | Field | Ceremony |
| --- | --- | --- |
| `operands/owner-installation.json` | `installationId` | O-1 |
| `operands/revocation-set.json` | `scope.installationId` | O-1 |
| `operands/revocation-set.json` | `activeSetRootAuthorityDigest` | O-2 |
| `operands/revocation-set.json` | `issuedAtEpochSeconds` | O-2 |
| `operands/tenant-overlay.json` | `trustedWorkflows[0].jobWorkflowRef` | O-2 |
| `operands/tenant-overlay.json` | `trustedWorkflows[0].jobWorkflowSha` | O-2 |
| `operands/tenant-overlay.json` | `authorizationPolicyDigest` | O-3 |
| `k8s/gf/revocation-set-revision.yaml` | `metadata.name` (derived) | O-1 |
| `k8s/gf/revocation-set-revision.yaml` | `spec.scope.installationId` | O-1 |
| `k8s/gf/revocation-set-revision.yaml` | `spec.artifact.manifestDigest`, `payload.digest`, `payload.size` | after the first publication, from `references/revocation-set.reference.json` |

`trustedWorkflows` names reusable-workflow identities that invocations may
present. The single placeholder entry binds the O-2 publisher workflow at an
exact commit so the list is non-empty and sorted; which reusable invocation
edge GFTB ultimately trusts is an O-2 ruling, recorded there.

## The GloriousFlywheel publisher this carrier consumes

`gf-operand-publisher` has not landed on GloriousFlywheel `main` at the pinned
revision. The workflow references it at its expected path and refuses when it
is absent. The interface this carrier consumes is:

```text
gf-operand-publisher canonicalize --kind TenantOverlay/v1 \
    --input <authored.json> --output <canonical-payload.json>
gf-operand-publisher canonicalize --kind OwnerInstallation/v1 \
    --input <authored.json> --tenant-overlay-payload <canonical-tenant-overlay.json> \
    --output <canonical-payload.json>
gf-operand-publisher canonicalize --kind RevocationSet/v1 \
    --input <authored.json> --output <canonical-payload.json>
gf-operand-publisher reference --kind <Kind> --repository oci://<registry>/<repo> \
    --manifest-digest sha256:<64-hex> --payload <canonical-payload.json> \
    --output <reference.json>
```

`canonicalize` validates the closed payload with the product `Validate`
rules, refuses placeholders and unknown fields, and writes GF Canonical JSON
v1 bytes. `reference` emits one canonical `ArtifactReference` after validating
the repository, digests, media types, and the 1..1048576-byte payload bound.
Neither subcommand publishes, signs, or fetches. When the command lands,
advance `GF_CORE_REF` in `publish-operands.yml` and the matching pin in
`scripts/validate-core-checkout.py` in one reviewed change.

## After a publication

`operand-references-pr.yml` opens `operands/references-<sha12>` from the exact
published revision with one GitHub-signed commit carrying the four files
under `references/`, and a pull request against `main`. Review it against the
run summary and the registry: every `manifestDigest` must resolve at
`ghcr.io/great-falls-tool-bus/gf-<operand>` and every signature must verify
against the O-2 identity. A pull request opened with the repository token
does not start `validate.yml`; push to the branch or close and reopen it to
run the required check before merging.

Copying the revocation-set reference into `k8s/gf/revocation-set-revision.yaml`
is a separate operator change. Submitting that object waits for the CRD.
