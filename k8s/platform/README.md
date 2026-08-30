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
or pull-secret value. The platform image references namespace-local
ghcr-pull; PR #118 owns the sole names-only kubernetes.io/dockerconfigjson
target contract. Governed consumer enrollment and its sole controller project
the bytes into that exact target (TIN-3768 / TIN-2609). The controller is not
currently live, so the projection remains a HOLD. Out-of-band kubectl,
per-tenant SOPS, and operator Secret creation are not admitted mechanisms.
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
   migrator. The governed controller is not live and its pull projection has
   not been observed; this PR claims no existence.
2. The tenant tuple is absent. A reviewed bootstrap carrier must establish and
   receipt UUID, slug, display name, and initial owner/keyholder grant. This PR
   invents none of them.
3. The exact Step-N policy-only plan/apply/live-proof carrier is registered in
   the Justfile. It remains attended and applies nothing until explicitly run.
4. CI is remote validation only; it does not mutate the cluster.
5. After app PR #218 publishes its successor receipt, a successor infra PR
   must re-pin both Deployments and the validator; this PR does not predict
   that digest.

## Attended release after blockers close

Run Step N first:

```bash
just platform-network-policy-plan
export PLATFORM_APPLY_KUBECONFIG=/path/to/platform-apply.kubeconfig
just platform-network-policy-server-dry-run
GFTB_APPLY_CONFIRM=apply just platform-network-policy-apply
just platform-network-policy-live-proof
```

Then the full release; its apply mechanically re-runs the exact live policy proof:

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
