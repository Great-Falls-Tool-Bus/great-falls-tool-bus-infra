# GFTB member database desired state

This directory carries the Great Falls Tool Bus half of Member v0 slice S1:
one dedicated PostgreSQL 16.15 CloudNativePG cluster, continuous WAL
archiving, scheduled base backups, a dedicated object store, and the
pre-rollout migration Job.

Authority:

- `Great-Falls-Tool-Bus/meta` `spec/member-v0-executable-slices-2026-08-18.md`
  §1.3 (S1)
- `Great-Falls-Tool-Bus/meta` `spec/launch-member-v0-system-2026-08-16.md`
  §6 (runtime shape)
- Linear TIN-3817 (Member v0 persistence acceptance)
- Linear TIN-4246 and TIN-4249 (protected v4 owner-overlay convergence)

The application owns migrations, the immutable migration-hash ledger, and
tenant-aware runtime behavior. This overlay owns only consumer desired state.
It does not own a runner, provider placement, registry credential bytes,
kubeconfig, cluster endpoint, or alternate apply path.

## Declared objects

| Path | Contract |
| --- | --- |
| `members-greatfallstoolbus-org-db-production/cluster.yaml` | PostgreSQL 16.15 CNPG cluster, separate WAL volume, WAL archiving, migration-owner and DML-only runtime roles |
| `members-greatfallstoolbus-org-db-production/scheduledbackup.yaml` | six-hourly base backup schedule |
| `members-greatfallstoolbus-org-db-production/networkpolicy.yaml` | default-deny network policy and closed workload admission |
| `members-greatfallstoolbus-org-db-production/rustfs.yaml` | dedicated object-store Service, StatefulSet, and PVC |
| `members-greatfallstoolbus-org-db-production/bucket-create.template.yaml` | one-shot bucket initialization Job |
| `members-greatfallstoolbus-org-db-production/restore-cluster.template.yaml` | isolated restore-rehearsal Cluster |
| `members-greatfallstoolbus-org-production/job-migrator.template.yaml` | one-shot pre-rollout migration Job |
| `secrets.contract.yaml` | names-only credential inventory and authority separation |

The database and platform workloads use separate namespaces. No Namespace or
Secret object is committed here. Secret values must be owner-authority outputs;
this public consumer overlay references only names, types, keys, roles, and
consumers.

## Acceptance properties

- The database image is the exact PostgreSQL 16.15 digest.
- `gftb_migrator` owns DDL; `gftb_app` is DML-only and cannot bypass RLS.
- The migration runs as a separate non-retrying Job using only the migration
  credential.
- Continuous WAL archiving bounds structured-data RPO to no worse than one
  hour.
- Scheduled base backups and an independent restore rehearsal carry the
  four-hour RTO proof. Declaring the schedule alone is not that proof.
- Workload images are digest-pinned and private-registry credentials are
  referenced only by their namespace-local Secret name.
- Network policies admit only the consumer-owned web, worker, migrator, CNPG,
  and backup-store relationships. Provider control-plane, DNS, and observability
  relations are deliberately absent from this carrier.

The migration image source SHA, publisher receipt, and digest must be advanced
atomically from one verified `ActionOutputSet` before this carrier is eligible
to land. A source validation result never claims that an object is reconciled,
running, served, backed up, or restored.

## Validation

The only repository entrypoints are finite source checks:

```text
just member-db-stack-validate
just member-db-stack-selftest
```

They validate committed desired state without acquiring apply authority. This
source is not activated until the protected shared v4 owner-overlay path exists
and records an exact-plan, apply, readback, and rollback receipt. There is no
repository-local apply, kubeconfig, readback, migration dispatch, or alternate
recovery path.
