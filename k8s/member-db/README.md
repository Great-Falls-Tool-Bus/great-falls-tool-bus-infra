# GFTB member database substrate (TIN-3817, Member v0 slice S1 — infra half)

One dedicated PostgreSQL **16.15** CloudNativePG cluster for the ratified member
lifecycle, plus the pre-rollout migration Job that is the only workload allowed
to hold DDL authority over it.

This is the **infra half** of slice S1. The app half — the tenant schema, the
Drizzle pins, the `/bin/migrator` entrypoint with its advisory lock and
migration-hash ledger, and the RLS policies — is
`Great-Falls-Tool-Bus/greatfallstoolbus.org` **PR #172** (draft, stacked on S0
PR #171). It is open but **unlanded**, so no platform image carrying
`/bin/migrator` has been published yet and the migration half of this stack
cannot run. That is why the PR that introduced this directory is held as a
draft.

The role and schema names below are **aligned against PR #172's checked-in
SQL**, not guessed: `MIGRATION_ROLE = 'gftb_migrator'`,
`RUNTIME_ROLE = 'gftb_app'`. Those names live in a hash-ledgered, forward-only
migration on that side and in plain YAML on this side, so this side is the one
that moves.

Authority: `Great-Falls-Tool-Bus/meta` main,
`spec/member-v0-executable-slices-2026-08-18.md` §1.3 (S1) and
`spec/launch-member-v0-system-2026-08-16.md` §6 (runtime shape), against
TIN-3817's acceptance rows.

## What is declared here

| Path | What | Namespace |
| --- | --- | --- |
| `members-greatfallstoolbus-org-db-production/cluster.yaml` | CNPG `Cluster` `gftb-member-db`: PostgreSQL 16.15 digest-pinned, 1 instance, separate WAL volume, WAL archiving, owner + DML-only roles | database |
| `members-greatfallstoolbus-org-db-production/scheduledbackup.yaml` | Six-hourly base backup (the RTO control) | database |
| `members-greatfallstoolbus-org-db-production/networkpolicy.yaml` | Default-deny plus five named allows | database |
| `members-greatfallstoolbus-org-production/job-migrator.template.yaml` | Pre-rollout migration `Job` template, image supplied at dispatch | platform |
| `secrets.contract.yaml` | Names-only credential inventory | both |

Two namespaces, deliberately. The database sits in its own namespace so the
platform's service account has no reach over `Cluster`, `Backup`, or the
CNPG-generated Secrets, and so the admission list in the NetworkPolicy is a
real boundary rather than an intra-namespace convention.

## The operator already exists — this overlay does not install it

`cloudnative-pg` is **live on honey and estate-owned**, checked read-only on
2026-08-19:

| Fact | Value |
| --- | --- |
| Deployment | `cnpg-cloudnative-pg` in namespace `cnpg-system` |
| Image | `ghcr.io/cloudnative-pg/cloudnative-pg:1.22.0` |
| Chart | `cloudnative-pg-0.20.0` |
| CRDs | `clusters`, `backups`, `scheduledbackups`, `poolers` `.postgresql.cnpg.io`, served at `v1`, installed 2026-04-23 |
| Existing `Cluster` objects | none, estate-wide |

Its declaration lives in the substrate (`blahaj deploy/honey/rke2-cnpg.yaml`, an
RKE2 `HelmChart` adopted 2026-05-05), not here. `AGENTS.md`'s no-re-homing rule
cuts both ways: GFTB apply-plane content does not move into blahaj, and blahaj's
substrate does not get copied into GFTB. So this overlay **consumes the operator
through a named interface** and declares no install.

If a future estate ever lacks the operator, the attended install path is
recorded as step **O2** of `docs/runbooks/member-db-bringup.md`; it is a
substrate PR plus an operator apply, never something this repository applies.

## What is deliberately absent

- **No `Namespace` object.** Both namespaces are provisioned out of band, the
  same posture the web stack holds. The validator fails the build if one appears.
- **No `Secret` object and no secret value.** Every credential is a name. See
  `secrets.contract.yaml`.
- **No CI apply path.** `just check-hosted` runs `member-db-stack-validate`,
  which never contacts a cluster. Every mutating recipe is operator-local,
  needs an operator-custody kubeconfig, and passes through
  `_operator-apply-confirm`.
- **No platform-namespace stack.** The web/worker Deployments, their Service,
  and that namespace's own NetworkPolicies are a later slice. Only the migration
  Job template is here, because the migration is a database concern.

## How the acceptance rows are actually held

| TIN-3817 acceptance | Held by | Checked by |
| --- | --- | --- |
| one dedicated PostgreSQL **16.15** CNPG cluster | `cluster.yaml` `imageName` digest-pinned to the 16.15 system image | validator asserts the exact repository, a 64-hex digest, and refuses a tag |
| migration is a **separate protected Job** | `job-migrator.template.yaml`, `command: ["/bin/migrator"]` | validator asserts the entrypoint, `backoffLimit: 0`, and the placeholder image |
| with a **narrow credential** | Job gets the owner DSN; web/worker get the DML-only role | validator asserts the Job references only `gftb-member-db-migrator-dsn` |
| runtime role is **DML-only** | `managed.roles` + `postInitApplicationSQL` default privileges | validator asserts `bypassrls: false`, `superuser: false`, `createdb`/`createrole` false |
| **RPO no worse than one hour** | continuous WAL archiving + `archive_timeout: 300s` | validator asserts the parameter is present and `<= 3600s` |
| **RTO no worse than four hours** | six-hourly base backups + 30d retention + a rehearsed restore | validator asserts the schedule cadence; the rehearsal is runbook step R |

## The seam with the app half

Checked against PR #172's diff rather than assumed. Where the two halves meet:

| Concern | This side declares | PR #172 expects | Composes? |
| --- | --- | --- | --- |
| Migration/owner role | `bootstrap.initdb.owner: gftb_migrator` | `MIGRATION_ROLE = 'gftb_migrator'`, owns every table | yes |
| Runtime role | `gftb_app`, created `NOLOGIN` at bootstrap, then given LOGIN + a password by `managed.roles` | `0002` creates `gftb_app` only `IF NOT EXISTS`; fails on `SUPERUSER` or `BYPASSRLS`, **never** on `LOGIN` | yes — `0002` finds the role, skips creation, and needs no `CREATEROLE` |
| `bypassrls` | `false`, asserted by this repo's validator | `0002` raises if it is true | yes, belt and braces |
| Schema `public` grants | default privileges `FOR ROLE gftb_migrator` at bootstrap | `0002` grants explicitly | overlapping on purpose: this side covers the window before `0002` first runs |
| Schemas `auth`, `migration` | nothing — not this side's | `0002` creates `auth`, grants `gftb_app` there, and revokes it from `migration` entirely | yes |
| Database name | `gftb_member` | unpinned (`DATABASE_URL` is a name) | this side's choice |
| Migrator image | guard admits `greatfallstoolbus.org` **or** `gftb-platform`, digest-pinned | S0 publishes `greatfallstoolbus.org` today; TIN-3815 renames it later | yes, and narrow the guard once the rename lands |

Two things the app half still owes, which nothing here can check:

1. **Pod labels.** The database admits `app.kubernetes.io/part-of: gftb-platform`
   with `app.kubernetes.io/component` in `web`, `worker`, `migrator`. Pods
   without those labels are denied on 5432.
2. **`C` collation.** Case-insensitive comparison must be explicit (`lower()` or
   `citext`) in the app's own migrations; it is not free from the database.

And one thing that would come back to this file: §1.3's GUC fix choice. PR #172
takes **fix A** (transaction handle out of `withTenant`), which needs nothing
here. Fix **B** would have needed an infra-owned `ALTER ROLE ... SET
app.tenant_id` in `cluster.yaml`.

## Recipes

```bash
just member-db-stack-validate
MEMBER_DB_APPLY_KUBECONFIG=/path/to/member-db-apply.kubeconfig just member-db-stack-server-dry-run
MEMBER_DB_MIGRATOR_IMAGE=ghcr.io/great-falls-tool-bus/gftb-platform@sha256:... just member-db-migrate-render
```

Bring-up, first migration, backup verification, and the restore rehearsal are
all attended: `docs/runbooks/member-db-bringup.md`.
