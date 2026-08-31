# SPEC — GFTB public microsite GF-I09 binding

> **STATUS: DRAFT, SOURCE-ONLY, HELD.** This is the GFTB overlay's phase-2
> requirements carrier for TIN-2611. It authorizes no ready-for-review
> transition, merge, workflow activation, publication, credential or secret
> operation, plan/apply, controller installation, cluster or edge mutation,
> production claim, or Cloudflare Access change.

- **Owning ticket:** TIN-2611
- **Source carrier:** Great-Falls-Tool-Bus/great-falls-tool-bus-infra #104
- **Decision authority:** Great-Falls-Tool-Bus/meta ADR 0022 and its
  role-assignment amendment carrier, Meta #46
- **Scope:** only the public `gftb-site` static web
  `greatfallstoolbus-org-production/Deployment/greatfallstoolbus-org`
- **Apply/state owner:** this repository remains the sole GFTB overlay and
  credential plane; reusable mechanics remain upstream
- **Launch gates:** TIN-2421 and TIN-4203

This file is an adoption contract, not a second implementation or mutable
status ledger. Current heads, checks, receipts, and blockers belong on the
named PRs and Linear tickets.

## 1. Authority and SSOT

GFTB consumes one versioned upstream chain:

| Authority | Required upstream result |
| --- | --- |
| `tinyland-inc/GloriousFlywheel` | Released GF-I09 `ApplicationRelease`, `OverlayBundle`, `ReleaseVerification`, and `VerifyReleaseHandoff` contract through Bazel/BCR |
| `tinyland-inc/ci-templates` | Versioned, protected publisher, independent verifier, planner, exact-plan executor, observer, readback, and receipt workflow surfaces |
| `tinyland-inc/owner-overlay-controller` | Bazel/BCR admission consumer of verifier-authored canonical bytes, invoking the pinned GF `VerifyReleaseHandoff` through a read-only path |
| `tinyland-inc/site.scaffold` | One-carrier, main-to-production, freeze, and liveness doctrine/tests |
| `Great-Falls-Tool-Bus/meta` | Workload scope, role selection, exceptions, and activation ruling |
| this repository | GFTB binding, exact pins, desired state, protected identities, state, probes, and receipts |

The overlay must pin immutable released versions and digests. It must not use a
Git archive, npm package, local override, floating workflow ref, branch ref,
mutable image tag, runtime repository clone, or GFTB-local copy of upstream
mechanics. In-house package consumption is Bazel/BCR only.

The controller cannot consume the GF library through native Go module
resolution. Before controller adoption, its own repository must land the
Tinyland repo contract, Bazel/Bzlmod graph, registry order, lockfile, registered
checks, and Bazel-built production image. Its GF dependency is the immutable
BCR module and public target, never an npm, Git, archive, or local override.

## 2. Fixed role and identity split

Meta ADR 0022 Amendment 1 fixes these non-interchangeable roles:

| Role | Fixed caller/owner | Positive authority |
| --- | --- | --- |
| Application publisher | protected canonical `main` of `Great-Falls-Tool-Bus/gftb-site`, using a versioned ci-templates publisher | publish and sign the exact Bazel/BCR-produced `ApplicationRelease`; record registry-observed payload and descriptor digests |
| Overlay publisher | protected canonical `main` of this repository, using a separate versioned ci-templates publisher | publish and sign the exact Bazel/BCR-produced `OverlayBundle`; record registry-observed payload and descriptor digests |
| Independent verifier/evidence writer | protected verification environment in this overlay, using a third identity and versioned ci-templates verifier | resolve both signed publications, verify canonical bytes and observed digests, emit immutable GF `ReleaseVerification` evidence |
| Admission consumer | `tinyland-inc/owner-overlay-controller` | read immutable evidence and call the pinned GF/BCR `VerifyReleaseHandoff` implementation |
| Planner | protected GFTB overlay identity | materialize one accepted binding and emit one immutable, run-bound saved plan |
| Executor | subordinate protected GFTB overlay identity | consume exactly the admitted saved-plan bytes once, without replanning |
| Observer | separate read-only GFTB overlay identity | independently observe live state, served state, drift, and rollback facts |

The application publisher cannot publish the overlay. Neither publisher may
write verification evidence. The verifier cannot publish, decide, plan, apply,
install, mutate, observe its own result, or author request/status state. The
controller cannot publish, synthesize evidence, write verification objects, or
apply. The planner, executor, and observer identities are mutually distinct.

Runner placement is a separate implementation proof. The exact workflow
version, OIDC subject, environment, permissions, and runner-group admission
must be recorded in the binding; assignment to a person or agent grants none of
those runtime capabilities.

## 3. Exact immutable handoff

The controller admission input preserves three canonical documents as exact
bytes:

1. the published `ApplicationRelease` payload;
2. the published `OverlayBundle` payload; and
3. independently authored `ReleaseVerification` evidence.

The upstream typed evidence carrier must be immutable and byte-preserving. A
request-derived ConfigMap, typed projection that discards canonical bytes,
publisher-authored verification, controller-authored verification, or
GFTB-local evidence schema is refused.

Before GFTB may bind this path, owner-overlay-controller must release a
byte-preserving evidence-consumer API/seam whose input includes, or is durably
associated by its owning upstream contract with, the exact request UID,
generation, and operand digest. The current operand-only
`ApplicationReleaseVerifier` seam and request-derived ConfigMap prototype do
not satisfy this prerequisite. GFTB must not supply an adapter or local schema
to fill that gap.

Through that released read-only admission surface, the consumer must:

1. consume the independently authored verification and both exact published
   payloads without discarding their canonical bytes;
2. refuse absent, mutable, stale, replayed, mismatched, or incompletely bound
   evidence under the upstream carrier's contract;
3. construct the two GF `ReleasePublication` observations only from the
   verifier-authored payload and descriptor digests;
4. call upstream `VerifyReleaseHandoff` with all three exact byte documents;
5. bind the verified tenant, source, commit/tree, media types, payload and
   descriptor digests, runtime image, overlay root, and policy fields; and
6. after successful pinned `VerifyReleaseHandoff`, require
   `ApplicationReleaseOperand.InstallationDigest` to equal both
   `verified.Application.RuntimeImage.ResultImageDigest` and
   `verified.Verification.ApplicationReferences.RuntimeResultImageDigest`;
   any mismatch refuses.

An OCI locator in a request is not verification evidence. If the canonical GF
wire or controller seam lacks a required proof, its owning upstream package
must version the contract; the overlay must not add a local extension.

## 4. Protected decision-to-execution chain

The only admitted phase-2 flow is:

```text
protected application main -> exact ApplicationRelease publication
protected overlay main     -> exact OverlayBundle publication
independent verifier       -> immutable ReleaseVerification evidence
read-only admission consumer -> one final Accept | typed Refuse
protected owner coordinator -> consume the accepted decision/nonce once and emit an immutable saved plan
subordinate executor       -> exact saved-plan bytes, no replan
independent observer       -> live/readback/served/rollback evidence
immutable receipt          -> one terminal outcome
```

The decision handoff, retry, recovery, fencing, and receipt transport must come
from released GF, controller, ci-templates, and site.scaffold contracts. This
overlay does not name or implement a wake, queue, redelivery, acknowledgement,
lease-arbitration, or recovery-successor protocol. Push,
`repository_dispatch`, routine `workflow_dispatch`, runtime Git clone, a
manual apply, or an attended side channel is not the permanent carrier.

The saved plan binds the exact accepted application, overlay, verification,
policy, desired-state tree, pre-state, target, runner/workflow identity, and
expiry. Apply consumes those admitted bytes without rendering or planning
again.

The chain must prove these upstream-defined outcomes:

- one canonical production decision per admitted generation, one production
  mutator, and separated planner, executor, and observer authorities;
- immutable release and attempt identities with one canonical terminal outcome;
- bounded retry and recovery without duplicate mutation;
- no late result can overwrite a final decision or outcome;
- failure before mutation is not rollback-eligible;
- a committed mutation failure is fenced, and rollback is an ordinary accepted
  release of the prior immutable artifact through the same protected chain;
- drift self-heal consumes the same protected declaration path, never a second
  controller or local script;
- freeze/kill prevents new admission, preserves readback, and cannot strand an
  unfenced target; and
- liveness fails when protected main advances without a bounded terminal
  production receipt.

Generic retry, recovery, freeze, self-heal, executor, observer, liveness, and
receipt semantics belong in their upstream packages and conformance tests.
This overlay may only bind released versions and prove their outcomes.

## 5. GFTB instance surface

The eventual overlay change may add only the GFTB instance material needed to
bind the upstream chain:

- exact released GF/BCR, ci-templates, controller, and image digests;
- exact application and overlay publication repositories and certificate/OIDC
  identities;
- protected environments and least-privilege service accounts;
- upstream-defined immutable byte-preserving evidence instances and writer-separated access controls;
- workload target, namespace, container, image, replica, policy, and probe
  bindings;
- protected backend/state and exact saved-plan retention;
- anonymous Access-interception proof while Access remains, credentialed
  source-marker readback, independent cluster readback, and external served
  proof after an authorized public flip;
- prior immutable operand and rollback binding; and
- structured release artifacts and concise Linear proof links.

It must not add a second workflow family, generic controller logic, cluster
credentials to a source repo, source-CI apply authority, Cloudflare credentials,
a second state owner, or secret values.

## 6. Inert installation and one-mutator activation

Installation and activation are separate reviewed protected-main changes.
Before activation, the released controller API definitions, digest-pinned
controller image, and separated read/write authorities must already be
installed inert and observed healthy. Installation admits no GFTB binding,
enables no production mutator, and preserves explicit upstream-defined
disabled/unarmed state.

The later activation change:

1. proves every upstream released pin and hostile-mutation/conformance receipt;
2. proves the installed controller/API and separated authorities are healthy,
   inert, and identical to the reviewed pins;
3. declares exactly one GFTB binding and exact workload target;
4. changes only the reviewed binding and upstream-defined enable/arm state
   needed to make the permanent carrier sole;
5. proves the generation-40 bootstrap bridge is deleted/disabled;
6. proves legacy manual, dispatch, and attended workload mutation identities,
   queued work, credentials, and recreation paths are absent or fenced;
7. proves one carrier and one mutator before the first admitted write; and
8. emits independent liveness/readback evidence.

Admission remains fenced throughout the cutover, and no interval has two
production mutators. Historical `web-stack.yml` dispatch and
`web-image-published` paths remain retired. The spent generation-40 bridge
remains retired and cannot become a rollback or later-generation path.

## 7. Acceptance and launch boundary

Phase 2 is not active until protected evidence proves all of the following:

- the two fixed publisher identities separately published and signed the exact
  application and overlay bytes, and the third identity independently reread
  and verified both publications;
- the controller consumed a non-nil verifier and accepted the exact handoff;
- the saved-plan producer and subordinate executor used identical admitted
  bytes;
- the independent observer bound the live workload and served source to the
  accepted release;
- induced drift self-healed through the sole carrier within the bounded SLO;
- forced process loss exercised bounded retry/recovery without duplicate
  mutation;
- freeze/kill refused new admission while retaining safe readback;
- protected main advance produced one bounded terminal receipt;
- the prior immutable operand and reviewed rollback declaration are known; and
- the bridge and every legacy workload mutator are absent.

Cloudflare Access remains unchanged. TIN-2421 and TIN-4203 are the authoritative
launch checklists; this file does not replace or narrow any current row. Every
row must pass, including Wave-3 prose/design sign-off; the exact publish-set
naming-consent sweep; mail receiving/list smoke; the consented reviewer path;
the pre-flip name, OG-image, and SEO sweep; a signed reviewed edge carrier that
drops only `web_apex`, `web_www`, and `web_apex_allow` while proving
dev/preview unchanged; separately ratified protected main-to-production edge
execution; external public apex and health proof with the exact served source
SHA and release digest; QR/phone plus no-JS, keyboard, reduced-motion, and
contact-path checks; the structured artifact and concise proof links required
by TIN-4203, TIN-3816, and TIN-2664; and the confirmed rollback digest. This
spec alone never authorizes the flip.

ADR 0022 excludes the member runtime, database/migrations, worker, mail/list,
payments, DNS, Tunnel, registrar, and every unnamed workload. They require
their own ratified bindings and cannot ride this static-web carrier.

## 8. Ordered implementation and holds

1. Land Meta #46 on protected Meta `main`; until then its role assignment is
   not adoption authority.
2. Land and release the canonical GF verification contract as a signed,
   immutable Bazel/BCR version.
3. Land owner-overlay-controller repo-contract/Bazel/production-image
   foundation, then pin that released GF target and lock.
4. Land the application and overlay publishers plus independent verifier in
   ci-templates with exact-head hostile-mutation proof and a ratified runner
   isolation contract.
5. Replace the held controller ConfigMap prototype and operand-only seam with
   the released upstream-owned immutable, byte-preserving, read-only admission
   surface; keep runtime installation held.
6. Land reusable planner/executor/observer/retry/freeze/liveness contracts and
   conformance tests in their owning upstream SSOTs.
7. Refit this PR once onto current signed infra main with only the GFTB binding,
   pins, identities, probes, and receipt requirements.
8. Install the released controller/API and separated authorities inert in a
   distinct reviewed change, then prove that installation healthy.
9. Land the later protected one-mutator bind/arm activation and prove the full
   acceptance matrix before any Access change.

Current explicit holds:

- this PR remains draft/source-only until the upstream carriers exist and a new
  exact-head review releases it;
- Meta #46 must land before its role amendment is treated as Meta-main
  authority;
- ci-templates #154 remains draft until its A/B runner-isolation choice and
  CT-01 proof are ratified;
- owner-overlay-controller #15 remains HOLD and must be superseded, not merged
  as a ConfigMap evidence path;
- GF source without a signed immutable release and BCR entry is not a
  consumable dependency;
- no source merge or publication is a production or served receipt.

## References

- TIN-2611 — sole GF-gated GFTB convergence carrier
- TIN-2421 / TIN-4203 — public Access exit and day-of served proof
- Great-Falls-Tool-Bus/meta ADR 0022 and Meta #46
- tinyland-inc/GloriousFlywheel #1690
- tinyland-inc/ci-templates #154
- tinyland-inc/owner-overlay-controller #15
- tinyland-inc/site.scaffold #160
- Great-Falls-Tool-Bus/great-falls-tool-bus-infra #104 — this held source unit

