# 0002 — Convert web CD to the production-convergence carrier pattern

- Status: **Proposed — BLOCKED** on (a) publication of the Push-2
  stateful-gitops module and (b) an operator enable ceremony. Nothing in
  the carrying PR applies, deploys, or retires anything.
- Date: 2026-08-06
- Coordination: site.scaffold `docs/patterns/production-convergence.md`
  (TIN-489, TIN-3065) + `docs/patterns/tofu-agent-carrier.md`; module
  publication mechanism TIN-2030; three-push spool Push 2 (pattern SSOT)
  / Push 3 (this conversion prep).
- Applied: **NOTHING.** The new stack fails `tofu init` by construction
  (placeholder module pin) and the kill switch ships `enabled: false`.
- Scope: the **web serving stack only**. mail/list/form/archive keep
  their kubectl apply ceremonies and TRUE zero-diff drift gates — they
  are correct today and out of scope. Edge stacks untouched. No mail
  objects, ever, from this lane.

## 1. What this PR lands (all inert)

| Surface | Content |
|---|---|
| `config/production-convergence.json` | Carrier declaration: `carrier_resource` (tofu address, leaf confirmed at pin swap) + `workflow_state_document`. Keys restricted to the site.scaffold contract-test allowlist. |
| `config/production-convergence-state.json` | Kill-switch as code, ships `enabled: false`. Flip = reviewed PR, operator ceremony. |
| `tofu/backend/honey-web-convergence.s3.hcl` | State-backend coordinates, names only: bucket `tofu-state`, key `great-falls-tool-bus-infra/web-convergence/terraform.tfstate`, endpoint `http://tofu-state-rustfs.nix-cache.svc:9000`. No credentials (repo convention; env-delivered at ceremony). |
| `tofu/stacks/web-convergence/` | The pattern instantiation: grounded locals + a module block whose source is a placeholder that fails `tofu init` until the Push-2 pin swap. PROVISIONAL input names document GFTB's requirements on the module interface (section 4). |
| this ADR | Ground truth, retirement list, blockers, enable ceremony. |

## 2. Ground truth — the mechanic being converted

Verified in-tree and live (read-only) 2026-08-06:

1. **Push-on-merge CD signal.** Site repo
   `Great-Falls-Tool-Bus/greatfallstoolbus.org` `container-ghcr.yml`
   builds on push to `main`, pushes **only** `sha-<commit>` tags (no
   moving tag), resolves the `@sha256` digest, and fires
   `repository_dispatch` type `web-image-published` at this repo with
   `client_payload {image, sha, replicas}` using
   `INFRA_CD_DISPATCH_TOKEN` (fail-soft when absent).
2. **Push-shaped apply.** `.github/workflows/web-stack.yml` receives the
   dispatch (plus a `workflow_dispatch` manual/rollback path), gates the
   CD path on site `ci.yml` green (`just web-cd-ci-green-gate`), then
   `just web-stack-apply`: `kubectl apply -k`, `kubectl set image`,
   `kubectl patch` replicas, `rollout status`. Health gate =
   `readyReplicas == desired` (`just web-stack-health`), where readiness
   is the kubelet probe `GET /health` on `:3000`.
3. **Drift that cannot fail on the serving stack.**
   `.github/workflows/k8s-stack-drift.yml`'s `web-stack-drift` job runs
   `just web-stack-drift-check` with `fail_on_drift=false` — by design:
   `k8s/web/greatfallstoolbus-org-production` stays parked in git
   (`replicas: 0`, PLACEHOLDER image, guarded by
   `scripts/validate-web-stack.sh`) while live state carries the
   imperatively patched digest and `replicas: 2`. A diff is EXPECTED, so
   drift on the serving surface is structurally unobservable as a
   failure. This is the defect the pattern retires: with the tofu stack
   as desired-state authority, drift becomes a non-empty plan and CAN
   fail.
4. **Second-authority trigger surface.** `repository_dispatch` +
   `workflow_dispatch` in the serving loop are exactly the ingress-
   trigger class `tofu-agent-carrier.md` section 3 forbids: revocable,
   throttleable, and indistinguishable from a quiet estate when absent
   (the fail-soft token path proves the point — CD silently stops when
   the token disappears).

## 3. Target shape

One pull-shaped carrier: the Push-2 module's in-cluster CronJob,
declared inside `tofu/stacks/web-convergence/` (self-managed — the
carrier is a resource in the state it applies). Each tick: clone this
overlay's `main` read-only → read `enabled` FIRST, exit 0 quietly when
false → resolve site `main` → derive `sha-<sha>` tag → pin digest →
plan/apply against the rustfs backend (lock + `concurrencyPolicy:
Forbid`) → wait for rollout → assert served sha at the real edge.
Receipts (resolved sha, applied digest, served evidence) are runtime
artifacts, never checked in.

## 4. GFTB-side requirements on the module interface

The PROVISIONAL inputs in `main.tf` encode these; reconcile at pin swap:

- **No moving tag exists.** The module must derive the tag from the
  resolved site `main` SHA (`sha-{site_main_sha}` template) and fail the
  tick cleanly when the image for that SHA is not yet queryable (the
  post-merge build race), rather than requiring a `latest`/`main` tag.
- **Two-repo split.** Converged symbol = SITE repo `main`
  (`Great-Falls-Tool-Bus/greatfallstoolbus.org`, public); carrier
  clone + workflow-state doc = THIS overlay (private; read-only deploy
  key).
- **Edge served-evidence must be Access-aware** (blocker B2).
- **Admission is pre-merge.** The site's required checks are the
  production decision; the module must NOT re-gate on CI post-merge
  (that machinery retires with the dispatch path, R1/R3).

## 5. Retirement list — dispatch machinery (STAGED, nothing removed here)

Every row is blocked on: module published + pin swapped + carrier live
with a first honest receipt + operator `enabled: true` flip. Rows land
as separate reviewed PRs at decommission.

| # | Surface | Replaced by |
|---|---|---|
| R1 | `web-stack.yml` `repository_dispatch` CD path (trigger, payload normalization, CI-green gate step) | carrier pull loop |
| R2 | `web-stack.yml` `workflow_dispatch` manual/rollback path | no converge-now button; rollback = reviewed revert on site `main` |
| R3 | Justfile `web-cd-ci-green-gate` | pre-merge admission (site required checks) |
| R4 | `k8s-stack-drift.yml` `web-stack-drift` job + Justfile `web-stack-drift-check` + the web carve-out in `_k8s-drift-check` | tofu plan drift that CAN fail |
| R5 | `k8s/web/greatfallstoolbus-org-production/` parked skeleton + `scripts/validate-web-stack.sh` + `web-crs.yml` | `tofu/stacks/web-convergence/` as desired-state authority |
| R6 | Justfile `web-stack-apply`, `web-stack-server-dry-run`, `web-stack-health`, `_web-apply-inputs`, `_web-apply-kubeconfig-only` | module plan/apply/rollout/receipt loop |
| R7 | SITE repo `container-ghcr.yml` `signal-infra-cd` job + `INFRA_CD_DISPATCH_TOKEN` secret | nothing — the carrier notices on its own schedule (**separate site-repo PR**) |
| R8 | `web-apply` GitHub environment + `WEB_APPLY_KUBECONFIG_B64` custody | operator decision: retiring it closes the workflow-side second-carrier credential class (tofu-agent-carrier section 3); keeping it is keeping a second carrier |

## 6. Blockers (honest)

- **B1 — module unpublished.** Push-2 coordinate, version, input names,
  and the carrier resource leaf address are unknown; the declaration's
  `carrier_resource` is provisional until pin swap.
- **B2 — Cloudflare Access fronts the entire public hostname.** Verified
  live 2026-08-06: `https://greatfallstoolbus.org/` and `/health` both
  302 to `sulliwood.cloudflareaccess.com` (Google SSO; edge stack
  manages the apex Access application). An unauthenticated served-sha
  assertion never reaches the app. Resolution is an operator decision:
  mint a CF Access service token for the probe (name staged:
  `web-convergence-edge-probe`) or review an Access bypass for a probe
  path. Until then the receipt's served-evidence leg cannot be gathered
  at the real edge.
- **B3 — carrier-liveness detector prerequisite.** The pattern REQUIRES
  a named detector on `kube_cronjob_spec_suspend == 1` and last-success
  staleness before adoption. This overlay declares no alerting surface
  today; the detector must be named and live before `enabled: true`.
- **B4 — credentials to mint (names only, operator ceremony):**
  read-only overlay deploy key (`web-convergence-overlay-read-deploy-key`),
  rustfs state-backend key pair (`web-convergence-state-backend`),
  carrier namespace ServiceAccount + RBAC (apply-scoped, extends the
  web-apply SA family), optional `web-convergence-edge-probe` (B2).
  State-backend credential custody stays exclusively in the carrier's
  `secretRef` — CI runners never receive it (the structural
  second-carrier boundary).
- **B5 — site-repo declaration.** The site is the site.scaffold product;
  its own `config/production-convergence.json` (product-side
  declaration) and the R7 retirement are site-repo PRs, out of scope
  here.
- **B6 — first-converge state adoption.** The workload currently exists
  only as imperative kubectl state. The first carrier apply must adopt
  (import) or recreate the live Deployment/Service/NetworkPolicy without
  a serving gap; the pin-swap PR must state which, per the module's
  capability.

## 7. Enable ceremony (operator, in order)

1. Push-2 module published → pin-swap PR (checklist at top of
   `main.tf`), reconciling inputs + `carrier_resource` leaf.
2. Mint B4 credentials; resolve B2; name the B3 detector and see it
   alert on a suspended test cronjob.
3. Operator-run first plan/apply ceremony (state adoption per B6);
   carrier installed but still halted (`enabled: false` — a halted
   carrier is a healthy carrier).
4. Reviewed PR flips `enabled: true`; watch a full tick produce an
   honest receipt (resolved sha, pinned digest, served evidence).
5. Retirement PRs R1–R6, R8 here; R7 + product declaration in the site
   repo.

Until step 4 completes, `web-stack.yml` remains the deploy mechanism and
this stack is documentation-grade, fail-closed code.
