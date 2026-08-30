# GFTB member database bring-up runbook

Tracking: TIN-3817 (Member v0 slice S1, infra half). Authority:
`Great-Falls-Tool-Bus/meta` main `spec/member-v0-executable-slices-2026-08-18.md`
§1.3 and `spec/launch-member-v0-system-2026-08-16.md` §6.
Stack: `k8s/member-db/` (see the README beside the manifests).

This runbook brings up one dedicated PostgreSQL 16.15 CloudNativePG cluster for
the ratified member lifecycle, runs the first pre-rollout migration, and proves
the RPO ≤ 1h / RTO ≤ 4h acceptance row with a real restore. Every step is
**attended**. Nothing in CI applies any of it.

> **Carrier state (2026-08-29): MERGED APP + PUBLISHED IMAGE + GIT PIN,
> NOT APPLIED.** Platform source
> `af60fcd7539a4beff6f24e1a95eb11160df7c166` is merged. Publisher workflow
> run `33279762284`, attempt 1, produced artifact
> `greatfallstoolbus-org-image-af60fcd7539a4beff6f24e1a95eb11160df7c166-33279762284-1`
> and image
> `ghcr.io/great-falls-tool-bus/greatfallstoolbus.org@sha256:10f853938dc6823afe8c9bdc54943587f963d22117aafd17247350b2b5712b35`.
> This PR pins that image in the one-shot Job. Merged, published, and Git-pinned
> do not mean applied, running, or served. This change performed no live
> readback, so the operator must establish current cluster state at the apply
> sitting rather than inherit an old “none exists” claim.

## Read this before starting: what remains before apply

The earlier app-image blocker is closed by the exact publisher receipt above.
The object-store ruling is also closed: GFTB uses its dedicated rustfs carrier,
not an estate-owned tcfs bucket. What remains is operational and attended:

1. Merge this PR through its required validation and review gates. The mutating
   recipes require clean, current, verified `main`; a PR branch cannot apply.
2. At the sitting, read current operator/namespace/cluster state, establish the
   two namespaces and the other operator-custody credentials if absent, and
   observe the governed `ghcr-pull` controller projection described in C3.
   Then follow the ordered S → M → R chain. This document does not claim those
   live objects or the projection are absent or present.
3. Preserve the exact Git-pinned image. There is no runtime image override or
   alternate repository authority. A different image requires a new app source,
   publisher receipt, reviewed Git pin, and the same validation/review gates.

## Step O — CloudNativePG operator conformance (read-only)

The operator is estate-owned, but this carrier does not inherit a current-live
claim. Read it now; do not install from this repository:

```bash
kubectl --context honey get crd | grep cnpg
kubectl --context honey -n cnpg-system get deploy cnpg-cloudnative-pg \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

The 2026-08-19 read showed the four CNPG CRDs served at `v1`, operator
image `ghcr.io/cloudnative-pg/cloudnative-pg:1.22.0`, and chart
`cloudnative-pg-0.20.0`. Treat those as historical receipts, not current
live truth. Record the values returned at this sitting, including every existing
`Cluster` object; do not use this runbook to infer an empty estate.

**O2 — only if the operator is ever absent.** The install is a **substrate**
change, not a GFTB one: the release is declared in `blahaj`
`deploy/honey/rke2-cnpg.yaml` as an RKE2 `HelmChart`, adopted 2026-05-05.
Bringing it back is a blahaj PR followed by an operator apply on the substrate
side. This repository does not install it and must not grow a copy of it —
`AGENTS.md`'s no-re-homing rule runs in both directions. Record the substrate PR
number here if this ever happens.

## Step N — namespaces (attended, out of band)

Create both namespaces and the namespace-scoped apply ServiceAccount +
kubeconfig. Neither stack ships a `Namespace` object and the apply SA is
namespace-scoped, so it cannot create them either — this is deliberate, and
`just member-db-stack-validate` fails if a `Namespace` object ever appears in
the tree.

| Namespace | Label it needs | Why |
| --- | --- | --- |
| `members-greatfallstoolbus-org-db-production` | (defaults) | the database |
| `members-greatfallstoolbus-org-production` | `kubernetes.io/metadata.name` (auto) | the platform; the database NetworkPolicy selects it by this auto-applied label |

The apply kubeconfig is operator-custody and its path is supplied as
`MEMBER_DB_APPLY_KUBECONFIG`. It is never committed and never a CI secret.

## Step B — backup destination (CLOSED ruling; B2 is still pre-apply work)

**B1 — the ruling, CLOSED 2026-08-20.** GFTB gets its own dedicated rustfs,
not an estate-owned tcfs bucket. This is no longer an open decision —
`cluster.yaml` and `rustfs.yaml` already carry it — this subsection is the
permanent record, not a gate.

> Ruling (2026-08-20): **GFTB-owned dedicated rustfs** — digest-pinned image,
> `local-path-sting` storage class, Retain reclaim, >=50Gi, NetworkPolicy
> admitting only pods labeled `cnpg.io/cluster: gftb-member-db` (and, since
> B-5, `gftb-member-db-restore` for the rehearsal cluster below). Neither tcfs
> endpoint is admitted (custody findings: 10Gi/local-path/Delete reclaim, zero
> NetworkPolicies, publicly tunneled). Recorded by the coordinating session
> that witnessed the operator interview answer ("GFTB-owned rustfs
> (Recommended)"), session 050cb99f, 2026-08-20 — the same interview-signature
> mechanism that enacted ADR 0016 (meta 0f66bce3). Recommendation adopted
> verbatim from data-plane-runway-20260820.md (operator-local brief).
>
> Placement addendum (2026-08-20, operator interview, same session): the
> `local-path-sting` placement is a **recorded GFTB-scoped exception to
> blahaj ADR 002** ("no durable PVC consumers on sting", cf. TIN-1965).
> Rationale: the backup store MUST live off the DB's node (bumble) so
> backups survive its loss; sting is the ruled exception host. A courtesy
> note belongs on the blahaj side before/at the apply sitting.

**B2 — root, bucket, then distinct scoped client authority.** Before the
backup-store apply, provision only
`gftb-member-db-backup-store-root` (type `Opaque`, exact
`RUSTFS_ACCESS_KEY` / `RUSTFS_SECRET_KEY` keys). It is rustfs
server-bootstrap/admin authority and is never accepted as CNPG backup authority.

Apply the store and run `member-db-backup-bucket-create`. That Job uses the
root Secret only to create `gftb-member-db-backups`; it does not create an IAM
identity or the CNPG client Secret.

Before cluster or restore apply, independently provision
`gftb-member-db-backup-s3` as a distinct, least-privilege bucket-scoped
credential with exact keys `ACCESS_KEY_ID` / `ACCESS_SECRET_KEY`. The current
RustFS policy-provisioning command and proof carrier are not invented here: the
operator must supply the reviewed ceremony. The Secret must carry:

- `app.tinyland.dev/object-store-scope=bucket:gftb-member-db-backups`
- `app.tinyland.dev/object-store-authority=object-read-write-no-admin`
- a nonempty `app.tinyland.dev/object-store-proof` receipt

`_member-db-cluster-prerequisites` rejects missing/wrong keys, annotations,
empty proof, or reuse of the root key pair.

## Step C — credentials

**C1 — the owner credential is not yours to make.** CNPG generates
`gftb-member-db-app` at bootstrap with the `gftb_migrator` password. No
operator action creates or reads it.

**C2 — mint the runtime credential.** Create `gftb-member-db-runtime` in the
database namespace, type `kubernetes.io/basic-auth`, `username:
gftb_app`. `managed.roles` binds the role to it. This is the DML-only
credential the platform's web and worker Deployments will consume.

**C3 — declare and observe the governed GHCR pull projection (Related to
TIN-3768 / TIN-2609).** The sole names-only target is `ghcr-pull` in
`members-greatfallstoolbus-org-production`, type
`kubernetes.io/dockerconfigjson`, with only `.dockerconfigjson`. The
migrator, web, and worker carriers reference that one name.

Secret bytes belong exclusively to TIN-3768 consumer enrolment through the
TIN-2609 sole governed owner-overlay controller's immutable
`RegistryPullProjection` intent and protected subordinate execution path.
Do **not** run `kubectl create secret` or `kubectl apply` for this Secret,
add a per-tenant SOPS payload, copy a personal dockerconfig, or treat an
operator-created object as an interim route. This runbook declares the target;
it does not claim the controller or projection is live.

Before migration dry-run or apply, require governed evidence for all four:

1. the controller's observed projection resolves exactly one
   `members-greatfallstoolbus-org-production/ghcr-pull` Secret with the exact
   type and key above;
2. `_member-db-platform-image-pull-prerequisite` passes against that observed
   object without printing its value;
3. an uncached cold pull proves registry access to the exact coordinated
   successor digest pinned by both #118 and #121; and
4. while current and previous credential generations are both retained, an
   uncached rollback pull proves the recorded previous digest. Only after that
   proof may the governed path revoke the old generation.

The app package was observed anonymously pullable during review, but only
gftb-site is authorized public. This PR changes no visibility and makes no
private-state claim; pull success never substitutes for the governed projection
receipt.

## Step S — apply the database stack (ORDERED, B-4)

**Precondition (B-6): this PR must be MERGED before this step runs.** All six mutating recipes (backup-store apply, bucket creation, cluster apply,
restore apply, restore teardown, and migration apply) pass through
`_reviewed-clean-main`, which requires
the current branch to be `main`, a clean worktree, and `HEAD` to equal the
verified `origin/main` tip — so none of them can run from this PR's branch,
only after it lands. `member-db-stack-server-dry-run` (which depends on
`member-db-stack-validate` and is the read-only dry-run below) does **not** carry that
requirement, so Phase 3's read-only proof works from the branch today; Phase
4 is gated on merging #118 first.

```bash
just member-db-stack-validate
export MEMBER_DB_APPLY_KUBECONFIG=/path/to/member-db-apply.kubeconfig
just member-db-stack-server-dry-run

# Bind the reviewed declaration receipt to a fresh live API /32 readback before
# the first NetworkPolicy mutation, not merely before Cluster creation.
export MEMBER_DB_API_EGRESS_SOURCE_SHA=<current-reviewed-blahaj-sha>

# Stage 1: root Secret already provisioned.
GFTB_APPLY_CONFIRM=apply just member-db-backup-store-apply
GFTB_APPLY_CONFIRM=apply just member-db-backup-bucket-create

# Provision and prove the distinct bucket-scoped client credential (B2), then:
GFTB_APPLY_CONFIRM=apply just member-db-cluster-apply
```

Every policy, cluster, and restore-apply mutation that depends on API egress
runs `_member-db-current-api-egress-prerequisite` first. It reads the current
`default/kubernetes` Endpoints and fails unless each named policy independently
equals that exact three-/32 set; the source SHA records the canonical
declaration reviewed with that readback. The
historical `blahaj@72b6c2d9...` snapshot is alignment evidence only.

`member-db-stack-apply` is a thin alias over three ordered steps — run it
directly, or run the three yourself to watch each one land:

1. `member-db-backup-store-apply` — applies ONLY the NetworkPolicy family and
   rustfs (StatefulSet/Service/PVC), filtered from an independently re-rendered
   `kubectl kustomize` stream after the validator passes, and
   waits for the StatefulSet to report Ready. `cluster.yaml`'s own comment
   says the backup store must be live before the Cluster is, because WAL
   archiving starts the moment the Cluster is applied — this step is what
   actually enforces that, where a single `apply -k` could not (B-4).
2. `member-db-backup-bucket-create` — creates the `gftb-member-db-backups`
   bucket via the one-shot Job (B-3, step B2 above). Idempotent; safe to
   re-run if it fails partway.
3. `member-db-cluster-apply` — applies the Cluster and its ScheduledBackup,
   only now that `archive_command` has somewhere to land its first WAL
   segment, and waits for `Ready`.

Each of the three passes through `_reviewed-clean-main` and
`_operator-apply-confirm` independently; `GFTB_APPLY_CONFIRM=apply` covers
all three in one run.

**S2 — readback.** A green `Ready` condition does not prove the contract. This
does:

```bash
just member-db-readback
```

Check all four, and record them as release evidence:

1. `image=` resolves to the 16.15 digest
   (`ghcr.io/cloudnative-pg/postgresql@sha256:e38d10bb…`), not a tag.
2. `instances=1`, `ready=1`, `phase=Cluster in healthy state`.
3. `continuousArchiving=True`. **If this is `False`, stop.** WAL archiving is
   the RPO control; a cluster that is Ready but not archiving is failing the
   acceptance row silently and is filling its WAL volume.
4. Both PVCs are `Bound` on `openebs-bumble-postgresql-retain` at 20Gi / 10Gi.

**S3 — prove the role separation.** Connect as `gftb_app` and confirm
`CREATE TABLE` is rejected and `INSERT` on a migrator-created table is accepted.
This is the infra-side half of S1's acceptance row. The currently pinned,
published app carrier at
`af60fcd7539a4beff6f24e1a95eb11160df7c166` holds the corresponding
PostgreSQL integration proof and refuses a runtime role with `SUPERUSER` or
`BYPASSRLS`. It is not the final production carrier. Open-carrier heads and
validation status are release-coordination evidence, not part of this durable
runbook. After the app package/hydration successor lands and publishes, this
migrator pin and the separate web/worker pins must advance together to that one
successor digest before either carrier is Ready or applied. This cluster
supplies the managed LOGIN credential by Secret name; no password or tenant
identity is declared here.

## Step B4 — backup verification (the RPO/RTO evidence)

```bash
just member-db-backup-verify
```

It prints the schedule and every `Backup` object, and **fails if none has
reached `completed`**. A schedule that exists is not evidence; a completed
backup with a `stoppedAt` timestamp is.

The first base backup is not taken automatically (`immediate: false`) — trigger
one on demand so the first one happens while you are watching, rather than at
the next six-hourly boundary. Record the elapsed time; it is the input to the
RTO budget in step R.

## Step M — first migration (exact Git-pinned publisher carrier)

**M1 — the narrow credential, platform-side.** Derive the
`gftb-member-db-migrator-dsn` Secret in the **platform** namespace from the
CNPG-generated `gftb-member-db-app` Secret, key `dsn`, with
`sslmode=verify-full`. This is the owner/DDL credential; it goes to the
migration Job and to nothing else. Rotating the owner password means
re-deriving this Secret.

**M2 — render and dry-run.**

```bash
just member-db-migrate-render            # inspect the exact Git-pinned bytes
just member-db-migrate-server-dry-run
```

The render has no image input. It emits the reviewed Job template containing
the exact publisher image and source identity recorded above. The validator
refuses a tag, foreign repository, wrong digest/source receipt, `command:`
override, non-`["migrator"]` args, or any credential other than
`gftb-member-db-migrator-dsn`. The dry-run and apply each independently render the same Git-pinned template;
identity is validated each time, but byte identity across invocations is not
claimed.

**M3 — run it.**

```bash
GFTB_APPLY_CONFIRM=apply \
GFTB_MEMBER_DB_MIGRATE_CONFIRM=member-db-migrate \
  just member-db-migrate-apply
```

Two confirmations, on purpose: the house-wide one and a migration-specific one,
because this is the step that writes DDL into the member database. The recipe
creates the Job (`generateName`, so each run is a fresh object), waits for
completion, and prints the logs. `backoffLimit: 0` means a failure stays failed —
read the logs, do not re-run blindly.

Expected on a re-run: the migrator takes its advisory lock, finds every applied
filename+hash unchanged, and exits clean. **A re-run that reports work to do is
a red flag**, not a convenience: it means the ledger disagrees with the tree.

The migration creates and protects schema; it does **not** seed a tenant,
keyholder, owner/member identity, application decision, or activation. Those
domain transitions remain in the reviewed member lifecycle. Do not insert an
initial tenant row by hand as part of database bring-up.

## Step R — restore rehearsal (the RTO ≤ 4h proof, B-5)

The acceptance row is not met by declaring a backup. It is met by restoring one
and timing it. Rehearse into a **new** cluster; never over the live one.

**This now actually runs.** Before B-5, `allow-cnpg-operator-ingress` and
`allow-cnpg-to-backup-store-ingress` admitted only `cnpg.io/cluster:
gftb-member-db` — a label the rehearsal cluster's pods (which carry
`cnpg.io/cluster: gftb-member-db-restore`) do not have. The operator could
never reach the restore instance manager, and the restore pods could never
read the backups they exist to restore, so the rehearsal cluster never
reported `Ready`. Those two ingress policies now admit `gftb-member-db-restore` by name, and
`allow-restore-postgres-egress` separately admits only DNS, the current-gated
API /32s, the backup store, and restore-cluster peers. Keeping restore egress
separate prevents primary↔restore cross-admission.

1. Note the start time.
2. Create the rehearsal `Cluster`
   (`restore-cluster.template.yaml`, recovering from the same
   `barmanObjectStore` with `serverName: gftb-member-db`) and wait for it to
   reach `Ready`:

   ```bash
   GFTB_APPLY_CONFIRM=apply just member-db-restore-rehearsal-apply
   ```

   This exact recipe consumes the checked-in template path and therefore proves
   latest-available recovery only. A point-in-time target needs its own reviewed,
   exact template/recipe carrier with
   `spec.bootstrap.recovery.recoveryTarget.targetTime` and the same branch,
   confirmation, absence, and fresh-UID gates; an operator-local copy is not
   consumed by this recipe.
3. Verify: row counts match the source at the target time, and the migration
   ledger table is intact.
4. Note the end time. **Total must be under four hours**, including the object
   pull, not just the CNPG phase — the recipe's own wait is bounded generously
   (4h) so it cannot mask a rehearsal that ran over budget by timing out first.
5. Remove the rehearsal cluster:

   ```bash
   GFTB_APPLY_CONFIRM=apply just member-db-restore-rehearsal-teardown
   ```

   The teardown captures exactly the fresh Cluster's two owned PVC/PV pairs
   before deletion, waits for those PVCs to disappear and those exact retained
   PVs to reach `Released`, rechecks each claimRef, and prints only those PVs.
   It refuses a cluster whose exact owned claim inventory cannot be proved. Reclaiming a `Released` PV
   for reuse (`kubectl patch pv … -p '{"spec":{"claimRef":null}}'`) is
   tracked as a follow-up (P-2); for a rehearsal this is expected and fine to
   leave Released.

Record the measured RTO and the RPO (the gap between the target time and the
last committed transaction, which should be at most one `archive_timeout`
window — 5 minutes) in the TIN-3817 evidence.

Re-run this rehearsal whenever the PostgreSQL minor, the storage class, or the
object-store endpoint changes. Any of the three invalidates the timing.

## Rollback

| Failure | Recovery |
| --- | --- |
| Stack apply produces a bad `Cluster` | Revert the manifest change, re-run `just member-db-stack-server-dry-run`, then `member-db-stack-apply`. CNPG reconciles in place. |
| Migration fails | The Job is `backoffLimit: 0` and stays failed. Migrations are forward-only by contract (spec §6): fix forward in the app repo, publish a new exact artifact, land its reviewed Git pin here, then run M3 again. Do not hand-edit the database or inject an image at runtime. |
| Migration succeeded but the release is bad | Re-pin the previous platform image for web/worker. The schema stays; forward-only means the previous image must tolerate the newer schema, which is why additive migrations are the app-side rule. |
| Data loss | Step R, for real. That is what the rehearsal was for. |
| Object store lost | WAL archiving fails and `continuousArchiving` goes `False`. The database keeps serving; RPO degrades immediately. Treat as an incident: restore the endpoint before the WAL volume fills. |

## Receipts to record on TIN-3817

- Step O operator conformance output.
- Step B1 ruling text and date.
- Step S2 readback: the four checks, verbatim.
- Step B4 completed `Backup` name and duration.
- Step M3 Job name, image digest, and migrator log tail.
- Step R measured RTO and RPO.
