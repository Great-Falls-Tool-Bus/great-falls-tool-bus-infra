# GFTB production web declaration

This directory owns the reviewed Kubernetes declaration for the
`greatfallstoolbus.org` origin. It serves the static `gftb-site` image through
an in-cluster Caddy process:

```text
Cloudflare edge -> shared cloudflared connector -> ClusterIP :80
                -> gftb-site Caddy origin :3000
```

Merging this directory does not apply it. The shared GloriousFlywheel v4 and
owner-overlay path is the required end state, but it is not yet a complete
production executor. Until that takeover is proved, the existing
`web-release-*` transaction is the only supported mutation path.

## Live files

| File | Contract |
| --- | --- |
| `greatfallstoolbus-org-production/deployment.yaml` | Two replicas of the exact digest-pinned `ghcr.io/great-falls-tool-bus/gftb-site` image; non-root, read-only root filesystem, `/health` probes on port 3000. |
| `greatfallstoolbus-org-production/service.yaml` | Internal `ClusterIP` service, port 80 to the named container port. |
| `greatfallstoolbus-org-production/networkpolicy.yaml` | Default-deny ingress and egress; only cloudflared and Prometheus ingress are admitted. |
| `greatfallstoolbus-org-production/kustomization.yaml` | Exact workload render: Deployment, Service, and four NetworkPolicies. It does not include authority objects. |
| `greatfallstoolbus-org-production/web-apply-rbac.yaml` | Desired namespace-scoped apply identity. It is excluded from the workload kustomization and cannot bootstrap its own authority. |

Secret names and custody live in [`../../secrets/README.md`](../../secrets/README.md).
Cloudflare and DNS state live in [`../../tofu/stacks/edge/`](../../tofu/stacks/edge/).
There is no parked route-intent, PR-lane, reaper, or local controller contract
in this directory.

## Validation

`just web-stack-validate` checks the committed shape and
`just web-stack-render` renders it without contacting the cluster. The required
`validate` workflow runs both checks for pull requests.

Validation requires all of the following:

- namespace and workload identity are exact;
- the image is a full lowercase `@sha256:` digest from the one admitted
  `gftb-site` repository;
- the workload tree contains no Namespace, Secret, or RBAC object;
- the separate RBAC source is one exact ServiceAccount/Role/RoleBinding set;
- the render contains exactly the Deployment, Service, and four
  NetworkPolicies;
- no kustomize reference escapes the repository or fetches a remote resource.

## Current production transaction

The current static-origin transaction is:

1. `just web-release-candidate-proof`
2. `just web-release-plan`
3. `just web-release-server-dry-run`
4. `GFTB_APPLY_CONFIRM=apply just web-release-apply`
5. `just web-release-pinned-running-proof`
6. `just web-release-served-proof`

It consumes an exact candidate digest and source SHA, saves and hashes the
rendered plan, applies only those reviewed bytes, and proves PINNED, RUNNING,
and SERVED. Rollback repeats the same transaction with the previously reviewed
digest and SHA. The detailed operator procedure remains in
[`../../docs/runbooks/oncluster-web-cutover.md`](../../docs/runbooks/oncluster-web-cutover.md).

No workflow may call this transaction. Its kubeconfig is operator-custodied,
namespace-scoped, and named only in `secrets/README.md`.

## v4 takeover and retirement

The attended release transaction can be deleted only in the same reviewed
change that proves the protected v4 owner-overlay replacement can:

1. accept the exact signed application and overlay revisions;
2. produce and save the exact production plan;
3. apply that saved plan under the owner identity;
4. independently observe the pinned image and served source SHA; and
5. execute the reviewed rollback artifact.

GF source types or OOC admission alone are not that proof. The first complete
production transaction must reach PINNED, RUNNING, and SERVED before the
current apply identity, release recipes, and direct observer are removed.
