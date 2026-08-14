# SPEC — GFTB convergence through the sole GF-gated owner-controller chain

> **STATUS: DRAFT, SOURCE-ONLY, HELD.** This document replaces the superseded
> shared-workflow design previously carried by this branch. It authorizes no
> workflow dispatch, credential operation, plan, apply, cluster or DNS change,
> production activation, ready-for-review transition, or merge.

- **Owning ticket:** TIN-2611
- **Source carrier:** Great-Falls-Tool-Bus/great-falls-tool-bus-infra #104
- **Controller carrier:** tinyland-inc/owner-overlay-controller #5
- **Reference executor carriers:** tinyland-inc/tinyland-infra #55 and #56
- **Binding architecture rulings:** TIN-2609 comments
  `a498b0ec-57f2-4a7a-b01b-3dc2acbdc366` and
  `adaa70dd-a6e3-4293-b1a1-71e5a7686bdf`, plus TIN-3578 comment
  `70364081-24a6-4d86-8306-c8fa4ccbc688`
- **Source-held RING-0 design inputs:** TIN-2609 proposal
  `2c50174d-ac3d-4630-b037-a6149ec0e58d` and adversarial review
  `4abd3993-10d4-4370-b869-f5635e500410`. These constrain this requirements
  carrier but do not authorize Core, CRD, workflow, or runtime implementation.
- **Executable edge audit:** TIN-2609 comment
  `e0e74eb9-44bf-4f2f-aed0-52fa78395e65`
- **Full-source control-chain reviews:**
  #104#pullrequestreview-4934324323 and
  #104#pullrequestreview-4934482235, plus the recovery/lifecycle re-review
  #104#pullrequestreview-4934718957 mirrored at TIN-2611 comment
  `181b9caf-8d65-4075-8fe9-9bee4c05c13a`, and the authoritative-finalization,
  in-flight-write, outcome-arbitration, and scheduled-readback re-review
  #104#pullrequestreview-4934871912 mirrored at TIN-2611 comment
  `a2482191-62a7-4779-bdab-a33d3e238c2e`, plus the common-fence,
  transition-order, and recovery-successor re-review
  #104#pullrequestreview-4935101115 mirrored at TIN-2611 comment
  `596d05b1-4f57-4957-bcf4-02ff0880ae22`. Their six historical, seven
  full-source, two recovery/lifecycle, four interleaving/fail-closed, and three
  final serialization/liveness findings are repaired here without releasing
  this source or any runtime carrier.
- **Enrolment/controller MVP ruling:** TIN-3768 comment
  `27a1616e-b8d8-4560-81d6-d1dbf6fe7145`, grounded by correction
  `48be6e96-86a8-470a-9db6-f175f58202b8`. Its original direct-identity/GF-Q17
  sketch is superseded by the projection structural authority in
  tinyland-inc/GloriousFlywheel protected main at exact signed merge
  `c885177118e6ee633f5c11223100271ffcab1e38` (#1500; reviewed source head
  `ef99e04fd59d31c42d044bd80061dbcf85b629bd`): a closed
  `TenantOverlay.registryPullProjection` requirement, complete pre-decision
  equality, independent post-write activation evidence, and GF-Q18. The final
  protected-main receipt is #1500#issuecomment-5290087472; the automatic
  registry-publication consequence is corrected at
  #1500#issuecomment-5290032566. Neither source adoption nor publication is
  runtime projection or activation authority. RING-0 cross-link
  `d96b78cd-368a-46d8-b961-9b29b93e1f88` proposes signed
  `OwnerInstallation/v2` and expiring `OwnerOverlayInstance/v1` coordinate
  sources plus executor-local custody; review
  `fde41451-c2ae-4213-93a7-dbeefe226241` records that this coherent shape still
  requires an explicit operator-ratification carrier before concrete
  controller/CRD/runtime work.

This is a design contract, not a second mutable status surface. Dated evidence
below is retained only where it explains a required invariant. Current
activation state must be read from the named ticket and PR carriers.

## 0. Decision

GFTB converges through the estate's existing receipt-driven, GF-gated model:

```text
reviewed site source
  -> immutable image + authenticated GF-I09 application release
  -> authenticated release-complete edge into the existing GFTB owner lane
  -> create-only immutable request generation using the shared interface
  -> GFTB owner-overlay protected materialize/check/plan for that generation
  -> owner-overlay-controller #5: typed, exact-plan Accept | Refuse
  -> GFTB consumes the exact ImagePinReplicaFlip/v1 accepted intent
  -> separate protected GFTB apply identity
  -> observe/serve/rollback
  -> immutable terminal receipts
```

The execution is edge-triggered by immutable accepted intent. Each accepted
decision digest is consumed once by the protected executor. Every original
attempt terminates in its own outcome receipt. Rollback, when an accepted prior
generation exists, is a separate accepted transaction and never substitutes for
the original attempt's outcome. There is no standing **mutation or
convergence** loop. The existing scheduled drift/readback surface is
nevertheless mandatory until an explicitly equivalent carrier replaces it: it
is authenticated, report-only, and fail-closed on absent authority, readback
error, ambiguity, or real drift from the exact latest accepted desired state and
operation marker. It carries no decision, plan, apply, or lifecycle authority.

This diagram is the required **GFTB** chain, not a claim that its initiating
edge exists. Two existing-carrier edges must not be conflated:

- GF self-dogfood uses #55's protected-main push edge and #56's bounded
  self-dogfood adapter. #55 currently GETs an already-existing request, #56
  consumes a supplied request, and #5 does not install its sample request. A
  separate create-only publisher job inside #55 remains a prerequisite for that
  Ring-0 proof only.
- GFTB adoption starts when the existing protected site producer publishes the
  immutable GF-I09 release and emits one authenticated release-complete event
  into the existing GFTB owner-lane carrier, refit in place from
  `web-stack.yml`. The event is wake-up evidence only: it binds the protected
  producer identity/run and exact GF-I09 release coordinate, carries no image,
  replica, plan, apply, or credential authority, and resolves idempotently to
  one canonical request. The current bespoke `repository_dispatch` payload and
  routine `workflow_dispatch` are not that durable event contract. The exact
  authenticated transport must be selected on the existing TIN-2609/TIN-2611
  carriers before implementation; until then the GFTB initiating edge is
  absent and activation refuses.

The GFTB plan identity invokes the same reviewed create-only publisher
interface, then the exact-name reader verifies the object on create or
`AlreadyExists` and emits UID plus generation. While exact evidence for that
server identity is absent, #5 records `MaterializationPending` only as a
non-authorizing, non-decision deferred condition and requeues the same request
generation. It creates no immutable decision or intent. Once exact evidence is
available—or bounded expiry or malformed evidence makes refusal final—#5 uses
the authoritative finalization CAS in Section 3.3 to emit exactly one immutable
final `Accept | Refuse` for that same UID/generation. A final decision is never
revised, and API-arrival order between reconcilers cannot choose its
classification. The separately protected apply job in the same GFTB owner lane
invokes only the GFTB `Justfile`/owner executor. It never invokes #56 or
transfers GFTB state to tinyland-infra. No new workflow, manual dispatch
authority, or hand-created request is admitted.

The current exact #55 (`59c603467e033652097258652ad12d2bbd730986`) and
#56 (`e57085a88cd17e9d6bf76653db301870574304c5`) heads remain incompatible
with the RING-0 union: they retain caller-authored verification/source fields
and mirrored request plan/pre-state fields that the verifier-owned design
removes. Both held heads are based on `c0544ca2`. RING-0 review verified that
protected tinyland-infra `main@1babe981` contains the short-lived
`HONEY_ARC_PLAN_TOKEN_MINTER_KUBECONFIG` TokenRequest path. Their refit must be
reconstructed from protected main, preserve that path and any successor, and
must not overwrite current-main authority or revive held #55's stored
`HONEY_ARC_PLAN_KUBECONFIG` path. Both remain held; this document does not claim
an executable edge.

The design contains:

- one decision authority: owner-overlay-controller #5;
- one closed request union with exactly one typed operand per immutable
  request: `RegistryPullProjection/v1`, `ApplicationRelease/v1`, or
  `ImagePinReplicaFlip/v1`;
- one tenant state owner: the GFTB owner overlay;
- one protected executor chain owned by that overlay;
- one immutable evidence graph binding release, decision, plan, result, served
  state, and rollback.

It contains no Flux, Argo CD, source-controller CRDs, shell/CronJob lifecycle
controller, state-owning shared apply workflow, second backend, runtime Git
clone, routine manual dispatch, or application lifecycle in GF core or Blahaj.
Immutable OCI is artifact transport only; transport never becomes lifecycle
authority.

## 1. Ownership boundary

### 1.1 GF core

GF core owns the generic typed contracts, GF-I09 release/evidence protocol,
capability and admission semantics, identity, pooled execution substrate, and
evidence doctrine. GF-I09 may authenticate immutable application and overlay
release coordinates. It does not carry credentials, Secret payloads, tenant
lifecycle, or tenant apply state.

### 1.2 Owner controller

owner-overlay-controller #5 is the sole deterministic `Accept | Refuse`
authority. It validates closed, immutable request and evidence maps; binds
policy, identity, nonce and lease; refuses unknown, incomplete, stale,
replayed, or mismatched inputs; and retains immutable decision and terminal
receipt coordinates.

One authority does not mean one generic payload. The first CRD is a closed,
extensible operand-class union. Projection, application release, and the exact
image-pin/replica-flip verb are separate variants with verifier and result
schemas; adding mail, Tofu-plan, or edge-DNS later requires a reviewed union
member, not a free-form manifest, patch, command, or runtime plugin. GFTB
consumes `ImagePinReplicaFlip/v1` for one exact `apps/v1` Deployment,
container, immutable image transition, and replica transition. Its owner
overlay remains the subordinate state, plan, apply, observe, and rollback
executor.

The no-Flux refit keeps #5 fail-closed while materialization or plan evidence
is missing. `MaterializationPending` is a controller-owned deferred observation,
not a decision variant, receipt, intent, or executor input. It carries the exact
request UID/generation, last-observed time, retry count, and bounded
materialization deadline; it authorizes nothing and may be refreshed only while
no final decision exists. The protected plan identity can therefore publish
exact evidence bound to the already-known server UID/generation, after which #5
emits the generation's one immutable final decision through the authoritative
pending-to-final CAS in Section 3.3. Evidence eligibility is the server commit
that fills the finalization record's write-once evidence slot; evidence
admission and expiry therefore contend on the same record and resource version.
Malformed classification and expiry use that common fence; a separate evidence
object timestamp, client start time, or reconciler arrival order is never
decision authority. Malformed admitted evidence refuses immediately; continued
absence refuses when the bounded request/lease deadline expires. No application
mutation is accepted merely because an image or release exists.

### 1.3 GFTB owner overlay

This repository owns GFTB application and edge plan, state, apply, rollback,
and lifecycle. It also owns the tenant-specific mapping from verified release
inputs to the exact GFTB workload. The executor must call reviewed repository
entrypoints and must not move tenant verbs into GF, Blahaj, or a shared
workflow.

Plan and apply use different identities. Production credentials are exposed
only behind the protected apply boundary. The plan identity can read and
materialize only what is required to form evidence; it cannot mutate
production.

### 1.4 Blahaj

Blahaj remains generic cluster/host admission and substrate. It may own
namespace, RBAC, route-admission, and other substrate contracts, but not the
GFTB application's release choice, apply state, rollback, or lifecycle. The
GFTB apply plane is not re-homed into Blahaj.

### 1.5 tinyland-infra #55/#56

tinyland-infra #55/#56 are the current reference for the subordinate executor
shape: digest-addressed materialization, a closed adapter, path-scoped plan,
protected apply, and immutable results. They are not a reusable GFTB workflow,
do not own GFTB state, and must not be called as a cross-tenant state backend.
GFTB implements the same interface and evidence invariants in its own owner
overlay. A GFTB accepted intent therefore never invokes #56. Their current held
heads are not compatible runtime dependencies:
#55/#56 still mirror caller-authored fields removed by the union and must be
coordinated with #5 before any activation.

### 1.6 Reusable GF product stack

GFTB and MMS are exemplary consumers of the reusable GF stack, not exceptions
to design around. Their production mail, metal, RBAC, complex-topology, and
application-stack deployment requirements are product inputs that GF's typed
contracts, controller, executor primitives, and evidence model must support.
The reusable stack must therefore be richer than an ARC-only or simple
web-Deployment path, and it must accept tenant-specific topology and
least-privilege operations without forcing those tenants into ad hoc control
planes.

Reuse does not centralize tenant state or credentials. GF supplies generic
typed protocol and reviewed executor machinery; the GFTB owner overlay
instantiates it with GFTB mappings, state, protected identities, recipes, and
rollback. TIN-2597 and TIN-2611's app-stack findings remain requirements for
that reusable machinery even though the former shared-workflow authority is
retired.

## 2. Existing GFTB path and its disposition

At the branch's 2026-08-06 baseline, the site repository's
`container-ghcr.yml` published an image and used a bespoke
`repository_dispatch` signal. This repository's `web-stack.yml` normalized
that signal with a manual input path, checked source CI, materialized a
namespace-scoped kubeconfig, and called `Justfile` validation/apply/health
recipes.

That path proved several useful tenant-specific surfaces, but it is not the
durable control plane:

- producer-side dispatch possession is not a typed controller decision;
- a skipped signal is neither success nor failure;
- source CI green is not an immutable release or apply receipt;
- the current inline digest resolution and payload are not the GF-I09
  authority;
- routine manual input is not continuous convergence;
- the same workflow currently combines policy decisions that must be split
  across plan and apply identities.

Future source work joins and refits the existing `web-stack.yml` and `Justfile`
surfaces in place. It must not add a parallel workflow, scratch controller,
state-owning shared apply module, or dual production mutation path. It may and
should consume the reusable GF typed/executor interfaces once their exact
carriers land.

The existing public operator-surface rule remains: workflows call reviewed
`Justfile` recipes; privileged mutation is not copied inline into workflow or
documentation.

## 3. Required protocol

### 3.0 Governed source edge

Before any activation, each owner adoption names one existing carrier whose
event starts the protected plan run. The initiation contract binds the exact
writer and event identities, source/ref/tree or signed-owner-input digests, the
expected request digest, reader-observed generation and UID, nonce/lease
semantics, and the corresponding protected plan run. A request publication must
reliably initiate that run without a routine manual click, runtime Git clone, or
second controller/workflow/backend.

For GF self-dogfood, that carrier is #55's protected-main push workflow; its
separate create-only publisher precedes materialization and #56 remains only its
bounded executor. For GFTB Ring 2, the existing site producer emits the
authenticated release-complete event described in Section 0 to the existing
GFTB `web-stack.yml` owner lane. That GFTB plan identity, not the site producer
and not #55, invokes the shared create-only publisher interface. The notification
is independently verified and supplies only the exact protected producer/run
and GF-I09 release coordinate. Missing, mutable, replayed, differently bound, or
payload-authoritative notifications refuse before request creation.

Ring-1 `RegistryPullProjection/v1` has a separate owner-input edge. It starts
only from the independently materialized signed owner-installation or instance
input, applicable custody identity, policy, and publication facts. It requires
no GF-I09 application/overlay release and cannot be triggered by a Ring-2 image
publication. The concrete coordinate and custody source remains held under
TIN-3768; no implementation may infer it while that hold remains.

Every publisher invocation authors exactly one immutable request containing a
common envelope and exactly one typed union member. Create-only retries stop at
canonical name plus expected digest: the exact-name plan reader, not the
publisher, verifies an existing object and supplies its UID and generation.

### 3.1 Immutable release

This subsection applies only to Ring-2 `ApplicationRelease/v1` and
`ImagePinReplicaFlip/v1` transactions. It is never a prerequisite for Ring-1
`RegistryPullProjection/v1`.

For Ring 2, the producer must publish an authenticated GF-I09 application
release that binds at least:

- source repository, exact commit, source-tree digest, and protected producer
  identity/run;
- application descriptor and payload digests;
- immutable image repository, digest, platform, and media coordinates;
- derivation, signature, provenance, and publication-receipt coordinates;
- the GFTB tenant and exact owner-overlay release/root required to install it.

A mutable tag, branch name, green workflow conclusion, or caller-authored
`verified=true` field is not release authority.

### 3.2 Operand-scoped materialization and plan evidence

The verifier selects a closed evidence schema from the request's exact union
member. Common fields bind the request digest and reader-observed UID/generation,
the union tag and full operand digest, tenant, environment, policy, controller
identity, nonce and lease epoch/expiry, pre-state fingerprint, backend identity,
verifier identity, and protected workflow run. Every mutation-capable receipt
also binds the exact monotonic cutover-latch digest and epoch plus the verifier's
observation that every legacy mutation authority applicable to that operand is
disabled. Fields belonging to another operand schema are forbidden, not
optional decoration.

For Ring-2 `ApplicationRelease/v1` and `ImagePinReplicaFlip/v1`, the GFTB plan
identity acquires declared OCI content by digest, independently checks
size/hash/media/source identity, and materializes it in a private, bounded
directory. It performs no runtime Git checkout and accepts no free-form
executable. The owner overlay supplies a closed adapter and exact path scope.
The Ring-2 extension to the common receipt binds:

- the exact GF-I09 application/overlay release digests;
- exact materialized descriptor, payload, and owner-overlay root digests;
- saved-plan artifact digest and machine-readable change summary; and
- plan identity and protected workflow run.

For Ring-1 `RegistryPullProjection/v1`, the verifier-owned evidence receipt
instead binds only the independently signed and materialized
`OwnerInstallation/v2` or `OwnerOverlayInstance/v1` input digest, the exact full
projection operand, independently observed custody identity, policy and
pre-state, and the exact `RegistryPullProjectionVerification` value/digest. A
Ring-1 receipt must not contain a GF-I09 application/overlay release, image
release, OCI descriptor or payload, owner-overlay release/root, application
saved-plan, image-pin, or replica field. The concrete owner-input and custody
shape remains source-held as stated in Section 4; this schema does not promote
it.

The request does not author `verified=true`, `planDigest`,
`preStateFingerprint`, verifier observations, or the cutover-latch observation.
Protected materialization derives and records them independently before a final
decision can accept.

A Ring-2 saved plan is immutable and single-use. Ring 1 has no application
saved-plan: its only executable authorization is the accepted full projection
operand plus the exact verifier-owned evidence. An apply must refuse if its
operand-specific evidence, pre-state, decision, nonce, lease, policy, identity,
or cutover latch no longer matches.

Prerequisite receipts form a closed, verifier-owned list before they enter the
canonical binding. Their digests are sorted and unique; every receipt belongs to
the same tenant, has an admitted predecessor operand kind and terminal-success
outcome, and names the exact prior generation when that operand requires one.
Self-reference, a dependency cycle, an unknown kind, a nonterminal receipt, or a
receipt from another tenant is a refusal.

### 3.3 Controller decision

Controller #5 validates the exact request-bound, operand-scoped evidence receipt
and emits exactly one immutable **final** closed decision per request
UID/generation:

- Ring-2 `Accept` binds the only saved plan that the apply identity may execute;
- Ring-1 `Accept` binds the exact full projection operand, its verifier-owned
  evidence, and no application saved plan; or
- `Refuse` carries a typed reason and authorizes no mutation.

Decision lifecycle is closed, linearizable, and race-independent:

1. After create/read establishes the server UID/generation, #5 creates or reads
   one canonical controller-owned finalization record. Its immutable identity
   binds the request name, UID, generation and digest; its server-authored
   `Pending` state binds the request/lease deadline and current authoritative
   resource version. Absent evidence before that deadline refreshes only the
   non-authorizing `MaterializationPending` observation and schedules a bounded
   requeue. No final decision object, immutable intent, refusal receipt, or
   nonce consumption is created.
2. The finalization record contains two initially empty, write-once slots under
   that one resource version: `admittedEvidence` and `finalDecision`. The
   protected verifier submits the canonical operand-scoped evidence envelope
   through the controller's authoritative API. The API admits it only by CAS
   from `Pending(current resourceVersion, admittedEvidence = empty,
   finalDecision = empty)` to a new `Pending` resource version whose evidence
   slot binds the request UID/generation, evidence identity/content digest, and
   server-issued admission time. That successful same-record commit is the
   **only** deadline-eligibility linearization point. Client start/finish time
   and any separately stored evidence object's creation time are not eligible-
   before-deadline authority. A separate immutable evidence object may remain
   provenance, but the finalization record references it by identity/digest and
   never uses its independent resource version as a compare key.
3. Evidence admission and expiry contend on that common record. Admission may
   fill the empty evidence slot only when its server-side CAS linearizes at or
   before the inclusive deadline. The minimally identifiable envelope is
   admitted even when its closed operand content is malformed, so malformed
   evidence cannot disappear into an absence/expiry classification. An expiry
   contender may CAS `Pending(current resourceVersion, admittedEvidence =
   empty)` to `Final(Expired)` only when authoritative server time is later than
   the deadline. If admitted evidence is present, only validation may leave
   `Pending`: the finalizer CASes that exact current resource version to
   `Final(Accept | typed Refuse)` while binding the admitted evidence payload,
   digest, and admission time.
4. The successful same-key CAS defines deterministic precedence. If evidence
   admission linearizes first at or before the deadline, every expiry CAS is
   stale and the admitted evidence is evaluated even when its response or later
   validation is delayed; complete matching evidence may `Accept`, while
   malformed, unknown, mismatched, unsafe, replayed, or policy-invalid evidence
   terminally `Refuse`s. If the evidence call is still held and unlinearized
   when a post-deadline empty-slot expiry CAS wins, the evidence CAS is stale
   and late even if its client request began before the deadline. No timestamp
   from a separately versioned object can reverse either ordering.
5. The winning final CAS installs the one canonical immutable decision payload
   in the record's write-once `finalDecision` slot. The finalization record is
   the decision object, so no second resource write can split classification
   from finalization. Its name is derived from request UID/generation. Every
   stale or later contender reads the existing final state and is non-authoring;
   pending is never unbounded.
6. Runtime activation requires proof that evidence-slot admission, empty-slot
   expiry, evidence validation, and the final slot all use this one
   authoritative key/resource version. An eventually consistent evidence read,
   a separately versioned evidence-key predicate without a transactional store,
   or an independent create-only decision write does not satisfy the contract.

A newer independent source event does not silently supersede an in-flight
accepted transaction; lease and nonce rules serialize authority. It is not a
recovery workaround for normal same-generation materialization. Every `Accept`
also binds the exact monotonic cutover-latch digest and epoch observed by its
verifier. A changed or rearmed latch makes that decision ineligible for
execution.

For GFTB, the application release and image transition remain typed operands,
not authority embedded in the tenant workflow. The accepted
`ImagePinReplicaFlip/v1` binds the exact Deployment/container, current and
desired immutable image, current and desired replicas, prior acceptance,
rollout deadline, and—when the image is private—the exact successful post-write
projection activation receipt. The GFTB executor may consume only that closed
intent.

`RegistryPullProjection/v1` remains Ring 1. `TenantOverlay` registers one closed
`NoProjection | PrivateProjection` requirement. A public-only tenant chooses
`NoProjection` and cannot activate a supplied private-projection tuple. For a
private projection, verifier-owned pre-decision evidence independently observes
the tenant and opaque credential identity, registry authority, expected input
digest, canonical target-coordinate set and count, canonical private-image
audience and count, projection policy, custody, writer scope, and pre-state. The
owner controller first requires `registryPullProjectionIsVerified`: input,
custody, writer-scope, and pre-state checks are all true and every observed key
is positive. Any failed verifier-only check emits `VerificationFailed` and
refuses before write. Only then may registration and field equality be tested;
the controller refuses unless the overlay registers that exact projection and
every verifier counterpart equals the declared operand. Exact `Accept`
authorizes only the scoped subordinate write for that full operand. It requires
neither post-write success nor a Ring-2 GF-I09
`ApplicationRelease/v1`/overlay handoff or `ImagePinReplicaFlip/v1` operand.

After the accepted write, an independent observer emits
`RegistryPullProjectionActivationEvidence` for Secret readback, activity at all
exact targets, and cold pull of the complete private-image audience. Activation
requires equality across the registered overlay, declared operand, every
pre-decision verifier observation, accepted decision operand, and independently
observed post-write operand. A later Ring-2 transaction may consume that
terminal successful activation receipt, but never becomes the projection's
prerequisite.

### 3.4 Protected apply

Only the separate operand-specific GFTB apply identity, behind the existing
protected environment, may consume an unexpired `Accept` decision. Ring 2
executes the exact saved plan. Ring 1 executes only the closed projection
operand under its exact verifier evidence and resolves opaque custody only at
the subordinate write boundary. The result records:

- environment/protection approval and apply identity;
- decision, request, operand-specific evidence or plan, pre-state, artifact,
  and cutover-latch digests/epochs;
- apply start/end, exit classification, and post-state fingerprint;
- for Ring 2, the exact workload image, operation marker, Deployment generation,
  observedGeneration, desired replicas, and ready replicas;
- for Ring 1, the exact projection operation marker and accepted projection
  operand, without Secret bytes or a GF-I09/application-plan field;
- immutable failure evidence when any step does not complete.

No source merge, controller source green, scheduled run, or manual click may
stand in for this terminal apply result.

Before mutation, the apply run atomically creates one durable attempt record
whose canonical name is deterministically derived from the request
UID/generation and accepted-decision digest. The create-only record contains the
attempt claim and its one authoritative arbitration state. It binds the full
operand-specific execution evidence (Ring-2 saved-plan digest or Ring-1
projection-verification digest), decision-derived operation marker, exact
cutover-latch digest/epoch, and the exact protected apply identity and workflow
run ID that won creation. It also binds a bounded owner lease epoch/deadline and
a closed monotonic owner phase machine: `Claimed` -> `PreWrite` -> `WriteIssued`.
The decision lease bounds the owner lease; only the exact winner may renew it or
advance phase, using compare-and-swap while the independently observed workflow
run remains active. Phase never moves backward, and an expired or independently
terminal owner can never renew or resume its lease.

The attempt also binds the exact target commit coordinates. For every existing
target mutation they include API authority, kind, namespace/name, UID, current
resource version, and controller-owned target fencing epoch. The operation
marker, next fencing epoch, and intended state change are one API-server commit
with preconditions on that UID, resource version, and prior fencing epoch; a
separate pre-write check followed by an unfenced mutation is forbidden. For a
create or multi-object step that cannot supply an equivalent target-atomic CAS,
recovery must instead prove an authoritative quiescence barrier covering every
submitted mutation before it can classify unchanged or terminal failure. Lease
expiry or workflow termination alone is not quiescence. Ring-1 initial
bootstrap additionally retains Section 4's quarantine, partial-attempt, and
idempotent-resume rules.

Authoritative-store create success is the ownership grant; the server-issued
attempt UID/generation, digest, owner lease, phase, arbitration resource version,
and target commit coordinates are independently read back. An `AlreadyExists`
contender is initially observation-only. It may not classify unchanged
pre-state, publish an outcome, or acquire recovery while the exact owner run is
active with an unexpired lease. Recovery eligibility requires all of: no
terminal outcome; independent proof that the original workflow run is terminal
**or** its bounded owner lease is expired; exact readback of the latest owner
phase; and the same decision, operation marker, target, and post-state bindings.

Owner result publication and recovery takeover use one canonical attempt
arbitration compare-and-swap; there is no separate raceable recovery-claim
object. The owner may CAS `OwnerActive(current resourceVersion)` directly to
`Final(owner)` only after target-commit readback. An eligible recovery contender
may CAS that exact same `OwnerActive(current resourceVersion)` to
`RecoveryFencing`, binding original owner/run, last owner phase and lease,
termination or expiry proof, recovery identity/run, a new recovery fencing
epoch, and a bounded recovery lease/deadline. `RecoveryFencing` has a closed
monotonic phase machine—`Acquired` -> `TargetsFencing` -> `ReadbackBound` ->
`Finalizing`—and a per-target fence/readback journal. Exactly one transition can
win. A losing or later contender remains observation-only while that exact
recovery run is independently active with an unexpired lease. Recovery
acquisition permanently removes the original owner's result-publication and
future-write authority. This CAS is the atomic recovery-finalization ownership
grant required by the prior repair.

Immediately before its one mutation, the original winner must CAS the attempt
to `WriteIssued` and freshly prove all of the following: its owner lease remains
unexpired; its exact identity/run and arbitration/fencing epochs still own the
attempt; the arbitration state is `OwnerActive`; the cutover-latch digest/epoch
is unchanged; the executable legacy paths consume the latch fail-closed; and
every legacy authority remains disabled. It then submits only the target-atomic
UID/resource-version/fencing-epoch commit defined above. A pause, expiry,
owner-run termination, recovery takeover, phase mismatch, missing readback,
rearmed path, latch change, target replacement, or target resource-version/
fence change denies that commit.

After recovery wins arbitration, it never executes the saved plan or projection
write. For every unresolved `WriteIssued` target, it must first advance the
target fencing epoch by an API-server CAS against the exact target UID, resource
version, and owner epoch, or establish the proved quiescence barrier required
above. The owner's already-submitted mutation and the recovery fence therefore
serialize at the target commit: if the owner commit wins, recovery observes and
classifies that committed state; if the recovery fence wins, the delayed owner
commit fails its stale resource-version/fence precondition. Recovery may not
publish unchanged or failed state until all targets are fenced or proven
quiescent and then freshly read. An admitted but delayed owner request can never
commit after a recovery failure.

Recovery ownership cannot wedge the attempt. Only the exact recovery owner may
renew its bounded lease or advance its phase/journal, by CAS while its workflow
run is independently active. If that run is independently terminal or its lease
expires, a successor may CAS the same `RecoveryFencing(current resourceVersion)`
to `RecoveryFencing` at the next recovery epoch. The successor transition binds
the predecessor identity/run, lease, terminal-or-expiry proof, last phase,
durable target journal as stored, successor identity/run, and a fresh bounded
lease. A predecessor renewal/final CAS and a successor-acquisition CAS contend
on the same arbitration resource version: if `Final` wins, the successor only
reads the outcome; if the successor wins, every predecessor CAS is stale. The
transition never returns arbitration to `OwnerActive`, never revives owner write
authority, and grants only read/fence/finalize authority—never saved-plan,
projection, or desired-state mutation authority.

The successor resumes idempotently from authoritative target state, not from a
predecessor's local memory. A target fence committed before a crash but absent
from the journal is rediscovered through UID/resource-version/fencing-epoch
readback; an uncommitted fence is safely retried by CAS. Each successor may only
advance fencing epochs and recovery phases. A crash immediately after recovery
acquisition, between any two target fences, after fence commit but before
journal CAS, after readback binding, or before final CAS therefore leaves a
bounded successor path. Under an eventually available protected recovery run
and authoritative API, one successor reaches the existing sole final slot; no
successor executes a second apply or creates a second outcome.

There is one canonical immutable `AttemptOutcome` name and one empty terminal
slot in the attempt record. The same authoritative arbitration CAS that changes
`OwnerActive` to `Final(owner)`, or later changes `RecoveryFencing` to
`Final(recovery)`, installs that slot's create-only outcome payload and digest
in the same record; no second resource write can split arbitration from outcome
publication. Owner publication racing recovery takeover uses the same current
arbitration resource version, so exactly one wins; no path may publish a second
outcome. For Ring 2 the outcome includes target UID/resource version/fencing
epoch, Deployment generation, image, replicas, and post-state. Ring 1 uses
independently observed projection readback without recovering Secret bytes.
Exact desired state with the decision-derived marker yields success. Exact
unchanged pre-state or ambiguous/partial state yields immutable terminal failure
only after target fencing/quiescence, and fences further mutation until a fresh
accepted rollback or forward transaction. Recovery is result publication, not
a second apply authority. The canonical `AttemptOutcome` digest is the sole
terminal outcome and rollback operand.

### 3.5 Observe, serve, and rollback

An apply result is not a served result. The terminal chain separately records:

- controller-observed result evidence;
- cluster readback with `observedGeneration >= generation` and desired replicas
  greater than zero;
- the registry's independent view of the immutable digest;
- credentialed served-content evidence through the real protected origin;
- the source revision/build marker observed in served content.

Rollback is a distinct accepted transaction and may follow only an exact
accepted transaction whose immutable terminal result is classified failure. It
binds that failed request UID/generation, decision and attempt-record digests,
plus the sole canonical create-only `AttemptOutcome` digest; a retained prior
accepted release; fresh post-failure pre-state; a new saved rollback plan; the
current cutover-latch digest/epoch; fresh nonce/lease; and an externally
observed served result. A successful, noncanonical, conflicting, or merely
missing result cannot be its failed-result operand. Reusing a pre-failure plan
or merely reselecting an old image is not a rollback receipt.

Attempt, refusal, outcome, served, and rollback receipts are append-only. Every
original attempt ends in a terminal outcome receipt, including when a separate
rollback transaction is accepted afterward. A terminal failure is evidence; it
is never converted to green by skipping downstream jobs or by recording only
the rollback outcome.

## 4. Pull-credential projection

TIN-3768 comment `27a1616e-b8d8-4560-81d6-d1dbf6fe7145` ratifies Secret
projection as the controller's first `Accept`-consuming apply, keeps Core
opaque, and requires GF self-dogfood first. Correction
`48be6e96-86a8-470a-9db6-f175f58202b8` proves that the originally named
coordinate sources do not exist. The original direct-identity/projection-Q17
sketch is superseded by GF #1500 protected-main
`c885177118e6ee633f5c11223100271ffcab1e38` (reviewed source
`ef99e04fd59d31c42d044bd80061dbcf85b629bd`). TIN-3768 proposal
`d96b78cd-368a-46d8-b961-9b29b93e1f88` supplies a coherent replacement, but
review `fde41451-c2ae-4213-93a7-dbeefe226241` explicitly keeps that coordinate
and custody shape pending operator ratification. This GFTB spec records the
requirements and the hold; it does not promote the proposal, instantiate
concrete coordinates, or add another registry, writer, decision authority, or
projection protocol.

The upstream typed source contract is:

- `Core.dhall` stays opaque: `TenantOverlay.registryPullProjection` is the
  closed `NoProjection | PrivateProjection RegistryPullProjection/v1`
  requirement. Public-only tenants carry no decorative pull identity;
- a private `RegistryPullProjection/v1` binds tenant and Option-E credential
  identities, registry authority, expected input digest, canonical target-set
  digest/count, canonical private-image-audience digest/count, and projection
  policy digest;
- verifier-owned `RegistryPullProjectionVerification` independently observes
  every declared field plus input, custody, writer-scope, and pre-state checks;
- `RegistryPullProjectionDecision` first requires all verifier-only input,
  custody, writer-scope, and pre-state checks to be true; otherwise it emits
  `VerificationFailed`. It then refuses unless the overlay registers the exact
  projection and every verifier counterpart equals the declared operand.
  Exact `Accept` carries that full operand and is the immutable authorization
  for the scoped subordinate write, independent from GF-I09 and post-write
  success;
- independent post-write `RegistryPullProjectionActivationEvidence` binds
  Secret readback, all-target activity, and private-audience cold pull to the
  same full operand. Activation rechecks overlay registration, verification,
  decision, and observed-operand equality;
- controller Go owns a closed authority type rather than payload bytes or an
  unstructured command;
- projection is Ring 1 and the first accepted apply, with GF self-dogfood before
  MMS or GFTB activation; and
- GF-Q18 is the sole mutable projection-status question. GF-Q17 remains the
  runner resource-envelope question and is not a projection carrier. Source
  green is not runtime projection evidence.

The source-held concrete-coordinate proposal, which must be explicitly ratified
or superseded before controller/CRD/runtime implementation, is:

- stable targets come from a signed protected-main tenant-owner
  `OwnerInstallation/v2`, independently materialized as projection input rather
  than supplied by a Ring-2 GF-I09 handoff. It binds the exact namespace and
  cluster authority, Secret object identity, private-image audience,
  writer-scope/quota source digests, and the projection operand's opaque
  credential identity key;
- preview targets come from a signed, expiring `OwnerOverlayInstance/v1`
  produced by the same owner's protected instance-admission lane. It binds one
  namespace and instance, exact source repository/ref/SHA/event, expiry and
  lease, writer-scope/quota digests, and its parent `OwnerInstallation/v2`
  descriptor; and
- neither source is inferred from a PR number, namespace glob or label,
  `runner_class`, `tfvars_anchor`, the RBE consumer/spoke/org registries, or
  `tofu_plan_secret_read_namespaces`.

The source-held custody interpretation in TIN-2609
`330f52cd-bb6b-4eae-a39d-bf2f43a93125` and TIN-3768 `d96b78cd...` must likewise
be ratified or superseded. Under that proposal, only the protected subordinate
executor resolves opaque custody and sends dockerconfigjson bytes directly to
the Kubernetes API. The bytes never enter Git, OCI, the CRD, controller
memory/state, ConfigMaps, status, logs, plans, intents, results, or receipts.
The controller sees only opaque identity/generation keys; the pre-decision
verifier and independent post-write observer own their respective
non-recoverable observations.

Already-ruled operational boundaries remain:

- `converge-agent` is public and needs no carrier pull Secret; controller and
  `gf-reapi-cell` remain private on the existing infra projection path;
- a GFTB application image follows its declared visibility; a private image
  requires accepted projection evidence, while a public image does not
  fabricate that dependency;
- no interim cluster-admin workflow or second apply authority is admitted; and
- the protected subordinate executor may act only on the exact accepted
  projection under scoped, short-lived authority.

Before the projection protocol is implementable, RING-0 review
`4abd3993-10d4-4370-b869-f5635e500410` requires the owning carrier to close two
non-atomic proof cases:

1. **Initial bootstrap:** namespace, quota, RBAC, Secret, and pull proof are a
   multi-object transaction with no honest rollback to absence. A partial first
   attempt fails closed into quarantine, emits an append-only partial-attempt
   receipt, and resumes idempotently from the same exact artifacts. Standing
   Namespace delete remains forbidden. Projection rollback applies only when an
   accepted prior credential generation exists.
2. **Cold pull:** Kubernetes has no pull-only Pod API. Proof must prevent tenant
   image code from executing, for example through a ratified verified-absent,
   nonce-derived command plus strict Pod sandbox and observation of successful
   pull before the expected create failure, or through another ratified scoped
   independent observer. A normal cold Pod start is application execution and
   does not count as projection proof.

Rotation may revoke an old generation only after a non-executing cold-pull proof
covers every accepted private digest in every exact target. #1500's typed law is
landed on protected main, but until the coordinate and custody design is
ratified, that law is consumed by a scoped executor, initial-bootstrap
quarantine/resume is proved, and rollback plus independent post-write readback
and non-executing cold-pull controls pass, the GF `docs/current-state.md` GF-Q18
answer remains `No` and a private-image GFTB activation must refuse. GF-Q17
continues to report runner resource-envelope evidence only.

## 5. Acceptance oracle

One release `S` is accepted as converged only when independently sourced
evidence proves all of the following:

| ID | Required fact | Independent source |
|---|---|---|
| O1 | `S` is the reviewed protected source revision | site repository |
| O2 | GF-I09 binds `S` to immutable image/release coordinates | protected producer receipt |
| O3 | materialization and saved plan bind the exact release and pre-state | GFTB plan receipt |
| O4 | #5 accepted that exact plan under current policy/identity/nonce/lease | controller decision receipt |
| O5 | the protected apply identity executed that exact saved plan once and the sole attempt-arbitration finalization produced the canonical successful `AttemptOutcome`, or the current recovery epoch owner (initial or successor) recovered that committed target state after proven owner termination/expiry and target fencing/quiescence; any terminal failure keeps O5 false for that request/generation | attempt/arbitration CAS, recovery lease/phase, target UID/resource-version/fence commit, and sole canonical `AttemptOutcome` |
| O6 | the registry independently serves the bound image digest | authenticated registry read |
| O7 | live state carries the operation marker and caught-up generation with replicas greater than zero | cluster readback |
| O8 | the protected served origin returns content built from `S` | credentialed served-content probe |

The mandatory scheduled readback is a separate release gate, not a ninth
mutation or decision authority. For each environment it derives one
`LatestAcceptedDesired` view only from the controller's append-only accepted-
decision order. That view binds the exact request UID/generation, decision and
full desired-operand digests, decision-derived operation marker, and canonical
outcome digest when present; it never derives desired state from repository
HEAD, a mutable tag, workflow input, or the live object it is checking. Missing
or ambiguous accepted desired state fails closed. Before `S` can be declared
accepted as converged, a fresh authenticated scheduled invocation must select
`S`'s accepted desired state and marker and report exact live readback. An
accepted but not yet applied transaction may therefore make the scheduled run
red; that is drift evidence and never authority to apply it.

The oracle must preserve these known failure lessons:

1. **Constant `/health` is liveness, not served-content proof.** The current
   endpoint can stay as a readiness probe, but it cannot satisfy O8.
2. **Digest equality is insufficient.** Reproducible builds can produce the
   same image digest for a content-neutral commit. O7 therefore requires an
   accepted operation marker and generation readback; O8 binds the served
   revision independently.
3. **Skipped is not success.** A positive O2 receipt must exist. Absence of a
   red job proves nothing.
4. **Old readiness is not new readiness.** Readiness is sampled only after
   observedGeneration catches generation.
5. **Zero of zero is not healthy.** Desired replicas must be greater than zero.
6. **Payload echo is not corroboration.** Registry, cluster, and served probes
   cannot use the request payload as their truth source.
7. **Terminal is not synonymous with successful.** An apply or recovery result
   classified failure remains failed forever and cannot satisfy O5 after later
   cluster or served observations. Only a fresh accepted transaction can
   produce a new outcome.

Before the first production acceptance, mutation-proven negative controls must
show the chain refuses or fails on:

- unknown/mutable release coordinates and a bad digest;
- stale, expired, or replayed nonce/lease;
- absent materialization evidence: it must create a non-authorizing pending
  condition and **no final decision**, then later exact evidence must create
  exactly one final decision for the same request UID/generation;
- malformed evidence or bounded pending expiry: each must create exactly one
  terminal `Refuse`, and late evidence must not create or revise a decision;
- simultaneous evidence admission and expiry on the common finalization-record
  resource version, including both held-call orders: (a) an evidence call begun
  before but still unlinearized after the deadline loses to a winning empty-slot
  expiry CAS, and (b) an evidence-slot CAS linearized by the deadline but whose
  response/validation is held makes the expiry CAS stale and must be evaluated;
  malformed admitted evidence yields typed refusal rather than absence;
- changed pre-state or a mismatched saved plan;
- absent or operand-mismatched post-write projection activation evidence when
  private-image projection is required;
- failure to publish/read back the attempt claim before mutation, and a crash
  after mutation but before result publication; retry must not reapply and the
  independent observer must recover a terminal result;
- duplicate atomic claim creation, where exactly one protected run wins and an
  `AlreadyExists` contender cannot finalize recovery while that owner run is
  merely slow but active with an unexpired lease;
- owner termination/lease expiry with concurrent recovery contenders: exactly
  one initial attempt-arbitration recovery CAS wins and every other contender
  remains read-only while that recovery lease is active; after independently
  proven termination/expiry exactly one successor CAS may win the next epoch;
  a late-resuming original owner must fail the arbitration and target
  UID/resource-version/fencing-epoch checks before mutation;
- an owner mutation admitted at `WriteIssued` but delayed across recovery
  takeover: the owner target commit and recovery target-fence CAS must
  serialize, and no owner write may commit after recovery publishes terminal
  unchanged/failure state;
- owner result publication concurrent with recovery acquisition: both contend
  on the same attempt-arbitration resource version, exactly one reaches
  `Final`, and exactly one canonical create-only `AttemptOutcome` exists as the
  sole rollback operand;
- recovery-owner crashes immediately after `RecoveryFencing` acquisition,
  between every target-fence operation, after a fence commit but before journal
  publication, after readback binding, and immediately before finalization: an
  independently proven terminal/expired recovery lease must permit exactly one
  successor CAS, monotonic fence/journal recovery, one eventual canonical
  outcome, and no saved-plan/projection/desired-state re-execution;
- either legacy mutation path remaining armed when governed apply is enabled,
  or its cutover latch changing/rearming after plan or decision but before the
  fresh pre-write read;
- a recovered terminal failure followed by otherwise-positive live observations;
  O5 and the full oracle must remain false for that generation;
- apply failure and served-content mismatch;
- rollback evidence that does not bind the failed result and fresh pre-state;
- scheduled drift/readback with absent authentication, readback/API error, or
  real drift from the exact `LatestAcceptedDesired` state/operation marker: each
  must fail the scheduled run while emitting no decision, intent, plan, apply,
  or mutation.

Each control is restored and the same oracle must then return green. A check
whose red path has not been observed is not acceptance evidence.

## 6. In-place transition

The transition never runs two production mutation authorities.

1. **Close typed prerequisites.** Land the no-Flux refit on #5, the protected
   three-member operand union, the create-only publisher inside #55, compatible
   #55/#56 verifier/executor interfaces, the GFTB GF-I09 producer plus its
   authenticated release-complete edge into the existing GFTB owner lane, the
   GFTB-owned executor interface, and the operator-ratified TIN-3768
   coordinate/custody shape. Reconstruct #55/#56 from current protected source
   while preserving the short-lived TokenRequest path; do not revive the held
   static plan kubeconfig. Source green is not runtime acceptance.
2. **Refit tests and contracts in place.** Extend existing validation families
   with fixtures for release, plan, decision, terminal result, replay, refusal,
   lost-result recovery, served-content, and rollback. The decision lifecycle
   fixtures must prove pending creates no final object, exact later evidence
   creates one final decision on the same generation, malformed/expired paths
   create one immutable refusal, and evidence/deadline contenders use the same
   record/resource version in both held-call orders. Recovery interleavings must
   prove a slow live owner excludes recovery; owner outcome publication and
   recovery takeover serialize on one arbitration resource version; a delayed
   already-admitted owner write cannot commit after recovery failure; crashes at
   every `RecoveryFencing` boundary admit a monotonic read/fence/finalize-only
   successor; and exactly one canonical `AttemptOutcome` exists. The existing
   scheduled readback family must also prove absent authentication, readback
   error, and actual drift from the exact latest accepted desired state/marker
   are red while every mutation surface is absent. Every new validator names
   its claim and retirement trigger in the same change.
3. **Plan-only rehearsal.** Run the exact GFTB path with mutation disabled;
   independently verify materialization, pre-state, saved plan, controller
   refusal/acceptance semantics, and receipts. While either legacy path remains
   armed, the live decision must refuse; acceptance may be exercised only in a
   non-authoritative contract fixture. This is not a shadow controller or
   second workflow.
4. **Fence legacy mutation authority.** Before the first governed write, a
   protected, append-only monotonic cutover-latch receipt disables the existing
   `repository_dispatch` apply and routine manual mutation path. Both old paths
   consume that latch and fail closed while it is set; the governed executor
   refuses while either old path remains armed. Every pre-latch plan or decision
   is stale and must be regenerated with the new latch digest/epoch before the
   canary. The disabled source may remain for comparison until parity, but it
   has no credential or mutation authority.
5. **Refit and prove live scheduled readback before canary.** Before the first
   governed GFTB write, refit the existing `k8s-stack-drift.yml` carrier in
   place to use protected short-lived authentication and the exact
   `LatestAcceptedDesired` selection described in Section 5. Remove its current
   skip-on-absent-credential and `fail_on_drift=false` behavior. Through that
   actual scheduled carrier, prove missing authentication, API/readback error,
   and a bounded real-drift fixture each fail red while no decision, intent,
   plan, apply, or mutation is emitted. If no governed accepted desired state
   exists before the first canary, `NoAcceptedDesired` is itself fail-closed;
   neither that expected red state nor a fixture is convergence evidence. This
   source refit and live negative proof must complete before step 6.
6. **Governed successful canary.** After the self-dogfood and MMS prerequisite
   proofs, execute one accepted GFTB transaction through the protected identity.
   Its accepted decision advances `LatestAcceptedDesired` to that exact full
   desired operand and decision-derived operation marker before apply, so drift
   remains visibly red until convergence. After its successful canonical
   outcome, a fresh authenticated invocation of the already-refit scheduled
   carrier must select and read back those exact values before O1-O8 can be
   declared green. Retain this exact accepted release as the rollback target.
7. **Create one exact failed transaction.** Execute a distinct, accepted,
   mutation-proven canary transaction using a separately reviewed bounded
   post-write failure fixture from the validation family in step 2. It must end
   in its own immutable terminal failure, and its request UID/generation,
   decision, attempt record, post-failure pre-state, and sole canonical
   `AttemptOutcome` digest are captured as the only failed-transaction operand
   for rollback; the fresh rollback inputs in Section 3.5 remain mandatory.
   Expected failure is evidence, never a converged acceptance.
8. **Rollback proof.** Consume exactly the failed transaction from step 7 and
   externally observe the retained successful release from step 6 through a
   fresh accepted rollback transaction. The governed rollback is the only
   enabled rollback mutation path.
9. **Reconverge.** Execute a fresh forward transaction and require O1-O8 plus a
   fresh scheduled readback of its exact accepted desired state/operation marker;
   neither the failed result nor rollback result is rewritten or reused.
10. **Retire the bespoke authority.** Only after parity, exact failed-transaction
   rollback, and reconvergence evidence,
   remove producer `repository_dispatch`, bespoke signal credentials and
   payload, routine manual apply, inline digest-resolution authority, and any
   duplicate policy gates.
11. **Continue scheduled observational enforcement.** The carrier refit and
   negative proof already completed in step 5 remain mandatory and recurring.
   Every run reads the current exact `LatestAcceptedDesired` state/operation
   marker, fails closed on missing authority, readback error, ambiguity, or
   drift, and never substitutes for edge-triggered attempt/outcome/served
   receipts. It may retire only in the same change that activates an explicitly
   named equivalent scheduled carrier with the same latest-accepted binding,
   authentication, fail-closed, report-only, and zero-mutation contract.

## 7. Existing surfaces and retirement triggers

| Existing surface | Disposition | Retirement trigger |
|---|---|---|
| site `container-ghcr.yml` publish logic | retain build/publication, make GF-I09 the release authority | authenticated GFTB GF-I09 producer proof |
| producer `signal-cd` / `repository_dispatch` | fence before the first governed mutation; remove after parity | cutover receipt proves old path disabled before canary; one governed successful transaction, one exact terminal failed transaction, its bound rollback, and reconvergence have immutable receipts |
| infra `web-stack.yml` | refit in place as the GFTB protected executor; do not clone it | accepted controller/executor contract and protected runtime proof |
| manual `workflow_dispatch` steady-state apply | fence before the first governed mutation; retire as product mechanism | governed rollback is exercised and externally observed |
| `Justfile` workload validation/apply entrypoints | retain as GFTB-owned verbs, split by plan/apply authority as needed | replaced only by a separately ratified GFTB owner-overlay interface |
| `/health` probe | retain for liveness only | never promoted to served-content oracle |
| `k8s-stack-drift.yml` | refit and prove before first governed canary; retain as mandatory authenticated, report-only, fail-closed scheduled readback of exact `LatestAcceptedDesired` state/operation marker; never a convergence loop or mutation trigger | replace only in the same change by an explicitly named equivalent scheduled carrier with the same latest-accepted binding that fails on absent authority, readback error, ambiguity, and real drift and retains zero mutation/decision authority |
| this spec | retire into an operator runbook and durable interface docs | #104's design is implemented, production/rollback receipts are accepted, and no mutable status remains here |

Removing a superseded surface and its false documentation happens in the same
change that activates its replacement. No cleanup is deferred after the old
claim becomes false.

## 8. Release gates

The following are gates, not workarounds:

- owner-overlay-controller #5 must have a landed and adjudicated no-Flux
  source refit, governed installation, and live refusal/acceptance receipts;
- GF Ring-0 self-dogfood must have the protected exact-request publisher/event
  contract identified by `e0e74eb9-44bf-4f2f-aed0-52fa78395e65`, implemented
  as a separate create-only job inside #55. It exports canonical name and
  expected digest only; the exact-name reader verifies the object and emits UID
  plus generation. #55/#56 do not currently create or advance the request. This
  publisher placement is Ring-0-only and is not the GFTB initiating edge;
- tinyland-infra #55/#56 are held self-dogfood reference carriers whose current
  heads are incompatible with the RING-0 union, not deployed GFTB execution
  authority. Any refit must preserve protected main's
  `HONEY_ARC_PLAN_TOKEN_MINTER_KUBECONFIG` TokenRequest acquisition and must not
  revive the stored `HONEY_ARC_PLAN_KUBECONFIG` path;
- GFTB does not yet have the authenticated GF-I09 producer, authenticated
  release-complete event contract into its existing owner lane, closed
  owner-overlay adapter, or GFTB-owned protected executor described here. It
  never invokes #56 for GFTB state;
- GF #1500 protected-main `c885177118e6ee633f5c11223100271ffcab1e38` is the
  final typed authority for the closed overlay requirement, pre-decision
  verification/Accept boundary, post-write activation evidence, and GF-Q18.
  Its exact reviewed source is `ef99e04f`; the
  terminal merge-group/fresh-main carrier is
  #1500#issuecomment-5290087472. Automatic registry publication is recorded by
  #1500#issuecomment-5290032566 and is not deployment or runtime proof. Its
  concrete path must be joined by
  an explicit operator carrier for the proposed signed
  `OwnerInstallation/v2` / expiring `OwnerOverlayInstance/v1` coordinates and
  executor-local custody. Initial-bootstrap quarantine/resume and non-executing
  cold-pull proof must land on the GF/controller carriers rather than being
  reimplemented here;
- protected plan/apply identities; one common-record resource-version fence for
  same-generation evidence admission versus expiry/finalization; atomic
  create-only run-bound attempt ownership; bounded owner lease/phase; one
  owner-publication/recovery arbitration CAS; target-commit-atomic
  UID/resource-version/fencing epochs or proved quiescence; bounded recovery
  lease/phase and read/fence/finalize-only successor CAS; one canonical
  create-only `AttemptOutcome`; single-use lost-result recovery; and terminal
  GFTB receipt publication require reviewed source and runtime proof;
- a protected monotonic cutover-latch receipt must bind through plan, decision,
  attempt record, and fresh pre-write observation and prove both legacy mutation
  paths fail closed before governed canary or rollback can consume an accepted
  decision;
- a credentialed served-content probe is required; constant `/health` cannot
  substitute;
- the existing scheduled drift/readback must be authenticated, report-only,
  bind the exact latest accepted desired state/operation marker, and fail closed
  on absent authority, readback/API error, ambiguity, and real desired/live
  drift while carrying zero mutation or decision authority; its in-place refit
  and live negative proof precede the first governed canary, and it may retire
  only with an explicitly equivalent scheduled carrier;
- refusal, replay/expiry, failure isolation, rollback, and self-dogfood/MMS/GFTB
  canary order remain acceptance gates.

Do not resolve a blocker by adding Flux/Argo, a state-owning shared apply
workflow, a shell/CronJob controller, runtime Git, hosted fallback, a second
backend, cluster-admin projection, a manual production path, or a tenant
lifecycle owner outside this repository. Do not use that fence to discard
GFTB's full-stack requirements from the reusable GF product.

## 9. References

- TIN-2611 — GFTB CD convergence through the sole GF-gated
  owner-controller chain
- TIN-2609 — governed owner-overlay controller consuming GF-I09
- TIN-2609 `adaa70dd-a6e3-4293-b1a1-71e5a7686bdf` — one decision authority,
  three typed MVP operand classes
- TIN-2609 `2c50174d-ac3d-4630-b037-a6149ec0e58d` — RING-0 operand union,
  verifier, replay, receipt, and existing-workflow publisher proposal
- TIN-2609 `4abd3993-10d4-4370-b869-f5635e500410` — RING-0 adversarial review:
  publisher retry, bootstrap, cold pull, ordering, TokenRequest, and receipt
  constraints
- TIN-3578 — executable GF-gated production-convergence contract
- TIN-3768 — first-class pull-credential projection
- tinyland-inc/GloriousFlywheel #1500 protected-main
  `c885177118e6ee633f5c11223100271ffcab1e38` — GF-Q18 typed projection law:
  closed overlay requirement, pre-decision authorization, and independent
  post-write activation evidence; reviewed source `ef99e04f`, exact-head clean
  review #1500#pullrequestreview-4934195522, protected-main terminal carrier
  #1500#issuecomment-5290087472, and publication-truth correction
  #1500#issuecomment-5290032566
- TIN-3768 `d96b78cd-368a-46d8-b961-9b29b93e1f88` — source-held opaque-custody
  and signed stable/preview coordinate proposal
- TIN-3768 `fde41451-c2ae-4213-93a7-dbeefe226241` — explicit ratification hold
  and projection safety cross-link
- TIN-3270 — privileged dispatch/credential trust boundary
- TIN-3457 — mutation-proven assertions
- Great-Falls-Tool-Bus/great-falls-tool-bus-infra #104 — this held source unit
- tinyland-inc/owner-overlay-controller #5 — sole decision controller
- tinyland-inc/tinyland-infra #55/#56 — reference protected executor/adapter
- tinyland-inc/GloriousFlywheel #1482 — held GF-I09 proof/publication seam
