# Great-Falls-Tool-Bus (GFTB) owner overlay for the shared Honey ARC substrate.
#
# ORG SHAPE: unlike the older personal-account overlay, GFTB registers
# ARC at the ORGANIZATION scope. One scale set serves every repo in the org,
# so extra_runner_sets stays empty — no per-repo registration anchors.
# The scale-set NAME is the ARC registration identity ONLY; workflows request
# the shared `tinyland-nix` capability label (the arc-runner module publishes
# runner_label alongside the owner-distinct runnerScaleSetName).
# Registration is not admission: which GFTB repositories may actually be
# assigned this scale set's work is the runner_group boundary below.
#
# CONSERVATIVE CAPACITY POSTURE (TIN-2165/TIN-2234 pod-cap crunch): nix lane
# only, max 4, min 0, no warm pool, docker/dind lanes OFF. Sting placement +
# the dedicated compute-expansion toleration mirror the tinyland-goo-nix
# anchor shape in the older personal-account overlay (honey is pod-count full; sting carries
# the dedicated.tinyland.dev/compute-expansion taint).

cluster_context       = "honey"
github_config_url     = "https://github.com/Great-Falls-Tool-Bus"
github_config_secret  = "github-app-secret-great-falls-tool-bus"
ghcr_pull_secret_name = "ghcr-pull"

# TIN-3902 RUNNER GROUP. Every scale set in this stack registers into the
# dedicated, selected-repository `great-falls-tool-bus-infra` GitHub runner
# group instead of GitHub's shared `Default` group. TIN-3209 closed the
# Default-group grandfather exception on 2026-08-15; that exception's roster
# (`legacy-default`) is a stack-coded list of nine tinyland-inc scale sets and
# never included `great-falls-tool-bus-nix`, so `organization-restricted` is
# the only policy this overlay may use. Under that policy the stack's
# `terraform_data.runner_group_policy` precondition rejects any scale set whose
# group resolves to `default`.
#
# The group name is an owner/tenancy identity, not a runner capability, so it
# does not violate the shared-label taxonomy: workflows still request
# `tinyland-nix`. The roster, visibility, and public-repository posture are
# declared in config/organization.yaml `runner_contract.runner_group`.
#
# NOT module-created: the GloriousFlywheel arc-runners stack loads only the
# kubernetes and helm providers and owns no `github_actions_runner_group`
# resource, so the GitHub-side group must exist BEFORE the first plan/apply.
# See docs/implementation-overlay.md "Runner group cutover".
runner_group        = "great-falls-tool-bus-infra"
runner_group_policy = "organization-restricted"

deploy_arc_controller       = false
create_controller_namespace = false
create_runner_namespace     = false

controller_chart_version = "0.14.0"

controller_node_selector = {
  "kubernetes.io/hostname" = "honey"
}

nix_runner_name    = "great-falls-tool-bus-nix"
docker_runner_name = "great-falls-tool-bus-docker"
dind_runner_name   = "great-falls-tool-bus-dind"

nix_runner_scale_set_name    = "great-falls-tool-bus-nix"
docker_runner_scale_set_name = "great-falls-tool-bus-docker"
dind_runner_scale_set_name   = "great-falls-tool-bus-dind"

# docker/dind names above are inert while their deploy flags are false; they
# exist so a future lane enable is a one-flag change, not a naming decision.

# The site build lane materializes Nix, pnpm, and Bazel state on the runner
# rootfs while the volumes below are disabled. On 2026-08-17, four independent
# build/test pods were evicted after crossing the former 8Gi container limit.
# 8Gi/16Gi preserves the max-four posture while restoring the last known
# nix-build limit; docs/implementation-overlay.md defines the measured soak gate.
# Capacity is unchanged by TIN-3902: the runner-group cutover is an admission
# fix, not a capacity change. min 0 / max 4 is the reviewed TIN-2165/TIN-2234
# posture and must stay non-zero — a dedicated group with zero capacity admits
# nobody, which was the defect in the unmerged 2026-07-31 quarantine draft.
nix_min_runners               = 0
nix_max_runners               = 4
nix_cpu_limit                 = "4"
nix_memory_limit              = "8Gi"
nix_ephemeral_storage_request = "8Gi"
nix_ephemeral_storage_limit   = "16Gi"
nix_store_enabled             = false
nix_store_prepopulate_enabled = false
nix_store_storage_class       = "openebs-bumble-zfs"
nix_store_size                = "50Gi"
nix_warm_pool_enabled         = false
deploy_docker_runner          = false
deploy_dind_runner            = false
deploy_longhorn               = false

# Shared-cache-backed wiring for the primary nix lane: the runner injects
# BAZEL_REMOTE_CACHE + GF_BAZEL_SUBSTRATE_MODE=shared-cache-backed and the
# Attic substituter (arc-runner module locals.tf cache_env_vars).
# EXECUTOR FLIP (later, deliberate): adding
#   bazel_executor_endpoint = "grpc://gf-reapi-cell.gf-rbe.svc.cluster.local:8980"
# here flips the injected mode to executor-backed for ALL GFTB runner pods;
# do that only together with arming FLYWHEEL_EXECUTOR_ENABLED in consumers and
# a registry substrate_mode update.
attic_server         = "http://attic.nix-cache.svc.cluster.local"
attic_cache          = "main"
attic_public_key     = "main:eaUydxuDu7xBoy5cCo3MdknYAkVyTIASQ7DGuwxa+XA="
bazel_cache_endpoint = "grpc://bazel-cache.nix-cache.svc.cluster.local:9092"

# GloriousFlywheel hosted token-exchange front door for the GFTB org nix lane
# (TIN-2364 L5 org-mint soak). The oidc-profile helper reads
# GF_REAPI_TOKEN_EXCHANGE_ENDPOINT to exchange the job's GitHub Actions OIDC
# identity for a short-lived gf-reapi-cell token. This is a cluster-internal
# Service endpoint value, committed here under the same discipline as
# bazel_cache_endpoint and attic_server above; it mirrors the honey.tfvars
# export that covers the shared tinyland-nix lanes (GloriousFlywheel PR #1066).
nix_env_vars = [
  {
    name  = "GF_REAPI_TOKEN_EXCHANGE_ENDPOINT"
    value = "http://gf-reapi-token-exchange.gf-rbe.svc.cluster.local:8081/v1/token/exchange"
  },
  {
    name  = "GF_REAPI_CACHE_FRONTDOOR_ENDPOINT"
    value = "grpc://gf-reapi-cell.gf-rbe.svc.cluster.local:8980"
  }
]

shared_runner_node_selector = {
  "kubernetes.io/hostname" = "sting"
}

shared_nix_runner_node_selector = {
  "kubernetes.io/hostname" = "sting"
}

shared_runner_tolerations = [
  {
    key      = "dedicated.tinyland.dev/compute-expansion"
    operator = "Equal"
    value    = "true"
    effect   = "NoSchedule"
  }
]
shared_runner_affinity = {}

# Listeners are request-less ARC intake plumbing (no resource requests), so the
# sting pod-cap rationale above applies to runner payloads only. Keep listeners
# off sting after the 2026-07-09 total-intake outage (TIN-2455/TIN-2677;
# mirrors GloriousFlywheel PR #1067).
listener_node_selector = {
  "kubernetes.io/hostname" = "bumble"
}

listener_tolerations = [
  {
    key      = "dedicated.tinyland.dev/compute-expansion"
    operator = "Equal"
    value    = "true"
    effect   = "NoSchedule"
  }
]

# Org-scoped registration covers every GFTB repo; keep this empty. A non-empty
# entry here requires an explicit operator decision AND re-adding the
# --allow-repo-registration-anchor flag to the taxonomy verbs.
extra_runner_sets = {}
