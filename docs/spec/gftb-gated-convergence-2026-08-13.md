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
| `tinyland-inc/owner-overlay-controller` | Bazel/BCR consumer with a non-nil, byte-preserving GF-I09 verifier and read-only admission path |
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

The admission consumer must:

1. read the independently authored evidence with uncached/read-only API access;
2. bind the evidence object to the exact request UID, generation, and operand
   digest;
3. reject deleting, owned, finalized, mutable, stale, replayed, or mismatched
   evidence;
4. construct the two publication observations from verifier-owned digests;
5. call upstream `VerifyReleaseHandoff` with all three exact byte documents;
6. bind the verified tenant, source, commit/tree, media types, payload and
   descriptor digests, runtime image, overlay root, and policy fields; and
7. derive `installationDigest` only from
   `Verified.Application.RuntimeImage.ResultImageDigest`.

An OCI locator in a request is not verification evidence. If the canonical GF
wire lacks a required repository-coordinate proof, GF must version the wire;
the overlay and controller must not add a local extension.

## 4. Protected decision-to-execution chain

The only admitted phase-2 flow is:

```text
protected application main -> exact ApplicationRelease publication
protected overlay main     -> exact OverlayBundle publication
independent verifier       -> immutable ReleaseVerification evidence
read-only controller       -> one final Accept | Refuse
durable non-authorizing wake -> protected saved-plan producer
subordinate executor       -> exact saved-plan bytes, no replan
independent observer       -> live/readback/served/rollback evidence
immutable receipt          -> one terminal outcome
```

A wake contains identity only. It carries no operand bytes, command, plan,
credential, or mutation authority. It must survive process loss and
redelivery, and it cannot acknowledge away the sole due generation before an
exact attempt handoff or a terminal pre-mutation outcome exists. Push,
`repository_dispatch`, routine `workflow_dispatch`, runtime Git clone, a
manual apply, or an attended side channel is not this carrier.

The saved plan binds the exact accepted application, overlay, verification,
policy, desired-state tree, pre-state, target, runner/workflow identity, and
expiry. Apply consumes the admitted bytes without rendering or planning again.
Every compare, lease, expiry, recovery, and finalization transition uses
server-enforced identity/time and same-record version arbitration.

The chain must prove:

- exactly one decision, planner, executor, observer, and production mutator;
- immutable attempt identity and exactly one canonical terminal outcome;
- bounded retry and at most one bounded recovery successor;
- no late result can overwrite a final decision or outcome;
- failure before mutation is not rollback-eligible;
- failure after a committed mutation is fenced and either recovered or
  reversed by an independently admitted rollback operand;
- drift self-heal consumes the same protected declaration path, never a second
  controller or local script;
- freeze/kill prevents new admission, preserves readback, and cannot strand an
  unfenced target; and
- liveness fails when protected main advances without a bounded terminal
  production receipt.

Generic retry, recovery, freeze, self-heal, executor, observer, liveness, and
receipt semantics belong in their upstream packages and conformance tests.
This overlay may only bind and prove them.

## 5. GFTB instance surface

The eventual overlay change may add only the GFTB instance material needed to
bind the upstream chain:

- exact released GF/BCR, ci-templates, controller, and image digests;
- exact application and overlay publication repositories and certificate/OIDC
  identities;
- protected environments and least-privilege service accounts;
- immutable typed object instances and writer-separated RBAC;
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

## 6. One-mutator activation

Activation is one reviewed protected-main change that simultaneously:

1. proves every upstream released pin and hostile-mutation/conformance receipt;
2. installs the typed CRDs, digest-pinned controller, and separated RBAC;
3. declares exactly one GFTB binding and exact workload target;
4. arms the permanent carrier;
5. proves the generation-40 bootstrap bridge is deleted/disabled;
6. proves legacy manual, dispatch, and attended workload mutation identities,
   queued work, credentials, and recreation paths are absent or fenced;
7. proves one carrier and one mutator before the first admitted write; and
8. emits independent liveness/readback evidence.

No interval may have zero admission fencing or two production mutators.
Historical `web-stack.yml` dispatch and `web-image-published` paths remain
retired. The spent generation-40 bridge remains retired and cannot become a
rollback or later-generation path.

## 7. Acceptance and launch boundary

Phase 2 is not active until protected evidence proves all of the following:

- exact application and overlay bytes were independently published, signed,
  reread, and verified;
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

Cloudflare Access remains unchanged until every TIN-2421 and TIN-4203 criterion
also passes: naming consent, mail/list smoke, reviewer path, pre-flip sweep,
signed edge declaration, dev/preview preservation, protected main-to-production
edge execution, public external served SHA/digest proof, QR/phone and
no-JS/keyboard/reduced-motion/contact checks, artifact receipt, and rollback
digest. This spec alone never authorizes the flip.

ADR 0022 excludes the member runtime, database/migrations, worker, mail/list,
payments, DNS, Tunnel, registrar, and every unnamed workload. They require
their own ratified bindings and cannot ride this static-web carrier.

## 8. Ordered implementation and holds

1. Land and release the canonical GF verification contract as a signed,
   immutable Bazel/BCR version.
2. Land owner-overlay-controller repo-contract/Bazel/production-image
   foundation, then pin that released GF target and lock.
3. Land the application and overlay publishers plus independent verifier in
   ci-templates with exact-head hostile-mutation proof and a ratified runner
   isolation contract.
4. Replace the held controller ConfigMap prototype with the immutable typed
   byte-preserving, read-only verifier; keep runtime installation held.
5. Land reusable planner/executor/observer/retry/freeze/liveness contracts and
   conformance tests in their owning upstream SSOTs.
6. Refit this PR once onto current signed infra main with only the GFTB binding,
   pins, identities, probes, and receipt requirements.
7. Land the protected one-mutator activation and prove the full acceptance
   matrix before any Access change.

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

