# Staging platform serving — attended bring-up (TIN-3815 / TIN-3817)

The ordered operator path from "the platform stack is merged declare-only" to
"staging.greatfallstoolbus.org serves the gated member application with
receipts". Everything here is attended; nothing runs from CI. Companion:
[`../../k8s/platform/README.md`](../../k8s/platform/README.md) (the stack and
its authority table) and, for the database half,
`docs/runbooks/member-db-bringup.md` on the PR #118 branch.

## Step 0 — preconditions (all four, in this order)

1. **Publisher receipt exists.** App S0–S3 are landed, and the exact main
   workflow run has emitted its immutable digest artifact through PR #216's
   publisher carrier. Record that artifact's source SHA and digest; do not
   reconstruct either from a mutable tag or a later registry lookup. Until the
   ADR 0014 §1.3 rename gates pass, the publisher is
   `ghcr.io/great-falls-tool-bus/greatfallstoolbus.org`.
2. **Database exists.** PR #118 is merged and its attended bring-up has run
   through step B4 (cluster Ready, `continuousArchiving=True`, one completed
   Backup) plus step C2 (the `gftb-member-db-runtime` Secret minted).
3. **Namespace + SA.** `members-greatfallstoolbus-org-production` exists
   (operator-provisioned out of band; no stack here creates it) and a
   namespace-scoped `platform-apply` SA kubeconfig is minted with get/list/
   watch/create/update/patch on deployments, services, and networkpolicies in
   that namespace only. Keep it outside every repo tree, mode 0600.
4. **This carrier is reviewed.** You are on a clean, signed checkout equal to
   canonical main (`_reviewed-clean-main` enforces this at apply).

## Step C1 — derive the runtime DSN

Create `gftb-member-db-runtime-dsn` (type Opaque, key `dsn`) in the PLATFORM
namespace from the `gftb-member-db-runtime` basic-auth Secret in the database
namespace, with `sslmode=verify-full` and database `gftb_member`. This is the
DML-only `gftb_app` credential; it is the ONLY database credential the web and
worker Deployments ever see. (The owner DSN `gftb-member-db-migrator-dsn` is
PR #118's step M1 and goes to the migration Job alone.) Names are recorded in
`k8s/platform/secrets.contract.yaml`; values never enter git.

## Step N — admit the NetworkPolicy family first

Using the namespace-scoped `platform-apply` kubeconfig from Step 0
precondition 3, admit `k8s/platform/members-greatfallstoolbus-org-production/
networkpolicy.yaml` on its own, before the first migration. It carries no
sentinels and needs no image or tenant, so nothing here blocks doing this
standalone and early — and doing it first means the migrator (PR #118's Job,
which shares this namespace) never runs unpoliced.

Confirm all six NetworkPolicy objects exist in the namespace
(`default-deny-ingress`, `default-deny-egress`,
`allow-cloudflared-tunnel-ingress`, `allow-prometheus-scrape`,
`allow-egress-dns`, `allow-egress-member-db`) before proceeding to Step M.
The Deployments and Service in this directory are still admitted later, at
Step S, once the platform image and tenant are known — `platform-release-apply`
re-admits the same NetworkPolicy bytes at that point too, which is a no-op.

## Step M — pre-rollout migration first

Pods never migrate on startup (spec §6). Run PR #118's chain to completion
before serving:

```bash
export MEMBER_DB_MIGRATOR_IMAGE=<same digest you will serve>
just member-db-migrate-render
just member-db-migrate-server-dry-run
GFTB_APPLY_CONFIRM=apply GFTB_MEMBER_DB_MIGRATE_CONFIRM=member-db-migrate just member-db-migrate-apply
```

Record the Job log tail as release evidence. The migration applies schema
only: it does **not** create or seed a tenant row.

## Step T — establish the one reviewed tenant

This PR has no authority to invent the production tenant identity. Before
Step S, a separate reviewed tenant-bootstrap carrier must establish and receipt
the exact tenant UUID, slug, display name, and initial owner/keyholder grant.
The tenant UUID becomes `GFTB_TENANT_ID`; a wrong-but-real UUID passes the RLS
shape while selecting the wrong tenant. If that carrier is absent, stop here
and mark platform serving BLOCKED—do not insert an ad hoc row during the apply
sitting.

After the first successful serve, replace
`PLACEHOLDER-GFTB-TENANT-ID` in both Deployments through a reviewed PR so Git
records the same UUID used by the release plan.

## Step S — plan, dry-run, apply, prove

```bash
just platform-stack-validate
export PLATFORM_APPLY_IMAGE=ghcr.io/great-falls-tool-bus/greatfallstoolbus.org@sha256:<64 hex>
export GFTB_TENANT_ID=<tenant uuid from step M>
just platform-release-plan
export PLATFORM_APPLY_KUBECONFIG=/path/to/platform-apply.kubeconfig
just platform-release-server-dry-run
GFTB_APPLY_CONFIRM=apply just platform-release-apply
just platform-release-pinned-running-proof
```

The plan records the rendered bytes, their sha256, the image, the tenant, and
the carrier commit under `.k8s-plans/` (operator-private, never committed);
the preflight refuses a stale plan, a changed carrier, or bytes that no longer
re-render identically; the apply dry-runs and applies exactly the recorded
bytes and waits for both rollouts. Expected worker behavior is Running and idle when no eligible jobs exist.
`EMPTY_REGISTRY` is not an acceptable current-image state: S7/S9 handlers are
already registered. A worker in CrashLoopBackOff exiting 78 means DATABASE_URL
or GFTB_TENANT_ID is wrong — that visibility is by design.

## Step E — edge (separate authority, still operator-gated)

In this order, all dashboard/token-managed (TIN-991; nothing in git):

1. Mint the Cloudflare **Access application** for
   `staging.greatfallstoolbus.org` (operator QA identities only, plus a
   service token pair for the served proof). Staging is PRIVATE (TIN-3815);
   Access gates reachability while the application's own auth remains the
   surface under QA.
2. Add the tunnel public-hostname route on honey-ingress:
   `staging.greatfallstoolbus.org` →
   `http://gftb-platform-web.members-greatfallstoolbus-org-production.svc.cluster.local:80`.
3. Add the proxied CNAME on the zone via the edge stack authority.
4. Flip `tofu/intent/great-falls-tool-bus/staging-platform-route.json` to
   `applied: true` (+ dns/route flags) in a follow-up PR the same day, so the
   intent file keeps telling the truth. (`validate-platform-stack.sh` pins the
   flags; the follow-up PR updates both together.)

Then the served receipt:

```bash
STAGING_ACCESS_STATE=gated just platform-release-served-proof
# optionally with CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET for the
# authenticated /health 200 line
```

## Rollback

Rollback is re-planning with the previous digest — never an imperative pin:

```bash
export PLATFORM_APPLY_IMAGE=<previous sha256 digest>
just platform-release-plan && just platform-release-server-dry-run
GFTB_APPLY_CONFIRM=apply just platform-release-apply
just platform-release-pinned-running-proof
```

Migrations do not roll back (forward-only, hash-ledgered); if a migration must
be unwound the path is PR #118's restore rehearsal (its runbook step R), which
is exactly why its RPO/RTO rows are acceptance rows.

## Receipts to keep

Plan receipt block (image / tenant / carrier / render sha256), migration Job
log tail, `platform-release-pinned-running-proof` output, served-proof lines,
and the edge readback. File them with the release, the same way the web
cutover receipts are filed.
