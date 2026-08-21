# GFTB member database bring-up runbook

Tracking: TIN-3817 (Member v0 slice S1, infra half). Authority:
`Great-Falls-Tool-Bus/meta` main `spec/member-v0-executable-slices-2026-08-18.md`
§1.3 and `spec/launch-member-v0-system-2026-08-16.md` §6.
Stack: `k8s/member-db/` (see the README beside the manifests).

This runbook brings up one dedicated PostgreSQL 16.15 CloudNativePG cluster for
the ratified member lifecycle, runs the first pre-rollout migration, and proves
the RPO ≤ 1h / RTO ≤ 4h acceptance row with a real restore. Every step is
**attended**. Nothing in CI applies any of it.

> **Current state (2026-08-21): DECLARED, NOT APPLIED.** No `Cluster` object
> exists anywhere on the estate. No namespace has been created. No credential
> has been minted. Steps N through R below have not been run. The object-store
> ruling (step B1) IS closed — see below — so the remaining pre-apply blocker
> is the app half landing (S1 below) plus, at Phase 4, merging this PR itself
> (step S precondition, B-6).

## Read this before starting: what is actually blocked

One blocker gates half of this runbook; the object-store question is decided.

1. **The app half of slice S1 is open but unlanded.**
   `Great-Falls-Tool-Bus/greatfallstoolbus.org` **PR #172** (draft, stacked on
   S0 PR #171) carries the `/bin/migrator` entrypoint, the advisory lock, and
   the migration-hash ledger. Until it lands and publishes an image,
   **steps M1-M3 cannot run.** Steps N through B4 (the database itself) do not
   depend on it.

   The role names here are aligned to that PR's checked-in SQL —
   `gftb_migrator` (owner/DDL) and `gftb_app` (DML-only). If PR #172 renames
   either before landing, `cluster.yaml` and
   `scripts/validate-member-db-stack.sh` move with it.
2. **The object-store ruling in step B1 is CLOSED (2026-08-20).** GFTB gets
   its own dedicated rustfs, not an estate-owned tcfs bucket. `cluster.yaml`
   and `rustfs.yaml` already carry the ruling; step B1 below is the record of
   it, not an open question. What remains before step S is executing B2 (the
   bucket-create step) in order (step B, below) and, separately, B-6's
   merge-before-Phase-4 precondition.

## Step O — CloudNativePG operator conformance (read-only)

The operator is **already live and estate-owned**. Confirm it, do not install
it:

```bash
kubectl --context honey get crd | grep cnpg
kubectl --context honey -n cnpg-system get deploy cnpg-cloudnative-pg \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Expected, as observed 2026-08-19:

| Check | Expected |
| --- | --- |
| CRDs | `backups`, `clusters`, `poolers`, `scheduledbackups` `.postgresql.cnpg.io` |
| Served version | `v1` |
| Operator image | `ghcr.io/cloudnative-pg/cloudnative-pg:1.22.0` |
| Chart | `cloudnative-pg-0.20.0` |
| Existing `Cluster` objects | none |

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

**B2 — bucket and credential. Mint BOTH Secrets BEFORE step S — only the
bucket creation is step-S-ordered.** `rustfs.yaml`'s `envFrom` is
`optional: false`: if the Secrets are unminted when step S applies the
store, the pod sits in `CreateContainerConfigError` and the 300s rollout
wait fails (loud, fast, recoverable — but avoidable). Mint the
`gftb-member-db-backup-s3` Secret AND the
`gftb-member-db-backup-store-root` Secret in the database namespace —
**identically**: same `ACCESS_KEY_ID`/`ACCESS_SECRET_KEY` value pair under
the two different key-naming conventions each side needs
(`k8s/member-db/secrets.contract.yaml` explains why this is one credential,
not two). Values never leave the cluster.

The bucket itself is created by `just member-db-backup-bucket-create`
(B-3) — a one-shot Job carrying the `cnpg.io/cluster: gftb-member-db` label
so the existing NetworkPolicy admits it into the store, rather than a helper
pod the policy would deny. It is step two of the ordered chain in step S
below; you do not run it standalone.

## Step C — credentials

**C1 — the owner credential is not yours to make.** CNPG generates
`gftb-member-db-app` at bootstrap with the `gftb_migrator` password. No
operator action creates or reads it.

**C2 — mint the runtime credential.** Create `gftb-member-db-runtime` in the
database namespace, type `kubernetes.io/basic-auth`, `username:
gftb_app`. `managed.roles` binds the role to it. This is the DML-only
credential the platform's web and worker Deployments will consume.

## Step S — apply the database stack (ORDERED, B-4)

**Precondition (B-6): this PR must be MERGED before this step runs.** Every
mutating recipe below passes through `_reviewed-clean-main`, which requires
the current branch to be `main`, a clean worktree, and `HEAD` to equal the
verified `origin/main` tip — so none of them can run from this PR's branch,
only after it lands. `member-db-stack-server-dry-run` (used by
`member-db-stack-validate` and the dry-run below) does **not** carry that
requirement, so Phase 3's read-only proof works from the branch today; Phase
4 is gated on merging #118 first.

```bash
just member-db-stack-validate
export MEMBER_DB_APPLY_KUBECONFIG=/path/to/member-db-apply.kubeconfig
just member-db-stack-server-dry-run
GFTB_APPLY_CONFIRM=apply just member-db-stack-apply
```

`member-db-stack-apply` is a thin alias over three ordered steps — run it
directly, or run the three yourself to watch each one land:

1. `member-db-backup-store-apply` — applies ONLY the NetworkPolicy family and
   rustfs (StatefulSet/Service/PVC), filtered from the SAME rendered
   `kubectl kustomize` bytes `member-db-stack-validate` already asserted, and
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
This is the infra-side half of S1's acceptance row; PR #172 proves the same
thing in `just test-integration` against a real PostgreSQL. Note that its
fixture asserts `gftb_app` has **no** login, which is true in a bare
testcontainer and deliberately not true here — this cluster is what issues the
login credential, and `0002` tolerates it (it fails only on `SUPERUSER` or
`BYPASSRLS`).

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

## Step M — first migration (BLOCKED until the app half lands)

**M1 — the narrow credential, platform-side.** Derive the
`gftb-member-db-migrator-dsn` Secret in the **platform** namespace from the
CNPG-generated `gftb-member-db-app` Secret, key `dsn`, with
`sslmode=verify-full`. This is the owner/DDL credential; it goes to the
migration Job and to nothing else. Rotating the owner password means
re-deriving this Secret.

**M2 — render and dry-run.**

```bash
# TIN-3815's repository rename has not happened yet, so today this is the
# greatfallstoolbus.org slug; the guard admits the gftb-platform slug too.
export MEMBER_DB_MIGRATOR_IMAGE=ghcr.io/great-falls-tool-bus/greatfallstoolbus.org@sha256:<64 hex>
just member-db-migrate-render            # inspect the exact bytes
just member-db-migrate-server-dry-run
```

The input guard refuses a tag and refuses the declare-only `PLACEHOLDER`. It
admits exactly two repositories — `greatfallstoolbus.org` (today) and
`gftb-platform` (after TIN-3815) — and nothing else. The render is the single
source of the bytes: the dry-run and the apply both go through it.

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

## Step R — restore rehearsal (the RTO ≤ 4h proof, B-5)

The acceptance row is not met by declaring a backup. It is met by restoring one
and timing it. Rehearse into a **new** cluster; never over the live one.

**This now actually runs.** Before B-5, `allow-cnpg-operator-ingress` and
`allow-cnpg-to-backup-store-ingress` admitted only `cnpg.io/cluster:
gftb-member-db` — a label the rehearsal cluster's pods (which carry
`cnpg.io/cluster: gftb-member-db-restore`) do not have. The operator could
never reach the restore instance manager, and the restore pods could never
read the backups they exist to restore, so the rehearsal cluster never
reported `Ready`. Both policies now admit `gftb-member-db-restore` too, by
name, alongside the primary.

1. Note the start time.
2. Create the rehearsal `Cluster`
   (`restore-cluster.template.yaml`, recovering from the same
   `barmanObjectStore` with `serverName: gftb-member-db`) and wait for it to
   reach `Ready`:

   ```bash
   GFTB_APPLY_CONFIRM=apply just member-db-restore-rehearsal-apply
   ```

   For a specific point-in-time target rather than latest-available, add
   `spec.bootstrap.recovery.recoveryTarget.targetTime` to an operator-local
   copy of `restore-cluster.template.yaml` before running the recipe above —
   never commit a real timestamp to the reviewed template.
3. Verify: row counts match the source at the target time, and the migration
   ledger table is intact.
4. Note the end time. **Total must be under four hours**, including the object
   pull, not just the CNPG phase — the recipe's own wait is bounded generously
   (4h) so it cannot mask a rehearsal that ran over budget by timing out first.
5. Remove the rehearsal cluster:

   ```bash
   just member-db-restore-rehearsal-teardown
   ```

   `openebs-bumble-postgresql-retain` means the two PVCs' underlying PVs go
   to `Released`, not deleted, when the Cluster is removed — the recipe
   prints them so nothing is orphaned silently. Reclaiming a `Released` PV
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
| Migration fails | The Job is `backoffLimit: 0` and stays failed. Migrations are forward-only by contract (spec §6): fix forward in the app repo and run M3 again with a new digest. Do not hand-edit the database. |
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
