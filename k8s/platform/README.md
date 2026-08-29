# GFTB platform staging serving (TIN-3815 / TIN-3817 — the serving half of the platform namespace)

The web + worker Deployments, the web ClusterIP Service, and the default-deny
NetworkPolicy family for the gftb-platform member/inventory application in
`members-greatfallstoolbus-org-production`, served at
**staging.greatfallstoolbus.org** once the operator opens the fail-closed
route intent. This is the stack the member-db slice deliberately deferred
("the web/worker Deployments, their Service, and that namespace's own
NetworkPolicies are a later slice" — `../member-db/README.md`, PR #118).

> **MERGING THIS DIRECTORY APPLIES NOTHING — and unlike the legacy web stack
> it cannot even be applied as committed.** Both Deployments carry the
> `PLACEHOLDER-PLATFORM-IMAGE` sentinel and the `PLACEHOLDER-GFTB-TENANT-ID`
> sentinel, and `scripts/validate-platform-stack.sh` (run by
> `just platform-stack-validate`, in `check-hosted`) *requires* the sentinels
> intact — a real digest or UUID committed here fails CI. The reviewed values
> arrive only through the attended `platform-release-*` chain (below), which
> renders once, records the bytes, and applies exactly those bytes.

## Authority

| Claim | Source |
| --- | --- |
| This repo owns "PostgreSQL, Secrets, workloads, migrations, image pins, staging/apex routes, backups, runtime receipts"; product behavior stays out | meta `spec/launch-member-v0-system-2026-08-16.md` §2 repository table |
| `staging.greatfallstoolbus.org` = exact-PR/operator QA with the **application** auth path; `members.greatfallstoolbus.org` = member production later, application auth, never a Cloudflare Access substitute | meta `spec/member-v0-executable-slices-2026-08-18.md` §4 hosts row; TIN-3815 acceptance |
| One immutable image, three entrypoints (`web`, `worker`, `migrator`); pods never migrate on startup; ClusterIP behind the in-cluster cloudflared tunnel; operator-gated digest pin; rollback = re-pin the previous digest | spec §6 runtime shape; slices §1.3 deploy row; ADR 0008 §3 / ADR 0010 §5 (read at `13ab0fe^:decisions/` in meta) |
| Aug-30 Member v0 requires a staging QA pass first | spec §12 P1; launch-authority-flow.mmd (AppImage → Infra → "serve gated app") |
| The platform image publishes as `ghcr.io/great-falls-tool-bus/greatfallstoolbus.org` until the TIN-3815 rename gates pass (private CI, package pull, rollback proof under the new identity) | ADR 0014 §1.3–1.5 |
| DATABASE_URL is two never-crossed Secrets; GFTB_TENANT_ID is config-review material; GFTB_WORKER_ID is per-replica observability (the guard is the per-claim lease token); gftb_app `connectionLimit: 40` is the budget | TIN-3817 hand-off rows; app half `src/lib/server/worker.ts` and `src/lib/server/outbox/dispatch.ts` headers (PR #173 review HIGH-2); `../member-db/.../cluster.yaml` |

## Files

| File | Role | Fail-closed posture |
| --- | --- | --- |
| `members-greatfallstoolbus-org-production/deployment-web.yaml` | adapter-node member/inventory app (image-default `/bin/web`; no Kubernetes command/args override) | image + tenant sentinels; replicas 2 (budget); non-root 1001; read-only rootfs; `/health` probes on :3000 |
| `members-greatfallstoolbus-org-production/deployment-worker.yaml` | transactional-outbox dispatcher (image `Cmd` overridden only by `args: ["worker"]`; no `command:` override) | same sentinels; replicas 1, `Recreate` (budget); no ports, no Service, no ingress; `GFTB_WORKER_ID` from the pod name (downward API) |
| `members-greatfallstoolbus-org-production/service-web.yaml` | ClusterIP 80→3000, web only | internal DNS only; never internet-exposed directly |
| `members-greatfallstoolbus-org-production/networkpolicy.yaml` | default-deny **both directions** + named allows | ingress: cloudflared→web:3000, prometheus; egress: DNS + member-db:5432 only; no Stripe egress until TIN-3818's sitting |
| `members-greatfallstoolbus-org-production/kustomization.yaml` | kustomize entrypoint | renders cleanly; creates **no** Namespace |
| `secrets.contract.yaml` | names-only additions this slice consumes | no values, ever; extends (never restates) `../member-db/secrets.contract.yaml` |
| `../../tofu/intent/great-falls-tool-bus/staging-platform-route.json` | staging route intent | `applied:false`, `dns_enabled:false`, `route_enabled:false`; Access-gated posture recorded |

**Deliberately absent:** a Namespace object (operator-provisioned out of band,
as every stack here), any Secret object or value, any CI apply path, any
`members.greatfallstoolbus.org` route intent (member production is its own
later sitting), and the migration Job — that template lives in
`../member-db/members-greatfallstoolbus-org-production/` (PR #118) because the
migration is a database concern; it is one-shot `generateName` state and is
not kustomized into this serving stack.

## The credential boundary (why this stack can never migrate)

Two DSN Secrets reach the same database with different authority, and no
workload is ever handed both (`../member-db/secrets.contract.yaml`):

| Secret (platform namespace) | Role | Goes to | Never goes to |
| --- | --- | --- | --- |
| `gftb-member-db-runtime-dsn` | `gftb_app` (DML-only, `bypassrls: false`, `connectionLimit: 40`) | web + worker Deployments (this stack) | the migration Job |
| `gftb-member-db-migrator-dsn` | `gftb_migrator` (owner/DDL) | the pre-rollout migration Job (PR #118) | web + worker |

`validate-platform-stack.sh` fails this stack if the migrator secret name
appears in any executable position, and both Deployments reference
`gftb-member-db-runtime-dsn/dsn` exactly.

## The connection budget

`gftb_app` carries `connectionLimit: 40`; the app half's `pg.Pool` defaults to
max 10 per process. The committed shape is sized so the worst case is exactly
the cap: web 2×10 + web rollout surge 1×10 + worker 1×10 = 40 (the worker uses
`Recreate`, so it never doubles). The validator pins web `replicas: 2` /
`maxSurge: 1` and worker `replicas: 1` / `Recreate`; raising any of them is a
budget change reviewed against `../member-db/.../cluster.yaml` first.

## Dependencies (why nothing here can be applied yet)

1. **Use the publisher receipt, never a registry re-lookup.** S0–S3 are
   landed and main publishes the three-entrypoint image. The eligible release
   input is the immutable digest artifact emitted by the publisher workflow
   for the exact source SHA (PR #216's carrier); until that receipt is
   recorded, no digest is eligible for this stack.
2. **The database remains an attended prerequisite.** member-db PR #118 is
   still draft. Its object-store ruling is closed; its reviewed merge,
   operator-only bring-up, `continuousArchiving=True`, completed backup,
   runtime-role Secret, and this slice's derived
   `gftb-member-db-runtime-dsn` all precede first serve. The migration Job
   applies schema only and does not create the tenant row. **Nothing in this
   directory duplicates or unblocks #118** — the cluster, roles, backups, and
   migration Job template stay its.
3. **The tenant identity is not ratified.** The migration does not seed one,
   and this PR deliberately invents no UUID, slug, display name, or initial
   owner. A reviewed tenant-bootstrap carrier must establish those values
   before `GFTB_TENANT_ID` can enter a release plan.
4. **The rename gates have not passed** (ADR 0014 §1.3–1.5): the image
   admission here accepts the pre-rename `greatfallstoolbus.org` slug today
   and the post-rename `gftb-platform` slug for the day the gates pass;
   narrowing to the single surviving name is the recorded follow-up.
5. **CI is validation-only and remote.** `check-hosted` validates the
   declare-only carrier; it never renders with credentials, mutates a
   cluster, or substitutes for the attended release proofs.

## Attended chain (mirrors the web-release discipline)

```bash
just platform-stack-validate                     # offline guard (hosted)
export PLATFORM_APPLY_IMAGE=ghcr.io/great-falls-tool-bus/greatfallstoolbus.org@sha256:<64 hex>
export GFTB_TENANT_ID=<the one configured tenant UUID>
just platform-release-plan                       # render ONCE, record bytes + receipt
export PLATFORM_APPLY_KUBECONFIG=/path/to/platform-apply.kubeconfig
just platform-release-server-dry-run             # server-side dry-run of the recorded bytes
GFTB_APPLY_CONFIRM=apply just platform-release-apply
just platform-release-pinned-running-proof       # live digest == plan; web(2)+worker(1) ready
STAGING_ACCESS_STATE=gated just platform-release-served-proof
```

Nothing in the chain runs `kubectl set image`, `kubectl scale`, or a replicas
patch; every recipe is receipt-bound in
`scripts/validate-public-operator-surface.py` (dependencies and executable
bodies), and the migration (`member-db-migrate-apply`, PR #118) must complete
before `platform-release-apply` — pods never migrate on startup. Full ordered
procedure, credential minting, edge steps, and rollback:
[`../../docs/runbooks/staging-platform-serving.md`](../../docs/runbooks/staging-platform-serving.md).

## The tunnel route is dashboard-managed (not in git)

Identical posture to `../web/README.md`: the public path rides the shared
honey-ingress cloudflared connector, its public-hostname routes are
Cloudflare dashboard/token-managed (TIN-991), and no live `cfargotunnel` UUID
is inlined anywhere. `staging-platform-route.json` records the *shape*
fail-closed only — including the planned Cloudflare **Access gate on the
staging hostname** (staging is private operator QA; Access controls
reachability, while the application auth path behind it is the product
surface under test and is never substituted by Access).
