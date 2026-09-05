# Great-Falls-Tool-Bus (GFTB) v4 GitHub dispatch edge (TIN-2611, RULING 3).
#
# Operator ruling 2026-09-05 (TIN-2611): the `gf-v4-dispatch` edge for GFTB
# lives in GFTB's own -infra overlay. GloriousFlywheel core keeps the reusable
# root module; this file is the consumer's installation fact.
#
# MODULE SOURCE: tinyland-inc/GloriousFlywheel
#   tofu/stacks/arc-owner-overlay-release at the exact reviewed commit
#   82c96f5ce290bc768062782e911ed66a3527b941 (Justfile gf_v4_dispatch_core_sha;
#   workflow GF_CORE_REF; scripts/validate-gf-v4-dispatch-contract.py pin).
#   It is consumed the way every other GloriousFlywheel stack is consumed here:
#   a pinned, verified core checkout run with -chdir and this -var-file. There
#   is no git:: module source (the root carries its own backend and provider
#   blocks, and the core repository is private).
#
# DELIBERATELY ABSENT: no provider endpoint, cache, executor, storage class,
# node selector, toleration, affinity, namespace, runner label, or repository
# roster. Every identity below the eight inputs (namespace
# arc-runners-<owner>, scale set <owner>-gf-v4-dispatch, label gf-v4-dispatch,
# App Secret github-app-secret-<owner>-gf-v4-dispatch, ConfigMap sink
# gf-v4-action-resolution-endpoint) is derived by the module, never declared
# here. k8s_config_path is never committed: the recipes pass it through
# TF_VAR_k8s_config_path from the materialized transaction kubeconfig.

# Kubernetes API context only; never placement authority.
cluster_context = "honey"

owner_slug        = "great-falls-tool-bus"
github_config_url = "https://github.com/Great-Falls-Tool-Bus"

# TO-RATIFY: reuse of the admitted tenancy group declared in
# config/organization.yaml runner_contract.runner_group (the repository's
# stated principle: a group is a tenancy boundary, not a capability). The
# operator's fork is a dedicated `great-falls-tool-bus-infra-gf-v4-dispatch`
# group with a gftb-site-only canary roster; see
# docs/runbooks/gf-v4-dispatch-edge.md step 1.
runner_group = "great-falls-tool-bus-infra"

# Honey fleet pin (tinyland-infra honey.tfvars nix_runner_image, read-only
# 2026-09-05). RE-PIN to the GloriousFlywheel #1766 publisher-baked digest in
# one reviewed PR (this file, the validator constant, and the tftest digest
# together) once deploy/gf-rbe/published-digests.log carries its receipt.
runner_image = "ghcr.io/tinyland-inc/actions-runner-nix@sha256:7bf301a6275bbe7d8e7b5d063335c9673ce284073606356ffc0900e560026be7"

# Honey is RKE2 v1.33; matches the module's own example.
pod_security_version = "v1.33"

# Thin dispatchers only. REAPI workers, not this value, carry action
# parallelism.
min_runners = 0
max_runners = 4
