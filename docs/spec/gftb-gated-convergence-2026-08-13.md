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
- **Enrolment/controller MVP ruling:** TIN-3768 comment
  `27a1616e-b8d8-4560-81d6-d1dbf6fe7145`, grounded by correction
  `48be6e96-86a8-470a-9db6-f175f58202b8`. RING-0 cross-link
  `d96b78cd-368a-46d8-b961-9b29b93e1f88` proposes signed
  `OwnerInstallation/v2` and expiring `OwnerOverlayInstance/v1` coordinate
  sources plus executor-local custody; review
  `fde41451-c2ae-4213-93a7-dbeefe226241` records that this coherent shape still
  requires an explicit operator-ratification carrier before Core/CRD work.

This is a design contract, not a second mutable status surface. Dated evidence
below is retained only where it explains a required invariant. Current
activation state must be read from the named ticket and PR carriers.

## 0. Decision

GFTB converges through the estate's existing receipt-driven, GF-gated model:

```text
reviewed site source
  -> immutable image + authenticated GF-I09 application release
  -> create-only publisher in the existing #55 protected-main push workflow
  -> owner-overlay-controller #5 typed request gate (default refusal)
  -> GFTB owner-overlay protected materialize/check/plan
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
the original attempt's outcome. There is no standing convergence or drift loop.
Periodic diagnostics, if retained, are observational only and carry no
decision, plan, apply, or lifecycle authority.

This diagram is the required chain, not a claim that its initiating edge
exists. The current #55 relay GETs an already-existing request on protected
main push; #56 consumes a supplied request; and #5 does not install its sample
request. The existing #55 protected-main workflow must gain a separate
create-only publisher job before materialization. It consumes already-published
digest-addressed artifacts, creates the digest-named typed request, and exports
only its canonical name and expected digest. On either create success or
`AlreadyExists`, the existing exact-name plan reader GETs the object, verifies
its immutable bytes, digest, and publisher identity, and emits the observed UID
and generation into verifier-owned evidence. #55 then writes typed verification,
#5 emits one immutable intent, and the same run's separately protected apply job
invokes #56. GFTB neither owns that central publisher nor substitutes a new
workflow, manual dispatch, or hand-created request.

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
is missing. A request may remain `Refuse: MaterializationPending` until the
protected plan identity has produced exact, request-bound evidence. No
application mutation is accepted merely because an image or release exists.

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
overlay. Their current held heads are not compatible runtime dependencies:
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

Before any GFTB activation, the existing #5/#55/#56 chain must gain one
explicit protected initiation contract. It binds the exact writer identity,
source/ref/tree/release digests, the expected request digest, reader-observed
generation and UID, nonce/lease semantics, and the corresponding protected plan
run. Publishing a request must reliably initiate that run without a routine
manual click, runtime Git clone, or second controller/workflow/backend.

This is a create-only publisher identity inside the existing #55
protected-main push workflow, before its existing materialization job. It
authors exactly one immutable request containing a common envelope and exactly
one typed union member. This is central GF/controller-chain work. The GFTB
producer supplies authenticated release and owner-overlay coordinates; it does
not hand-create the Kubernetes request or introduce a tenant-specific dispatch
authority. Create-only publisher retries stop at canonical name plus expected
digest: the exact-name plan reader, not the publisher, verifies an existing
object and supplies its UID and generation.

### 3.1 Immutable release

The producer must publish an authenticated GF-I09 application release that
binds at least:

- source repository, exact commit, source-tree digest, and protected producer
  identity/run;
- application descriptor and payload digests;
- immutable image repository, digest, platform, and media coordinates;
- derivation, signature, provenance, and publication-receipt coordinates;
- the GFTB tenant and exact owner-overlay release/root required to install it.

A mutable tag, branch name, green workflow conclusion, or caller-authored
`verified=true` field is not release authority.

### 3.2 Materialization and plan

The GFTB plan identity acquires declared OCI content by digest, independently
checks size/hash/media/source identity, and materializes it in a private,
bounded directory. It performs no runtime Git checkout and accepts no
free-form executable.

The owner overlay supplies a closed adapter and exact path scope. The
verifier-owned plan receipt binds:

- request and release digests;
- tenant, environment, policy digest, controller identity, nonce, and lease
  epoch/expiry;
- exact materialized descriptor, payload, and owner-overlay root digests;
- pre-state fingerprint and backend identity;
- saved-plan artifact digest and machine-readable change summary;
- plan identity and protected workflow run.

The request does not author `verified=true`, `planDigest`, or
`preStateFingerprint`. Protected materialization derives and records those
observations independently before a final decision can accept.

The saved plan is immutable and single-use. An apply must refuse if the plan,
pre-state, decision, nonce, lease, policy, or identity no longer matches.

Prerequisite receipts form a closed, verifier-owned list before they enter the
canonical binding. Their digests are sorted and unique; every receipt belongs to
the same tenant, has an admitted predecessor operand kind and terminal-success
outcome, and names the exact prior generation when that operand requires one.
Self-reference, a dependency cycle, an unknown kind, a nonterminal receipt, or a
receipt from another tenant is a refusal.

### 3.3 Controller decision

Controller #5 validates the exact request-bound typed materialization and plan
receipt and emits one closed decision:

- `Accept` binds the only saved plan that the apply identity may execute; or
- `Refuse` carries a typed reason and authorizes no mutation.

Missing evidence, expiry, replay, unknown fields, digest mismatch, unexpected
path, changed pre-state, unsafe plan semantics, or unproved credential
projection fail closed. A newer request does not silently supersede an
in-flight accepted transaction; lease and nonce rules serialize authority.

For GFTB, the application release and image transition remain typed operands,
not authority embedded in the tenant workflow. The accepted
`ImagePinReplicaFlip/v1` binds the exact Deployment/container, current and
desired immutable image, current and desired replicas, prior acceptance,
rollout deadline, and—when the image is private—the exact successful projection
receipt. The GFTB executor may consume only that closed intent.

`RegistryPullProjection/v1` remains Ring 1. Its activation predicate binds the
`Accept` for that exact projection request and operand, not an unrelated tenant
decision. Its private-image audience comes from projection-owned publication
evidence. The publisher may require only the applicable signed owner-coordinate,
custody, policy, and publication facts for the projection operand; it must not
require a Ring-2 `ApplicationRelease/v1` or `ImagePinReplicaFlip/v1`. A later
Ring-2 transaction may consume the terminal successful projection receipt, but
never becomes the projection's prerequisite.

### 3.4 Protected apply

Only the separate GFTB apply identity, behind the existing protected
environment, may consume an unexpired `Accept` decision. It executes the exact
saved plan and records:

- environment/protection approval and apply identity;
- decision, request, plan, pre-state, and artifact digests;
- apply start/end, exit classification, and post-state fingerprint;
- exact workload image, operation marker, Deployment generation,
  observedGeneration, desired replicas, and ready replicas;
- immutable failure evidence when any step does not complete.

No source merge, controller source green, scheduled run, or manual click may
stand in for this terminal apply result.

### 3.5 Observe, serve, and rollback

An apply result is not a served result. The terminal chain separately records:

- controller-observed result evidence;
- cluster readback with `observedGeneration >= generation` and desired replicas
  greater than zero;
- the registry's independent view of the immutable digest;
- credentialed served-content evidence through the real protected origin;
- the source revision/build marker observed in served content.

Rollback is a distinct accepted transaction. It binds a retained prior
accepted release, fresh post-failure pre-state, a new saved rollback plan, the
failed-result digest, fresh nonce/lease, and an externally observed served
result. Reusing a pre-failure plan or merely reselecting an old image is not a
rollback receipt.

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
coordinate sources do not exist. TIN-3768 proposal
`d96b78cd-368a-46d8-b961-9b29b93e1f88` supplies a coherent replacement, but
review `fde41451-c2ae-4213-93a7-dbeefe226241` explicitly keeps that coordinate
and custody shape pending operator ratification. This GFTB spec records the
requirements and the hold; it does not promote the proposal or add another
TenantOverlay field, registry, writer, or projection protocol.

The ratified envelope requirements are:

- `Core.dhall` stays opaque: TenantOverlay carries the Option-E-only
  `credentialIdentityKey : Natural`;
- declared `CredentialProjection` is separate from verifier-owned
  `CredentialProjectionVerification`;
- controller Go owns a closed authority type rather than payload bytes or an
  unstructured command;
- projection is Ring 1 and the first accepted apply, with GF self-dogfood before
  MMS or GFTB activation; and
- GF-Q17 is the required merge-blocking typed act for the new surface; source
  green is not runtime projection evidence.

The source-held coordinate proposal, which must be explicitly ratified or
superseded before implementation, is:

- stable targets come from a protected-main tenant-owner
  `OwnerInstallation/v2` carried by the authenticated overlay release. It binds
  the exact namespace and cluster authority, Secret object identity,
  private-image audience, writer-scope/quota source digests, and opaque Core
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
The controller sees only opaque identity/generation keys and verifier-owned,
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
   verifier. A normal cold Pod start is application execution and does not count
   as projection proof.

Rotation may revoke an old generation only after a non-executing cold-pull proof
covers every accepted private digest in every exact target. Until the coordinate
and custody design is ratified, GF-Q17 is defined with its rejection cases, the
typed operand and scoped executor exist, initial-bootstrap quarantine/resume is
proved, and rollback plus non-executing cold-pull controls pass, a private-image
GFTB activation must refuse.

## 5. Acceptance oracle

One release `S` is accepted as converged only when independently sourced
evidence proves all of the following:

| ID | Required fact | Independent source |
|---|---|---|
| O1 | `S` is the reviewed protected source revision | site repository |
| O2 | GF-I09 binds `S` to immutable image/release coordinates | protected producer receipt |
| O3 | materialization and saved plan bind the exact release and pre-state | GFTB plan receipt |
| O4 | #5 accepted that exact plan under current policy/identity/nonce/lease | controller decision receipt |
| O5 | the protected apply identity executed that exact saved plan | apply result receipt |
| O6 | the registry independently serves the bound image digest | authenticated registry read |
| O7 | live state carries the operation marker and caught-up generation with replicas greater than zero | cluster readback |
| O8 | the protected served origin returns content built from `S` | credentialed served-content probe |

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

Before the first production acceptance, mutation-proven negative controls must
show the chain refuses or fails on:

- unknown/mutable release coordinates and a bad digest;
- stale, expired, or replayed nonce/lease;
- changed pre-state or a mismatched saved plan;
- absent private-image projection when one is required;
- apply failure and served-content mismatch;
- rollback evidence that does not bind the failed result and fresh pre-state.

Each control is restored and the same oracle must then return green. A check
whose red path has not been observed is not acceptance evidence.

## 6. In-place transition

The transition never runs two production mutation authorities.

1. **Close typed prerequisites.** Land the no-Flux refit on #5, the protected
   three-member operand union, the create-only publisher inside #55, compatible
   #55/#56 verifier/executor interfaces, the GFTB GF-I09 producer, and the
   operator-ratified TIN-3768 coordinate/custody shape. Reconstruct #55/#56 from
   current protected source while preserving the short-lived TokenRequest path;
   do not revive the held static plan kubeconfig. Source green is not runtime
   acceptance.
2. **Refit tests and contracts in place.** Extend existing validation families
   with fixtures for release, plan, decision, terminal result, replay, refusal,
   served-content, and rollback. Every new validator names its claim and
   retirement trigger in the same change.
3. **Plan-only rehearsal.** Run the exact GFTB path with mutation disabled;
   independently verify materialization, pre-state, saved plan, controller
   refusal/acceptance semantics, and receipts. This is not a shadow controller
   or second workflow.
4. **Governed canary.** After the self-dogfood and MMS prerequisite proofs,
   execute one accepted GFTB transaction through the protected identity and
   require O1-O8 plus negative controls.
5. **Rollback proof.** Exercise and externally observe the retained prior
   release through a fresh accepted rollback transaction, then reconverge.
6. **Retire the bespoke authority.** Only after parity and rollback evidence,
   remove producer `repository_dispatch`, bespoke signal credentials and
   payload, routine manual apply, inline digest-resolution authority, and any
   duplicate policy gates.
7. **Bound observational audit.** The existing scheduled drift surface may
   remain only as authenticated, report-only diagnostics. It never accepts
   intent, schedules convergence, mutates, or substitutes for the edge-triggered
   attempt/outcome/served receipts. Remove wording that makes it a standing
   controller or product liveness authority.

## 7. Existing surfaces and retirement triggers

| Existing surface | Disposition | Retirement trigger |
|---|---|---|
| site `container-ghcr.yml` publish logic | retain build/publication, make GF-I09 the release authority | authenticated GFTB GF-I09 producer proof |
| producer `signal-cd` / `repository_dispatch` | remove | one governed production transaction, negative controls, rollback, and reconvergence all have terminal receipts |
| infra `web-stack.yml` | refit in place as the GFTB protected executor; do not clone it | accepted controller/executor contract and protected runtime proof |
| manual `workflow_dispatch` steady-state apply | retire as product mechanism | governed rollback is exercised and externally observed |
| `Justfile` workload validation/apply entrypoints | retain as GFTB-owned verbs, split by plan/apply authority as needed | replaced only by a separately ratified GFTB owner-overlay interface |
| `/health` probe | retain for liveness only | never promoted to served-content oracle |
| `k8s-stack-drift.yml` | retain/refit only as observational diagnostics; never a convergence loop or mutation trigger | delete if it duplicates the immutable terminal receipt/readback claim |
| this spec | retire into an operator runbook and durable interface docs | #104's design is implemented, production/rollback receipts are accepted, and no mutable status remains here |

Removing a superseded surface and its false documentation happens in the same
change that activates its replacement. No cleanup is deferred after the old
claim becomes false.

## 8. Release gates

The following are gates, not workarounds:

- owner-overlay-controller #5 must have a landed and adjudicated no-Flux
  source refit, governed installation, and live refusal/acceptance receipts;
- the central chain must have the protected exact-request publisher/event
  contract identified by `e0e74eb9-44bf-4f2f-aed0-52fa78395e65`, implemented
  as a separate create-only job inside #55. It exports canonical name and
  expected digest only; the exact-name reader verifies the object and emits UID
  plus generation. #55/#56 do not currently create or advance the request;
- tinyland-infra #55/#56 are held self-dogfood reference carriers whose current
  heads are incompatible with the RING-0 union, not deployed GFTB execution
  authority. Any refit must preserve protected main's
  `HONEY_ARC_PLAN_TOKEN_MINTER_KUBECONFIG` TokenRequest acquisition and must not
  revive the stored `HONEY_ARC_PLAN_KUBECONFIG` path;
- GFTB does not yet have the authenticated GF-I09 producer and closed
  owner-overlay adapter described here;
- TIN-3768's ratified projection-first/Core envelope must be joined by an
  explicit operator carrier for the currently proposed signed
  `OwnerInstallation/v2` / expiring `OwnerOverlayInstance/v1` coordinates and
  executor-local custody. Initial-bootstrap quarantine/resume and non-executing
  cold-pull proof must land on the GF/controller carriers rather than being
  reimplemented here;
- protected plan/apply identities and terminal GFTB receipt publication require
  reviewed source and runtime proof;
- a credentialed served-content probe is required; constant `/health` cannot
  substitute;
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
