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
- **Credential-projection carrier:** TIN-3768, especially comments
  `dc5ac98f-ecf2-4ddf-9c0a-d288c2cfd722`,
  `4b1f75ab-01c0-48cf-9efc-3b8bb019cc55`, and
  `040b9054-79e5-443d-acd9-fcb0421f8428`

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

The execution is edge-triggered by immutable accepted intent. Scheduled
automation is authenticated, report-only, and fail-closed drift/readback; it
does not mutate and is not a pull reconciler.

The design contains:

- one decision authority: owner-overlay-controller #5;
- one tenant state owner: the GFTB owner overlay;
- one protected executor chain owned by that overlay;
- one immutable evidence graph binding release, decision, plan, result, served
  state, and rollback.

It contains no Flux, Argo CD, source-controller CRDs, shell/CronJob lifecycle
controller, shared multi-tenant apply workflow, second backend, runtime Git
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
shared apply module, or dual production mutation path.

The existing public operator-surface rule remains: workflows call reviewed
`Justfile` recipes; privileged mutation is not copied inline into workflow or
documentation.

## 3. Required protocol

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

TIN-3768 makes private-image pull projection the controller's first governed
operand, but the typed TenantOverlay/owner-installation field is not yet
landed. This spec records the required boundary and does not invent that field.

- Projection is required only for a release whose declared image audience is
  private. The public `converge-agent` carrier does not require a pull Secret.
- Exact cluster authority, namespace, object name, opaque credential reference,
  and private-image audience come from signed TenantOverlay/owner-installation
  data. They are never inferred from GF consumer/spoke registries, runner
  classes, labels, namespace globs, or repository names.
- GF-I09 carries no credential bytes and performs no projection.
- An accepted #5 decision emits immutable projection intent. The existing
  protected subordinate-executor pattern performs create-if-absent projection
  under a scoped identity and reports exact object/version/hash evidence.
- Git, OCI operands, logs, plans, and receipts contain no dockerconfigjson
  payload bytes.
- Rotation retains current and previous generations until a cold Pod proves
  every accepted private digest can be pulled in every exact target. Only then
  may the old generation be revoked.
- Dynamic namespaces enter the target inventory only through their own
  accepted instance decision.

Until the typed surface, scoped executor, custody, rotation, rollback, and
cold-pull proof exist, a private-image GFTB activation must refuse. If the GFTB
application image is declared public, the release records that fact and no
credential dependency is fabricated.

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

1. **Close typed prerequisites.** Land the no-Flux refit on #5, the governed
   executor interfaces, the GFTB GF-I09 producer, and any required TIN-3768
   TenantOverlay projection shape. Source green is not runtime acceptance.
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
7. **Complete continuous readback.** Refit the existing scheduled drift surface
   as authenticated report-only, fail-closed readback bound to the same
   accepted desired state. It may alert/refuse future work; it never mutates.

## 7. Existing surfaces and retirement triggers

| Existing surface | Disposition | Retirement trigger |
|---|---|---|
| site `container-ghcr.yml` publish logic | retain build/publication, make GF-I09 the release authority | authenticated GFTB GF-I09 producer proof |
| producer `signal-cd` / `repository_dispatch` | remove | one governed production transaction, negative controls, rollback, and reconvergence all have terminal receipts |
| infra `web-stack.yml` | refit in place as the GFTB protected executor; do not clone it | accepted controller/executor contract and protected runtime proof |
| manual `workflow_dispatch` steady-state apply | retire as product mechanism | governed rollback is exercised and externally observed |
| `Justfile` workload validation/apply entrypoints | retain as GFTB-owned verbs, split by plan/apply authority as needed | replaced only by a separately ratified GFTB owner-overlay interface |
| `/health` probe | retain for liveness only | never promoted to served-content oracle |
| `k8s-stack-drift.yml` | refit in place to authenticated report-only readback | delete only if the same scheduled claim is enforced by a higher-ranked existing contract |
| this spec | retire into an operator runbook and durable interface docs | #104's design is implemented, production/rollback receipts are accepted, and no mutable status remains here |

Removing a superseded surface and its false documentation happens in the same
change that activates its replacement. No cleanup is deferred after the old
claim becomes false.

## 8. Release gates

The following are gates, not workarounds:

- owner-overlay-controller #5 must have a landed and adjudicated no-Flux
  source refit, governed installation, and live refusal/acceptance receipts;
- tinyland-infra #55/#56 are held self-dogfood reference carriers, not deployed
  GFTB execution authority;
- GFTB does not yet have the authenticated GF-I09 producer and closed
  owner-overlay adapter described here;
- TIN-3768's typed projection operand and exact cold-pull proof are absent;
- protected plan/apply identities and terminal GFTB receipt publication require
  reviewed source and runtime proof;
- a credentialed served-content probe is required; constant `/health` cannot
  substitute;
- refusal, replay/expiry, failure isolation, rollback, and self-dogfood/MMS/GFTB
  canary order remain acceptance gates.

Do not resolve a blocker by adding Flux/Argo, a shared apply workflow, a
shell/CronJob controller, runtime Git, hosted fallback, a second backend,
cluster-admin projection, a manual production path, or a tenant lifecycle
owner outside this repository.

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
