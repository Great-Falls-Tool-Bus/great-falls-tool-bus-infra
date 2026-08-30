# Staging platform serving — attended bring-up (TIN-3815 / TIN-3817)

Nothing in this runbook is a CI deploy. Do not proceed past any STOP.

## Step 0 — exact preconditions

1. Git pins `ghcr.io/great-falls-tool-bus/greatfallstoolbus.org@sha256:10f853938dc6823afe8c9bdc54943587f963d22117aafd17247350b2b5712b35` in both serving Deployments. Publisher receipt:
   source `af60fcd7539a4beff6f24e1a95eb11160df7c166`; workflow run `33279762284`, attempt 1; artifact
   `greatfallstoolbus-org-image-af60fcd7539a4beff6f24e1a95eb11160df7c166-33279762284-1` (id `9722715788`). Do not re-resolve or override it.
2. Before proceeding, require PR #118 to land. Then require its single
   names-only ghcr-pull SecretContract to be authoritative and require the
   operator-provisioned namespace-local kubernetes.io/dockerconfigjson Secret
   to be observed. Require its attended database path to prove Ready,
   `continuousArchiving=True`, one completed Backup, and the runtime role
   Secret.
3. `members-greatfallstoolbus-org-production` and the namespace-scoped
   `platform-apply` identity exist. The kubeconfig is outside every repo,
   operator-owned, and mode 0600.
4. The infra checkout is clean, signed, and equal to canonical main.

## Step C1 — derive the runtime DSN

Create `gftb-member-db-runtime-dsn/dsn` in the platform namespace from PR
#118's DML-only runtime role, using database `gftb_member` and
`sslmode=verify-full`. Never give web/worker the migrator DSN. Values remain
outside Git.

## Step N — plan and admit the exact policy-only slice

This canonical Just carrier renders only the six NetworkPolicies from the same
Kustomize graph as the full stack, records exact Git bytes and inventory, then
server-dry-runs, applies, and compares every live policy name/spec to the plan:

```bash
just platform-network-policy-plan
export PLATFORM_APPLY_KUBECONFIG=/path/to/platform-apply.kubeconfig
just platform-network-policy-server-dry-run
GFTB_APPLY_CONFIRM=apply just platform-network-policy-apply
just platform-network-policy-live-proof
```

The live proof requires exactly those six policies in the namespace and the
`app.kubernetes.io/part-of=great-falls-tool-bus` identity used by PR #118.
Raw `kubectl` or the whole serving stack is not an equivalent Step-N carrier.
The later `platform-release-apply` mechanically depends on this exact live proof.

## Step M — migrate schema, not tenant data

After Step N closes and PR #118 lands, run its Git-pinned one-shot migration
chain. It accepts no image input; the Job keeps the image entrypoint, uses only
args ["migrator"], restartPolicy Never, and backoffLimit 0:

```bash
just member-db-migrate-render
just member-db-migrate-server-dry-run
GFTB_APPLY_CONFIRM=apply GFTB_MEMBER_DB_MIGRATE_CONFIRM=member-db-migrate just member-db-migrate-apply
```

Record the Job log tail. Migration applies schema only; it does not create or
seed the tenant.

## Step T — establish the reviewed tenant tuple

A separate reviewed bootstrap carrier must establish and receipt the exact
tenant UUID, slug, display name, and initial owner/keyholder grant. The UUID
becomes `GFTB_TENANT_ID`. A wrong-but-real UUID can satisfy shape while
selecting the wrong tenant. If the tuple/carrier is absent, stop.

## Step S — plan, dry-run, apply, prove

```bash
just platform-stack-validate
export GFTB_TENANT_ID=<tenant UUID from Step T>
just platform-release-plan
export PLATFORM_APPLY_KUBECONFIG=/path/to/platform-apply.kubeconfig
just platform-release-server-dry-run
GFTB_APPLY_CONFIRM=apply just platform-release-apply
just platform-release-pinned-running-proof
```

Image and pull-secret values are not inputs. After app PR #218 publishes a
successor receipt, a successor infra PR must re-pin both Deployments and the
validator before a new plan; this runbook does not guess that digest. The plan derives the identical web/worker digest from
Git, requires the exact admitted publisher identity, and records it beside the
tenant, carrier, bytes, and sha256. Preflight refuses drift or tampering.

## Step E — edge and served proof

Edge authority remains separate and operator-gated. After reviewed Access,
tunnel-route, and DNS changes, run:

```bash
STAGING_ACCESS_STATE=gated just platform-release-served-proof
```

Staging remains private QA. Gate-only proof requires exact 302 and Cloudflare
Access login redirect semantics; it proves edge/Access, not origin. A complete
service-token pair is required for the protected-origin 200 claim.

## Rollback

Open and land a reviewed PR that re-pins both Deployments and the validator to
the previous signed publisher receipt. Then record a fresh plan, server-dry-run
it, apply the exact bytes, and run the pinned/running proof. There is no runtime
image override. Migrations stay forward-only; use PR #118's restore rehearsal
when data/schema restoration is required.
