# GFTB platform staging serving (TIN-3815 / TIN-3817)

This declare-only stack owns the web + worker Deployments, web ClusterIP
Service, and six default-deny/named-allow NetworkPolicies in
`members-greatfallstoolbus-org-production`. Merging it applies nothing.

## Exact publisher authority

Git pins one image in both Deployments:

- image: `ghcr.io/great-falls-tool-bus/greatfallstoolbus.org@sha256:10f853938dc6823afe8c9bdc54943587f963d22117aafd17247350b2b5712b35`
- source: `af60fcd7539a4beff6f24e1a95eb11160df7c166`
- workflow: run `33279762284`, attempt 1
- artifact: `greatfallstoolbus-org-image-af60fcd7539a4beff6f24e1a95eb11160df7c166-33279762284-1` (id `9722715788`)

No release recipe accepts an image input, tag, alternate repository, digest,
or pull-secret value. The private platform image references namespace-local
ghcr-pull; PR #118 owns its single names-only kubernetes.io/dockerconfigjson
contract and the operator provisions the value outside Git. Only gftb-site was
authorized public.
A future repository rename changes both manifest pins and the validator in one
reviewed Git PR. Rollback is a reviewed Git re-pin.

## Runtime invariants

| Object | Contract |
| --- | --- |
| `Deployment/gftb-platform-web` | replicas 2, RollingUpdate 0/1, exact image above, no Kubernetes `command` or `args`; inherits OCI Entrypoint and `/bin/web` Cmd |
| `Deployment/gftb-platform-worker` | replica 1, Recreate, same image, no `command`, exact `args: ["worker"]` |
| `Service/gftb-platform-web` | ClusterIP 80 → named port `http` (:3000), web only |
| six NetworkPolicies | default deny both ways; cloudflared/prometheus ingress; cluster-DNS/member-db egress; no `ipBlock` and no empty egress `to` |

Both workloads consume only `gftb-member-db-runtime-dsn/dsn`. The owner/DDL
DSN belongs only to PR #118's migrator. The migration applies schema and never
creates or seeds a tenant.

## Remaining blockers

1. PR #118 must merge, remain the single names-only authority for ghcr-pull,
   and complete database/backup/runtime-DSN proof and its Git-pinned one-shot
   migrator. The pull Secret has not been observed; this PR claims no existence.
2. The tenant tuple is absent. A reviewed bootstrap carrier must establish and
   receipt UUID, slug, display name, and initial owner/keyholder grant. This PR
   invents none of them.
3. NetworkPolicy-first admission has no registered, receipt-bound Just carrier.
   The runbook stops at Step N. Raw `kubectl`, an ad hoc script, or applying
   the whole serving stack is not a substitute.
4. CI is remote validation only; it does not mutate the cluster.

## Attended release after blockers close

```bash
just platform-stack-validate
export GFTB_TENANT_ID=<tenant UUID from reviewed Step T carrier>
just platform-release-plan
export PLATFORM_APPLY_KUBECONFIG=/path/to/platform-apply.kubeconfig
just platform-release-server-dry-run
GFTB_APPLY_CONFIRM=apply just platform-release-apply
just platform-release-pinned-running-proof
STAGING_ACCESS_STATE=gated just platform-release-served-proof
```

The renderer substitutes exactly two tenant sentinels. The plan derives the
single identical web/worker image from Git-owned rendered bytes and records it
with the tenant, carrier SHA, bytes, and sha256. Preflight re-derives and
re-renders before any mutation. See
[`docs/runbooks/staging-platform-serving.md`](../../docs/runbooks/staging-platform-serving.md).
