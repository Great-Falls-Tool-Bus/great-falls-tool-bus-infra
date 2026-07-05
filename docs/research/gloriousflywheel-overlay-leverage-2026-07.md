# GloriousFlywheel overlay leverage review + GFTB adoption plan (TIN-2545)

Status: **RESEARCH BRIEF + PHASED ADOPTION PLAN, not a decision** (authored
2026-07-05). This document does **not** flip any switch, mint any grant, or
apply any config. It (1) maps the full GloriousFlywheel (GF) substrate feature
set, (2) states where Great-Falls-Tool-Bus (GFTB) sits against it today, (3)
proposes a phased, doctrine-aligned, switchable, public-repo-safe adoption plan,
and (4) files the GF-product gaps found as candidate GF issues. Every posture
claim is grounded in the research packet cited in §6; nothing here is applied.

**Secret/endpoint hygiene:** this doc deliberately carries **no** cluster
hostnames, ports, tokens, GHCR repo paths, or quota literals. The GF substrate's
own doctrine (`pilot-repo-guide`) forbids hard-coding deployment-specific
endpoints in source; a soon-public repo must not carry them at all. Endpoints
are described by role only.

---

## 0. Bottom line up front

- **GF is a substrate, not a library.** GFTB does not `bazel_dep` on
  GloriousFlywheel — no such module exists. GF is a single-hardware, on-prem,
  pooled build backend (Nix cache + Bazel remote cache + a real REAPI executor
  cell + capability-class self-hosted runners + Nix/OCI image build + an
  enrollment front door) that many orgs share over the wire through a
  three-part **consumer latch**: a registry line, an **endpoint-free**
  `.bazelrc.flywheel`, and a server-side `gf.platform` exec-property. The moat
  is a **network boundary**, not a dependency edge.
- **GFTB rides exactly ONE feature today: the cache-first, read-only shared
  cache** (TIN-1997 "Option D"). `ci.yml` passes `flywheel_config: flywheel` +
  `cache_backed: true`; `.bazelrc build:ci-cached` is read-only
  (`--remote_upload_local_results=false`, `--remote_download_minimal`, empty
  `--disk_cache=` in CI so a green proves the **remote** cache). Endpoints live
  in the wrapper/env, never in `.bazelrc`.
- **The gap to full-feature RBE is INTENTIONAL and doctrine-blocked, not
  drift.** GFTB already has a real Bazel target graph (genuine
  `js_run_binary`/`js_test`/vitest targets tagged `flywheel-eligible`) and
  carries the full executor plumbing **dormant** (`.bazelrc.flywheel`
  `flywheel-executor` config, `flywheel-runner-selftest`). It has simply not
  taken the flip — correctly, because it has **proved no target class** and its
  org tenant has **no executor grant**.
- **Doctrine caps GFTB at cache-only until two things happen:** (a) a
  TIN-2288-style cold-start executor **proof** for one of GFTB's own
  flywheel-eligible classes, and (b) a TIN-2299 org-tenant flip to
  `runtime_grants_enabled: true` for `executor-backed` mode. Absent either, a
  `flywheel-executor` flip would **fail-closed at the substrate boundary gate**.
- **TIN-1997 (cache-first read-only default, Done 2026-07-03) is the ratified
  resting posture. TIN-2488 ("remote-only for everything") does NOT supersede
  it** and has no ratified instrument. This plan therefore treats every
  executor step as **opt-in, target-class-scoped, and reversible by one line**,
  and never proposes a "default remote" collapse of the three modes
  (shared-cache-backed / compatibility-local-only / executor-backed, TIN-670).

---

## 1. The full GF feature set (what the substrate actually offers)

GF is organized as 4 layers (`platform-layers.md`): **L1** FOSS core substrate
(Nix cache, Bazel remote cache, the REAPI executor cell, runner images,
K8s+OpenTofu, a SvelteKit operator dashboard, Just/MCP tooling); **L2** forge
adapters + owner-specific implementation overlays (GitHub App installs, tfvars,
backend state, registration anchors — these live in the operator overlays, NOT
the core); **L3** a future managed SaaS control plane; **L4** a legacy
compatibility kit. Enrollment is 4-dimensional: forge scope × operator tenant ×
execution pool × cache/state plane (`enrollment-model.md`).

The concrete capabilities a consumer can lace up to:

### 1a. Cache front door (acceleration only, never authority)
Two surfaces, both explicitly *shared acceleration layers for CI and developer
workflows* and explicitly **not** the source of deployment authority
(`cache-and-state-roles.md`; `runner-and-cache-contracts.md`):
- **Attic multi-tenant Nix binary cache** — an in-cluster substituter for
  cluster/tailnet runners and a public-read HTTPS surface for humans/dev
  machines. Substituter auth is netrc-backed HTTP, not Nix access-tokens.
- **Bazel remote cache** — an S3/RustFS-backed CAS reachable over gRPC from
  in-cluster runners, with a pod-local hot cache.

PRs stay **read-only** for cache writes; broad proofs keep push-cache off while
the storage bucket-index recurrence is open.

### 1b. REAPI executor cells (real remote execution)
`gf-reapi-cell` is an in-house REAPI v2 implementation (all five services,
`instance_name` routing, OIDC/JWT authz, action-cache-writer attestation +
audit, digest verification, metrics) reachable only on a **cluster-internal
gRPC** address. Multi-tenancy is enforced **server-side**: per-tenant
concurrency/blob quotas and an executor-pool admission keyed on the
`gf.platform` exec-property. It runs as a single hardened replica; execution is
**local to the cell** (no distributed worker fleet, no durable worker registry
yet — roadmap pillar 3). A proof envelope can scale-to-zero between runs so it
does not starve the heavy runner lane.

### 1c. tinyland-nix runner boundary (the moat)
Capability-class ARC runner ScaleSets (nix / nix-heavy / dind / kvm / gpu /
docker / operator) route work by **shared capability label**, not by repo
identity ("repo-shaped runner labels are architectural debt"). The load-bearing
boundary: **only cluster/tailnet-resident runners reach the cell's internal
gRPC port**; GitHub-hosted runners cannot reach the data plane. The shared cache
is reachable off-cluster only for tailnet members via a tailnet-fronted
ClusterIP, and the front door **refuses to emit that routable endpoint as a
default** because the cache enforces no client auth.

### 1d. Nix / Docker image build (incl. Nix→OCI)
Three composite actions: `setup-flywheel` (derives cache hints + substrate mode
from the runner profile, attaches the substituter), `nix-job` (bootstraps
Determinate Nix if absent, attaches the substituter via netrc, push-deltas to
Attic when enabled), and `docker-job`. The image path is **nix2container-
preferred** (no Docker daemon, byte-reproducible, streamable push), so runners
without DinD can still build OCI images; the build workflow signs with cosign
keyless / Sigstore OIDC.

### 1e. Enrollment token-dispatch (the consumer latch + front door)
A consumer laces up via ONE registry line (`consumer-registry.json` or
`spoke-registry.json`) declaring repo, runner class, image repo, tfvars anchor,
substrate mode, build targets, and related issue — validated by a contract
check. Shell attachment is `flywheel-doctor` → `flywheel-enroll` →
`flywheel-verify` (verify proves internal coherence, not that a cache answered).
Since 2026-07-01 there is a **public off-cluster token on-ramp**: a GitHub-OIDC
caller with zero tinyland creds can exchange for a short-lived, tenant-scoped
cell token. **Mint reach is public; data-plane reach is NOT.** Action-cache
write trust is subject-pinned and currently in warn/detect-only mode.

### 1f. flywheel ↔ flywheel-executor (the one selector)
`.bazelrc.flywheel` carries pure `--config=flywheel` (cache-only) vs
`--config=flywheel-executor` (cache+executor) flags with **no endpoints/creds**;
the executor lane selects its worker purely by the `gf.platform` exec-property,
preferably via a consumer-declared local `platform()` target.
`GF_BAZEL_SUBSTRATE_MODE` is derived by `.envrc` (executor-backed when an
executor endpoint is present, shared-cache-backed when only a cache endpoint is,
else compatibility-local-only). Executor mode defaults `--jobs` to match the
per-tenant concurrency cap and disables cache compression the cell doesn't
advertise.

### 1g. Target-class eligibility (candidate → proved)
`rbe-target-eligibility.json` gates which Bazel target classes may run
executor-backed; `default_posture` is *cache-forward local/CI execution;
executor-backed is opt-in and target-class scoped*. ~38 proved classes exist
across other workspaces, each with `workflow_run` + workspace + target evidence.
Browser RBE is a distinct authority (pinned Chromium from a locked nixpkgs rev
into a `worker_image_digest`, with `forbidden_in_reapi_actions` banning
action-time browser installs). The proof harness is `gf-reapi-cell-proof.yml`
(`force_execution` default true → reject AC hits and require fresh remote
evidence). A maturity ladder (rungs 0–6) gates broad/default RBE on durable
CAS/AC, auth, external-input durability, tenant enforcement, and observability.

---

## 2. The GFTB-today gap (cache-first only)

GFTB consumes **one** rung of the ladder above: the ratified TIN-1997
cache-first, read-only shared-cache default. Everything else is present but
dormant or absent-by-doctrine.

| GF capability | GFTB today | Why |
|---|---|---|
| Shared Nix + Bazel **cache**, read-only on PR | **USED** | `ci.yml` `flywheel_config: flywheel` + `cache_backed: true`; `.bazelrc build:ci-cached` read-only, empty CI disk-cache. TIN-1997 Option D verbatim. |
| Real Bazel **target graph** | **PRESENT** | `BUILD.bazel` has genuine `sveltekit_types`, `svelte_check_test`, `eslint_test`, `prettier_check_test`, `//:build` (vite), `unit_tests` (vitest), `playwright_static_smoke`, most tagged `flywheel-eligible`. Canonical build is still `pnpm run build`; Bazel graph is the registry-resolution smoke. |
| Executor **plumbing** | **DORMANT** | `.bazelrc.flywheel` defines `common:flywheel-executor`; `Justfile` has `flywheel-runner-selftest` (fail-closed executor canary). But `ci.yml` never sets `flywheel_config: flywheel-executor`. |
| **Enrollment** front door | **WIRED (shared-cache mode)** | `Justfile` `flywheel-doctor`/`-enroll`/`-verify`/`-enrollment-contract-check`; `cache-attachment-contract.sh --strict` reads `enrollment.substrateMode` from `tinyland.repo.json` (= `shared-cache-backed`). TIN-2126 success metric for the cache mode. |
| tinyland-nix runner **reachability** | **SATISFIED** | GFTB routes exclusively to `tinyland-nix` (all runner classes map there — "no -heavy/-kvm classes exist here"). Cache-attach prerequisite (TIN-1279) met. |
| Target-class **proof** | **ABSENT** | `rbe-target-eligibility.json` lists **zero** greatfallstoolbus workspaces / classes. GFTB has never dispatched a cold-start cell proof. |
| Org-tenant executor **grant** | **DENIED (by design)** | `org-tenant-registry.json` tenant `org-great-falls-tool-bus`: `runtime_grants_enabled: false`, `migration_stage: schema-only`, `allowed_modes: [shared-cache-backed]`, `repositories: []` empty, `ac_trusted_subjects: []` empty (TIN-2299). Registry is planning-record-only today. |
| **Image build** on the substrate | **ABSENT from Bazel** | Container publish runs **outside** Bazel (honoring the executor-ineligibility invariant); the infra overlay has no Bazel action graph at all — only `git_override` of `attic-iac` for IaC modules and `exports_files` of tfvars/hcl. |

**Reading:** the gap is a chain of missing *proofs and grants*, not missing
wiring. GFTB is correctly parked at the doctrinally-correct resting state.

---

## 3. Phased, doctrine-aligned GFTB adoption plan

Design constraints, non-negotiable:
- **TIN-1997 cache-first read-only stays the default** through every phase. The
  executor is only ever added for a *specific proved class*, never as a global
  default.
- **TIN-2488 tension noted:** "remote-only for everything" is explicitly
  **rejected as superseding doctrine**. This plan never collapses the three
  substrate modes into "always remote"; each executor step is opt-in and
  target-class scoped.
- **Switchable:** every executor gain is a one-line, reversible flip
  (`flywheel_config: flywheel` ⇄ `flywheel-executor`) with the endpointless
  `.bazelrc.flywheel` already in place (the TIN-1571 flip pattern).
- **Public-repo-safe:** no endpoint, token, or cluster topology enters the app
  repo in any phase; authority stays in the wrapper/env + the private overlay.

### Phase 0 — Proper enrollment (front door), no posture change
Make GFTB's enrollment machine-legible before proving anything.
- Backfill the org-tenant `repositories[]` and note the `shared-cache-backed`
  enrollment under TIN-2299 (see §4 gap).
- Reconcile `lanes.json` advertised classes with reality (either drop to
  cache-only or rename to the workspace-scoped candidate names — see §4 gap) so
  no future operator misreads GFTB as executor-ready.
- Replace the `../GloriousFlywheel#ci` sibling-checkout in the infra overlay
  with a pinned flake ref / explicit checked-out-path input (see §4 gap;
  TIN-2546). **Exit:** `flywheel-verify` + contract check green; registry
  self-describes GFTB.

### Phase 1 — Real Bazel target graph (rules_js/pnpm, ADR-008 shape)
GFTB already has this for the site; the phase is to *confirm and harden* it as
the RBE-shaped surface, not create it.
- Keep the canonical build as `pnpm run build`; keep Bazel as the graph +
  registry-resolution proof (two-registry chain: `tinyland-inc/bazel-registry`
  then BCR).
- Ensure the `flywheel-eligible`-tagged classes are hermetic and CAS-cacheable
  under the ADR-008 remote-first shape (endpoints in runtime env, never
  `.bazelrc`; TIN-2090). **Exit:** `bazel mod graph` + tagged targets build
  clean cache-backed on `tinyland-nix`.

### Phase 2 — Cache-first read-only (already the resting state)
This is TIN-1997 Option D, already live. The phase's job is to *hold* it as the
default and treat it as the fallback every later phase can revert to in one
line. **Exit:** unchanged — remain here indefinitely if no proof is run.

### Phase 3 — `flywheel_config` → `flywheel-executor` flip for eligible classes (TIN-1571)
Only after Phases 0–2 and a passing cold-start proof (Phase 5's harness). The
candidate classes are exactly GFTB's flywheel-eligible ones:
- `sveltekit-app-build`
- `sveltekit-unit-tests`
- `deployment-bundle-packaging`
- `docs-site-static-build`

The flip is the one-line `flywheel_config` change plus a
consumer-declared local `platform()` carrying `gf.platform`. It **must** be
preceded by the TIN-2299 org-tenant grant (`runtime_grants_enabled: true`,
`allowed_modes` including `executor-backed`) or it fails-closed at the boundary.
**Exit:** the flipped class runs executor-backed with nonzero remote-process
evidence; every non-flipped class stays cache-first.

### Phase 4 — Nix-OCI image build on tinyland-nix (feeds TIN-2543 container build)
Adopt the `nix-job` / nix2container path to build GFTB's OCI image
reproducibly on `tinyland-nix` **without** DinD, feeding the TIN-2543 container
build. Image **push** stays outside Bazel and outside executor eligibility
(see NEVER list). **Exit:** a byte-reproducible image builds on-substrate; the
TIN-2543 build consumes it; no push runs on the executor.

### Phase 5 — gf-reapi-cell-proof (TIN-2288 / TIN-1126 pattern)
The gating proof for Phase 3, run via `gf-reapi-cell-proof.yml` with
`force_execution: true` (reject AC hits, require fresh remote evidence):
- ≥2 consecutive **cold-start** greens
- nonzero remotely-executed processes (cache-HIT vs RBE distinction held)
- a captured `proof-result.json` provenance artifact
**Exit:** the class graduates candidate → proved in
`rbe-target-eligibility.json`; only then is Phase 3's flip doctrinally
authorized.

> **Sequencing note:** Phase 5's proof logically *gates* Phase 3's flip even
> though it is numbered later — Phases are named for the capability they adopt,
> and the executor flip is inert (fails-closed) until both the proof lands and
> the TIN-2299 grant flips. Phases 0–2 can proceed immediately; 3–5 are
> operator-gated and reversible.

### The NEVER list (executor-ineligibility invariants — hard, permanent)
Encoded in `.bazelrc.flywheel` and honored today; must survive every phase:
- **NEVER** make **image-push** targets executor-eligible (publish runs outside
  Bazel).
- **NEVER** make **OpenTofu / IaC apply** targets executor-eligible (the infra
  overlay keeps tofu/kubectl off the Bazel executor).
- **NEVER** make **dev-server** targets executor-eligible (dev servers are
  explicitly blocked from REAPI).
- **NEVER** treat a **cache HIT as RBE evidence**; **never** authorize cache
  **writes** from PRs (`GF_BAZEL_REMOTE_UPLOAD=false`); **never** trust the
  current interim store as CAS/action-cache/publication authority until its
  durability gate clears.
- **NEVER** bake an endpoint, token, or cluster hostname into `.bazelrc`,
  `.bazelrc.flywheel`, or any file in the soon-public app repo.

---

## 4. GF-product gaps found (candidate GF issues)

These are defects in the **substrate/product**, surfaced by GFTB's adoption
analysis. They are candidate GF-core (or overlay) issues, not GFTB blockers.
The first is already filed.

1. **[FILED — TIN-2546] `../GloriousFlywheel#ci` relative-path / sibling-checkout gap.**
   The GFTB infra overlay hard-codes a relative filesystem-sibling dependency on
   a private-repo checkout: `Justfile` `gf_core_ci := ... '../GloriousFlywheel#ci'`
   and `nix develop ../GloriousFlywheel#ci -c ...` across the `*-crs.yml`
   workflows. The deeper defect is that there is **no product surface** to
   consume the GF `#ci` toolchain devshell short of checking out the entire core
   repo. **Fix direction:** publish the `ci` devshell as a ref-consumable output
   (`nix develop github:tinyland-inc/GloriousFlywheel/<rev>#ci`) or a
   `devshell: ci` input on the `nix-job` composite that resolves by pinned rev.

2. **Stale/unproved lane-class advertisement in GFTB `lanes.json`.**
   `lanes.json` `flywheel_target_classes = ['sveltekit-app-build','sveltekit-unit-tests']`
   are legacy generic names that do **not** match GF-core's current
   workspace-scoped scheme (`web-<workspace>-sveltekit-vite-build`,
   `web-<workspace>-unit-vitest`), and no greatfallstoolbus class is proved. A
   future operator would misread GFTB as executor-ready; a flip fails-closed.
   **Fix:** drop to cache-only reality or rename to workspace-scoped candidate
   names before any proof.

3. **Org-tenant registry lists no repositories for a live, enrolled tenant.**
   `org-tenant-registry.json` `org-great-falls-tool-bus` has `repositories: []`
   though the site is genuinely cache-enrolled. The schema-only registry cannot
   later be machine-consumed to authorize the site without a manual edit.
   **Fix:** backfill `repositories[]` (+ note `shared-cache-backed`) under
   TIN-2299.

4. **AC-write attestation stuck in warn/detect-only mode.**
   The action-cache write trust boundary logs but never blocks untrusted
   writers; the warn→enforce flip is gated on JTI + metrics preconditions and
   appending the remaining real AC-writers so the rejection soak stays flat.
   Until flipped, the cell's action-cache trust boundary is advisory. **Fix:**
   track the enforce cutover and its precondition soak.

5. **Off-cluster shared Bazel cache enforces no client auth.**
   Any tailnet member can read/write the shared cache with no credential; the
   front door refusing to emit the routable endpoint is a soft guard, not a
   control. **Fix:** add client auth to the routable cache path before
   broadening off-cluster consumer access.

6. **Single-replica store is a SPOF backing both cache bodies and state, with an
   unresolved bucket-index recurrence.** The interim store backs both the Nix/
   Bazel cache bodies and the OpenTofu state stacks on one node; loss degrades
   cache+state together, and losing the runner node removes runners+cache
   together — no HA anywhere. This is the top structural risk blocking RBE
   rung 6. **Fix:** a consolidated durable-store / HA-backend tracking issue.

7. **Resident proof-cell default contends with the heavy lane.**
   `gf-reapi-cell-proof.yml` defaults to keeping the single-replica live
   executor endpoint resident, a standing capacity draw on the single-hardware
   pool that also serves the heavy runner lane. **Fix:** reconcile the
   resident-endpoint default against heavy-lane contention.

8. **No standalone `setup-flywheel` for plain validation jobs.**
   Because `setup-flywheel`/`nix-job` aren't usable outside the happy path,
   consumers hard-code the cluster substituter and re-implement Nix daemon
   bootstrap (the private-topology leak the compatibility doc warns against).
   **Fix:** make `setup-flywheel` a standalone composite (bootstrap + profile-
   sourced substituter attachment) usable outside `nix-job`.

9. **Cache-backed contract ships only as a whole-workflow reusable.**
   A repo with pre-existing required checks can't adopt it incrementally and
   vendors it (byte-identical script drift). **Fix:** publish the `cache_backed`
   contract as a standalone composite action or reusable **job**, not only a
   top-level workflow.

10. **Front-door verb names are squatted by divergent home-grown scripts.**
    Overlays implement registry/tfvars/Helm checks under GF's reserved
    `flywheel-enroll`/`-verify` verb names while the real
    `flywheel-frontdoor-kit` appears nowhere in the consumer. **Fix:** ship the
    kit as a discoverable, installable, version-pinned artifact and consider
    namespacing GF-owned verbs to prevent shadowing.

11. **Committed worktree residue duplicates SSoT config.**
    `consumer-registry.json` / `rbe-target-eligibility.json` are duplicated
    verbatim under committed `.claude/worktrees/` paths, risking an agent
    reading/editing the wrong file. **Fix:** gitignore `.claude/worktrees` and
    remove the residue.

**Candidate issues to file (this ticket's `gfProductGapsToFile`):** #2 (lanes
advertisement), #3 (registry backfill), #4 (AC-write enforce), #5 (cache client
auth), #6 (durable-store/HA), and the already-filed TIN-2546 (#1). Gaps #7–#11
are additional GF-core candidates to raise as capacity permits.

---

## 5. Doctrine anchors

- **TIN-1997** (Done 2026-07-03) — cache-first read-only shared-cache default
  ("Option D"). The ratified resting posture; this plan preserves it.
- **TIN-2488** (Backlog) — "remote-only for everything" does **not** supersede
  TIN-1997/TIN-668/TIN-670; no ratified instrument. This plan honors the tension
  by keeping every executor step opt-in and target-class scoped.
- **TIN-1571** (Done) — the `flywheel_config → flywheel-executor` one-line flip
  pattern (Phase 3).
- **TIN-2288 / TIN-1126 / TIN-665** — cold-start target-class proof discipline
  (Phase 5).
- **TIN-2299** — GFTB org-tenant record; executor grant gate.
- **TIN-1279** — tinyland-nix runner reaches the cluster-internal cell
  (cache-attach prerequisite; Backlog).
- **TIN-2090** — ADR-008 remote-first Bazel graph, endpoints in runtime env.
- **TIN-2126** — GF enrollment backbone / front door (cache mode Done for GFTB).
- **TIN-2543** — container build the Phase 4 nix-OCI image feeds.
- **TIN-2546** — the filed relative-path product gap (§4 #1).

## 6. Sources

Grounded in the TIN-2545 research packet (three lenses: `gf-feature-map`,
`consumer-laceup-audit`, `gftb-gap-and-doctrine`), which cites GF-core docs
(`platform-layers.md`, `consumer-latch.md`, `enrollment-model.md`,
`cache-and-state-roles.md`, `runner-topology.md`, `enrollment.md`,
`containers.md`, `glorious-build.md`), GF-core config
(`rbe-target-eligibility.json`, `consumer-registry.json`,
`org-tenant-registry.json`), GF-core actions/workflows (`setup-flywheel`,
`nix-job`, `docker-job`, `gf-reapi-cell-proof.yml`, `build-image.yml`), and
GFTB's own `ci.yml`, `.bazelrc`, `.bazelrc.flywheel`, `BUILD.bazel`, `Justfile`,
`lanes.json`, `tinyland.repo.json`. In-repo grounding for §4 #1: this overlay's
`Justfile` lines 9–10 and `edge-drift.yml` GF-core checkout. No endpoints,
tokens, or cluster topology are reproduced here.
