# GFTB production web release and recovery

This is the current operator procedure for promoting the static `gftb-site`
origin on `greatfallstoolbus.org`. There is no alternate origin,
cross-repository dispatch, parked preview/reaper contract, or imperative
tree-apply carrier.

The target is protected GloriousFlywheel v4 owner-overlay convergence. That
path does not yet provide the complete saved-plan, apply, observer, and
rollback transaction, so the attended `web-release-*` recipes remain the
production recovery path until one measured v4 takeover completes.

## Authority boundary

- `gftb-site` owns reviewed public source and publishes the immutable
  candidate image.
- This overlay owns the digest pin, Kubernetes declaration, edge declaration,
  and current production transaction.
- GloriousFlywheel owns shared action and authority types.
- The owner-overlay controller accepts owner demand; source types alone do not
  apply production.
- Secret values, kubeconfigs, cluster endpoints, and Cloudflare credentials
  never enter the repository.

The production workload is the existing
`Deployment/greatfallstoolbus-org` in namespace
`greatfallstoolbus-org-production`, behind the existing ClusterIP Service and
Cloudflare tunnel. A release does not create a namespace, install a Secret, or
change edge routing.

## Inputs

The same input guard protects render, plan, apply, and proofs.

| Variable | Contract |
| --- | --- |
| `WEB_APPLY_IMAGE` | Exact `ghcr.io/great-falls-tool-bus/gftb-site@sha256:<64 lowercase hex>` reference. |
| `WEB_APPLY_SHA` | Exact lowercase 40-hex `gftb-site` source commit carried by the image. |
| `WEB_APPLY_REPLICAS` | Unset or exactly `2`. |
| `WEB_APPLY_KUBECONFIG` | Absolute, non-symlink, operator-owned mode-0600 apply kubeconfig outside every repository. Ambient `KUBECONFIG` is refused. |
| `WEB_RELEASE_KUBECONFIG` | Absolute, non-symlink, operator-owned mode-0600 proof-only kubeconfig outside every repository. Its inability to mutate release objects is verified. |
| `WEB_ACCESS_STATE` | Exactly `gated` or `public`, based on current edge readback. |
| `CF_ACCESS_COOKIE_JAR` | Required only for `WEB_ACCESS_STATE=gated`; absolute, non-symlink, operator-owned mode-0600 file staged into private temporary custody before use. |

Ambient proxy and TLS-steering variables are refused. Do not put any input
value in Git, a PR, a CI artifact, or a release receipt.

## Transaction

### 1. Resolve and prove the candidate

Start from the exact merged `gftb-site` source commit:

```bash
export WEB_APPLY_SHA=<40-hex-gftb-site-commit>
unset WEB_APPLY_IMAGE
just web-release-resolve-candidate
```

The resolver constructs the single allowed `sha-<commit>` tag, resolves it
anonymously, calls the same candidate proof used by the rest of the
transaction, and resolves the tag again. A moved tag or second-read failure
ends the attempt. The resulting digest, not the tag, becomes
`WEB_APPLY_IMAGE`.

The proof verifies the immutable digest, single-image manifest, static-Caddy
runtime identity, source repository label, and exact source revision. These
labels are publisher assertions, not hostile-publisher attestation; package
publication authority remains part of the trust root.

### 2. Save and review the exact plan

```bash
export WEB_APPLY_IMAGE=ghcr.io/great-falls-tool-bus/gftb-site@sha256:<64-hex>
just web-release-candidate-proof
just web-release-plan
just web-release-render
```

`web-release-render` emits the committed kustomize bytes verbatim and asserts
that the committed image and source annotation equal the reviewed inputs.
`web-release-plan` stores those bytes, their SHA-256, the input identities,
and the exact infra carrier commit under the ignored, operator-private
`.k8s-plans/` root.

Review the render before continuing. A changed input, carrier commit, or byte
sequence requires a new plan.

### 3. Dry-run and apply the saved bytes

```bash
export WEB_APPLY_KUBECONFIG=/absolute/operator/path/web-apply.kubeconfig
just web-release-server-dry-run
GFTB_APPLY_CONFIRM=apply just web-release-apply
```

The apply recipe requires a clean, signed checkout exactly equal to canonical
`main`, explicit confirmation, stable inputs, a byte-identical re-render, and
the exact namespace-scoped authorization set. It server-dry-runs and applies
only the saved plan, then waits for rollout completion.

No recipe may imperatively set an image, patch replicas, or apply the web tree
directly. The public-surface validator scans the entire Justfile and has no
allowlist exception for those mutations.

### 4. Prove PINNED, RUNNING, and SERVED

```bash
export WEB_RELEASE_KUBECONFIG=/absolute/operator/path/web-proof.kubeconfig
just web-release-pinned-running-proof

export WEB_ACCESS_STATE=gated  # or public, after edge readback
export CF_ACCESS_COOKIE_JAR=/absolute/operator/path/access.cookies  # gated only
just web-release-served-proof
```

`web-release-pinned-running-proof` proves the live pod template carries the
reviewed digest and source annotation; exactly one active ReplicaSet is 2/2;
old ReplicaSets are scaled down; both Ready pods report the selected image
digest; the EndpointSlice binds those pods; and the four-policy NetworkPolicy
census and semantic digest match.

`web-release-served-proof` proves the external homepage, `/health`,
`/health.sha`, and apex QR asset. In gated mode it first proves anonymous
Cloudflare Access interception and then uses the staged cookie. In public mode
it refuses any cookie. `/health.sha` must equal `WEB_APPLY_SHA`.

An authenticated browser or physical QR LOOK is a human observation and is not
replaced by the served-proof recipe.

## Rollback

Before apply, record the previous `gftb-site` digest and source SHA. Rollback
uses this same transaction:

1. set `WEB_APPLY_IMAGE` and `WEB_APPLY_SHA` to the previous reviewed pair;
2. create and review a new saved plan;
3. dry-run and apply that plan;
4. repeat PINNED, RUNNING, and SERVED proof.

There is no alternate-origin, raw `kubectl`, or direct-tree fallback. If the
previous immutable candidate is unavailable, stop and restore its
package/publication authority before changing production.

## Release receipt

Record exactly these non-secret fields:

```text
1  issue and milestone
2  source repository and exact head SHA
3  tree hash and diff hash
4  reviewer identity, verdict, and reviewed SHA
5  required check names, run IDs, conclusions, and completion time
6  human ship authorization and author
7  merge SHA and time
8  package name, tag, and digest
9  infra pin commit, deployment generation, pod imageID
10 external URL, served SHA/marker, observation time
11 real-device/QR or member-flow result
12 previous digest and rollback rehearsal/result
13 Linear receipt link
```

Never include cookies, tokens, kubeconfig data, secret values, private
locations, or member data.

## v4 takeover gate

Delete the attended release transaction, apply kubeconfig, RBAC, and direct
observer only in the same reviewed change that demonstrates the replacement
can:

1. authenticate and accept the exact signed owner and tenant revisions;
2. bind the exact application and overlay artifacts;
3. save and apply one exact production plan under owner authority;
4. independently read back the live digest and served source SHA;
5. exercise the previous immutable artifact as rollback; and
6. carry the protected transaction from merge through PINNED, RUNNING, and
   SERVED without a local, repository-specific, or operator-shell fallback.

Until then, GF/OOC source changes are prerequisites, not proof of production
takeover.
