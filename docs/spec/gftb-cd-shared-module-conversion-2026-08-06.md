# SPEC — GFTB two-repo CD chain → shared multi-tenant module

> **STATUS: BLOCKED-ON-MODULE. This is a requirements document, not an
> implementation plan you may execute.** The shared module this spec converts
> onto **does not exist**. Nothing in §3 may begin until §6's blockers clear.
> Do not build a competing module against this document — it is written *for*
> the module author, as the tenant's requirements list.

- **Status:** Blocked (requirements only; no implementation authorized)
- **Date:** 2026-08-06
- **Owning ticket:** TIN-2611 (two-repo CD chain as the optional dynamic-spoke lane)
- **Blocked by:** TIN-2609 (apply-plane ADR — *hard* blocker), TIN-2610 (ADAPTER
  toggle), TIN-2597 / ci-templates #78 (the module itself)
- **Security constraint it must satisfy:** TIN-3270
- **Applied:** **NOTHING.** No workflow, recipe, manifest, cluster object, or
  credential is changed by this document.

## Home note

This lands in `great-falls-tool-bus-infra`, not in the public site repo, for the
same reason ADR `0001-pr-gated-ephemeral-preview-deploys.md` recorded: the
load-bearing half of this conversion is the **apply plane**, and the site repo
pins `owns_gitops_apply=false` / `owns_cloudflare_mutation=false`. Two further
reasons specific to now:

1. The site repo has a live pushed branch `chore/docs-to-private-meta` whose
   head commit is *"Remove all docs from the site repo — they belong in the
   private meta repo."* Landing a spec into `greatfallstoolbus.org/docs/` would
   collide head-on with that in-flight eviction.
2. This document is cross-repo by nature (it specifies both halves of the
   chain). The overlay already owns the receiving half and already carries the
   cross-boundary contract file `k8s/web/secrets.contract.yaml`.

It is filed under `docs/spec/`, **deliberately not `docs/decisions/`**: the
apply-plane shape is TIN-2609's ruling to make. This document must not be read
as pre-empting it. Where the two possible shapes diverge, §2 states the
requirement in shape-neutral terms and flags the divergence.

---

## 0. Scope

**In scope:** the contract GFTB requires from a shared CD module; the order in
which GFTB may migrate onto it; what GFTB keeps regardless; and the oracle that
decides whether the conversion actually worked.

**Out of scope:** designing the module (that is TIN-2597 / ci-templates #78);
ruling the apply-plane shape (TIN-2609); the ADAPTER runtime toggle (TIN-2610).

---

## 1. Baseline — the mechanic as built

Measured against `Great-Falls-Tool-Bus/greatfallstoolbus.org@origin/main`
(`8665544`) and `Great-Falls-Tool-Bus/great-falls-tool-bus-infra@origin/main`
(`1daf862f`) on 2026-08-06. Line numbers are from those trees.

A hand-rolled two-repo "merge-on-green == live" chain. The site repo **signals**;
the overlay **applies**. It has never been factored into anything shared.

| Half | File | Shape |
|---|---|---|
| Producer | `greatfallstoolbus.org/.github/workflows/container-ghcr.yml` | `push:main` → daemonless nix2container build on `tinyland-nix` → `build-push.outputs.published` marker → `signal-cd` job resolves the pushed `@sha256` and POSTs `repository_dispatch` |
| Consumer | `great-falls-tool-bus-infra/.github/workflows/web-stack.yml` | `repository_dispatch: [web-image-published]` → normalize → gates → CI-green gate → dry-run → apply → health, all via `Justfile` recipes |

Load-bearing details a module must preserve or consciously replace:

- The publish marker (`container-ghcr.yml:127-129`) is the **sole** authority
  that a deploy may be signalled; `signal-cd` requires `push` + `refs/heads/main`
  + `result == 'success'` + `published == 'true'` (`:146-150`).
- Digest resolution is ~50 lines of inline bash: registry manifest `HEAD` primary
  (`:178-189`), GH package-versions API fallback (`:190-194`), 5 attempts with
  `sleep 6` (`:197-204`), hard error if unresolvable (`:206-209`).
- Fail-soft on absent `INFRA_CD_DISPATCH_TOKEN` — skip green with a `::notice::`
  (`:165-168`).
- The consumer's `confirm=apply` sentinel is **manual-path only**
  (`web-stack.yml:145-150`); the CD path's authorization is instead the
  cross-repo CI-green gate (`:210-222` → `Justfile:494-...`).
- Every cluster mutation lives in `Justfile` recipes, never inline in the
  workflow (`Justfile:429-464`). This is the public-operator-surface contract
  and it is **not** negotiable (§4.1).

### 1.1 Chassis duplication — measured

TIN-2597 records "copy-pasted 5x". The live count in this overlay, measured by
presence of a protected `environment:` and/or `base64 -d` kubeconfig
materialization:

| Shape | Workflows | Count |
|---|---|---|
| Protected env **and** kubeconfig materialization | `mail-crs.yml`, `list-crs.yml`, `form-crs.yml`, `archive-stack.yml`, `web-stack.yml`, `k8s-stack-drift.yml` | **6** |
| Kubeconfig materialization, no protected env | `deploy-arc-runners.yml` | 1 |
| Protected env, no kubeconfig (Cloudflare/tofu variant) | `edge-plan.yml`, `edge-drift.yml` | 2 |

The **6** is the number that matters: that is the collapse the module has to
earn. Converting `web-stack.yml` alone is not worth the dependency — it is worth
it only if the same chassis absorbs the other five. State that as a module
sizing requirement, not an aspiration.

### 1.2 Current liveness

The chain is real and has fired repeatedly (infra `repository_dispatch` runs
2026-07-07 → 2026-07-26, last `30184443841` success). **But current site `main`
never dispatched:** `container-ghcr` run `31038195902` was **cancelled** at the
build job, so `signal-cd` reports `skipped` — not red. The deployed image lags
site head *and nothing went red about it*. See §5.3(f); this is not a footnote,
it is the single most important failure mode in this document.

Open defect on this exact mechanic: **TIN-2640** — web-stack `repository_dispatch`
applies failing at rollout (~15min).

---

## 2. The contract GFTB requires FROM the shared module

Written for the module author. **MUST** = GFTB cannot convert without it.
**SHOULD** = GFTB will implement it locally if absent, at the cost of keeping
bespoke code. **MUST NOT** = accepting it would be a regression GFTB will
refuse.

### 2.0 Framing requirement — tenancy is data, not a fork

Every literal in §2.1/§2.3 is today hardcoded in GFTB's tree. The module MUST
accept them as typed inputs or a per-tenant descriptor. If a second tenant would
have to *fork the workflow file* to change any of them, the module has failed
its purpose. Precedent already exists inside GFTB for the right shape: `ci.yml`
and `lane-env.yml` are already thin `uses:` wrappers over
`tinyland-inc/ci-templates`, with tenant identity externalized to
`.github/lanes.json`. **Only CD is not.**

> Latent inconsistency to resolve during conversion, not to inherit:
> `lane-env.yml:35` passes `spoke: site-scaffold` while `lanes.json:5` declares
> `greatfallstoolbus`. Whatever descriptor the CD module reads must have exactly
> one spelling of tenant identity.

### 2.1 Producer half — inputs the module MUST accept

| Input | Type | Why (literal it replaces) |
|---|---|---|
| `image_name` | string | `greatfallstoolbus.org` is hardcoded in **four** independent places: `container-ghcr.yml:112, :171, :187, :192` |
| `registry` | string, default `ghcr.io` | `:180` base64-encodes `GITHUB_TOKEN` as a **GHCR-specific** bearer; not portable |
| `image_owner` | string | currently implicit `github.repository_owner` |
| `owner_type` | enum `org`\|`user` | `:192` uses `orgs/${OWNER}/packages/...`; a user-account tenant needs `users/...` and today silently breaks |
| `publish_recipe` | string | `just container-image-publish` (`:126`) |
| `build_runner_class` | string | `tinyland-nix` (`:86`) — see §4.4 |
| `signal_runner_class` | string, default MUST NOT be `ubuntu-latest` for on-prem tenants | `:151` puts a GitHub-hosted dependency inside an otherwise on-prem lane |
| `core_ref` | string | `GF_CORE_REF` (`:56`) — **must be the same input the consumer takes**; see §2.3 |
| `target_repo` | string `owner/name` | `:225` hardcodes `repos/${OWNER}/great-falls-tool-bus-infra/dispatches` **and** assumes site+infra share one owner |
| `event_type` | string | `web-image-published` (`:222`), a bare cross-repo string |
| `deploy_params` | JSON object | today a hardcoded `replicas:"2"` (`:220`) whose own comment justifies it as *"MassageIthaca production shape"* — a different tenant's sizing decision copied in |
| `dispatch_token` | secret | `INFRA_CD_DISPATCH_TOKEN` |

### 2.2 Producer half — behaviours the module MUST guarantee

1. **Content-addressed digest resolution.** Resolve the just-pushed `@sha256`
   with bounded retry and **hard-fail** if unresolvable. A tag MUST NOT be
   dispatched as a substitute. (Preserves `:196-209`.)
2. **Deployment-inert manual path.** `workflow_dispatch` publishes but MUST NOT
   dispatch. Only `push` + default branch + publish-marker deploys. This trigger
   asymmetry is policy-as-code and MUST survive templating.
3. **Publish marker is the sole authority.** A build that did not publish MUST
   NOT be able to signal, regardless of job `result`.
4. **Fail-soft on absent dispatch credential** — skip green with an explanatory
   `::notice::`, never a red main. (TIN-2597 scopes this `HAS_X` idiom as a
   reusable composite; GFTB requires that composite's semantics exactly.)
5. **No shell-source interpolation of externally sourced values.** All such
   values enter via environment or argv. (TIN-3270 acceptance #2 — mandatory.)
6. **A machine-readable dispatch receipt** binding: source repo + workflow path,
   commit SHA, resolved digest, receiver repo, event type, and the dispatching
   identity. (TIN-3270 acceptance #4.) §5 depends on this existing; without it
   the oracle cannot distinguish "did not dispatch" from "dispatched and the
   receiver dropped it".
7. **Registry pluggability.** The GHCR base64-bearer idiom MUST be behind the
   `registry` input, not assumed.

### 2.3 Consumer half — inputs the module MUST accept

| Input | Type | Why |
|---|---|---|
| `stack_dir` | string | `k8s/web/greatfallstoolbus-org-production` (`Justfile:429`) |
| `validate_recipe` / `dry_run_recipe` / `apply_recipe` / `health_recipe` | string | the module MUST delegate; see §4.1 |
| `protected_environment` | string | `web-apply` (`web-stack.yml:106`) |
| `kubeconfig_secret_name` | string | `WEB_APPLY_KUBECONFIG_B64` |
| `accepted_event_type` | string | must match producer `event_type` |
| `allowed_sender_repo` | string | **new requirement** — today the receiver does not verify who dispatched it |
| `ci_green_repo`, `ci_green_workflow` | string | `Justfile:498, 509` hardcode `Great-Falls-Tool-Bus/greatfallstoolbus.org` and the literal filename `ci.yml`. The overlay currently knows the site repo's *workflow filename* — a reverse-direction coupling the module must externalize |
| `core_ref` | string | `web-stack.yml:92` duplicates `GF_CORE_REF` as an **independent literal** from the producer's `:56`. Nothing enforces they stay equal. Collapsing this to one input kills a silent two-repo drift class — this is one of the conversion's real wins, not a nicety |
| `apply_runner_class` | string | `tinyland-nix` (`:99`) |
| `rollout_deadline_seconds`, `ci_green_timeout_seconds` | number | `300s` (`Justfile:463`), `1200s` |

**MUST NOT accept:** Kubernetes object names (Deployment, container, namespace).
Those belong to the tenant's recipes. A module that templates
`set image deployment/<name> <container>=` has reached into tenant territory and
GFTB will not adopt it.

### 2.4 Consumer half — behaviours the module MUST guarantee

1. **Fail-closed on missing apply credential**, before any cluster touch.
   (Preserves `:152-157`.)
2. **Dual-shape normalization** of manual inputs and dispatch payload into one
   parameter set, so a single apply chassis serves both. (Preserves `:109-140`.)
3. **Preserved manual override.** The `confirm=apply` sentinel path MUST survive
   as the rollback/override route to an arbitrary prior digest. Rollback is
   re-dispatch with an earlier digest; there is no CF Pages fallback anymore
   (`web-stack.yml:44-47`). Losing this loses GFTB's only rollback.
4. **Static ordering contract:** validation → authorization → credential
   materialization → network/cluster. Today the CI-green gate (`:210-222`)
   correctly precedes kubeconfig materialization (`:224-232`); the module MUST
   make that ordering *enforced*, not incidental. (TIN-3270: "validation occurs
   before token mint or network access.")
5. **Digest-pin enforcement MUST be an error on the CD path.** Today
   `web-stack.yml:174-177` only emits a `::warning::` for a non-digest-pinned
   image. A mutable tag on an automated path is a supply-chain hole; the module
   MUST make it fatal for `repository_dispatch` while it may stay a warning for
   a deliberate operator `workflow_dispatch`.
6. **Placeholder rejection** (`:168-173`) — the declare-only tree must never
   apply itself.
7. **Sender verification.** The receiver MUST verify the dispatch originated
   from `allowed_sender_repo`. A `repository_dispatch` credential is bearer
   authority; nothing today constrains *which* repo used it.
8. **Never checkout or execute sender-controlled code**, and never trust
   sender-produced artifacts or caches, in the privileged job. (TIN-3270.)
9. **Rollout wait as a deadline loop.** Poll until
   `status.observedGeneration >= metadata.generation` **and**
   `status.readyReplicas >= spec.replicas`, with `spec.replicas >= 1` asserted.
   Demote single-shot `kubectl rollout status` to informational — it benign-reds
   on cold-node image pulls. This is a *carry-forward lesson*, documented at
   `Justfile:463` against run `28769199755` and symptomatic in TIN-2640. A
   module that ships single-shot `rollout status` as the gate reintroduces a
   known-closed defect.
10. **Serialized applies.** `cancel-in-progress: false`; never cancel an
    in-flight apply (`:86-89`).
11. **Apply receipt** binding: accepted event, sender, payload digest, resolved
    cluster state after apply. §5 consumes this.

### 2.5 The payload becomes a versioned contract

Today `web-image-published` is a bare string duplicated across a repo boundary
(`container-ghcr.yml:222` ↔ `web-stack.yml:81`) with **no schema, no version
field, no validator**.

The precedent already exists in the same estate for the *other* dispatch lane:
`greatfallstoolbus.org/scripts/lane-dispatch.py` builds a payload conforming to
`docs/schemas/blahaj-dispatch.schema.json` carrying `"schema_version": 1`, and
production dispatch uses the `tinyland-inc/ci-templates` `lane-dispatch`
composite. The CD payload MUST get the same treatment:

```jsonc
{
  "schema_version": 1,
  "image": "…@sha256:…",   // digest-pinned; tag form MUST be rejected
  "sha": "…",              // producing commit
  "source_repo": "…",      // for §2.4(7) sender verification
  "deploy_params": { "replicas": "2" }
}
```

Plus **a contract test asserting producer and consumer agree** — run in both
repos' CI, failing if either side drifts. Per the estate's standing rule
(TIN-3457) that test MUST be mutation-proven: break the payload, observe red,
restore. An assertion that cannot fail is worse than no assertion.

### 2.6 Explicitly OUT of the module's scope

The module MUST NOT absorb: Kubernetes manifests; the `Justfile` recipes; SA/RBAC
provisioning; namespace creation; runner placement policy; GF core pinning
policy; cache/RBE configuration. See §4.

---

## 3. Migration sequence — receiver before deletion

**Ordering law: the new path must be live and proven before any bespoke
machinery is removed.** GFTB has exactly one production origin and no CF Pages
fallback; a gap between paths is a site outage.

Each step names its exit gate. **A step may not begin until the previous step's
gate is satisfied by evidence, not by expectation.**

- **G0 — Unblock.** TIN-2609 ruled and the ADR updated; module published and
  version-pinnable. *Gate:* a tagged module ref exists that satisfies §2.
  *Until G0, steps 1-8 are not authorized.*

- **G1 — Consumer shadow.** Add the templated apply chassis to the overlay as a
  **new, separately-named workflow** accepting a distinct event type
  (`web-image-published-v2`), targeting a **scratch namespace**, not
  `greatfallstoolbus-org-production`. `web-stack.yml` is untouched and remains
  the only production path. *Gate:* the shadow lane applies a known digest to
  the scratch namespace and its health gate passes — **and has been shown to go
  red** on a deliberately bad digest (§5.3).

- **G2 — Producer dual-signal.** `container-ghcr.yml` emits the **v2 payload in
  addition to** the existing one. Both dispatches fire. The bespoke path still
  drives production; the templated path still drives scratch. *Gate:* the
  contract test (§2.5) is green in both repos, and the two payloads are proven
  to describe the identical digest for the same commit.

- **G3 — Receiver promotion.** Point the templated lane at
  `greatfallstoolbus-org-production` while `web-stack.yml` is disarmed by
  **removing `repository_dispatch` from its trigger set only** — its
  `workflow_dispatch` manual/rollback path stays fully armed. Production is now
  driven by the module; rollback is still the old, known-good manual route.
  *Gate:* §5's full oracle passes on a real commit — plus the negative control.

- **G4 — Soak.** No fewer than **three** independent production deploys through
  the templated path, each with a complete receipt chain. One of them MUST be a
  rollback exercised through the preserved manual path, proving §2.4(3) survived
  templating. *Gate:* three green receipt chains + one proven rollback.

- **G5 — Producer cutover.** Remove the bespoke `signal-cd` job body, leaving
  only the `uses:` wrapper. *Gate:* one further green deploy after removal.

- **G6 — Consumer cutover.** Reduce `web-stack.yml` to a `uses:` + `with:`
  block. **This is the first step that deletes production apply logic.** *Gate:*
  one further green deploy, and the manual rollback path re-proven **after** the
  reduction — not carried over from G4.

- **G7 — Fleet collapse.** Only now migrate `mail-crs.yml`, `list-crs.yml`,
  `form-crs.yml`, `archive-stack.yml`, `k8s-stack-drift.yml` onto the same
  chassis (§1.1). Each is its own gated step with its own soak; they are not a
  batch. *Gate:* per-stack.

- **G8 — Bespoke deletion.** Delete the superseded inline digest-resolution
  bash, the duplicated `GF_CORE_REF` literal, and the dead chassis copies.
  *Nothing is deleted before this step.*

**Rollback posture at every gate:** the previous step's path remains present and
armed until the next step's gate passes. The single point of no return is G6;
it is therefore the step that requires the freshly re-proven rollback.

**Ordering note for the module author:** G1→G3 is why §2.3 requires
`accepted_event_type` and `stack_dir` as *inputs*. A module that hardcodes its
event type or assumes one stack per repo makes the shadow phase impossible, and
therefore makes a safe conversion impossible. **The shadow phase is a hard
requirement on the module's shape, not a GFTB implementation detail.**

---

## 4. What stays GFTB-owned regardless

Non-negotiable. A module proposing to absorb any of these will be refused.

### 4.1 The cluster mutation surface

`k8s/web/`, the `Justfile` apply recipes, `scripts/validate-web-stack.sh`, and
the declare-only parked tree (`replicas:0` + placeholder image + no namespace).
The public-operator-surface contract — *workflows call `Justfile` recipes, never
raw `kubectl`* (`web-stack.yml:33-36`) — is a GFTB invariant. The module
supplies the chassis; the tenant supplies the verbs.

This also protects a least-privilege design the module must not flatten:
replicas are patched on the Deployment resource rather than via the `scale`
subresource specifically so the namespace-scoped SA needs only a
patch-Deployment grant (`Justfile:457-462`).

### 4.2 The apply credential and its RBAC

The `web-apply` namespace-scoped ServiceAccount, its kubeconfig, the protected
environment, and namespace provisioning are operator ceremonies
(`k8s/web/secrets.contract.yaml`). The module consumes a secret *by name*; it
never mints, scopes, or provisions one.

### 4.3 The edge/DNS apply plane

`tofu/stacks/edge*`, route intent, the cloudflared public-hostname route, the
apex/www flip. This overlay's `AGENTS.md` states it directly: **"never re-home
GFTB apply-plane content into `tinyland-inc/blahaj`."**

This constrains the module's *shape*, not just its scope. Blahaj's charter
("What Belongs In Blahaj / What Does Not", ratified TIN-3066, applied in the
MassageIthaca substrate eviction PR #1255 — 146 paths removed) lists *app deploy
workflows* and *app PR-environment lanes* as explicitly not belonging in blahaj.
`k8s/web/secrets.contract.yaml:56` correspondingly records blahaj as
*"layer 1 (substrate; logically replaceable, 'never a required dependency')"*.

> **This is the live tension TIN-2609 must rule.** The scaffold ADR
> (`dynamic-spoke-adapter-mode.md` + the comment-only stub
> `greatfallstoolbus.org/tofu/dynamic-spoke-deploy-target.tf:14-16`) says a
> dynamic spoke will *"request (NOT own) a blue/green server deployment from the
> Blahaj GitOps receiver … The spoke only emits a dispatch payload."* GFTB, the
> only live consumer, built the opposite. The blahaj charter points away from
> the blahaj-receiver shape — **but the ruling is the operator's on TIN-2609,
> and this document does not make it.** What this document *does* assert is
> narrower and shape-independent: whichever receiver is ruled, GFTB's edge/DNS
> apply plane stays in this overlay.

### 4.4 ARC runner policy and placement

Runner class, capacity posture (`nix_max_runners = 4`, no warm pool, docker/dind
off), and org-scoped registration are GFTB/GF policy (`AGENTS.md`;
`deploy-arc-runners.yml`). The module accepts a runner class as an **input** and
expresses no opinion about it.

Live and relevant: GF PR **#1381** (open, unmerged) proposes replacing the
shared `tinyland-nix` runner's `nodeSelector {kubernetes.io/hostname: honey}`
with a `hostname In [honey, bumble]` affinity after the 2026-08-06 incident in
which a phantom DiskPressure taint on honey froze the entire shared Nix CI fleet.
On `GloriousFlywheel@origin/main` the fix has **not** landed —
`shared_nix_runner_affinity` does not exist and
`tofu/stacks/arc-runners/honey.tfvars:226-227` still pins the hostname.
**TIN-3417** (Urgent, Backlog) records that the imagefs churn is the
`tinyland-nix` family itself and refutes bumble as a capacity answer
(~15Gi RAM / 4 CPU vs a single heavy runner's ~9-10GiB working set) —
bumble is degraded-mode continuity only.

Because both halves of GFTB's CD chain run on `tinyland-nix`
(`container-ghcr.yml:86`, `web-stack.yml:99`), the converted lane inherits
whatever placement contract lands. **The module must not encode placement**, or
it will have to be re-cut when TIN-3417 resolves.

### 4.5 Bazel/RBE executor proof and the GF cache front door

`flywheel-cache-proof.yml` — the org-tenancy OIDC exchange to a `gf-reapi-cell`
profile, the cache-backed Bazel round-trip routed to
`remote_instance_name=org-great-falls-tool-bus`, and the enforcing posture
established by the TIN-2364 soak — is **GloriousFlywheel's** front door,
consumed by GFTB. Endpoint authority is fleet-runtime environment
(`BAZEL_REMOTE_CACHE` from cluster DNS; `GF_REAPI_TOKEN_EXCHANGE_ENDPOINT` from
the fleet profile), deliberately **never in YAML**.

Two consequences the module author must respect:

- The module MUST NOT template, wrap, or take inputs for cache/executor
  endpoints. Doing so would move endpoint authority back into YAML and undo the
  design.
- The `push-cache: 'false'` posture on non-trusted lanes
  (`container-ghcr.yml:117-120`) is a trust decision: cache-*write* is a trusted
  default-branch concern. If the module exposes cache behaviour at all, it MUST
  default to read-only and MUST NOT silently enable writes on a lane that can be
  reached from a pull request.

Also GF-owned and not templatable: `container-image-and-push` is blocked at the
GF manifest layer from remote execution (`container-ghcr.yml:26-29`). The module
must not assume image push is RBE-eligible.

---

## 5. The acceptance oracle

### 5.1 What must be true

The conversion worked **iff**, for a single commit `S` pushed to site `main`
through the templated path, all six facts hold **and are sourced independently**:

| # | Fact | Source (must be distinct) |
|---|---|---|
| O1 | `S` is the head of site `main` | site repo git |
| O2 | The producer run for `S` resolved digest `D` and dispatched | producer receipt (§2.2.6) |
| O3 | A consumer run was triggered *by that dispatch* and applied `D` | consumer receipt (§2.4.11) |
| O4 | `D` is the digest the **registry** serves for `S`'s image | direct registry probe with a `read:packages` credential — **not** the payload echoed back |
| O5 | The live Deployment's container image `== D`, `observedGeneration >= generation`, `readyReplicas == spec.replicas`, `spec.replicas >= 1` | cluster read |
| O6 | The **served origin** returns content built from `S` | authenticated fetch through the tunnel, asserting the `__COMMIT_SHORT__` build stamp (`vite.config.ts:117`) matches `S` |

O4 and O6 are the ones that make this an oracle rather than a tautology. Without
them the check is "the payload says `D`, and the thing we set from the payload
says `D`."

### 5.2 The two capabilities this oracle needs that GFTB does not have

**Stated as blockers, not as assumptions.**

1. **O4 requires a `read:packages` credential.** The workstation-side probe
   currently cannot distinguish absence from denial: GHCR answers **403 on the
   tag path but 404 on the digest path** for the same unauthorized token, so a
   404-by-digest is exactly what an unreadable-but-existing manifest produces.
   Until that credential exists, O4 is unverifiable off-CI.

2. **O6 has no credentialed content probe today, and the two obvious substitutes
   are both false-green generators:**

   - **`/health` cannot serve as a content oracle.** `src/routes/health/+server.ts`
     is `prerender = true` and returns a constant `{"status":"ok"}`. It does not
     read the build stamp, render a route, or touch an asset. A passing
     readinessProbe therefore proves *"a process is listening and returning a
     constant"* — it does **not** prove the new image serves the new site. This
     is precisely the TIN-2224 class (omit the `optimize-images` guard and the
     hero 404s while `/health` stays 200).
   - **The public edge probe cannot see the origin.** `production-health-probe.sh`
     states it outright: an unauthenticated Access login redirect *"cannot prove
     the protected origin because Access authenticates a request before
     forwarding it there."*
   - **An in-namespace curl is blocked by design.** The NetworkPolicy admits
     `:3000` only from the cloudflared tunnel and Prometheus (`Justfile:469`).

   So O6 requires a **new** capability: an Access service-token fetch through the
   tunnel asserting the build stamp. **Do not accept the conversion on O1–O5
   alone** — that set is satisfiable by a deploy that serves a blank site.

### 5.3 How the oracle can fail

Each of these is a way to get a **green that means nothing**. The oracle is not
adopted until each has a named defence.

**(a) Payload tautology.** The consumer echoes `client_payload.image` into its
summary and the check compares payload to payload. *Defence:* O5 reads the
cluster and O4 reads the registry; neither may accept the payload as a source.

**(b) Reproducible-digest blindness — the subtle one.** The image is built with
nix2container, which is reproducible by design. A content-neutral commit can
produce **the same digest** as the previous deploy. Then "cluster image == D"
passes *even if nothing was applied at all*. This failure mode is invisible to
O5's image comparison. *Defence:* require `metadata.generation` to have advanced
and `observedGeneration` to have caught up to the new value, or carry `S` in a
pod-template annotation so a new commit always produces a new template hash.
**A digest-equality-only oracle is unfailable here, and an unfailable assertion
is the estate's most common defect class (TIN-3457).**

**(c) `readyReplicas` read too early.** Sampled immediately after the patch, it
reports the *old* ReplicaSet's ready count. *Defence:* gate on
`observedGeneration >= generation` before reading readiness — this is the O5
ordering, and it is also the real fix for TIN-2640 / the `Justfile:463` benign
red.

**(d) `0/0` passes.** `readyReplicas == spec.replicas` is trivially true at
`spec.replicas == 0`, which is exactly the parked declare-only state. The
current `web-stack-health` recipe computes `ready="${ready:-0}"` and compares to
`desired` — at `desired=0` this returns success. *Defence:* assert
`spec.replicas >= 1` explicitly (already required in O5).

**(e) CI-green gate matching the wrong run.** `Justfile:509` queries
`workflows/ci.yml/runs?head_sha=…&event=push&per_page=1` and takes
`workflow_runs[0]` — "most recent", not "the run that gated this commit". A
re-run, or a second push run for the same head SHA, can satisfy the gate with a
different execution than the one intended. *Defence:* bind the receipt to the
run **ID**, and assert that ID is the one whose conclusion was read.

**(f) Skipped ≠ green, and skipped ≠ red.** This is live right now: site `main`
`8665544` never dispatched because `container-ghcr` run `31038195902` was
**cancelled**, so `signal-cd` reported `skipped`. Nothing went red; the deployed
image simply lags head. The `INFRA_CD_DISPATCH_TOKEN` fail-soft (§2.2.4) has the
same shape by design. *Defence:* **the oracle must assert a dispatch receipt
positively exists (O2). It must never infer success from the absence of a
failure.** Any conversion sign-off that reads "no red runs" is invalid.

**(g) The oracle has never been shown to fail.** *Defence:* before any green is
trusted, run the negative control — dispatch a known-bad digest to the scratch
namespace at G1 and **observe the oracle go red**. Restore, re-run, observe
green. Per TIN-3457 this is mandatory, not optional. An oracle whose red path is
unproven is not evidence.

**(h) Probe blindness.** The verification tooling can fail in ways unrelated to
the thing being verified — §5.2's GHCR 403-vs-404 is a worked example from this
same conversion. *Defence:* every probe in the oracle carries a positive control
proving it can observe a true positive, and a negative control proving it can
observe a true negative, before its verdict is admissible.

### 5.4 False reds (do not accept these as conversion failures)

- Cold-node image pull exceeding the rollout deadline — documented benign race
  (`Justfile:463`, run `28769199755`); the deadline loop in §2.4(9) is the fix.
- Tailnet egress flap on the SA kubeconfig's `100.x:6443` endpoint
  (`web-stack.yml:234-240`).
- GHCR digest not yet queryable in the first seconds after push — already
  retried five times upstream.

---

## 6. Blockers — none of which this document clears

1. **TIN-2609 — apply-plane ADR unruled. Hard blocker.** The scaffold ADR and
   the only live consumer describe different receivers (§4.3). A shared module
   cannot be designed against two receivers.
2. **TIN-2597 / ci-templates #78 — the module does not exist.** Verified
   2026-08-06: `tinyland-inc/ci-templates@origin/main` carries ten reusable
   workflows (`js-bazel-package`, `npm-publish`, `spoke-ci`,
   `spoke-ci-restricted`, `spoke-deploy-cloudflare-pages`, `spoke-lane-env`,
   `spoke-lane-env-restricted`, `spoke-lane-ttl-reap`, `spoke-public-preview`,
   `spoke-pulse-ingest`) — **none is a gitops/k8s-stack apply lane**. Issues #78
   and #79 remain **open**; TIN-2597 is **Backlog, never started**.
3. **TIN-2610 — ADAPTER dual-mode toggle.** TIN-2611 is `blockedBy` both this
   and TIN-2609.
4. **TIN-3270 — dispatch-credential trust boundary unresolved.** ci-templates
   PRs **#99** (TIN-3270 containment) and **#100** (TIN-2406 GitOps binding-mode
   manifest schema) are both **draft, unmerged**. §2.2(5), §2.4(4), §2.4(7) and
   §2.4(8) are this ticket's requirements landing on the module.
5. **Missing boundary key.** TIN-2609 requires `owns_container_image_production`
   in `docs/schemas/tinyland-repo-manifest.schema.json` — the key that lets a
   repo declare *"I publish the image but do not apply."* Flagged in
   `k8s/web/secrets.contract.yaml`; not yet present.
6. **`read:packages` credential absent** — blocks oracle item O4 (§5.2.1).
7. **No credentialed content probe** — blocks oracle item O6 (§5.2.2). This one
   is GFTB's to build and does not depend on the module.
8. **TIN-2640 open** against the current mechanic. Converting on top of an
   unfixed rollout defect would attribute its symptoms to the module.

---

## 7. Observed drift, recorded not fixed

Two facts contradict documents in this repo. Recorded here for the operator; **no
change is proposed by this spec.**

1. **This overlay is public.** `AGENTS.md` opens *"This repository is the private
   Great-Falls-Tool-Bus (GFTB) organization implementation overlay"* and
   `k8s/web/secrets.contract.yaml` declares
   `private_overlay: … layer: 2 (apply-plane, private)`. The GitHub API reports
   `"visibility": "public"`, confirmed by an unauthenticated probe returning
   HTTP 200 (control: `tinyland-inc/site.scaffold` returns 404 to the same
   unauthenticated probe, proving the probe distinguishes the two states).

   This is not cosmetic for this spec: **it raises the TIN-3270 threat model.**
   The workflows that receive `INFRA_CD_DISPATCH_TOKEN` and materialize
   `WEB_APPLY_KUBECONFIG_B64` sit in a world-readable tree, so the source
   boundary is public even though the secret values are not. Any shared CD
   module GFTB adopts must be safe under *public-caller* assumptions, not
   private-overlay ones. Whether the visibility or the documents are wrong is an
   operator call.

2. **`GF_CORE_REF` is duplicated across repos** as independent literals
   (`container-ghcr.yml:56`, `web-stack.yml:92`) with nothing enforcing
   equality. §2.3 folds this into one module input; until then a lockstep bump
   remains a manual two-repo edit.

---

## References

Read at `origin/main` on 2026-08-06 (site `8665544`, overlay `1daf862f`):

- `greatfallstoolbus.org`: `.github/workflows/container-ghcr.yml`, `ci.yml`,
  `lane-env.yml`, `.github/lanes.json`, `scripts/lane-dispatch.py`,
  `scripts/production-health-probe.sh`, `src/routes/health/+server.ts`,
  `vite.config.ts`, `tofu/dynamic-spoke-deploy-target.tf`,
  `docs/decisions/dynamic-spoke-adapter-mode.md`
- `great-falls-tool-bus-infra`: `.github/workflows/web-stack.yml`,
  `flywheel-cache-proof.yml`, `Justfile`, `k8s/web/secrets.contract.yaml`,
  `AGENTS.md`, `docs/decisions/0001-pr-gated-ephemeral-preview-deploys.md`
- `tinyland-inc/ci-templates`: reusable-workflow inventory, issues #78/#79,
  PRs #99/#100
- `tinyland-inc/GloriousFlywheel`: `tofu/stacks/arc-runners/honey.tfvars`, PR #1381
- `tinyland-inc/blahaj`: `docs/reference/repo-charter.md`
  ("What Belongs In Blahaj / What Does Not")
