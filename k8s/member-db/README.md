# GFTB member database substrate (TIN-3817, Member v0 slice S1 — infra half)

One dedicated PostgreSQL **16.15** CloudNativePG cluster for the ratified member
lifecycle, plus the pre-rollout migration Job that is the only workload allowed
to hold DDL authority over it.

This is the **infra half** of slice S1. The app half — the tenant schema, the
Drizzle pins, the `/bin/migrator` entrypoint with its advisory lock and
migration-hash ledger, and the RLS policies — lives in `gftb-platform` and has
not landed yet. Nothing here can be applied before it does, which is why the PR
that introduced this directory is held as a draft.

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

## Hand-offs the app half must honour

1. **Pod labels.** The database admits `app.kubernetes.io/part-of: gftb-platform`
   with `app.kubernetes.io/component` in `web`, `worker`, `migrator`. Pods
   without those labels are denied on 5432.
2. **`C` collation.** Case-insensitive comparison must be explicit (`lower()` or
   `citext`) in the app's own migrations; it is not free from the database.
3. **The `auth` schema.** S2 vendors six `auth.*` tables. The default privileges
   declared here cover schema `public` only, so S2's vendored migration must
   issue its own `GRANT USAGE ON SCHEMA auth` and matching
   `ALTER DEFAULT PRIVILEGES` for `gftb_member_runtime`.
4. **The GUC fix choice.** Spec §1.3 requires S1's PR body to state whether it
   took fix **A** (per-unit-of-work adapter construction) or fix **B**
   (role-level GUC). Fix B needs an infra-owned `ALTER ROLE ... SET
   app.tenant_id`, which is a change to `cluster.yaml` here — not something the
   app half can do alone.

## Recipes

```bash
just member-db-stack-validate
MEMBER_DB_APPLY_KUBECONFIG=/path/to/member-db-apply.kubeconfig just member-db-stack-server-dry-run
MEMBER_DB_MIGRATOR_IMAGE=ghcr.io/great-falls-tool-bus/gftb-platform@sha256:... just member-db-migrate-render
```

Bring-up, first migration, backup verification, and the restore rehearsal are
all attended: `docs/runbooks/member-db-bringup.md`.
