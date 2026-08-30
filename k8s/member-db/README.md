# GFTB member database substrate (TIN-3817, Member v0 slice S1 — infra half)

One dedicated PostgreSQL **16.15** CloudNativePG cluster for the ratified member
lifecycle, plus the pre-rollout migration Job that is the only workload allowed
to hold DDL authority over it.

This is the **infra half** of slice S1. The app half is merged at exact source
`af60fcd7539a4beff6f24e1a95eb11160df7c166`: tenant-aware schema, the
`/bin/migrator` entrypoint, advisory lock, immutable migration-hash ledger,
and RLS/runtime-role checks. Publisher workflow run `33279762284`, attempt 1,
produced artifact
`greatfallstoolbus-org-image-af60fcd7539a4beff6f24e1a95eb11160df7c166-33279762284-1`
and the image now pinned in this carrier. Those facts prove merged, published,
and Git-pinned states only; they do not prove this stack applied, running, or
served. This is a frozen interim carrier, not the final production pin: app main
is now signed `3d6909c242dbd847cf044730f74347a69eeaae80`, and app PR #218 at
signed `dd12f0a1acedc8fb39cd3b63dd3ffc542c4ce3f4` changes the
package/hydration graph. PR #121's repaired signed head
`ed6567986625ca9c2899d71254e10a40449a4c7d` already uses the exact
`app.kubernetes.io/part-of=great-falls-tool-bus` identity admitted by this
database policy. After #218 lands and publishes, the migrator here and #121's
web/worker must advance together to the same successor digest before
Ready/apply.

The role names are bound on both sides: `gftb_migrator` owns DDL and
`gftb_app` is the DML-only runtime role. The migration creates the `tenant`
table and the rest of the schema; it does not seed an initial tenant,
keyholder, owner/member, application decision, or activation.

Authority: `Great-Falls-Tool-Bus/meta` main,
`spec/member-v0-executable-slices-2026-08-18.md` §1.3 (S1) and
`spec/launch-member-v0-system-2026-08-16.md` §6 (runtime shape), against
TIN-3817's acceptance rows.

## What is declared here

| Path | What | Namespace |
| --- | --- | --- |
| `members-greatfallstoolbus-org-db-production/cluster.yaml` | CNPG `Cluster` `gftb-member-db`: PostgreSQL 16.15 digest-pinned, 1 instance, separate WAL volume, WAL archiving, owner + DML-only roles | database |
| `members-greatfallstoolbus-org-db-production/scheduledbackup.yaml` | Six-hourly base backup (the RTO control) | database |
| `members-greatfallstoolbus-org-db-production/networkpolicy.yaml` | Default-deny plus eight named allows, including separate closed restore egress | database |
| `members-greatfallstoolbus-org-db-production/rustfs.yaml` | GFTB-owned rustfs StatefulSet+Service+PVC backing WAL/base-backup storage (B1 ruling, 2026-08-20) | database |
| `members-greatfallstoolbus-org-db-production/bucket-create.template.yaml` | One-shot Job that mints the `gftb-member-db-backups` bucket inside rustfs (B-3) | database |
| `members-greatfallstoolbus-org-db-production/restore-cluster.template.yaml` | Restore-rehearsal `Cluster` template — the RTO<=4h acceptance row's proof path (B-5) | database |
| `members-greatfallstoolbus-org-production/job-migrator.template.yaml` | One-shot pre-rollout migration `Job`, exact publisher image/source pinned in Git | platform |
| `secrets.contract.yaml` | Names-only credential inventory | both |

Two namespaces, deliberately. The database sits in its own namespace so the
platform's service account has no reach over `Cluster`, `Backup`, or the
CNPG-generated Secrets, and so the admission list in the NetworkPolicy is a
real boundary rather than an intra-namespace convention.

## Operator substrate: historical declaration, current readback required

A read-only observation on 2026-08-19 found `cnpg-cloudnative-pg` in
`cnpg-system`, image `ghcr.io/cloudnative-pg/cloudnative-pg:1.22.0`, chart
`cloudnative-pg-0.20.0`, and the four CNPG CRDs served at `v1`. That is a
historical receipt, not live truth. This PR performs no cluster readback and
does not claim that a `Cluster`, namespace, or credential is currently absent
or present. The attended apply sitting must read and record current state.

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
- **No platform-namespace serving stack in this carrier.** Web/worker and their
  policies live in their separate reviewed carrier. This slice owns only the
  exact Git-pinned migration Job template and its names-only `ghcr-pull`
  reference.

## How the acceptance rows are actually held

| TIN-3817 acceptance | Held by | Checked by |
| --- | --- | --- |
| one dedicated PostgreSQL **16.15** CNPG cluster | `cluster.yaml` `imageName` digest-pinned to the 16.15 system image | validator asserts the exact repository, a 64-hex digest, and refuses a tag |
| migration is a **separate protected Job** | `job-migrator.template.yaml`, exact Git-pinned publisher image, `args: ["migrator"]`, no `command:` | validator asserts exact image/source identity, positional args, `backoffLimit: 0`, `restartPolicy: Never`, and narrow DSN |
| with a **narrow credential** | Job gets the owner DSN; web/worker get the DML-only role | validator asserts the Job references only `gftb-member-db-migrator-dsn` |
| runtime role is **DML-only** | `managed.roles` + `postInitApplicationSQL` default privileges | validator asserts `bypassrls: false`, `superuser: false`, `createdb`/`createrole` false |
| **RPO no worse than one hour** | continuous WAL archiving + `archive_timeout: 300s` | validator asserts the parameter is present and `<= 3600s` |
| **RTO no worse than four hours** | six-hourly base backups + 30d retention + a rehearsed restore | validator asserts the schedule cadence; the rehearsal is runbook step R |

## The seam with the app half

Checked against the merged app carrier
`af60fcd7539a4beff6f24e1a95eb11160df7c166`, not an open PR:

| Concern | Infra carrier | Merged app carrier |
| --- | --- | --- |
| Migration/owner role | `bootstrap.initdb.owner: gftb_migrator` | migrator uses `gftb_migrator` and owns schema |
| Runtime role | managed `gftb_app`, LOGIN credential by Secret name | migrations refuse `SUPERUSER`/`BYPASSRLS` and grant only runtime access |
| RLS | `bypassrls: false` asserted here | tenant-scoped tables carry RLS/FORCE policy and runtime checks |
| Schema | cluster supplies roles/default privileges | forward-only ledger creates schema; no tenant or member identity is seeded |
| Image | exact `greatfallstoolbus.org@sha256` pin in the Job | publisher receipt above identifies source and artifact |

The database NetworkPolicy admits platform pods only when
`app.kubernetes.io/part-of: great-falls-tool-bus` and component is one of
`web`, `worker`, or `migrator`. This Job carries the exact migrator
identity. Web/worker labels belong to their separate reviewed release carrier;
nothing in this database slice creates those workloads.

Case-insensitive comparison remains app/migration behavior (for example,
explicit `lower()` or `citext`); the database overlay must not add an
infra-owned tenant GUC or hand-seeded row to approximate that behavior.

## Recipes

```bash
just member-db-stack-validate
just member-db-stack-selftest
just member-db-migrate-render
MEMBER_DB_APPLY_KUBECONFIG=/path/to/member-db-apply.kubeconfig just member-db-stack-server-dry-run
```

The migration render takes no image input: its publisher image and source
identity are part of the reviewed Git carrier. It also references
`ghcr-pull`, a namespace-local `kubernetes.io/dockerconfigjson` Secret by
name. Only gftb-site is authorized public; the app package was observed
anonymously pullable during review, and this carrier changes no visibility or
claims a private state.

Bring-up, first migration, backup verification, and the restore rehearsal are
all attended: `docs/runbooks/member-db-bringup.md`.
