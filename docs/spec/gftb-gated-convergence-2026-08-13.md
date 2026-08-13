# SPEC — GFTB convergence through the sole GF-gated owner-controller chain

> **STATUS: DRAFT, SOURCE-ONLY, HELD.** This document replaces the superseded
> shared-workflow design previously carried by this branch. It authorizes no
> workflow dispatch, credential operation, plan, apply, cluster or DNS change,
> production activation, ready-for-review transition, or merge.

- **Owning ticket:** TIN-2611
- **Source carrier:** Great-Falls-Tool-Bus/great-falls-tool-bus-infra #104
- **Controller carrier:** tinyland-inc/owner-overlay-controller #5
- **Reference executor carriers:** tinyland-inc/tinyland-infra #55 and #56
- **Binding architecture rulings:** TIN-2609 comment
  `a498b0ec-57f2-4a7a-b01b-3dc2acbdc366` and TIN-3578 comment
  `70364081-24a6-4d86-8306-c8fa4ccbc688`
- **Executable edge audit:** TIN-2609 comment
  `e0e74eb9-44bf-4f2f-aed0-52fa78395e65`
- **Enrolment/controller MVP ruling:** TIN-3768 comment
  `27a1616e-b8d8-4560-81d6-d1dbf6fe7145`, grounded by correction
  `48be6e96-86a8-470a-9db6-f175f58202b8`. The typed lane owns the keystone
  projection shape; its exact stable and instance-scoped target source remains
  pending rather than inferred from a nonexistent registry field.

This is a design contract, not a second mutable status surface. Dated evidence
below is retained only where it explains a required invariant. Current
activation state must be read from the named ticket and PR carriers.

## 0. Decision

GFTB converges through the estate's existing receipt-driven, GF-gated model:

```text
reviewed site source
  -> immutable image + authenticated GF-I09 application release
  -> owner-overlay-controller #5 request gate (default refusal)
  -> GFTB owner-overlay protected materialize/check/plan
  -> owner-overlay-controller #5: exact-plan Accept | Refuse
  -> separate protected apply identity
  -> observe/serve/rollback
  -> immutable terminal receipts
```

The execution is edge-triggered by immutable accepted intent. Each accepted
decision digest is consumed once by the protected executor and terminates in
receipts or rollback. There is no standing convergence or drift loop. Periodic
diagnostics, if retained, are observational only and carry no decision, plan,
apply, or lifecycle authority.

This diagram is the required chain, not a claim that its initiating edge
exists. The current #55 relay GETs an already-existing request on protected
main push; #56 consumes a supplied request; and #5 does not install its sample
request. The GF/controller chain must still land the protected operand
publication/event contract that authors the exact request generation and
triggers the corresponding protected plan run. GFTB neither owns that central
publisher nor substitutes a manual dispatch or hand-created request.

The design contains:

- one decision authority: owner-overlay-controller #5;
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
overlay.

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
source/ref/tree/release digests, request generation and UID, nonce/lease
semantics, and the corresponding protected plan run. Publishing a request must
reliably initiate that run without a routine manual click, runtime Git clone,
or second controller/workflow/backend.

This is central GF/controller-chain work. The GFTB producer supplies its
authenticated release and owner-overlay coordinates; it does not hand-create
the Kubernetes request or introduce a tenant-specific dispatch authority.

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

The owner overlay supplies a closed adapter and exact path scope. The plan
receipt binds:

- request and release digests;
- tenant, environment, policy digest, controller identity, nonce, and lease
  epoch/expiry;
- exact materialized descriptor, payload, and owner-overlay root digests;
- pre-state fingerprint and backend identity;
- saved-plan artifact digest and machine-readable change summary;
- plan identity and protected workflow run.

The saved plan is immutable and single-use. An apply must refuse if the plan,
pre-state, decision, nonce, lease, policy, or identity no longer matches.

### 3.3 Controller decision

Controller #5 validates the exact request-bound materialization and plan receipt and emits
one closed decision:

- `Accept` binds the only saved plan that the apply identity may execute; or
- `Refuse` carries a typed reason and authorizes no mutation.

Missing evidence, expiry, replay, unknown fields, digest mismatch, unexpected
path, changed pre-state, unsafe plan semantics, or unproved credential
projection fail closed. A newer request does not silently supersede an
in-flight accepted transaction; lease and nonce rules serialize authority.

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

Attempt, refusal, outcome, served, and rollback receipts are append-only. A
terminal failure is evidence; it is never converted to green by skipping
downstream jobs.

## 4. Pull-credential projection

TIN-3768 comment `27a1616e-b8d8-4560-81d6-d1dbf6fe7145` makes Secret
projection the controller's first `Accept`-consuming apply and owns its exact
typed design. This GFTB spec consumes that design; it does not add another
TenantOverlay field, registry, writer, or projection protocol.

The ratified keystone shape is:

- `Core.dhall` stays opaque: TenantOverlay carries the Option-E-only
  `credentialIdentityKey : Natural`;
- declared `CredentialProjection` is separate from verifier-owned
  `CredentialProjectionVerification`;
- controller Go owns a closed `RegistryPullAuthority` mirroring
  `WorkerRouteAuthority`;
- `tenantProjectionActivates` binds projection to an `Accept` for the same
  tenant and refuses cross-tenant or `Refuse` cases; and
- GF-Q17 is the merge-blocking typed act for the new surface.

The proposed namespace derivation is not an implementable source contract yet.
Protected GF source has no registry `runtime_namespaces` field, and
`tofu_plan_secret_read_namespaces` owns plan-identity `secrets:get` RBAC rather
than projection-write targets; it also excludes ephemeral previews. The
GF/controller typed-surface lane must ratify the source for exact stable and
instance-scoped projection coordinates, how preview instances enter it, and
how it remains distinct from plan-read RBAC. GFTB contributes those
requirements and consumes the resulting immutable decision; it does not invent
a schema or independently implement a competing shape.

The operational boundary remains:

- `converge-agent` is public and needs no carrier pull Secret; controller and
  `gf-reapi-cell` remain private on the existing infra projection path;
- a GFTB application image follows its declared visibility; a private image
  requires accepted projection evidence, while a public image does not
  fabricate that dependency;
- the first proof is GF self-dogfood, before MMS or GFTB activation;
- the protected subordinate executor consumes the exact accepted projection
  once under scoped authority and reports object/version/hash evidence;
- no interim cluster-admin workflow or second apply authority is admitted;
- Git, OCI operands, logs, plans, and receipts contain no dockerconfigjson
  payload bytes; and
- rotation retains current and previous generations until a cold Pod proves
  every accepted private digest can be pulled in every exact target, then
  revokes the old generation.

Until GF-Q17, the typed operand, scoped executor, custody, rotation, rollback,
and cold-pull proof exist, a private-image GFTB activation must refuse.

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
   request-publication/event contract, the governed executor interfaces, the
   GFTB GF-I09 producer, and the TIN-3768 typed projection shape. Source green
   is not runtime acceptance.
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
  contract identified by `e0e74eb9-44bf-4f2f-aed0-52fa78395e65`; #55/#56 do
  not currently create or advance the request;
- tinyland-infra #55/#56 are held self-dogfood reference carriers, not deployed
  GFTB execution authority;
- GFTB does not yet have the authenticated GF-I09 producer and closed
  owner-overlay adapter described here;
- TIN-3768's ratified GF-Q17/typed projection operand, exact stable/instance
  coordinate source, and cold-pull proof must land on the GF/controller
  carriers rather than being invented here;
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
- TIN-3578 — executable GF-gated production-convergence contract
- TIN-3768 — first-class pull-credential projection
- TIN-3270 — privileged dispatch/credential trust boundary
- TIN-3457 — mutation-proven assertions
- Great-Falls-Tool-Bus/great-falls-tool-bus-infra #104 — this held source unit
- tinyland-inc/owner-overlay-controller #5 — sole decision controller
- tinyland-inc/tinyland-infra #55/#56 — reference protected executor/adapter
- tinyland-inc/GloriousFlywheel #1482 — held GF-I09 proof/publication seam
