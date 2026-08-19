# GFTB member database bring-up runbook

Tracking: TIN-3817 (Member v0 slice S1, infra half). Authority:
`Great-Falls-Tool-Bus/meta` main `spec/member-v0-executable-slices-2026-08-18.md`
§1.3 and `spec/launch-member-v0-system-2026-08-16.md` §6.
Stack: `k8s/member-db/` (see the README beside the manifests).

This runbook brings up one dedicated PostgreSQL 16.15 CloudNativePG cluster for
the ratified member lifecycle, runs the first pre-rollout migration, and proves
the RPO ≤ 1h / RTO ≤ 4h acceptance row with a real restore. Every step is
**attended**. Nothing in CI applies any of it.

> **Current state (2026-08-19): DECLARED, NOT APPLIED.** No `Cluster` object
> exists anywhere on the estate. No namespace has been created. No credential
> has been minted. Steps N through R below have not been run.

## Read this before starting: what is actually blocked

Two independent blockers, and they gate different halves of the runbook.

1. **The app half of slice S1 has not landed.** The migration Job's image is
   `ghcr.io/great-falls-tool-bus/gftb-platform`, whose `/bin/migrator`
   entrypoint, advisory lock, and migration-hash ledger are S1's app-side
   deliverable. **Steps M1–M3 cannot run before that image exists.** Steps
   N through B5 (the database itself) do not depend on it.
2. **The object-store ruling in step B1 is open.** WAL archiving starts the
   moment the `Cluster` is applied, so B1 is a hard pre-apply gate for step S,
   not a follow-up. Applying with an unreachable object store gives a database
   that comes up healthy and then wedges when the WAL volume fills.

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

## Step B — backup destination (HARD PRE-APPLY GATE)

**B1 — the open ruling.** `cluster.yaml` declares
`endpointURL: http://seaweedfs.tcfs.svc.cluster.local:8333` and
`destinationPath: s3://gftb-member-db-backups/`. Two things need an operator
decision before step S:

- **Which endpoint.** The `tcfs` namespace exposes both `seaweedfs:8333` and
  `tcfs-s3-posture-gateway:8333`. Pick the admitted tenant entrypoint.
- **Whether an estate-owned bucket is acceptable at all** for member personal
  data, or whether GFTB should get its own object-store lane. The validator only
  guarantees the endpoint is in-cluster (never a public URL); it cannot make a
  tenancy decision.

Record the ruling here with a date, then update `cluster.yaml` if the endpoint
changes. **Do not proceed to step S until this line is filled in.**

> Ruling: _(unrecorded)_

**B2 — bucket and credential.** Create the `gftb-member-db-backups` bucket,
scoped to this cluster only. Mint the `gftb-member-db-backup-s3` Secret in the
database namespace with keys `ACCESS_KEY_ID` and `ACCESS_SECRET_KEY`. Names only
are recorded in `k8s/member-db/secrets.contract.yaml`; the values never leave the
cluster.

## Step C — credentials

**C1 — the owner credential is not yours to make.** CNPG generates
`gftb-member-db-app` at bootstrap with the `gftb_member_migrator` password. No
operator action creates or reads it.

**C2 — mint the runtime credential.** Create `gftb-member-db-runtime` in the
database namespace, type `kubernetes.io/basic-auth`, `username:
gftb_member_runtime`. `managed.roles` binds the role to it. This is the DML-only
credential the platform's web and worker Deployments will consume.

## Step S — apply the database stack

```bash
just member-db-stack-validate
export MEMBER_DB_APPLY_KUBECONFIG=/path/to/member-db-apply.kubeconfig
just member-db-stack-server-dry-run
GFTB_APPLY_CONFIRM=apply just member-db-stack-apply
```

`member-db-stack-apply` runs the offline guard and the server dry-run first,
then requires a clean `main` worktree and the explicit confirmation, then applies
and waits for `Ready`.

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

**S3 — prove the role separation.** Connect as `gftb_member_runtime` and confirm
`CREATE TABLE` is rejected and `INSERT` on a migrator-created table is accepted.
This is the infra-side half of S1's acceptance row; the app half proves the same
thing in `just test-integration` against a testcontainer.

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
export MEMBER_DB_MIGRATOR_IMAGE=ghcr.io/great-falls-tool-bus/gftb-platform@sha256:<64 hex>
just member-db-migrate-render            # inspect the exact bytes
just member-db-migrate-server-dry-run
```

The input guard refuses a tag, refuses the declare-only `PLACEHOLDER`, and
requires the exact `gftb-platform` repository. The render is the single source
of the bytes: the dry-run and the apply both go through it.

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

## Step R — restore rehearsal (the RTO ≤ 4h proof)

The acceptance row is not met by declaring a backup. It is met by restoring one
and timing it. Rehearse into a **new** cluster; never over the live one.

1. Note the start time.
2. Create a second `Cluster` (for example `gftb-member-db-restore`) in the same
   namespace, whose `bootstrap.recovery` sources an `externalClusters` entry
   pointing at the same `barmanObjectStore` with `serverName: gftb-member-db`.
   Point-in-time recovery goes in `recoveryTarget.targetTime`.
3. Wait for it to reach `Ready`, then verify: row counts match the source at the
   target time, and the migration ledger table is intact.
4. Note the end time. **Total must be under four hours**, including the object
   pull, not just the CNPG phase.
5. Remove the rehearsal cluster and its PVCs.

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
