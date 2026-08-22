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
  `596d05b1-4f57-4957-bcf4-02ff0880ae22`, plus the legacy-quiescence,
  recovery-wake, served-failure, and operand-set re-review
  #104#pullrequestreview-4935297697 mirrored at TIN-2611 comment
  `6ce50ecc-30a5-44ff-b889-b3e0109e5f9d`. Their six historical, seven
  full-source, two recovery/lifecycle, four interleaving/fail-closed, three
  final serialization/liveness, and four final cutover/observation findings
  are repaired here without releasing this source or any runtime carrier.
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
error, ambiguity, or real drift from the complete operand-keyed set of active
accepted desired state and operation markers. It carries no decision, plan,
apply, or lifecycle authority.

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
- one immutable evidence graph binding release, decision, plan, mutation and
  convergence results, served state, and rollback.

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
also binds the exact monotonic cutover-latch digest and epoch, the exact
`LegacyAdmissionFence/v1` UID/epoch and stage-current server-issued compare
resource version, the immutable digests of the closed legacy authority set and
governed identity allow set, the enforcement mode and per-target token-map
digest, and the verifier's
observation that every legacy mutation authority applicable to that operand is
disabled. Fields belonging to another operand schema are forbidden, not
optional decoration.

Mutation-capable evidence does not trust a legacy run to observe a source-side
latch. It binds one protected, append-only `LegacyAuthorityQuiesced/v1` cutover
receipt for the environment and operand scope. That receipt becomes final only
after repository-side legacy trigger admission is frozen, an authoritative
workflow and Environment enumeration across **every** ref and workflow revision
reports zero queued, waiting, pending-approval, or in-progress mutation-capable
runs, every credential or authorization already issued to those runs is server-
side revoked or independently expired, and an authoritative API-server
quiescence barrier reports zero in-flight mutations by the legacy identities
after ordering every pre-fence admitted request as committed or rejected. Fresh
target readback follows that barrier. The receipt binds the frozen workflow/
trigger revisions, enumeration cursor and run IDs, credential/authorization
generations and revocation-or-expiry evidence, quiescence-barrier/admission-fence
identity, and fresh target UID/resource-version/fencing epochs. Cancelling a
run, editing only the latest workflow revision, observing an empty per-ref
concurrency group, or asking an old client to read the latch is not quiescence.
If any issued legacy authority or already-admitted write cannot be enumerated
and fenced, the receipt cannot finalize and governed mutation refuses.

The quiescence receipt is not merely a historical observation. Before it may
finalize, the protected cutover operation installs and reads back one persistent
server-side `LegacyAdmissionFence/v1` for the exact environment, operand target
scope, and closed legacy identity set. That set binds the repository, workflow,
and ref claims, Environment and service-account subjects, credential issuers and
generations, allowed API authorities/verbs, and every target coordinate formerly
reachable by either legacy path. The API server rejects every request carrying
one of those legacy identities regardless of client workflow revision, token
refresh, or latch awareness. Mutation in the fenced target scope is
deny-by-default except for the exact governed identities bound into the fence.

The `Enforced` authority/target set, governed-identity allow set, enforcement
mode, and target-token mapping are immutable. No caller, including the protected
cutover identity, may add or remove an issuer, subject, grant, target, verb,
credential generation, governed writer, or target token while that fence is
`Enforced`; such a request is refused server-side without changing its epoch or
digests. The current fence remains `Enforced` for the complete lifetime of the
governed mutation lane, including after step 10 removes the legacy mutation
authorities, queued work, credentials, and paths. There is no standalone
`Enforced` -> `Retired` transition and no `Disabled`, `Rearmed`, or
mutable-enforced state. The protected cutover identity may supersede the current
fence only through one authoritative transaction or target-local CAS that
atomically installs and reads back an equivalent or stricter successor in
`Enforced` state over the same complete target scope. The successor must retain
or strengthen the old fence's legacy-identity, issuer, grant, verb, and target
deny coverage and may not broaden its governed-identity allow set. It must expose
the same `LegacyAdmissionFence/v1` admission contract so every future plan,
decision, attempt, and target commit binds the one current enforced instance.
The old record becomes historical `Superseded` evidence only as the successor
becomes current. Every committed state has exactly one current `Enforced` fence
over the complete governed target scope; no observation may see an unfenced
target. Every plan, decision, or attempt bound to the old UID, epoch, mode,
digests, token, or resource-version lineage is stale if that handoff wins.

Fence enforcement must choose and record one of two closed authoritative modes.
In `Transactional`, the fence row stores the immutable server-written
target-token map. The mutation request carries the exact opaque server-issued
token as a transaction precondition; the server compares it with the current
row's token, UID, epoch, `Enforced` state, immutable digests, and resource
version. One serializable store transaction takes the required read/write
conflict against that row while committing the target mutation; an atomic
successor-fence handoff writes that same current-fence authority and therefore
contends.
`TargetLocal` is available only when the complete fenced target scope is one
target or server-controlled aggregate target object under one UID and resource
version. The protected cutover installs the fence UID/epoch, both immutable set
digests, enforcement mode, `Enforced` state, and one server-written token in that
same object. The token, fence UID, and enforced epoch are write-once while
`Enforced`. Each governed or recovery request must carry that exact opaque
server-issued token plus the current server-issued object resource version, and
the API server must compare both against the co-located authoritative fields in
the **same** target CAS. A successful governed mutation or recovery fence
preserves the token, fence UID/epoch, immutable digests, mode, and `Enforced`
state while advancing the target fields, target fencing epoch, and object
resource version. That returned resource version is the next authoritative
lineage value recorded by the attempt/readback journal; the original resource
version is a one-transition compare precondition, not an immutable token alias.
An atomic successor-fence handoff CASes the latest value in that same lineage,
installs the successor's complete immutable `Enforced` tuple and new
server-issued token, and retains the old tuple and token as historical evidence.
The receipt maps every covered target coordinate to that sole current token and
initial resource version. A scope requiring independent per-target CASes,
including an N-step successor handoff, must use `Transactional` mode or refuse;
partial target-local activation, replacement, or retirement is forbidden.

Token carriage is required but never self-authenticating authority. A caller-
invented token, boolean such as `fenceVerified=true`, stale or unissued resource
version, webhook observation, cached admission read, or client assertion that is
not compared with the authoritative token/state/epoch/resource version in the
recorded transaction or co-located CAS is forbidden. A separate pre-write check
does not qualify.
If neither mode is available
for every target—including create coordinates and multi-object steps—governed
mutation refuses; quiescence alone is not a substitute for this commit fence.

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
cutover latch, or exact enforced legacy-admission fence mode, immutable digests,
and target token no longer match.

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
   that one resource version—`admittedEvidence` and `finalDecision`—plus a
   controller-owned `applyWake` state initially set to `Dormant`. The
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
   in the record's write-once `finalDecision` slot. When that payload is
   `Accept`, the same resource-version transition must also change `applyWake`
   from `Dormant` to `Due(generation = 1)`, binding the accepted-decision digest,
   exact existing-owner-lane route, exact protected apply identity as delivery
   audience, and first due deadline. A `Refuse` changes it to `Closed(NoApply)`
   instead. No visible
   final `Accept` may exist without its durable due apply generation. The
   finalization record is the decision and initial wake object, so no second
   resource write can split classification from apply notification. Its name is
   derived from request UID/generation. Every stale or later contender reads the
   existing final state and is non-authoring; pending is never unbounded.
6. Runtime activation requires proof that evidence-slot admission, empty-slot
   expiry, evidence validation, the final slot, and initial apply-wake
   registration all use this one authoritative key/resource version. An
   eventually consistent evidence read, a separately versioned evidence-key
   predicate without a transactional store, an independent create-only decision
   write, or best-effort post-`Accept` dispatch does not satisfy the contract.

A newer independent source event does not silently supersede an in-flight
accepted transaction; lease and nonce rules serialize authority. It is not a
recovery workaround for normal same-generation materialization. Every `Accept`
binds the exact operand-specific protected apply identity and the exact monotonic
cutover-latch digest and epoch observed by its
verifier, the exact enforced `LegacyAdmissionFence/v1` UID/epoch, its
stage-current server-issued compare resource version, the digests of the closed
legacy authority set and governed identity allow set, the enforcement mode, and
the per-target token-map digest. A changed latch, fence identity/epoch, immutable
digest, mode, or token makes that decision ineligible for execution. A changed
`TargetLocal` resource version is accepted only as the next value produced and
recorded by this decision's own successful target-CAS lineage; an unrelated or
unrecorded change makes the decision stale. The persistent legacy deny remains
active even when no governed write is in progress.

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
protected environment, may consume an unexpired `Accept` decision for mutation.
An `Accept` whose execution lease expires before claim handoff may only be
consumed into the canonical non-mutating terminal failure described below. Ring 2
executes the exact saved plan. Ring 1 executes only the closed projection
operand under its exact verifier evidence and resolves opaque custody only at
the subordinate write boundary. The result records:

- environment/protection approval and apply identity;
- decision, request, operand-specific evidence or plan, pre-state, artifact,
  cutover-latch digest/epoch, exact `LegacyAuthorityQuiesced/v1` digest, and
  exact enforced `LegacyAdmissionFence/v1` UID/epoch, stage-current server-issued
  compare resource version, immutable digests, enforcement mode, and relevant
  server-issued target token;
- apply start/end, exit classification, and post-state fingerprint;
- for Ring 2, the exact workload image, operation marker, Deployment generation,
  observedGeneration, desired replicas, and ready replicas;
- for Ring 1, the exact projection operation marker and accepted projection
  operand, without Secret bytes or a GF-I09/application-plan field;
- immutable failure evidence when any step does not complete.

No source merge, controller source green, scheduled run, or manual click may
stand in for this terminal apply result.

An accepted decision never relies on a best-effort workflow event. The
finalization record's due `applyWake` generation is delivered at least once by a
storage-backed authenticated outbox/timer into the existing GFTB owner lane.
Delivery contains only finalization-record identity/digest, wake generation and
due deadline. It grants no decision, saved-plan, projection, attempt, or
target-write authority. The protected run must read the final record and
independently revalidate every normal apply precondition. A lost delivery, an early delivery,
or a run that dies before claim handoff leaves that same generation due and
redeliverable with bounded backoff.

Attempt creation and apply-wake handoff are one authoritative transaction. The
`OwnerActive` branch predicates on `Final(Accept, applyWake = Due(current
generation, current resourceVersion))`, canonical attempt-name absence, and
authoritative server time at or before the inclusive decision execution
deadline. It creates the exact run-bound attempt in `OwnerActive`, changes the
wake to `HandedOff(current generation, attempt UID/generation/digest)`, and
registers the attempt's first recovery-wake generation in the same commit. A
separate client clock cannot classify expiry.

After authoritative server time is later than the execution deadline, an expiry
branch authenticated as the exact protected apply identity bound into the
accepted decision may instead predicate on that exact same due generation and
resource version and atomically create the canonical attempt directly in `Final`
with the one terminal
`AttemptOutcome(Failed:DecisionExpiredBeforeMutation)` while closing the apply
wake. It grants no owner/write phase or recovery wake. The outcome binds
`rollbackEligible = false`: because no governed target mutation was admitted or
attempted, it is categorically excluded from both members of
`RollbackFailureOperand/v1`. Recovery and rollback cannot consume it; a later
source event requires a fresh request, evidence, decision, and attempt. The `OwnerActive`
and expiry transactions contend on the same record: a handoff linearized by the
deadline makes expiry stale even if its response is held; a handoff call begun
before but still unlinearized after a winning server-time expiry CAS is stale.
Neither branch can silently drop an accepted digest.

If the authoritative store cannot provide the multi-key transaction, the
attempt-ownership/handoff state must be co-located in a write-once `attemptSlot`
under the finalization record's resource version; a separate create followed by
acknowledgement is forbidden. In that mode the deterministic attempt name remains
the logical slot key, empty-slot CAS replaces object-name absence, the slot owns
the logical attempt UID/generation/digest, and the finalization record resource
version is the attempt arbitration resource version used by every later
`OwnerActive`, `RecoveryFencing`, and `Final` CAS. In that mode, the canonical
`AttemptOutcome` and, on a successful Ring-2 `Final`, the convergence record and
its first due `observationWake` are write-once fields of that same finalization
record installed by the one `Final` CAS; slot occupancy replaces create-only object existence, and
no separate object create may stand in for any of them. In transactional mode,
separate records are permitted only through the explicit serializable transaction
against the attempt arbitration resource version. Downstream references to the
attempt record, outcome, convergence record, or wake mean those canonical logical
subrecords in co-located mode. A response lost after either handoff commit is
recovered by exact readback; duplicate deliveries read the same handoff and
attempt and remain observation-only.

Delivery acknowledgement may close an apply-wake generation only after that
exact handoff is durably read back, or after the same transaction records the
non-mutating expiry outcome. A crash before the transaction leaves the current
generation due; a crash after it leaves either the attempt recovery wake or the
terminal outcome. Under eventual authenticated delivery and authoritative-store
availability, lost, early, crashed, and duplicate deliveries therefore converge
to one attempt claim and never a second apply.

The atomically handed-off durable attempt record has a canonical name derived
from the request UID/generation and accepted-decision digest. Its create-only
claim and one authoritative arbitration state bind the full
operand-specific execution evidence (Ring-2 saved-plan digest or Ring-1
projection-verification digest), decision-derived operation marker, exact
cutover-latch digest/epoch, exact `LegacyAuthorityQuiesced/v1` digest, exact
`LegacyAdmissionFence/v1` UID/epoch, stage-current server-issued compare resource
version and recorded resource-version lineage, immutable digests, enforcement
mode and relevant server-issued target token, and the exact protected apply
identity and workflow run ID that won handoff. It
also binds a bounded owner lease epoch/deadline and a closed monotonic owner
phase machine: `Claimed` -> `PreWrite` -> `WriteIssued`.
The decision lease bounds the owner lease; only the exact winner may renew it or
advance phase, using compare-and-swap while the independently observed workflow
run remains active. Phase never moves backward, and an expired or independently
terminal owner can never renew or resume its lease.

The attempt also binds the exact target commit coordinates. For every existing
target mutation they include API authority, kind, namespace/name, UID, current
resource version, controller-owned target fencing epoch, and the recorded fence
mode plus relevant server-issued target token and compare resource version. In
`Transactional` mode, the operation marker, next target fencing epoch, intended
state change, and exact server-issued token commit in one serializable store
transaction that validates the token/state/epoch/resource version and takes the
required read/write conflict on the current `Enforced` fence row. In
`TargetLocal` mode, that tuple and the exact opaque server-issued token are CAS
preconditions on the co-located target UID and current object resource version.
The server compares them with the stored `Enforced` token/state/epoch in that
same CAS; success preserves those fence fields, advances target state/fencing
epoch, and returns the next object resource version for the attempt lineage. The
carried token is required input, but an unverified client-authored token,
resource version, boolean assertion, webhook result, or separate read does not
qualify. If an atomic successor-fence handoff wins the same transactional
conflict or target-local CAS first, the governed commit is stale;
if the governed commit wins first, the server-side deny remains enforced and the
successor handoff must re-evaluate against the resulting current state. A create
or multi-object step must use `Transactional` mode unless every mutation and
fence token really is co-located in one authoritative CAS; otherwise governed
mutation refuses. A
quiescence barrier, lease expiry, or workflow termination is not an atomicity
substitute. Ring-1 initial bootstrap additionally retains Section 4's
quarantine, partial-attempt, and idempotent-resume rules.

Authoritative-store handoff success is the ownership grant; the server-issued
attempt UID/generation, digest, owner lease, phase, arbitration resource version,
apply-wake handoff, and target/fence commit coordinates are independently read
back. An `AlreadyExists`
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
is unchanged; the exact `LegacyAuthorityQuiesced/v1` receipt remains current;
the exact `LegacyAdmissionFence/v1` UID/epoch remains `Enforced`, with the
stage-current server-issued compare resource version matching the attempt's
recorded lineage and unchanged digests for the closed legacy authority set and
governed identity allow set, enforcement mode, and relevant server-issued target
token;
fresh server-side reads still show frozen trigger admission, zero nonterminal
legacy runs across every ref/revision, revoked-or-expired issued legacy
authority, and the receipt's target admission fence/quiescence coordinates; and
no legacy authority has been recreated. It then submits only the target-atomic
UID/resource-version/fencing-epoch plus legacy-admission-fence commit defined
above. A pause, expiry, owner-run termination, recovery takeover, phase mismatch,
missing readback, rearmed trigger, newly issued legacy authority, latch change,
legacy-fence/digest/mode/token change, target replacement, or target resource
version/fence change denies that commit. A rearm or allow-set expansion after
this fresh read is refused because `Enforced` is immutable. The only permitted
current-fence transition is an atomic handoff that installs an equivalent or
stricter successor as the current `Enforced` fence, and it contends with the
governed write through the recorded `Transactional` conflict or `TargetLocal`
CAS. A standalone retirement or disable request is refused. An old workflow
revision cannot bypass this boundary because its identity is rejected at API
admission through and after the governed commit, never on the old client's
cooperation.

After recovery wins arbitration, it never executes the saved plan or projection
write. For every unresolved `WriteIssued` target, it must advance the target
fencing epoch using the attempt's exact recorded fence mode: a serializable
target/fence-row transaction in `Transactional`, or one target UID and
current resource-version CAS carrying and server-validating the co-located opaque
token in `TargetLocal`. A successful target-local recovery fence preserves the
stored fence token/UID/enforced epoch, advances the target fencing epoch and
object resource version, and records that returned value as the next lineage
entry. The owner's
already-submitted mutation and the recovery fence therefore serialize at that
same authoritative commit: if the owner commit wins, recovery observes and
classifies that committed state; if the recovery fence wins, the delayed owner
commit fails its stale resource-version/fence precondition. Recovery may not
publish unchanged or failed state until every target is fenced through that mode
and freshly read. An admitted but delayed owner request can never commit after a
recovery failure; a quiescence observation is not a replacement for the required
transaction or co-located CAS.

Recovery liveness has a durable wake edge in the existing GFTB owner lane; it
does not depend on a surviving workflow process or a routine manual click. The
attempt handoff, each bounded owner/recovery lease renewal, and every
`RecoveryFencing` acquisition/successor CAS atomically register or advance a
storage-backed recovery-wake generation for that exact attempt and lease
deadline. The authenticated outbox/timer delivery is at-least-once and is
redelivered with bounded backoff until the record is `Final` or a protected
contender has atomically installed the next lease plus its successor wake. A
delivery binds only attempt identity/digest, wake generation, and due deadline.
It starts the existing owner-lane recovery entrypoint but grants no decision,
plan, saved-plan execution, projection write, target-fence, or result authority.
The started contender must independently read the authoritative attempt, prove
owner or recovery-run termination/lease expiry, and win the same arbitration
CAS before it may fence or finalize.

Delivery acknowledgement cannot discard the only future wake. A contender that
dies before acquisition leaves the current due generation redeliverable; a
winner schedules the next deadline generation in the acquisition CAS; and the
sole final CAS closes the outbox generation with the canonical outcome. Thus a
lost delivery, a terminated runner, or a crash immediately after acquisition
cannot strand `RecoveryFencing`. This deadline/outbox edge is non-authorizing
recovery notification, not a standing mutation/convergence loop, second
controller, or scheduled apply surface.

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
bounded successor path. Under eventual delivery to an available protected
recovery run and an available authoritative API, one successor reaches the
existing sole final slot; no successor executes a second apply or creates a
second outcome.

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
terminal mutation outcome; it is never rewritten by later observation.

### 3.5 Observe, serve, and rollback

An apply result is not a served result. The terminal chain separately records:

- controller-observed result evidence;
- cluster readback with `observedGeneration >= generation` and desired replicas
  greater than zero;
- the registry's independent view of the immutable digest;
- credentialed served-content evidence through the real protected origin;
- the source revision/build marker observed in served content.

For Ring-2 application/image transactions, the mutation outcome and the
convergence outcome are distinct. The same authoritative attempt-finalization
transaction that installs a successful `AttemptOutcome` also creates, or
co-locates under that attempt resource version, one canonical convergence record
and its first due `observationWake` generation. No successful mutation outcome
may become visible without both. The record is keyed by request UID/generation,
decision, attempt-record, and `AttemptOutcome` digests and binds the exact
immutable protected observer subject admitted for this operand. Its immutable
overall observation deadline and bounded `Observing` state contain an observer
owner tuple initially empty, a closed monotonic phase (`Unclaimed` ->
`Collecting` -> `Finalizing`), write-once registry, cluster-readback,
served-content and final-outcome slots, and the durable wake generation under one
authoritative resource version. An observer owner tuple is exactly `(immutable
subject, protected run, observer epoch, lease deadline)`; sharing the immutable
subject does not make a different run the owner. An independent best-effort
record create or post-outcome dispatch is forbidden.

The storage-backed authenticated outbox/timer delivers each due observation
generation at least once into the existing owner lane. Delivery binds only the
convergence-record identity/digest, generation and due deadline and grants no
evidence-publication, finalization, decision, plan, apply, recovery, rollback,
or mutation authority. A run authenticated as that exact immutable observer
subject must independently read the record and CAS `Observing(current
resourceVersion, current wake generation)` to bind its exact run, a bounded
observer epoch and `Collecting` lease whose deadline is
`min(authoritativeServerNow + boundedLease, immutableOverallObservationDeadline)`.
That acquisition CAS installs the exact owner tuple and atomically registers the
next wake at the earlier of lease expiry and the overall deadline. It cannot
acquire or renew `Collecting` after the overall deadline.
Acknowledgement is valid only after this successor wake is durably read back; a
lost or early delivery, or a runner death before acquisition, leaves the current
generation due and redeliverable with bounded backoff.

Every observer lease renewal, phase change, evidence-slot write, and pre-deadline
finalization CAS must authenticate as the record's exact immutable observer
subject **and** match the current owner tuple's run, observer epoch, unexpired
lease, phase, wake generation, and `Observing` resource version. The immutable
subject alone is not ownership. Initial acquisition instead predicates on the
empty owner tuple; a successor acquisition predicates on the complete current
owner tuple plus the termination/expiry proof below. Neither grants the new run
authority until its CAS wins. An evidence-slot CAS additionally requires
authoritative server time at or before the inclusive overall deadline; every
`Collecting` renewal keeps its lease deadline at or before that immutable
deadline and schedules the next wake in the same CAS. If the exact current run is
independently terminal or its lease expires before the overall deadline, a
contender authenticated as the same immutable subject may CAS that current
resource version to the next `Collecting` observer epoch. It binds predecessor
owner/lease and terminal-or-expiry proof, current phase and all write-once slots,
the exact successor run and capped lease, and the next wake generation. Any
different subject, same-subject different run without the successor CAS, stale
epoch, stale lease, or stale resource version is refused. The predecessor's
renewal, evidence, phase, and finalization CASes become stale.

After authoritative server time is later than the immutable overall observation
deadline, `Collecting` is frozen:
no acquisition, renewal, or evidence-slot write can extend or reopen it. A due
deadline contender authenticated as the exact immutable subject must instead CAS
the current resource version directly into `Finalizing`, freezing all admitted
slots and installing one exact `(subject, run, finalizer epoch, bounded
finalizer-only lease)` owner tuple plus the next finalizer wake. This is not an
observer-lease renewal: it cannot admit evidence or move phase backward. If that
run terminates or its bounded finalizer lease expires before the terminal CAS,
exactly one same-subject successor may CAS the current resource version to the
next finalizer epoch with the frozen slots and a new bounded finalizer-only lease;
the prior run becomes stale. A finalizer lease is never renewed in place. The
terminal CAS requires the exact current finalizer owner tuple, unexpired lease,
`Finalizing` phase, wake generation, and resource version. Thus every evidence
and final CAS has one unambiguous run/epoch owner while post-deadline liveness does
not extend the evidence window. Every successor resumes only from authoritative
slots, never local memory, and gains no mutation authority.

Evidence admission and the server-deadline finalizer contend on that same
record. Only authoritative server time classifies the inclusive overall
observation deadline. At or before the inclusive deadline, the exact current `Collecting` owner
may publish a definitive success or failure only with its complete owner tuple
and current resource version. After the deadline, the exact current
`Finalizing` owner publishes from the frozen slots. One CAS produces exactly one immutable
`ConvergenceOutcome = Converged | Failed(typed reason)` and closes the current
wake generation. Exact registry, target, operation marker, generation/replica,
and served source-marker agreement yields `Converged`. A definitive served
source-marker mismatch, or a bounded terminal registry/readback/served failure
after the immutable observation deadline, yields typed failure. Missing,
ambiguous, unauthenticated, or conflicting evidence cannot synthesize success;
before the deadline it remains non-authorizing observation, and after the
deadline the due generation is redelivered until one finalizer owner or
successor publishes the corresponding typed terminal failure. An evidence CAS
linearized by the inclusive deadline advances the resource version and makes a
concurrent deadline-freeze CAS stale; an evidence request still unlinearized
after the freeze CAS is stale and cannot alter the frozen slots. A delivery
cannot acknowledge away the only deadline wake before a next wake or `Final`
state exists.

A crash before or after atomic convergence-record creation, observer
acquisition, any evidence-slot CAS, the overall deadline, or the final CAS
therefore leaves either no committed successful mutation outcome to observe, a
due generation, a bounded successor path, or the sole terminal outcome. Under
eventual authenticated delivery and authoritative-API availability every
successful Ring-2 mutation reaches one terminal convergence result. This
observer can publish evidence and that result only; it carries no decision,
plan, apply, recovery, rollback, or mutation authority and is not a standing
convergence loop or second controller. The successful `AttemptOutcome` remains
successful and append-only even when its `ConvergenceOutcome` is failure.

Ring-1 remains independent of this Ring-2 served-content finalizer. Its
successful post-write terminal evidence is the exact
`RegistryPullProjectionActivationEvidence` in Sections 3.3 and 4, with no
GF-I09 application release, image-plan, or served-source prerequisite.

Rollback is a distinct accepted transaction and may follow only one canonical
`RollbackFailureOperand/v1`: either (a) an exact accepted transaction whose
immutable `AttemptOutcome` is classified as a rollback-eligible mutation
failure, or (b) an exact successful
`AttemptOutcome` paired with its canonical terminal
`ConvergenceOutcome(Failed)`. Case (b) is the governed rollback operand when O5
is true but O8 proves that the protected origin serves the wrong revision. The
operand binds the failed request UID/generation, decision and attempt-record
digests, the canonical create-only `AttemptOutcome` digest, and, for case (b),
the canonical convergence-record and failed `ConvergenceOutcome` digests and
exact independent observations. It also binds a retained prior accepted
release, fresh post-failure pre-state, a new saved rollback plan, the current
cutover-latch, `LegacyAuthorityQuiesced/v1`, and enforced
`LegacyAdmissionFence/v1` UID/epoch, stage-current server-issued compare resource
version, immutable digests, enforcement mode and relevant server-issued target
token, fresh nonce/lease, and an externally observed served result.
`AttemptOutcome(Failed:DecisionExpiredBeforeMutation)` always carries
`rollbackEligible = false` and cannot enter case (a): it proves that no governed
mutation was admitted, so there is no failed target state to roll back. A
successful `AttemptOutcome` by itself, a successful convergence outcome, any
other outcome marked rollback-ineligible, or a noncanonical, conflicting, or
merely missing terminal result cannot be its failed-result operand. Reusing a
pre-failure plan or merely reselecting an old image is not a rollback receipt.

Attempt, refusal, mutation-outcome, convergence-outcome, served, and rollback
receipts are append-only. Every original attempt ends in a terminal mutation
outcome receipt; every successful Ring-2 mutation admitted to post-write
observation ends in one terminal convergence outcome, including when a separate
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
| O5 | the protected apply identity executed that exact saved plan once and the sole attempt-arbitration finalization produced the canonical successful `AttemptOutcome`, or the current recovery epoch owner (initial or successor) recovered that committed target state after proven owner termination/expiry and target fencing/quiescence; any terminal mutation failure keeps O5 false for that request/generation | attempt/arbitration CAS, recovery lease/phase, target UID/resource-version/fence commit, and sole canonical `AttemptOutcome` |
| O6 | the registry independently serves the bound image digest | authenticated registry read |
| O7 | live state carries the operation marker and caught-up generation with replicas greater than zero | cluster readback |
| O8 | the protected served origin returns content built from `S` | credentialed served-content probe and canonical `ConvergenceOutcome` |

The mandatory scheduled readback is a separate release gate, not a ninth
mutation or decision authority. For each environment it folds the controller's
append-only accepted-decision order into a finite
`LatestAcceptedDesiredByOperand` map. Its canonical key is tenant, environment,
closed operand class, and exact target/authority coordinate; a multi-target
operand expands to every canonical target coordinate while retaining the one
full operand digest. Each accepted decision atomically updates only its exact
keys. It cannot evict still-active keys from another operand class or target,
and a removed target remains active until a later accepted same-class/same-
coordinate operand explicitly binds its desired absence under that closed
schema. Contradictory active
entries for the same live field, duplicate keys, an unaccounted prior key, or a
partial multi-target expansion is ambiguity and fails closed.

Every active entry binds the exact request UID/generation, decision and full
desired-operand digests, decision-derived operation marker, and canonical
mutation/convergence outcome digests when present. The fold never derives
desired state from repository HEAD, a mutable tag, workflow input, or the live
object it is checking. Every scheduled invocation reads the complete active
map, including projection, application-release, and image/replica surfaces; it
cannot select only the most recently accepted union member. Before `S` can be
declared accepted as converged, a fresh authenticated scheduled invocation must
read every active entry and report exact live state, including `S`'s keyed
desired state and marker. An accepted but not yet applied transaction may
therefore make the scheduled run red; that is drift evidence and never
authority to apply it.

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
8. **Mutation success is not served success.** A successful `AttemptOutcome`
   followed by a canonical `ConvergenceOutcome(ServedContentMismatch)` keeps
   O8 false and supplies case (b) of the rollback-failure operand without
   rewriting the mutation result.

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
- final `Accept` publication with initial apply-wake registration held across a
  crash: the one finalization-record CAS must expose both or neither. Lost and
  early apply-wake delivery, a runner crash before handoff, a response lost after
  handoff, and duplicate delivery must retain acknowledgement-safe redelivery and
  converge through one transactional or co-located-CAS wake-to-attempt handoff to
  exactly one canonical claim. Use authoritative server time and hold both
  deadline orderings: (a) a handoff CAS linearized at or before the inclusive
  execution deadline makes a later expiry CAS stale even when handoff response is
  held, and (b) a handoff call begun before but still unlinearized after a winning
  post-deadline expiry CAS is stale. Only the exact protected apply identity may
  execute expiry, which creates the one canonical non-mutating terminal failure,
  never a write or a dropped accepted digest, and must carry
  `rollbackEligible = false`; any attempt to construct either rollback-failure
  operand from `DecisionExpiredBeforeMutation` is refused;
- changed pre-state or a mismatched saved plan;
- absent or operand-mismatched post-write projection activation evidence when
  private-image projection is required;
- failure to publish/read back the attempt record or logical attempt slot before
  mutation, and a crash
  after mutation but before result publication; retry must not reapply and the
  independent observer must recover a terminal result;
- duplicate atomic claim creation, where exactly one protected run wins and an
  `AlreadyExists` or occupied-slot contender cannot finalize recovery while that
  owner run is merely slow but active with an unexpired lease;
- in co-located attempt mode, handoff, owner publication versus recovery takeover,
  recovery-successor acquisition, final outcome publication, and convergence
  record creation all CAS the finalization record's evolving resource version. A
  stale resource version or any separately invented attempt-object resource
  version is refused at each boundary; the one `Final` CAS installs the write-once
  logical `AttemptOutcome` and, after Ring-2 success, the convergence record and
  first due observation wake together or exposes none of them;
- owner termination/lease expiry with concurrent recovery contenders: exactly
  one initial attempt-arbitration recovery CAS wins and every other contender
  remains read-only while that recovery lease is active; after independently
  proven termination/expiry exactly one successor CAS may win the next epoch;
  a late-resuming original owner must fail the arbitration and target
  UID/resource-version/fencing-epoch checks before mutation;
- an owner mutation admitted at `WriteIssued` but delayed across recovery
  takeover: the owner target commit and recovery target fence must serialize
  through the exact recorded `Transactional` conflict or `TargetLocal` CAS. In
  `TargetLocal`, both must carry the exact server-issued opaque token and current
  resource version, the server must compare them with the co-located
  token/state/epoch in that same CAS, success must preserve the token and record
  the returned next resource version, and stale, unissued, or caller-invented
  values must fail. No owner write may commit after recovery publishes terminal
  unchanged/failure state;
- owner result publication concurrent with recovery acquisition: both contend
  on the same attempt-arbitration resource version, exactly one reaches
  `Final`, and exactly one canonical create-only `AttemptOutcome` exists as the
  immutable mutation-outcome anchor for any rollback-failure operand;
- recovery-owner crashes immediately after `RecoveryFencing` acquisition,
  between every target-fence operation, after a fence commit but before journal
  publication, after readback binding, and immediately before finalization: an
  independently proven terminal/expired recovery lease must permit exactly one
  successor CAS, while a lost wake, delivery-before-run crash, and runner crash
  after acquisition each leave a durable generation for bounded redelivery;
  monotonic fence/journal recovery reaches one eventual canonical outcome with
  no saved-plan/projection/desired-state re-execution;
- a legacy run queued, waiting for Environment approval, or in progress from
  any ref or old workflow revision across cutover; a legacy credential still
  valid after the freeze; or a write already admitted before revocation but
  delayed across governed enablement: each prevents
  `LegacyAuthorityQuiesced/v1` finalization. The delayed write must be ordered
  committed or rejected before the barrier and bound target snapshot, and must
  never commit after the receipt or governed enablement;
- either legacy mutation path rearmed after the cutover receipt, or its latch,
  credential generation, run set, target coordinates, fence mode/token, or
  immutable legacy-authority or governed-identity set changing after plan or
  decision but before the fresh pre-write read;
- an attempted legacy-authority reissue, governed-identity allow-set expansion,
  target-token substitution, or any other `Enforced`-set/mode/token mutation
  **after** the fresh pre-write read: the server must refuse it without changing
  the fence epoch, immutable digests, mode, or token map. A standalone
  retirement or disable request is refused. A proposed successor that weakens
  legacy-identity, issuer, grant, verb, or target deny coverage; broadens the
  governed allow set; is not installed as the current `Enforced` fence in the
  same authoritative transition; or requires independent
  per-target CASes is likewise refused. Hold a valid atomic successor-fence
  handoff against a governed target commit in both orders under each recorded
  mode: `TargetLocal` covers one target/aggregate CAS only, and an independent
  multi-target scope must refuse or use `Transactional`. If the handoff wins the
  serializable conflict or target-local CAS, the old target intent is stale and
  refuses while the successor is `Enforced`; if the target commit wins, the old
  fence stays `Enforced` and the handoff must re-evaluate after that commit. No
  ordering permits both authority rearm and a governed write, an unfenced target,
  or a post-commit legacy write; retiring legacy authorities never removes the
  current enforced fence;
- a recovered terminal failure followed by otherwise-positive live observations;
  O5 and the full oracle must remain false for that generation;
- successful attempt finalization held immediately before and after atomic
  convergence-record plus observation-wake creation: a committed successful
  outcome must always have both. Then lose or duplicate the initial delivery and
  crash the observer before acquisition, immediately after acquisition, before
  and after every registry/readback/served evidence-slot CAS, across the overall
  observation deadline, and before/after final CAS. Acknowledgement must never
  discard the only due generation. Every `Collecting` lease must be capped at the
  immutable overall deadline; renewal at or past that cap and evidence
  publication after it must fail. Evidence, phase, renewal, and pre-deadline
  final CASes from the same subject but a different run, epoch, lease, wake
  generation, or resource version must fail. Independent run termination/lease
  expiry must permit exactly one same-record successor authenticated as the
  immutable protected observer subject and refuse every other subject, including
  one in a formerly accepted role or identity class. After the overall deadline,
  one exact finalizer-owner CAS must freeze the slots and bind the current
  subject/run/epoch/bounded finalizer-only lease; crash or expiry admits one next
  finalizer epoch, never a `Collecting` renewal or evidence write. Hold evidence
  and authoritative-server-deadline finalization in both CAS orders: evidence
  linearized by the inclusive deadline makes expiry stale, while an unlinearized
  evidence call loses after the post-deadline finalizer wins. The winner resumes
  authoritative slots and reaches one terminal `ConvergenceOutcome` without any
  mutation;
- apply failure and served-content mismatch, including a successful immutable
  `AttemptOutcome` followed by a definitive wrong served revision: exactly one
  terminal failed `ConvergenceOutcome` must exist and the apply outcome must not
  be rewritten;
- rollback evidence that does not bind the canonical rollback-eligible
  apply-failure or convergence-failure operand and fresh pre-state, including a
  poison that tries to use rollback-ineligible
  `Failed:DecisionExpiredBeforeMutation`;
- accept one operand class and then a disjoint class/target: the latter must not
  replace or hide the former in `LatestAcceptedDesiredByOperand`; overlapping
  contradictory keys, a missing active key, and partial multi-target expansion
  each fail the entire scheduled run;
- scheduled drift/readback with absent authentication, readback/API error, or
  real drift from any entry in the exact complete
  `LatestAcceptedDesiredByOperand` map: each must fail the scheduled run while
  emitting no decision, intent, plan, apply, or mutation.

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
   record/resource version in both held-call orders. Apply-delivery fixtures must
   prove final `Accept` and its first wake are atomic; lost/early/crashed delivery
   and a lost handoff response retain acknowledgement-safe redelivery; the
   wake-to-attempt handoff is one transaction or same-record CAS; authoritative server
   time decides expiry; both held deadline orders produce exactly one logical
   attempt and either `OwnerActive` or the non-mutating expiry outcome, and any
   expiry caller other than the exact protected apply identity is refused. The
   co-located fixture must then use the finalization record's evolving resource
   version for handoff, owner-publication/recovery arbitration, recovery
   successor, final outcome, and convergence-record creation, rejecting a stale
   or separate attempt-object resource version at every boundary. Its one `Final`
   CAS must install the write-once logical outcome plus, after Ring-2 success, the
   convergence record and first observation wake atomically.
   Recovery interleavings must
   prove a slow live owner excludes recovery; owner outcome publication and
   recovery takeover serialize on one arbitration resource version; a delayed
   already-admitted owner write cannot commit after recovery failure; crashes at
   every `RecoveryFencing` boundary admit a monotonic read/fence/finalize-only
   successor; lost/early/crashed recovery deliveries retain an at-least-once
   wake generation; and exactly one canonical `AttemptOutcome` exists.
   Observation interleavings must cover atomic successful-outcome/record/wake
   creation, lost/early/duplicate delivery, crash before and after acquisition
   and every evidence slot, both authoritative-server-deadline CAS orders,
   acknowledgement safety, capped `Collecting` leases that never extend evidence
   admission beyond the immutable overall deadline, and exact active
   subject/run/epoch/lease/wake/resource-version ownership at every evidence and
   final CAS. They must refuse every successor subject other than the record's
   exact immutable protected observer subject, refuse a same-subject run that has
   not won the successor CAS, and prove the post-deadline finalizer-only owner and
   one admitted same-record finalizer successor reach the only terminal outcome
   without reopening evidence collection.
   Add the successful-apply/wrong-served-revision fixture and require one failed
   `ConvergenceOutcome` plus the exact case-(b) rollback operand without outcome
   rewrite. Cutover fixtures hold an old-revision run queued, waiting, and
   in-flight across the freeze and credential fence; refuse any immutable-set,
   mode, or target-token-map change while `Enforced`; refuse standalone
   retirement, disable, a weaker or broader successor, and a successor that is
   not installed `Enforced` atomically; refuse independent multi-target
   `TargetLocal`; require the exact server-issued token to be carried and compared
   in the authoritative transaction/CAS while refusing caller-invented, unissued,
   or stale token/resource-version assertions; prove each successful
   target-local write preserves that token and records the returned next resource
   version; and hold a valid atomic successor-fence handoff against the governed
   write in both orders under `Transactional` and single-target/aggregate
   `TargetLocal`, proving one conflict/CAS winner, continuous enforcement, and no
   post-commit rearm or legacy write. The existing scheduled
   readback family must also prove absent authentication, readback error, a
   disjoint later operand acceptance, and actual drift from any active entry in
   the complete `LatestAcceptedDesiredByOperand` map are red while every
   mutation surface is absent. Every new validator names its claim and
   retirement trigger in the same change.
3. **Plan-only rehearsal.** Run the exact GFTB path with mutation disabled;
   independently verify materialization, pre-state, saved plan, controller
   refusal/acceptance semantics, and receipts. While either legacy path remains
   armed, the live decision must refuse; acceptance may be exercised only in a
   non-authoritative contract fixture. This is not a shadow controller or
   second workflow.
4. **Fence legacy mutation authority.** Before the first governed write, freeze
   trigger admission for the existing `repository_dispatch` apply and routine
   manual mutation path across every ref/revision; revoke the producer signal
   authority; and prevent new legacy Environment approvals. Then enumerate the
   authoritative workflow and Environment APIs until every legacy run ID is
   terminal and none is queued, waiting, pending approval, or in progress.
   Server-side revoke or independently expire every apply credential or
   authorization issued to those runs. Install and read back the persistent
   server-side `LegacyAdmissionFence/v1` over the complete legacy identity,
   issuer, grant, verb, and target set. Freeze its legacy-authority and governed
   identity sets while `Enforced`, and record either a serializable
   `Transactional` fence-row conflict or a `TargetLocal` co-located target token
   for every mutation coordinate. `TargetLocal` is permitted only when one target
   or server-controlled aggregate object covers the complete scope under one CAS;
   independent multi-target scopes require `Transactional`. Each mutation must
   carry the exact opaque server-issued token and current server-issued resource
   version, which the server compares with the authoritative fields in that same
   transaction/CAS; neither value is authority by client assertion. A separate
   resource-version pre-read is not an admission precondition.
   Then cross an authoritative API-server quiescence barrier that reports zero
   in-flight legacy mutations and orders every pre-fence admitted request as
   committed or rejected. Fresh target UID/resource-version/fencing-epoch and
   admission-fence readback follows that barrier. Only then may the protected
   cutover operation finalize
   the append-only `LegacyAuthorityQuiesced/v1` receipt and monotonic latch.
   Asking refit clients to consume the latch, cancelling a run, or draining only
   the current ref is insufficient because an old workflow revision can bypass
   that source check. The governed executor refuses until the exact receipt is
   bound through plan, decision, attempt, fresh pre-write read, and the target
   commit's recorded transaction or co-located CAS. Every pre-receipt plan or
   decision is stale and must be regenerated before the canary. The disabled
   source may remain for
   comparison until parity, but the API server continues to deny its closed
   identity set through and after governed commits; it has no credential or
   mutation authority.
5. **Refit and prove live scheduled readback before canary.** Before the first
   governed GFTB write, refit the existing `k8s-stack-drift.yml` carrier in
   place to use protected short-lived authentication and the exact
   complete `LatestAcceptedDesiredByOperand` fold described in Section 5.
   Remove its current skip-on-absent-credential and `fail_on_drift=false`
   behavior. Through that
   actual scheduled carrier, prove missing authentication, API/readback error,
   and a bounded real-drift fixture each fail red while no decision, intent,
   plan, apply, or mutation is emitted. If no governed accepted desired state
   exists before the first canary, `NoAcceptedDesired` is itself fail-closed;
   neither that expected red state nor a fixture is convergence evidence. This
   source refit and live negative proof must complete before step 6.
6. **Governed successful canary.** After the self-dogfood and MMS prerequisite
   proofs, execute one accepted GFTB transaction through the protected identity.
   Its accepted decision updates only that operand/target key in
   `LatestAcceptedDesiredByOperand` before apply, so drift remains visibly red
   until convergence and every other active key stays covered. After its
   successful canonical mutation and convergence outcomes, a fresh authenticated
   invocation of the already-refit scheduled carrier must read the complete map
   and those exact values before O1-O8 can be declared green. Retain this exact
   accepted release as the rollback target.
7. **Create one exact served-failure transaction.** Execute a distinct,
   accepted, mutation-proven canary transaction using the separately reviewed
   bounded wrong-served-revision fixture from step 2. It reaches an immutable
   successful `AttemptOutcome`, then its independent credentialed O8 observation
   produces one immutable terminal
   `ConvergenceOutcome(ServedContentMismatch)`. Capture its request
   UID/generation, decision, attempt and convergence records, fresh post-failure
   pre-state, canonical `AttemptOutcome` digest, failed `ConvergenceOutcome`
   digest, and exact observation evidence as the case-(b)
   `RollbackFailureOperand/v1`; the apply outcome remains successful and
   unchanged. The fresh rollback inputs in Section 3.5 remain mandatory.
   Expected convergence failure is evidence, never a converged acceptance.
8. **Rollback proof.** Consume exactly the failed transaction from step 7 and
   externally observe the retained successful release from step 6 through a
   fresh accepted rollback transaction. The governed rollback is the only
   enabled rollback mutation path.
9. **Reconverge.** Execute a fresh forward transaction and require O1-O8 plus a
   fresh scheduled readback of the complete operand-keyed accepted desired map;
   neither the failed mutation/convergence results nor rollback result is
   rewritten or reused.
10. **Retire the bespoke mutation authorities.** Only after parity, exact
   failed-transaction rollback, and reconvergence evidence,
   remove producer `repository_dispatch`, bespoke signal credentials and
   payload, routine manual apply, inline digest-resolution authority, and any
   duplicate policy gates. This removal does not retire
   `LegacyAdmissionFence/v1`: the current fence stays `Enforced` for the governed
   mutation lane's lifetime. It may be superseded only by an equivalent or
   stricter successor installed `Enforced` in the same server-authoritative
   transaction/CAS that makes the old record historical, with no unfenced
   interval; a standalone `Retired` or disabled state is forbidden.
11. **Continue scheduled observational enforcement.** The carrier refit and
   negative proof already completed in step 5 remain mandatory and recurring.
   Every run reads every active entry in the current exact
   `LatestAcceptedDesiredByOperand` map, fails closed on missing authority,
   readback error, ambiguity, omitted keys, or drift, and never substitutes for
   edge-triggered attempt/outcome/served receipts. It may retire only in the
   same change that activates an explicitly named equivalent scheduled carrier
   with the same complete operand-keyed binding, authentication, fail-closed,
   report-only, and zero-mutation contract.

## 7. Existing surfaces and retirement triggers

| Existing surface | Disposition | Retirement trigger |
|---|---|---|
| site `container-ghcr.yml` publish logic | retain build/publication, make GF-I09 the release authority | authenticated GFTB GF-I09 producer proof |
| producer `signal-cd` / `repository_dispatch` | freeze across every ref/revision and install a persistent server-side `LegacyAdmissionFence/v1` before the first governed mutation; remove the legacy producer after parity while the fence remains enforced | `LegacyAuthorityQuiesced/v1` proves trigger freeze, zero queued/waiting/pending/in-progress legacy runs, credential revocation/expiry, admitted-write quiescence, and enforced admission-fence readback before canary; one governed successful transaction, one exact terminal served-failure transaction, its bound rollback, and reconvergence have immutable receipts; the legacy producer, queued work, credentials, and recreation paths are removed while the current fence remains `Enforced`, and any fence successor is installed atomically with equivalent or stricter coverage through its recorded conflict/CAS |
| infra `web-stack.yml` | refit in place as the GFTB protected executor; do not clone it | accepted controller/executor contract and protected runtime proof |
| manual `workflow_dispatch` steady-state apply | freeze admission, drain every ref/revision, revoke/expire issued authority, and place its closed identity set behind the persistent server-side fence before the first governed mutation; retire the manual path as a product mechanism while the fence remains enforced | governed rollback is exercised and externally observed, the manual authority and recreation path are removed, and the current fence remains `Enforced` or is atomically superseded by an equivalent or stricter `Enforced` successor |
| `Justfile` workload validation/apply entrypoints | retain as GFTB-owned verbs, split by plan/apply authority as needed | replaced only by a separately ratified GFTB owner-overlay interface |
| `/health` probe | retain for liveness only | never promoted to served-content oracle |
| `k8s-stack-drift.yml` | refit and prove before first governed canary; retain as mandatory authenticated, report-only, fail-closed scheduled readback of the complete `LatestAcceptedDesiredByOperand` map; never a convergence loop or mutation trigger | replace only in the same change by an explicitly named equivalent scheduled carrier with the same complete operand-keyed binding that fails on absent authority, readback error, omitted/ambiguous keys, and real drift and retains zero mutation/decision authority |
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
  same-generation evidence admission versus expiry/finalization and atomic
  final-`Accept` apply-wake registration; durable authenticated at-least-once
  apply-wake delivery in the existing owner lane; acknowledgement-safe,
  transactional wake-to-attempt handoff; atomic create-only run-bound attempt
  ownership; bounded owner lease/phase; one
  owner-publication/recovery arbitration CAS; target-commit-atomic UID,
  resource-version, and fencing epochs under the exact `Transactional` or
  `TargetLocal` legacy-fence mode and immutable server-written target token. The
  exact token and stage-current server-issued resource version must be carried as
  request preconditions and compared with authoritative state in the same
  transaction/CAS; successful target-local mutations preserve the token and
  record the returned next resource version. An unverified client assertion,
  pre-read,
  independent multi-target CAS, or quiescence substitute; bounded recovery
  lease/phase, durable authenticated at-least-once recovery wake in the existing
  owner lane, and read/fence/finalize-only successor CAS; one canonical
  create-only `AttemptOutcome`; atomic post-success convergence-record plus wake
  creation; exact immutable protected observer subject plus exact active
  run/epoch/lease ownership, `Collecting` renewal capped by the immutable overall
  deadline, and a distinct post-deadline finalizer-only owner/successor phase;
  acknowledgement-safe at-least-once observation delivery and same-record
  observer-successor CAS through one
  canonical `ConvergenceOutcome`; the closed apply-failure/served-failure rollback-operand
  union; single-use lost-result recovery; and terminal GFTB receipt publication
  require reviewed source and runtime proof;
- a protected monotonic cutover-latch and exact
  `LegacyAuthorityQuiesced/v1` receipt must bind through plan, decision, attempt
  record, fresh pre-write observation, and the target commit. A persistent
  server-side `LegacyAdmissionFence/v1` over the closed legacy identity, issuer,
  grant, verb, and target set, governed-identity allow set, enforcement mode, and
  target-token mapping must be immutable while `Enforced` and enforced through and after
  that commit by the recorded serializable fence-row conflict or one co-located
  target/aggregate-token CAS. The receipt proves trigger admission frozen
  and zero queued/waiting/pending/in-progress legacy runs across every ref and
  workflow revision, server-side revocation/expiry of all issued legacy
  authority, and quiescence or rejection of every already-admitted write before
  governed canary or rollback can consume an accepted decision. Removing legacy
  authorities and recreation paths does not retire the current fence. Any fence
  replacement contends through that same mode and atomically installs an
  equivalent or stricter successor in `Enforced` state; a standalone retirement,
  disable, weaker/broader successor, independent multi-target `TargetLocal`,
  post-read rearm, unfenced interval, and post-commit legacy writes are
  server-refused;
- a credentialed served-content probe and the canonical convergence finalizer
  with durable deadline wake/redelivery and successor liveness are required;
  constant `/health` cannot substitute, and a successful
  `AttemptOutcome` followed by served mismatch must remain oracle-red while
  supplying an immutable rollback-failure operand; the pre-mutation
  `Failed:DecisionExpiredBeforeMutation` outcome is explicitly
  rollback-ineligible and cannot enter that operand union;
- the existing scheduled drift/readback must be authenticated, report-only,
  bind and read every active entry in the complete
  `LatestAcceptedDesiredByOperand` map, and fail closed on absent authority,
  readback/API error, omitted or ambiguous keys, and real desired/live drift
  while carrying zero mutation or decision authority; its in-place refit and
  live negative proof precede the first governed canary, and it may retire only
  with an explicitly equivalent scheduled carrier;
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
