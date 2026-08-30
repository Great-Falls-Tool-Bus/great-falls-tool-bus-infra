#!/usr/bin/env python3
"""Validate the public operator surface stays Justfile-centered.

This repo has two distinct operator planes:

- OpenTofu-managed infra stacks (ARC runners, edge zones).
- Namespace-scoped Kubernetes workload declarations for mail/list/form.

The public contract is not "all Kubernetes has already moved to Tofu". The
contract is narrower and enforceable: public docs and GitHub workflows point at
the audited Justfile recipes, not copy-paste raw tofu/kubectl/kustomize mutation
commands. The Justfile remains the sole live entrypoint.
"""

from __future__ import annotations

import copy
import hashlib
import json
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import textwrap
from dataclasses import dataclass
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent
SELF = Path(__file__).resolve().relative_to(REPO)

PUBLIC_DOC_GLOBS = [
    "README.md",
    "AGENTS.md",
    "docs/**/*.md",
    "k8s/**/*.md",
    "k8s/**/*.yaml",
    "k8s/**/*.yml",
    "secrets/**/*.md",
    "tofu/**/*.md",
]

WORKFLOW_GLOBS = [".github/workflows/*.yml", ".github/workflows/*.yaml"]
SCRIPT_GLOBS = ["scripts/*"]
COMPOSITE_ACTION_GLOBS = [
    ".github/actions/**/action.yml",
    ".github/actions/**/action.yaml",
]

RETIRED_EDGE_RECIPE = re.compile(
    r"\bjust\s+edge-(?:fmt(?:-check)?|validate|init|plan(?:-show|-destroy-check)?|apply)\b"
)
RAW_K8S_MUTATION = re.compile(
    r"(\bkubectl\b[^\n#`]*\b(?:apply|delete)\b|\bapply\s+-k\b|\bdelete\s+-k\b|"
    r"\bkustomize\s+build\b[^\n#`]*\bkubectl\b[^\n#`]*\b(?:apply|delete)\b)"
)
RAW_TOFU_WORKFLOW = re.compile(r"(?<![A-Za-z0-9_-])tofu(?:\s|-chdir\b)")
WORKFLOW_ENV_ENTRY = re.compile(r"^          (TF_VAR_[A-Za-z0-9_]+):[ \t]*(.+)$")

RETIRED_ARC_WORKFLOW = Path(".github/workflows/deploy-arc-runners.yml")
# TIN-3899 Phase 5 step 2: the legacy adapter-node CD carrier. It was the only
# workflow that ran `just web-stack-apply`, and its
# `repository_dispatch: web-image-published` trigger let a push to the PUBLIC
# site repo mutate Deployment/greatfallstoolbus-org unattended. It is deleted;
# re-adding the file, or re-introducing ANY repository_dispatch consumer in this
# repository, fails the public surface. The site repo's signal job is retired in
# the same change.
RETIRED_WEB_CD_WORKFLOW = Path(".github/workflows/web-stack.yml")
# TIN-4227 temporary generation-40 parity bridge. Its complete bytes are
# receipt-bound, its only hosted operator calls are path-scoped below, and the
# desired-state tuple stays frozen until the permanent GF-I09 receiver has
# proved canonical update -> revert -> re-forward and removes this bridge.
WEB_GENERATION40_BRIDGE_WORKFLOW = Path(".github/workflows/web-generation-40-parity.yml")
WEB_GENERATION40_BRIDGE_SHA256 = "df3020153289f0e30db5e6c5d70cd31408c77d698cbbcab8a054a8e1efb4a471"
WEB_GENERATION40_BRIDGE_RECIPES = frozenset(
    {"web-release-plan", "web-release-server-dry-run", "web-release-apply"}
)
WEB_GENERATION40_TARGET_SOURCE = "06e8b2c390b9c057fd084540e1e5710411a76a93"
WEB_GENERATION40_TARGET_IMAGE = "ghcr.io/great-falls-tool-bus/gftb-site@sha256:0295c226bd0bc78c0fe392b8955971ffbbd4fb9a0684939558d4c3d170a35dee"
WEB_GENERATION40_DEPLOYMENT = Path("k8s/web/greatfallstoolbus-org-production/deployment.yaml")
WEB_GENERATION40_TRANSIENT_VALIDATE = Path(".github/workflows/validate.yml")
WEB_GENERATION40_TRANSIENT_VALIDATE_SHA256 = "3e92c0d4f6e03060466977d0b3b5eb88b83282f2546c5c0cae4883de272b4e68"
WORKFLOW_REPOSITORY_DISPATCH = re.compile(r"^\s*repository_dispatch\s*:")
JUST_COMMAND_START = re.compile(r"\bjust\b")
JUST_OPTIONS_WITH_VALUES = {
    "-d": 1,
    "--chooser": 1,
    "--color": 1,
    "--completions": 1,
    "--dotenv-path": 1,
    "-f": 1,
    "--justfile": 1,
    "--list-heading": 1,
    "--list-prefix": 1,
    "--set": 2,
    "--shell": 1,
    "--shell-arg": 1,
    "--working-directory": 1,
}
JUST_NON_EXECUTING_OPTIONS = {
    "--choose",
    "--dump",
    "--evaluate",
    "--help",
    "--list",
    "--summary",
    "--version",
    "-V",
    "-h",
    "-l",
}
RETIRED_ARC_KUBECONFIG_SECRET = re.compile(
    r"\b(?:ARC_RUNNERS_KUBECONFIG(?:_B64)?|"
    r"GFTB_ARC_KUBECONFIG(?:_B64)?|"
    r"ARC_APPLY_KUBECONFIG_B64)\b"
)
HOSTED_WORKFLOW_JUST_ALLOWLIST = {
    "_edge-zones-plan-json",
    "_edge-zones-plan-text",
    "archive-stack-apply",
    "archive-stack-drift-check",
    "archive-stack-server-dry-run",
    "archive-stack-validate",
    "check-hosted",
    "edge-zones-apply",
    "edge-zones-fmt-check",
    "edge-zones-init",
    "edge-zones-plan",
    "edge-zones-plan-destroy-check",
    "edge-zones-plan-show",
    "edge-zones-validate",
    "flywheel-cache-proof",
    "form-stack-apply",
    "form-stack-drift-check",
    "form-stack-server-dry-run",
    "form-stack-validate",
    "list-stack-apply",
    "list-stack-drift-check",
    "list-stack-server-dry-run",
    "list-stack-validate",
    "listsync-stack-drift-check",
    "mail-cr-apply",
    "mail-cr-drift-check",
    "mail-cr-server-dry-run",
    "mail-cr-validate",
    "web-stack-diff-selftest",
    "web-stack-drift-check",
    "web-stack-render",
    "web-stack-validate",
    # Exact, byte-pinned TIN-4227 bridge only. scan_workflows subtracts these
    # from the operator-local set for that one path; every other workflow still
    # receives workflow-arc-operator-recipe for the same calls.
    "web-release-plan",
    "web-release-server-dry-run",
    "web-release-apply",
}

EDGE_RUNTIME_TF_VARS = {
    "TF_VAR_access_allowed_emails",
    "TF_VAR_cloudflare_api_token",
    "TF_VAR_dev_preview_allowed_emails",
    "TF_VAR_enable_github_sso",
    "TF_VAR_enable_google_sso",
    "TF_VAR_github_sso_client_id",
    "TF_VAR_github_sso_client_secret",
    "TF_VAR_google_sso_apps_domain",
    "TF_VAR_google_sso_client_id",
    "TF_VAR_google_sso_client_secret",
    "TF_VAR_onetimepin_idp_id",
}

GF_CORE_SHA = "2281b576bce0e8dd776a047b84e7464f5b508a62"
ARC_CORE_SHA = "11ace397282ff89aeb1dfeb4a32fcbed3200c2ff"
ARC_GLOBAL_ASSIGNMENTS = {
    "gf_core": 'env_var_or_default("GF_CORE_PATH", "../GloriousFlywheel")',
    "gf_core_ci": (
        'env_var_or_default("GF_CORE_CI_PATH", '
        f'"github:tinyland-inc/GloriousFlywheel/{GF_CORE_SHA}#ci")'
    ),
    "gf_core_sha": f'"{GF_CORE_SHA}"',
    "arc_core_default": '"../GloriousFlywheel-arc-11ace"',
    "arc_core_sha": f'"{ARC_CORE_SHA}"',
    "arc_core_ci_default": (
        f'"github:tinyland-inc/GloriousFlywheel/{ARC_CORE_SHA}#ci"'
    ),
    "arc_tfvars": '"tofu/stacks/arc-runners/great-falls-tool-bus.tfvars"',
    "arc_backend_default": '"tofu/backend/honey.s3.hcl"',
    "arc_cluster_uid": '"cc121476-7a95-4b24-aa61-79d1f45713bd"',
    "arc_target_uid": '"c768fdd2-e76f-4fbf-bc39-922430fedbb6"',
}

# Dependencies are an ordered control-flow contract. Adding a guard after the
# action, reordering confirmation, or smuggling in a helper is not equivalent.
ARC_RECIPE_DEPENDENCIES: dict[str, tuple[str, ...]] = {
    "enrollment-preflight": (
        "_reviewed-implementation-core",
        "_arc-kubeconfig-contract",
    ),
    "enrollment-preflight-strict": (
        "_reviewed-implementation-core",
        "_arc-kubeconfig-contract",
    ),
    "_arc-app-secret-inputs": (),
    "arc-app-secret-apply": (
        "_arc-app-secret-inputs",
        "_reviewed-clean-main",
        "_reviewed-implementation-core",
        "_arc-kubeconfig-contract",
        "_operator-apply-confirm",
    ),
    "arc-validate": ("_reviewed-arc-core", "_arc-tofu-environment-contract"),
    "arc-init": (
        "_reviewed-arc-core",
        "_arc-exclusive-confirm",
        "_arc-backend-contract",
        "_arc-runtime-contract",
        "_arc-artifact-root-contract",
    ),
    "arc-plan": (
        "_reviewed-clean-main",
        "_reviewed-arc-core",
        "_arc-exclusive-confirm",
        "_arc-plan-input-snapshot",
        "arc-init",
    ),
    "arc-plan-show": (
        "_reviewed-arc-core",
        "_arc-tofu-environment-contract",
        "_arc-artifact-root-contract",
    ),
    "arc-plan-scope-check": (
        "_reviewed-arc-core",
        "_arc-tofu-environment-contract",
        "_arc-artifact-root-contract",
    ),
    "arc-apply": (
        "_reviewed-clean-main",
        "_reviewed-arc-core",
        "_operator-apply-confirm",
        "_arc-exclusive-confirm",
        "_arc-plan-input-preflight",
        "arc-init",
        "arc-plan-scope-check",
    ),
    "arc-capacity-readback": (
        "_reviewed-clean-main",
        "_reviewed-arc-core",
        "_arc-exclusive-confirm",
        "_arc-backend-contract",
        "_arc-runtime-contract",
        "_arc-artifact-root-contract",
    ),
    "arc-enrollment-plan": ("enrollment-preflight", "arc-plan"),
    "_reviewed-clean-main": (),
    "_reviewed-implementation-core": (),
    "_reviewed-arc-core": (),
    "_arc-tofu-environment-contract": (),
    "_arc-backend-contract": ("_arc-tofu-environment-contract",),
    "_arc-kubeconfig-contract": (),
    "_arc-runtime-contract": ("_arc-kubeconfig-contract",),
    "_arc-artifact-root-contract": (),
    "_arc-plan-input-snapshot": (
        "_reviewed-clean-main",
        "_reviewed-arc-core",
        "_arc-exclusive-confirm",
        "_arc-backend-contract",
        "_arc-runtime-contract",
        "_arc-artifact-root-contract",
    ),
    "_arc-plan-input-preflight": (
        "_reviewed-clean-main",
        "_reviewed-arc-core",
        "_arc-backend-contract",
        "_arc-runtime-contract",
        "_arc-artifact-root-contract",
    ),
    "_operator-apply-confirm": (),
    "_arc-exclusive-confirm": (),
}

# SHA256 of executable_recipe_text(recipe body). Comments and blank lines are
# deliberately excluded: prose cannot satisfy a control, while every executable
# semantic change requires a deliberate receipt update in review.


def _receipt(*chunks: str) -> str:
    """Build review receipts without secret-shaped contiguous source literals."""
    value = "".join(chunks)
    if re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise ValueError("invalid executable receipt")
    return value


ARC_CRITICAL_RECIPE_DIGESTS: dict[str, str] = {
    "enrollment-preflight": _receipt(
        "d83a90b6a0ec08c7", "5095b8d291c95c78", "050fc9bed756da81", "7509f17dabb99e4f"
    ),
    "enrollment-preflight-strict": _receipt(
        "f666430209f1561e", "80efbbc40bfc2465", "3969cb137a856294", "9deb85ac8c672e9e"
    ),
    "_arc-app-secret-inputs": _receipt(
        "ea77d930f64895a3", "bf37ec8e829e8946", "78467ff2a4769cd7", "8c594f565491728b"
    ),
    "arc-app-secret-apply": _receipt(
        "aa0dc549487918dd", "7df6b291fcb46729", "10cba2aabcb224a3", "17f5b5ae7027b48a"
    ),
    "arc-validate": _receipt(
        "b8982e8a89c017ff", "ccdd1ad65a72bb27", "4f17316c5650b20d", "4db0a21ac4c667ac"
    ),
    "arc-init": _receipt(
        "1f30755a55cfb4b6", "2e5e26d1cd58fad6", "ed7fc9b3bc70c477", "21d11d401e00f442"
    ),
    "arc-plan": _receipt(
        "f7b21990c67c48e1", "3840ff179a9f3403", "2c18f97aedf8d517", "ad37254612f045fc"
    ),
    "arc-plan-show": _receipt(
        "c37fb8c36e826dc6", "3676b9eafb3336d0", "87893f2ae0d1c1ec", "c957b577fd505498"
    ),
    "arc-plan-scope-check": _receipt(
        "581e0d278c091783", "3d8635db7d9f965f", "adb725c3cf079a96", "2d491a784a580878"
    ),
    "arc-apply": _receipt(
        "fe8c324732148b38", "c967bad1c1ccab8e", "fd3840cedf78db82", "9b5a73294ec96ef6"
    ),
    "arc-capacity-readback": _receipt(
        "10a49e33fd0cb568", "0a0b53e097661d10", "5ca9ebe461940732", "79b00a0d36efef31"
    ),
    "arc-enrollment-plan": _receipt(
        "49a0e25c1cc8c8ff", "b15096271b4271a4", "fe1d38e06e5abf79", "905f0b0d50110b7a"
    ),
    "_reviewed-clean-main": _receipt(
        "fe9e048cffbba33b", "36e25d7e15eff9f0", "2ef7dca85552e144", "3b2bf9865a24d32e"
    ),
    "_reviewed-implementation-core": _receipt(
        "180f8edd55babb51", "43e15dac40bbad2a", "bffe444ff6221c04", "7c64836ae0c2cfc6"
    ),
    "_reviewed-arc-core": _receipt(
        "0ae5d0b8778afe94", "fb90bc4fcd27fea7", "911d24254d9fd0bd", "d62505a78f51ac1b"
    ),
    "_arc-tofu-environment-contract": _receipt(
        "ca156188b92e7f0a", "bd6b876e5716c3c7", "a141ecb54c15e158", "0b3e911671d4e5d5"
    ),
    "_arc-backend-contract": _receipt(
        "9d5dd393232dd6a3", "60be4e950105cfa5", "24b08c174e5f7281", "1c01747d4bcc44d8"
    ),
    "_arc-kubeconfig-contract": _receipt(
        "b0a11061708fcdfe", "55054b2b9e1f118b", "5bd0ece868acb187", "bcca11c478cda72a"
    ),
    "_arc-runtime-contract": _receipt(
        "f667efcef12ba025", "ab88b1f147ef3ad5", "fd33ddfdcd7aafe6", "88b797f7dd143dd0"
    ),
    "_arc-artifact-root-contract": _receipt(
        "3facf583d208268e", "ea605e546826e378", "115f0a222a718557", "a23fd2d2952e2bda"
    ),
    "_arc-plan-input-snapshot": _receipt(
        "f17c45f61d0488e0", "70475eb411b78eb5", "5e6dd0ab6a2a116e", "f144ce08c04809d6"
    ),
    "_arc-plan-input-preflight": _receipt(
        "6a5f69b8b73bb5d2", "285e9effeb9111c3", "8f5fbe0c34a07813", "51fe2e4ebf574cc1"
    ),
    "_operator-apply-confirm": _receipt(
        "6487928ae4f59860", "9a786fc78d5d0e9d", "7a1077a7ff8f4ecb", "966d483dd92058a0"
    ),
    "_arc-exclusive-confirm": _receipt(
        "9c8565974cf6f3b0", "f2aca232a5ff6978", "8d566d4ae8c96152", "900813ed27e88e7a"
    ),
}

# Purpose-bounded non-ARC mutations are operator-local for the same reason as
# ARC applies: they consume operator-custody credentials and may change live
# state. Dependencies are ordered, and executable bodies are receipt-bound so a
# comment cannot stand in for a guard or move a check after the mutation.
ATTENDED_RECIPE_DEPENDENCIES: dict[str, tuple[str, ...]] = {
    "_mail-kubeconfig-inputs": (),
    "_list-member-add-inputs": (),
    "list-member-add": (
        "_list-member-add-inputs",
        "_reviewed-clean-main",
        "_operator-apply-confirm",
    ),
    "form-altcha-secret-apply": (
        "_mail-kubeconfig-inputs",
        "_reviewed-clean-main",
        "_operator-apply-confirm",
    ),
}

ATTENDED_CRITICAL_RECIPE_DIGESTS: dict[str, str] = {
    "_mail-kubeconfig-inputs": _receipt(
        "b36a412965f54de1", "e8fcf75164a74a91", "dee1debc1edd79dc", "dacb634cb85cfc5b"
    ),
    "_list-member-add-inputs": _receipt(
        "8609c78a7ae5fb64", "8eb23bcb5e7352fc", "c21405b9c5c96605", "6df235e504c66699"
    ),
    "list-member-add": _receipt(
        "86c91e13b7181939", "cc9fbdbf60931341", "6a9cb4d544265d41", "fbc321f6d1a32c86"
    ),
    "form-altcha-secret-apply": _receipt(
        "d394883ac79138f4", "b78253e99505ee18", "f0931c8607f62fa9", "f5c1b30b25c115ce"
    ),
}

ATTENDED_OPERATOR_LOCAL_ROOTS = {
    "_list-member-add-inputs",
    "list-member-add",
    "form-altcha-secret-apply",
}

# The gftb-site cutover proofs are intentionally operator-local even though they
# are read-only: they inspect an operator-custody kubeconfig or Access cookie,
# and their receipts are release evidence rather than hosted-CI entrypoints.
WEB_RELEASE_RECIPE_DEPENDENCIES: dict[str, tuple[str, ...]] = {
    "_web-release-candidate-inputs": (),
    # The digest-discovery entrypoint. It deliberately declares NO Just
    # dependency: _web-release-candidate-inputs requires a WEB_APPLY_IMAGE that
    # does not exist until the tag has been resolved, so the resolver re-enters
    # the guard through its nested `just web-release-candidate-proof` call
    # instead of running it first against an unset variable.
    "web-release-resolve-candidate": (),
    "web-release-candidate-proof": ("_web-release-candidate-inputs",),
    "web-release-render": ("_web-release-candidate-inputs",),
    "_web-release-kubeconfig-inputs": (),
    "web-release-pinned-running-proof": ("_web-release-candidate-inputs",),
    "web-release-served-proof": ("_web-release-candidate-inputs",),
    # The mutating complement to the proofs above. It reuses their input guard
    # verbatim and it reuses web-release-render as the single renderer, so the
    # reviewed bytes and the applied bytes are the same bytes.
    "_web-release-plan-root-contract": (),
    "_web-release-apply-kubeconfig-contract": (),
    "web-release-plan": (
        "_web-release-candidate-inputs",
        "_web-release-plan-root-contract",
    ),
    "_web-release-plan-preflight": (
        "_web-release-candidate-inputs",
        "_web-release-plan-root-contract",
    ),
    "web-release-server-dry-run": (
        "_web-release-apply-kubeconfig-contract",
        "_web-release-plan-preflight",
    ),
    "web-release-apply": (
        "_reviewed-clean-main",
        "_operator-apply-confirm",
        "_web-release-apply-kubeconfig-contract",
        "_web-release-plan-preflight",
    ),
}

WEB_RELEASE_CRITICAL_RECIPE_DIGESTS: dict[str, str] = {
    "_web-release-candidate-inputs": _receipt(
        "5bf45b521f65b560", "d833eda99bfbe2e6", "98727dbe6a1c782b", "4695cc4e8a8184f6"
    ),
    # Recomputed exactly the way this validator checks it, so a reviewer can
    # reproduce the constant without running the whole self-test:
    #   sha256(executable_recipe_text(just_recipe_block(Justfile, name)[2]))
    # i.e. the recipe body with Just's indent removed and blank/comment-only
    # lines dropped (`#!` shebangs are kept). Editing one executable line of
    # web-release-resolve-candidate changes this digest and fails
    # `just public-surface` until the new value is reviewed in.
    "web-release-resolve-candidate": _receipt(
        "3d20dda898a6d600", "69bcef992f05d64c", "41fd6915595ff2e9", "37c35696e3607d98"
    ),
    "web-release-candidate-proof": _receipt(
        "6347e0f7e92498e9", "c6fdfd7c5d80b0ef", "06e4818e333f3cac", "c5ace4f7652a2273"
    ),
    # Updated 2026-08-29: yq-go now owns only YAML/JSON conversion; jq
    # owns release mutation and slurp semantics. The public-surface fixtures
    # execute both this renderer and the exact-one kubeconfig guard.
    "web-release-render": _receipt(
        "bafec28ca138b218", "93c7bb2f1374d48a", "f096847a301b966a", "0ce6033f3a7d039c"
    ),
    "_web-release-kubeconfig-inputs": _receipt(
        "916de1b406d43ca1", "f7a2870af5898faf", "4f51aa497b5876b9", "65f0a9f9b8d0b819"
    ),
    "web-release-pinned-running-proof": _receipt(
        "bb9f757c5e1a3dcf", "c48e67ad1aa40b11", "0f25466fc6db04e7", "159d31d0968b28ab"
    ),
    "web-release-served-proof": _receipt(
        "6ded71468ff6b068", "2af42983faec1ed2", "fa3f69fb10d46f86", "e169c0219ff4c7c3"
    ),
    "_web-release-plan-root-contract": _receipt(
        "271460cb71ceda56", "0bbca7e8b57d0ddf", "eb68c983d72ab455", "a44e713d9007bbf9"
    ),
    "_web-release-apply-kubeconfig-contract": _receipt(
        "5cd12307160b8a71", "3ad1307f87ee1298", "5a28a484924cd275", "23f3bbd56a1e97fb"
    ),
    "web-release-plan": _receipt(
        "4c521b684de15316", "694df6eec8402abd", "e6fb365e2cb8a4d1", "79d6b8a69379a844"
    ),
    "_web-release-plan-preflight": _receipt(
        "c8e58b12435c19a4", "036eb9a012fd322c", "31b494258d97824d", "f243bbec666716a6"
    ),
    "web-release-server-dry-run": _receipt(
        "b478fca65de1ae58", "a37038565e80d6f6", "23d5318412fc919d", "77382267087b8707"
    ),
    "web-release-apply": _receipt(
        "027bfae6f72ee45f", "6bd86a57e1b5d921", "d5df538b3905589c", "f111051c06f3da5e"
    ),
    # The legacy adapter-node carrier's promotion interlock. It is not part of
    # the web-release dependency graph -- it hangs off web-stack-apply, the
    # attended legacy carrier no workflow may invoke (TIN-3899) -- so it is
    # receipted here but deliberately NOT an operator-local root. Its body is
    # enforced by scan_web_stack_promotion_interlock_text.
    "_web-stack-promotion-interlock": _receipt(
        "f6fbb3dc72de15bb", "38d350899029f9fb", "afb1a885f3b59950", "a5f7c8a92999df1f"
    ),
}

WEB_RELEASE_OPERATOR_LOCAL_ROOTS = set(WEB_RELEASE_RECIPE_DEPENDENCIES)
WEB_RELEASE_JUST_GLOBAL_ASSIGNMENTS = {
    "dotenv-load": "set dotenv-load := false",
    "shell": 'set shell := ["bash", "-eu", "-o", "pipefail", "-c"]',
}
# Redirecting the stack the release chain renders and applies is the single
# highest-leverage silent mutation available, so both globals are pinned exactly.
WEB_RELEASE_STACK_GLOBAL_ASSIGNMENTS = {
    "web_stack_dir": '"k8s/web/greatfallstoolbus-org-production"',
    "web_stack_ns": '"greatfallstoolbus-org-production"',
}

# Imperative pinning -- `kubectl set image`, `kubectl scale ... deployment`, or a
# `replicas` patch -- makes live state stop equalling the reviewed tree. The scan
# covers the WHOLE Justfile (every recipe body plus every executable line outside
# a recipe), not an enumerated recipe list, so a brand-new unlisted recipe cannot
# reintroduce it. Exactly one recipe is allowed to do this: the legacy
# `web-stack-apply` adapter-node carrier, whose imperative pin predates the
# release chain and is documented in _k8s-drift-check's header. TIN-3899 removed
# that carrier's automated caller but KEPT the recipe and its promotion
# interlock as the attended belt-and-braces path, so this allowlist stays a
# one-element set instead of going empty and taking the interlock contract with
# it.
#
# The command anchor covers wrapper names built on `kubectl` (this repo's own
# `kubectl_clean`), and IMPERATIVE_PIN_CONTINUATION folds backslash line
# continuations into one logical line before matching, so splitting the verb onto
# the next line is not an evasion. Same-intent rewrites of the live pod template
# are covered too: `rollout undo`, `replace -f`, `delete ... deployment`,
# `delete -f`/`--filename`, `edit deployment`, `scale` in any form, and BOTH
# spellings of a container-image patch -- the JSON-patch path and the merge patch
# (`--type merge -p '{"spec":{"template":{"spec":{"containers":[{"image":...`).
#
# KNOWN RESIDUAL, deliberately not chased: shell *variable indirection*
# (`KC=kubectl; "${KC}" ... set image`, or building the patch body into a
# variable on one line and passing it to `kubectl patch` on the next) defeats a
# textual scan. The runbook states the guarantee at exactly this strength rather
# than claiming the scan is exhaustive. The recipe-body digests in
# WEB_RELEASE_CRITICAL_RECIPE_DIGESTS, not this scan, are what make an edit to a
# reviewed release recipe fail closed.
IMPERATIVE_PIN_CONTINUATION = re.compile(r"\\\n[ \t]*")
_IMPERATIVE_PIN_KUBECTL = r"\bkubectl[A-Za-z0-9_]*\b"
IMPERATIVE_PIN = re.compile(
    rf"{_IMPERATIVE_PIN_KUBECTL}[^\n]*\bset\s+image\b"
    rf"|{_IMPERATIVE_PIN_KUBECTL}[^\n]*\bscale\b[^\n]*--replicas\b"
    rf"|{_IMPERATIVE_PIN_KUBECTL}[^\n]*\bscale\b[^\n]*"
    rf"\b(?:deployment|deployments|deploy|statefulset|replicaset)\b"
    rf"|{_IMPERATIVE_PIN_KUBECTL}[^\n]*\bpatch\b[^\n]*\breplicas\b"
    rf"|{_IMPERATIVE_PIN_KUBECTL}[^\n]*\brollout\s+undo\b"
    rf"|{_IMPERATIVE_PIN_KUBECTL}[^\n]*\breplace\b[^\n]*(?:\s-f\b|\s--filename\b)"
    rf"|{_IMPERATIVE_PIN_KUBECTL}[^\n]*\bdelete\b[^\n]*"
    rf"\b(?:deployment|deployments|deploy)\b"
    rf"|{_IMPERATIVE_PIN_KUBECTL}[^\n]*\bdelete\b[^\n]*(?:\s-f\b|\s--filename\b)"
    rf"|{_IMPERATIVE_PIN_KUBECTL}[^\n]*\bedit\b[^\n]*"
    rf"\b(?:deployment|deployments|deploy)\b"
    rf"|{_IMPERATIVE_PIN_KUBECTL}[^\n]*[\"']replicas[\"']\s*:"
    rf"|{_IMPERATIVE_PIN_KUBECTL}[^\n]*[\"']containers[\"']\s*:[^\n]*[\"']image[\"']\s*:"
    rf"|/spec/template/spec/containers/[0-9*]+/image\b"
)
IMPERATIVE_PIN_ALLOWED_RECIPES = frozenset({"web-stack-apply"})

# A brand-new recipe running `kubectl ... apply -k/-f` against the web stack
# tree (`{{ web_stack_dir }}` or its literal path) is not an imperative pin, but
# it would recreate allow-egress-dns / allow-egress-discuss-archive and re-pin
# the tree's adapter-node digest WITHOUT passing through
# _web-stack-promotion-interlock, which only web-stack-apply is bound to. Only
# the legacy carrier and its server dry-run may apply the tree; the reviewed
# release chain applies rendered plan bytes (`apply -f "${plan}"`), never the
# tree. Same textual strength as IMPERATIVE_PIN: variable indirection of the
# directory is a known residual.
WEB_STACK_TREE_APPLY = re.compile(
    rf"{_IMPERATIVE_PIN_KUBECTL}[^\n]*\bapply\b[^\n]*"
    r"(?:\s-k\b|\s--kustomize\b|\s-f\b|\s--filename\b|\s-R\b|\s--recursive\b)"
    r"[^\n]*(?:\{\{\s*web_stack_dir\s*\}\}|k8s/web/greatfallstoolbus-org-production)"
)
WEB_STACK_TREE_APPLY_ALLOWED_RECIPES = frozenset(
    {"web-stack-apply", "web-stack-server-dry-run"}
)

# The legacy adapter-node carrier and the reviewed release chain mutate the SAME
# Deployment. web-stack.yml used to fire `just web-stack-apply` unattended from a
# repository_dispatch the public site repo sent on every push to main; TIN-3899
# deleted both ends of that path, so the carrier is now attended-only. The
# interlock is RETAINED as belt-and-braces on that attended path: it reads the
# LIVE image and refuses once the gftb-site promotion is in place, and this
# contract makes removing or bypassing it -- or re-wiring any new mutating
# carrier around it -- a `just public-surface` failure.
WEB_STACK_PROMOTION_INTERLOCK = "_web-stack-promotion-interlock"
WEB_STACK_PROMOTION_INTERLOCK_DEPENDENTS = ("web-stack-apply",)
WEB_STACK_PROMOTION_INTERLOCK_REQUIRED_TEXT = (
    "get deployment/greatfallstoolbus-org",
    "ghcr.io/great-falls-tool-bus/gftb-site@",
    "exit 1",
)

WEB_RELEASE_VALIDATION_CALLEE = "web-stack-validate"
WEB_RELEASE_VALIDATION_CALLEE_DEPENDENCIES: tuple[str, ...] = ()
WEB_RELEASE_VALIDATION_CALLEE_DIGEST = _receipt(
    "482232ea1b2f080a", "aa86db3e695197c5", "61eb9b3fd8ca4210", "8643ac9e3e3ce0d2"
)
WEB_RELEASE_VALIDATION_SCRIPT = Path("scripts/validate-web-stack.sh")
# Updated 2026-08-21 (rung 1 tree honesty): scripts/validate-web-stack.sh now
# admits ghcr.io/great-falls-tool-bus/gftb-site instead of the retired legacy
# greatfallstoolbus.org adapter-node repository, so its bytes and this pinned
# digest both changed together in the same PR (`shasum -a 256
# scripts/validate-web-stack.sh`).
# Updated again 2026-08-21 (rung 2 round 3, PR #127 comment 5377613179):
# validate-web-stack.sh now calls scripts/guard-no-remote-kustomize-resources.sh
# before its own `kubectl kustomize` call, so its bytes and this pinned digest
# changed together in the same PR (same recompute command as above).
# Updated a third time 2026-08-22 (rung 2 round 4, PR #127 comments
# 5380010266 + 5380172269): the guard call site's comment text changed to
# describe the allowlist design (the guard script itself moved from a
# denylist to an allowlist; validate-web-stack.sh's own bytes changed only in
# that comment, not in behavior), so this pinned digest changed once more in
# the same PR (same recompute command as above).
# Updated 2026-08-29: the yq-go preflight now requires both the mikefarah
# vendor marker and a v4 version marker; this receipt binds that exact fix.
WEB_RELEASE_VALIDATION_SCRIPT_SHA256 = _receipt(
    "c260f829e1531513", "3c4fa03db9443b1d", "55cf9d7e5fa02b78", "a6a56635fbab64c8"
)

FLAKE_RELEASE_PACKAGES = ("crane", "curl")
FLAKE_LOCK_SHA256 = _receipt(
    "33150ce2f846aef0", "1539145f74a8eb1a", "04d45df5d960494c", "e188111a80e170e3"
)

NEGATIVE_OR_DESCRIPTIVE_CONTEXT = re.compile(
    r"\b(no|not|cannot|can't|never|without|avoid|accidental|deliberately|"
    r"unsupported|forbid|forbids|blocked|do\s+not)\b",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class Finding:
    rule: str
    path: Path
    line: int
    text: str


def git_files(globs: list[str]) -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "--"] + globs,
        cwd=REPO,
        check=True,
        capture_output=True,
        text=True,
    )
    return [Path(line) for line in sorted(set(result.stdout.splitlines())) if line]


def iter_lines(paths: list[Path]):
    for rel in paths:
        if rel == SELF:
            continue
        path = REPO / rel
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except (OSError, IsADirectoryError):
            continue
        for lineno, line in enumerate(lines, start=1):
            yield rel, lineno, line


def just_recipe_block(text: str, name: str) -> tuple[int, str, str] | None:
    """Return a Just recipe's line, dependency header, and indented body."""
    lines = text.splitlines()
    marker = re.compile(rf"^{re.escape(name)}(?:\s+[^:]*)?\s*:(?P<deps>.*)$")
    for index, line in enumerate(lines):
        match = marker.match(line)
        if not match:
            continue
        end = index + 1
        while end < len(lines) and (
            not lines[end] or lines[end].startswith((" ", "\t"))
        ):
            end += 1
        return index + 1, match.group("deps"), "\n".join(lines[index + 1 : end])
    return None


def all_just_recipe_blocks(text: str) -> dict[str, list[tuple[int, str, str]]]:
    """Parse every top-level recipe, retaining duplicates for fail-closed checks."""
    result: dict[str, list[tuple[int, str, str]]] = {}
    lines = text.splitlines()
    marker = re.compile(
        r"^(?P<name>[A-Za-z_][A-Za-z0-9_-]*)(?:\s+[^:]*)?\s*:(?P<deps>.*)$"
    )
    index = 0
    while index < len(lines):
        line = lines[index]
        if ":=" in line:
            index += 1
            continue
        match = marker.match(line)
        if not match:
            index += 1
            continue
        end = index + 1
        while end < len(lines) and (
            not lines[end] or lines[end].startswith((" ", "\t"))
        ):
            end += 1
        result.setdefault(match.group("name"), []).append(
            (index + 1, match.group("deps"), "\n".join(lines[index + 1 : end]))
        )
        index = end
    return result


def all_just_aliases(text: str) -> dict[str, list[tuple[int, str]]]:
    """Parse literal Just aliases, retaining duplicates and source lines."""
    aliases: dict[str, list[tuple[int, str]]] = {}
    marker = re.compile(
        r"^alias\s+(?P<name>[A-Za-z_][A-Za-z0-9_-]*)\s*:=\s*"
        r"(?P<target>[A-Za-z_][A-Za-z0-9_-]*)\s*$"
    )
    for line, text_line in enumerate(text.splitlines(), start=1):
        match = marker.match(text_line)
        if match:
            aliases.setdefault(match.group("name"), []).append(
                (line, match.group("target"))
            )
    return aliases


def just_recipe_arities(text: str) -> dict[str, int]:
    """Return each literal recipe's positional parameter count."""
    arities: dict[str, int] = {}
    marker = re.compile(
        r"^(?P<name>[A-Za-z_][A-Za-z0-9_-]*)(?P<params>(?:\s+[^:]+)?)\s*:"
    )
    for line in text.splitlines():
        if ":=" in line or line.startswith("alias "):
            continue
        match = marker.match(line)
        if not match:
            continue
        try:
            parameters = shlex.split(match.group("params"))
        except ValueError:
            continue
        arities.setdefault(match.group("name"), len(parameters))
    aliases = all_just_aliases(text)
    changed = True
    while changed:
        changed = False
        for name, declarations in aliases.items():
            targets = {target for _, target in declarations}
            if len(targets) == 1 and next(iter(targets)) in arities and name not in arities:
                arities[name] = arities[next(iter(targets))]
                changed = True
    return arities


def executable_recipe_text(body: str) -> str:
    """Normalize Just indent while preserving executable whitespace and shebangs."""
    dedented = textwrap.dedent(body)
    return "\n".join(
        line
        for line in dedented.splitlines()
        if line.strip()
        and not (
            line.strip().startswith("#") and not line.strip().startswith("#!")
        )
    )


ARC_OPERATOR_LOCAL_ROOTS = {
    "enrollment-preflight",
    "enrollment-preflight-strict",
    "_arc-app-secret-inputs",
    "arc-app-secret-apply",
    "arc-validate",
    "arc-init",
    "arc-plan",
    "arc-plan-show",
    "arc-plan-scope-check",
    "arc-apply",
    "arc-capacity-readback",
    "arc-enrollment-plan",
    "_reviewed-arc-core",
    "_arc-backend-contract",
    "_arc-kubeconfig-contract",
    "_arc-runtime-contract",
    "_arc-plan-input-snapshot",
    "_arc-plan-input-preflight",
}
ARC_EXPLICIT_OPERATOR_LOCAL_WRAPPERS = {"check"}


def shell_logical_lines(text: str) -> list[str]:
    """Join backslash continuations before inspecting shell-shaped text."""
    logical: list[str] = []
    pending = ""
    for line in textwrap.dedent(text).splitlines():
        stripped = line.rstrip()
        if stripped.endswith("\\"):
            pending += stripped[:-1] + " "
            continue
        logical.append(pending + line.lstrip() if pending else line)
        pending = ""
    if pending:
        logical.append(pending)
    return logical


def parse_just_calls(
    text: str,
    known_recipes: set[str],
    recipe_arities: dict[str, int] | None = None,
    *,
    ignore_help_echo: bool = True,
) -> tuple[set[str], bool, bool]:
    """Parse all literal recipe argv after Just options and assignments.

    The boolean reports a Just command whose first recipe is dynamic or cannot
    be parsed. Workflows fail closed on that ambiguity.
    """
    calls: set[str] = set()
    unresolved = False
    multiple = False
    for line in shell_logical_lines(text):
        command = line.strip().lstrip("@-").lstrip()
        if not command or command.startswith("#"):
            continue
        if ignore_help_echo and re.match(r"^(?:echo|printf)\b", command):
            # Ignore literal operator guidance, but never let an echo prefix
            # hide a second command or command substitution that invokes Just.
            if not re.search(r"[;&|`]|\$\(", command):
                continue
        for match in JUST_COMMAND_START.finditer(command):
            argv_text = re.sub(
                r"\{\{.*?\}\}", "JUST_TEMPLATE_VALUE", command[match.start() :]
            )
            try:
                tokens = shlex.split(argv_text, comments=True, posix=True)
            except ValueError:
                unresolved = True
                continue
            if not tokens or tokens[0] != "just":
                unresolved = True
                continue
            index = 1
            options_done = False
            command_recipe_count = 0
            while index < len(tokens):
                token = tokens[index]
                if token in {";", "&&", "||", "|", "&"} or token.startswith(
                    (">", "<")
                ):
                    break
                if not options_done and token == "--":
                    options_done = True
                    index += 1
                    continue
                if not options_done and token in JUST_OPTIONS_WITH_VALUES:
                    index += 1 + JUST_OPTIONS_WITH_VALUES[token]
                    continue
                if not options_done and (
                    token.startswith("--justfile=")
                    or token.startswith("--working-directory=")
                    or token.startswith("--dotenv-path=")
                    or token.startswith("--color=")
                    or (token.startswith("-f") and token != "-f")
                    or (token.startswith("-d") and token != "-d")
                ):
                    index += 1
                    continue
                if not options_done and token.startswith("-"):
                    index += 1
                    continue
                if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", token):
                    index += 1
                    continue
                if token in known_recipes:
                    calls.add(token)
                    command_recipe_count += 1
                    arity = (recipe_arities or {}).get(token, 0)
                    if index + arity >= len(tokens):
                        unresolved = True
                        break
                    index += arity
                else:
                    # At command level, an unknown/dynamic argv can name another
                    # recipe. Known recipe arguments were consumed by arity above.
                    unresolved = True
                index += 1
            if command_recipe_count > 1:
                multiple = True
            if command_recipe_count == 0 and not any(
                token in JUST_NON_EXECUTING_OPTIONS for token in tokens[1:]
            ):
                unresolved = True
    return calls, unresolved, multiple


def executable_just_calls(
    body: str, known_recipes: set[str], recipe_arities: dict[str, int]
) -> tuple[set[str], bool]:
    calls, unresolved, _ = parse_just_calls(body, known_recipes, recipe_arities)
    return calls, unresolved


def operator_recipe_closure(
    text: str, roots: set[str], *, taint_unresolved: bool = True
) -> tuple[set[str], dict[str, set[str]]]:
    """Return recipes that directly or transitively reach operator-local roots."""
    definitions = all_just_recipe_blocks(text)
    aliases = all_just_aliases(text)
    recipe_names = set(definitions) | set(aliases)
    recipe_arities = just_recipe_arities(text)
    edges: dict[str, set[str]] = {}
    unresolved_recipes: set[str] = set()
    for name, blocks in definitions.items():
        targets: set[str] = set()
        for _, dependencies, body in blocks:
            targets.update(
                token for token in dependencies.split() if token in recipe_names
            )
            body_calls, unresolved = executable_just_calls(
                body, recipe_names, recipe_arities
            )
            targets.update(body_calls)
            if unresolved:
                unresolved_recipes.add(name)
        edges[name] = targets
    for name, declarations in aliases.items():
        edges.setdefault(name, set()).update(target for _, target in declarations)

    tainted = set(roots)
    if taint_unresolved:
        tainted.update(unresolved_recipes)
    changed = True
    while changed:
        changed = False
        for name, targets in edges.items():
            if name not in tainted and targets & tainted:
                tainted.add(name)
                changed = True
    return tainted, edges


def arc_operator_recipe_closure(text: str) -> tuple[set[str], dict[str, set[str]]]:
    """Return recipes that directly or transitively reach operator-local ARC."""
    return operator_recipe_closure(text, ARC_OPERATOR_LOCAL_ROOTS)


def attended_operator_recipe_closure(
    text: str,
) -> tuple[set[str], dict[str, set[str]]]:
    """Return recipes reaching consented member or Secret mutation surfaces."""
    # The ARC closure already fail-closes every unresolved Just invocation. This
    # second closure only needs literal reverse reachability from its own roots.
    return operator_recipe_closure(
        text, ATTENDED_OPERATOR_LOCAL_ROOTS, taint_unresolved=False
    )


def web_release_operator_recipe_closure(
    text: str,
) -> tuple[set[str], dict[str, set[str]]]:
    """Return recipes reaching operator-local gftb-site release proofs."""
    # Fail closed independently of ARC: a dynamic or bare Just invocation may
    # resolve to a release proof even when no literal recipe name is visible.
    return operator_recipe_closure(text, WEB_RELEASE_OPERATOR_LOCAL_ROOTS)


def all_operator_local_recipe_closure(
    text: str,
) -> tuple[set[str], dict[str, set[str]]]:
    """Return the union of every operator-local recipe surface."""
    arc, edges = arc_operator_recipe_closure(text)
    attended, _ = attended_operator_recipe_closure(text)
    web_release, _ = web_release_operator_recipe_closure(text)
    return arc | attended | web_release, edges


def scan_arc_operator_contract_text(text: str, path: Path) -> list[Finding]:
    """Bind every sensitive ARC operator recipe to one reviewed implementation."""
    findings: list[Finding] = []

    for name, expected in ARC_GLOBAL_ASSIGNMENTS.items():
        observed = re.findall(
            rf"^{re.escape(name)}\s*:=\s*(.*?)\s*$", text, flags=re.MULTILINE
        )
        if observed != [expected]:
            findings.append(
                Finding(
                    "arc-global-contract-mismatch",
                    path,
                    1,
                    f"{name} must be declared exactly once as {expected!r}; "
                    f"observed {observed!r}.",
                )
            )

    dependency_names = set(ARC_RECIPE_DEPENDENCIES)
    digest_names = set(ARC_CRITICAL_RECIPE_DIGESTS)
    if dependency_names != digest_names:
        findings.append(
            Finding(
                "arc-validator-receipt-set-mismatch",
                Path(SELF),
                1,
                "ARC dependency and executable-receipt recipe sets differ: "
                f"dependencies-only={sorted(dependency_names - digest_names)!r}, "
                f"digests-only={sorted(digest_names - dependency_names)!r}.",
            )
        )

    definitions = all_just_recipe_blocks(text)
    aliases = all_just_aliases(text)
    for name, expected_dependencies in ARC_RECIPE_DEPENDENCIES.items():
        recipes = definitions.get(name, [])
        alias_count = len(aliases.get(name, []))
        if len(recipes) != 1 or alias_count:
            findings.append(
                Finding(
                    "arc-operator-recipe-missing",
                    path,
                    1,
                    f"Required operator-local recipe {name!r} must have exactly one "
                    f"recipe definition and no alias; observed {len(recipes)} recipe(s) "
                    f"and {alias_count} alias(es).",
                )
            )
            continue
        line, dependencies, body = recipes[0]
        observed_dependencies = tuple(dependencies.split())
        if observed_dependencies != expected_dependencies:
            findings.append(
                Finding(
                    "arc-recipe-dependencies-mismatch",
                    path,
                    line,
                    f"{name} dependencies must be exactly "
                    f"{expected_dependencies!r}; observed {observed_dependencies!r}.",
                )
            )

        executable = executable_recipe_text(body)
        observed_digest = hashlib.sha256(executable.encode("utf-8")).hexdigest()
        expected_digest = ARC_CRITICAL_RECIPE_DIGESTS.get(name)
        if expected_digest is not None and observed_digest != expected_digest:
            findings.append(
                Finding(
                    "arc-recipe-executable-receipt-mismatch",
                    path,
                    line,
                    f"{name} executable SHA256 must be {expected_digest}; "
                    f"observed {observed_digest}.",
                )
            )

    tainted, edges = arc_operator_recipe_closure(text)
    # ARC intentionally fail-closes shell-obfuscated/dynamic Just dispatches.
    # The release proofs are independently exact-body/dependency receipted, so
    # an unresolved tokenization edge inside one of those exact bodies is not
    # an unreceipted ARC wrapper. No other unresolved recipe is exempted.
    receipted = (
        set(ARC_RECIPE_DEPENDENCIES)
        | ARC_EXPLICIT_OPERATOR_LOCAL_WRAPPERS
        | set(WEB_RELEASE_RECIPE_DEPENDENCIES)
    )
    for name in sorted((tainted & set(edges)) - receipted):
        targets = sorted(edges[name] & tainted)
        if name in definitions:
            line = definitions[name][0][0]
        else:
            line = aliases[name][0][0]
        findings.append(
            Finding(
                "arc-unreceipted-operator-wrapper",
                path,
                line,
                f"{name} reaches operator-local ARC recipe(s) {targets!r} but has no "
                "exact dependency/body receipt.",
            )
        )

    for retired_name, rule, message in (
        (
            "_arc-plan-json",
            "arc-sensitive-json-carrier-retained",
            "Delete the persistent ARC plan-JSON carrier.",
        ),
        (
            "arc-app-secret-dry-run",
            "arc-secret-print-carrier-retained",
            "Delete the ARC Secret dry-run recipe; rendered Secret YAML exposes material.",
        ),
    ):
        retired = just_recipe_block(text, retired_name)
        if retired is not None:
            findings.append(Finding(rule, path, retired[0], message))

    if "ALLOW_ARC_DESTROY" in text:
        findings.append(
            Finding(
                "arc-destroy-bypass-retained",
                path,
                1,
                "ARC delete actions must fail closed without an environment bypass.",
            )
        )
    return findings


def scan_attended_operator_contract_text(text: str, path: Path) -> list[Finding]:
    """Bind each purpose-bounded non-ARC mutation to one reviewed implementation."""
    findings: list[Finding] = []
    dependency_names = set(ATTENDED_RECIPE_DEPENDENCIES)
    digest_names = set(ATTENDED_CRITICAL_RECIPE_DIGESTS)
    if dependency_names != digest_names:
        findings.append(
            Finding(
                "attended-validator-receipt-set-mismatch",
                Path(SELF),
                1,
                "Attended dependency and executable-receipt recipe sets differ: "
                f"dependencies-only={sorted(dependency_names - digest_names)!r}, "
                f"digests-only={sorted(digest_names - dependency_names)!r}.",
            )
        )

    definitions = all_just_recipe_blocks(text)
    aliases = all_just_aliases(text)
    for name, expected_dependencies in ATTENDED_RECIPE_DEPENDENCIES.items():
        recipes = definitions.get(name, [])
        alias_count = len(aliases.get(name, []))
        if len(recipes) != 1 or alias_count:
            findings.append(
                Finding(
                    "attended-operator-recipe-missing",
                    path,
                    1,
                    f"Required attended recipe {name!r} must have exactly one recipe "
                    f"definition and no alias; observed {len(recipes)} recipe(s) and "
                    f"{alias_count} alias(es).",
                )
            )
            continue
        line, dependencies, body = recipes[0]
        observed_dependencies = tuple(dependencies.split())
        if observed_dependencies != expected_dependencies:
            findings.append(
                Finding(
                    "attended-recipe-dependencies-mismatch",
                    path,
                    line,
                    f"{name} dependencies must be exactly "
                    f"{expected_dependencies!r}; observed {observed_dependencies!r}.",
                )
            )

        executable = executable_recipe_text(body)
        observed_digest = hashlib.sha256(executable.encode("utf-8")).hexdigest()
        expected_digest = ATTENDED_CRITICAL_RECIPE_DIGESTS.get(name)
        if expected_digest is not None and observed_digest != expected_digest:
            findings.append(
                Finding(
                    "attended-recipe-executable-receipt-mismatch",
                    path,
                    line,
                    f"{name} executable SHA256 must be {expected_digest}; "
                    f"observed {observed_digest}.",
                )
            )

    tainted, edges = attended_operator_recipe_closure(text)
    receipted = set(ATTENDED_RECIPE_DEPENDENCIES)
    for name in sorted((tainted & set(edges)) - receipted):
        targets = sorted(edges[name] & tainted)
        if name in definitions:
            line = definitions[name][0][0]
        else:
            line = aliases[name][0][0]
        findings.append(
            Finding(
                "attended-unreceipted-operator-wrapper",
                path,
                line,
                f"{name} reaches purpose-bound attended recipe(s) {targets!r} but "
                "has no exact dependency/body receipt.",
            )
        )
    return findings


def scan_web_release_operator_contract_text(
    text: str, path: Path
) -> list[Finding]:
    """Bind each release proof to one exact dependency graph and body."""
    findings: list[Finding] = []
    for setting, expected in WEB_RELEASE_JUST_GLOBAL_ASSIGNMENTS.items():
        observed = re.findall(
            rf"^set\s+{re.escape(setting)}\s*:=.*$", text, flags=re.MULTILINE
        )
        if observed != [expected]:
            findings.append(
                Finding(
                    "web-release-just-global-contract-mismatch",
                    path,
                    1,
                    f"Release proofs require exactly {expected!r}; "
                    f"observed {observed!r}.",
                )
            )
    for name, expected_assignment in WEB_RELEASE_STACK_GLOBAL_ASSIGNMENTS.items():
        observed = re.findall(
            rf"^{re.escape(name)}\s*:=\s*(.*?)\s*$", text, flags=re.MULTILINE
        )
        if observed != [expected_assignment]:
            findings.append(
                Finding(
                    "web-release-stack-global-contract-mismatch",
                    path,
                    1,
                    f"The release chain renders and applies {name}; it must be "
                    f"declared exactly once as {expected_assignment!r}; observed "
                    f"{observed!r}.",
                )
            )
    dependency_names = set(WEB_RELEASE_RECIPE_DEPENDENCIES)
    digest_names = set(WEB_RELEASE_CRITICAL_RECIPE_DIGESTS)
    # The promotion interlock is receipted in the same table but is deliberately
    # NOT part of the release dependency graph: that graph doubles as the
    # operator-local ROOT set, and the interlock hangs off the legacy
    # web-stack-apply carrier, which since TIN-3899 no workflow invokes at all.
    # scan_web_stack_promotion_interlock_text enforces its body receipt.
    dependency_names |= {WEB_STACK_PROMOTION_INTERLOCK}
    if dependency_names != digest_names:
        findings.append(
            Finding(
                "web-release-validator-receipt-set-mismatch",
                Path(SELF),
                1,
                "Web release dependency and executable-receipt recipe sets differ: "
                f"dependencies-only={sorted(dependency_names - digest_names)!r}, "
                f"digests-only={sorted(digest_names - dependency_names)!r}.",
            )
        )

    definitions = all_just_recipe_blocks(text)
    aliases = all_just_aliases(text)
    lines = text.splitlines()
    for name, expected_dependencies in WEB_RELEASE_RECIPE_DEPENDENCIES.items():
        recipes = definitions.get(name, [])
        alias_count = len(aliases.get(name, []))
        expected_header = f"{name}:" + (
            " " + " ".join(expected_dependencies) if expected_dependencies else ""
        )
        observed_headers = re.findall(
            rf"^{re.escape(name)}[^\n]*$", text, flags=re.MULTILINE
        )
        if observed_headers != [expected_header]:
            findings.append(
                Finding(
                    "web-release-recipe-header-mismatch",
                    path,
                    1,
                    f"{name} must have the exact zero-argument header "
                    f"{expected_header!r}; observed {observed_headers!r}.",
                )
            )
        if len(recipes) != 1 or alias_count:
            findings.append(
                Finding(
                    "web-release-operator-recipe-missing",
                    path,
                    1,
                    f"Required web release recipe {name!r} must have exactly one "
                    f"recipe definition and no alias; observed {len(recipes)} "
                    f"recipe(s) and {alias_count} alias(es).",
                )
            )
            continue
        line, dependencies, body = recipes[0]
        if line > 1 and lines[line - 2].lstrip().startswith("["):
            findings.append(
                Finding(
                    "web-release-recipe-attribute-mismatch",
                    path,
                    line - 1,
                    f"{name} must not carry a Just recipe attribute outside its "
                    "body receipt.",
                )
            )
        observed_dependencies = tuple(dependencies.split())
        if observed_dependencies != expected_dependencies:
            findings.append(
                Finding(
                    "web-release-recipe-dependencies-mismatch",
                    path,
                    line,
                    f"{name} dependencies must be exactly "
                    f"{expected_dependencies!r}; observed "
                    f"{observed_dependencies!r}.",
                )
            )

        executable = executable_recipe_text(body)
        observed_digest = hashlib.sha256(executable.encode("utf-8")).hexdigest()
        expected_digest = WEB_RELEASE_CRITICAL_RECIPE_DIGESTS.get(name)
        if expected_digest is not None and observed_digest != expected_digest:
            findings.append(
                Finding(
                    "web-release-recipe-executable-receipt-mismatch",
                    path,
                    line,
                    f"{name} executable SHA256 must be {expected_digest}; "
                    f"observed {observed_digest}.",
                )
            )

    callee = WEB_RELEASE_VALIDATION_CALLEE
    callee_recipes = definitions.get(callee, [])
    callee_alias_count = len(aliases.get(callee, []))
    expected_callee_header = f"{callee}:"
    observed_callee_headers = re.findall(
        rf"^{re.escape(callee)}[^\n]*$", text, flags=re.MULTILINE
    )
    if observed_callee_headers != [expected_callee_header]:
        findings.append(
            Finding(
                "web-release-validation-callee-header-mismatch",
                path,
                1,
                f"{callee} must have the exact zero-argument header "
                f"{expected_callee_header!r}; observed {observed_callee_headers!r}.",
            )
        )
    if len(callee_recipes) != 1 or callee_alias_count:
        findings.append(
            Finding(
                "web-release-validation-callee-missing",
                path,
                1,
                f"{callee} must have exactly one recipe definition and no alias; "
                f"observed {len(callee_recipes)} recipe(s) and "
                f"{callee_alias_count} alias(es).",
            )
        )
    else:
        line, dependencies, body = callee_recipes[0]
        if line > 1 and lines[line - 2].lstrip().startswith("["):
            findings.append(
                Finding(
                    "web-release-validation-callee-attribute-mismatch",
                    path,
                    line - 1,
                    f"{callee} must not carry a Just recipe attribute outside "
                    "its body receipt.",
                )
            )
        observed_dependencies = tuple(dependencies.split())
        if observed_dependencies != WEB_RELEASE_VALIDATION_CALLEE_DEPENDENCIES:
            findings.append(
                Finding(
                    "web-release-validation-callee-dependencies-mismatch",
                    path,
                    line,
                    f"{callee} dependencies must be exactly "
                    f"{WEB_RELEASE_VALIDATION_CALLEE_DEPENDENCIES!r}; observed "
                    f"{observed_dependencies!r}.",
                )
            )
        observed_digest = hashlib.sha256(
            executable_recipe_text(body).encode("utf-8")
        ).hexdigest()
        if observed_digest != WEB_RELEASE_VALIDATION_CALLEE_DIGEST:
            findings.append(
                Finding(
                    "web-release-validation-callee-receipt-mismatch",
                    path,
                    line,
                    f"{callee} executable SHA256 must be "
                    f"{WEB_RELEASE_VALIDATION_CALLEE_DIGEST}; observed "
                    f"{observed_digest}.",
                )
            )

    tainted, edges = web_release_operator_recipe_closure(text)
    # A recipe already protected by another exact operator receipt may contain
    # dynamic Just dispatch as part of that separately reviewed contract. New
    # or otherwise unreceipted dynamic dispatch still fails closed here.
    receipted = (
        set(WEB_RELEASE_RECIPE_DEPENDENCIES)
        | set(ARC_CRITICAL_RECIPE_DIGESTS)
        | set(ATTENDED_CRITICAL_RECIPE_DIGESTS)
    )
    for name in sorted((tainted & set(edges)) - receipted):
        targets = sorted(edges[name] & tainted)
        if name in definitions:
            line = definitions[name][0][0]
        else:
            line = aliases[name][0][0]
        findings.append(
            Finding(
                "web-release-unreceipted-operator-wrapper",
                path,
                line,
                f"{name} reaches or can dynamically resolve to operator-local "
                f"web release recipe(s) {targets!r} but has no exact "
                "dependency/body receipt.",
            )
        )
    return findings


def scan_imperative_pin_text(text: str, path: Path) -> list[Finding]:
    """Refuse imperative image/replica pinning anywhere in the Justfile."""
    findings: list[Finding] = []
    lines = text.splitlines()
    covered: dict[int, str] = {}
    for name, declarations in all_just_recipe_blocks(text).items():
        for line, _, body in declarations:
            for offset in range(line, line + len(body.splitlines()) + 1):
                covered[offset] = name

    for name, declarations in all_just_recipe_blocks(text).items():
        if name in IMPERATIVE_PIN_ALLOWED_RECIPES:
            continue
        for line, _, body in declarations:
            match = IMPERATIVE_PIN.search(
                IMPERATIVE_PIN_CONTINUATION.sub(" ", executable_recipe_text(body))
            )
            if match:
                findings.append(
                    Finding(
                        "imperative-pin",
                        path,
                        line,
                        f"{name} imperatively pins an image or replica count "
                        f"({match.group(0).strip()!r}). The reviewed release "
                        "chain renders the pin into the manifest bytes and "
                        "applies those bytes; only "
                        f"{sorted(IMPERATIVE_PIN_ALLOWED_RECIPES)!r} may still "
                        "patch the live workload imperatively.",
                    )
                )

    for name, declarations in all_just_recipe_blocks(text).items():
        if name in WEB_STACK_TREE_APPLY_ALLOWED_RECIPES:
            continue
        for line, _, body in declarations:
            match = WEB_STACK_TREE_APPLY.search(
                IMPERATIVE_PIN_CONTINUATION.sub(" ", executable_recipe_text(body))
            )
            if match:
                findings.append(
                    Finding(
                        "web-stack-tree-apply",
                        path,
                        line,
                        f"{name} applies the web stack tree directly "
                        f"({match.group(0).strip()!r}), bypassing "
                        f"{WEB_STACK_PROMOTION_INTERLOCK}; only "
                        f"{sorted(WEB_STACK_TREE_APPLY_ALLOWED_RECIPES)!r} may "
                        "apply the tree, and the reviewed release chain applies "
                        "rendered plan bytes instead.",
                    )
                )

    # Fold backslash continuations into one logical line, keeping the ORIGINAL
    # line number of the first physical line so findings stay navigable.
    top_level_logical: list[tuple[int, str]] = []
    open_continuation = 0
    for index, line_text in enumerate(lines, start=1):
        if index in covered or line_text.lstrip().startswith("#"):
            open_continuation = 0
            continue
        if open_continuation == index - 1 and top_level_logical:
            start, previous = top_level_logical[-1]
            top_level_logical[-1] = (start, previous[:-1] + " " + line_text.lstrip())
        else:
            top_level_logical.append((index, line_text))
        open_continuation = index if line_text.endswith("\\") else 0
    for index, line_text in top_level_logical:
        match = IMPERATIVE_PIN.search(line_text)
        if match:
            findings.append(
                Finding(
                    "imperative-pin",
                    path,
                    index,
                    "Justfile top level imperatively pins an image or replica "
                    f"count ({match.group(0).strip()!r}); the release chain "
                    "pins declaratively.",
                )
            )
        tree_match = WEB_STACK_TREE_APPLY.search(line_text)
        if tree_match:
            findings.append(
                Finding(
                    "web-stack-tree-apply",
                    path,
                    index,
                    "Justfile top level applies the web stack tree directly "
                    f"({tree_match.group(0).strip()!r}), bypassing "
                    f"{WEB_STACK_PROMOTION_INTERLOCK}.",
                )
            )

    for name in sorted(IMPERATIVE_PIN_ALLOWED_RECIPES | WEB_STACK_TREE_APPLY_ALLOWED_RECIPES):
        if len(all_just_recipe_blocks(text).get(name, [])) != 1:
            findings.append(
                Finding(
                    "imperative-pin-allowlist-stale",
                    path,
                    1,
                    f"{name} is allowlisted for imperative pinning but is not "
                    "defined exactly once; the allowlist must never outlive the "
                    "recipe it was written for.",
                )
            )
    return findings


def scan_web_stack_promotion_interlock_text(
    text: str, path: Path
) -> list[Finding]:
    """The legacy adapter-node carrier must refuse to revert the promotion."""
    findings: list[Finding] = []
    blocks = all_just_recipe_blocks(text)
    declarations = blocks.get(WEB_STACK_PROMOTION_INTERLOCK, [])
    if len(declarations) != 1:
        findings.append(
            Finding(
                "web-stack-promotion-interlock-missing",
                path,
                1,
                f"{WEB_STACK_PROMOTION_INTERLOCK} must be defined exactly once. "
                "It is the only mechanical stop between the unattended legacy "
                "CD carrier and a silent revert of the gftb-site promotion.",
            )
        )
    else:
        line, _, body = declarations[0]
        executable = executable_recipe_text(body)
        expected_digest = WEB_RELEASE_CRITICAL_RECIPE_DIGESTS.get(
            WEB_STACK_PROMOTION_INTERLOCK
        )
        observed_digest = hashlib.sha256(executable.encode("utf-8")).hexdigest()
        if expected_digest is None:
            findings.append(
                Finding(
                    "web-stack-promotion-interlock-receipt-missing",
                    Path(SELF),
                    1,
                    f"{WEB_STACK_PROMOTION_INTERLOCK} must carry an executable "
                    "receipt in WEB_RELEASE_CRITICAL_RECIPE_DIGESTS like the "
                    "rest of the reviewed chain.",
                )
            )
        elif observed_digest != expected_digest:
            findings.append(
                Finding(
                    "web-stack-promotion-interlock-receipt-mismatch",
                    path,
                    line,
                    f"{WEB_STACK_PROMOTION_INTERLOCK} executable SHA256 must be "
                    f"{expected_digest}; observed {observed_digest}.",
                )
            )
        for required in WEB_STACK_PROMOTION_INTERLOCK_REQUIRED_TEXT:
            if required not in executable:
                findings.append(
                    Finding(
                        "web-stack-promotion-interlock-weakened",
                        path,
                        line,
                        f"{WEB_STACK_PROMOTION_INTERLOCK} no longer reads the "
                        f"live Deployment image and refuses on it ({required!r} "
                        "is gone); the legacy carrier could revert the "
                        "promotion unattended.",
                    )
                )

    dependencies = parse_just_recipe_dependencies(text)
    for dependent in WEB_STACK_PROMOTION_INTERLOCK_DEPENDENTS:
        declared = dependencies.get(dependent)
        if declared is None:
            findings.append(
                Finding(
                    "web-stack-promotion-interlock-detached",
                    path,
                    1,
                    f"{dependent} is not declared; the promotion interlock "
                    "contract names a recipe that no longer exists.",
                )
            )
        elif not declared or declared[0] != WEB_STACK_PROMOTION_INTERLOCK:
            findings.append(
                Finding(
                    "web-stack-promotion-interlock-detached",
                    path,
                    1,
                    f"{dependent} must take {WEB_STACK_PROMOTION_INTERLOCK} as "
                    f"its FIRST dependency; it declares {list(declared)!r}. The "
                    "interlock has to precede every mutation of this workload.",
                )
            )
    return findings


def parse_just_recipe_dependencies(text: str) -> dict[str, tuple[str, ...]]:
    """Map every recipe name to its declared dependency list, in order."""
    dependencies: dict[str, tuple[str, ...]] = {}
    for name, declarations in all_just_recipe_blocks(text).items():
        for _, declared, _ in declarations:
            dependencies[name] = tuple(declared.split())
    return dependencies


def scan_web_release_validation_script_bytes(
    content: bytes,
    path: Path = WEB_RELEASE_VALIDATION_SCRIPT,
) -> list[Finding]:
    observed_digest = hashlib.sha256(content).hexdigest()
    if observed_digest == WEB_RELEASE_VALIDATION_SCRIPT_SHA256:
        return []
    return [
        Finding(
            "web-release-validation-script-receipt-mismatch",
            path,
            1,
            f"{path} SHA256 must be {WEB_RELEASE_VALIDATION_SCRIPT_SHA256}; "
            f"observed {observed_digest}.",
        )
    ]


def scan_web_release_toolchain_text(
    flake_text: str,
    flake_lock: bytes,
    flake_path: Path = Path("flake.nix"),
    lock_path: Path = Path("flake.lock"),
) -> list[Finding]:
    """Pin the two release-proof tools without accepting lockfile churn."""
    findings: list[Finding] = []
    package_blocks = re.findall(
        r"(?ms)^\s*packages\s*=\s*\[(.*?)^\s*\];", flake_text
    )
    if len(package_blocks) != 1:
        findings.append(
            Finding(
                "web-release-flake-package-block-mismatch",
                flake_path,
                1,
                "flake.nix must contain exactly one structurally reviewable "
                f"devShell packages list; observed {len(package_blocks)}.",
            )
        )
    for package in FLAKE_RELEASE_PACKAGES:
        token = f"pkgs.{package}"
        global_count = len(re.findall(rf"\b{re.escape(token)}\b", flake_text))
        block_count = (
            len(re.findall(rf"(?m)^\s*{re.escape(token)}\s*$", package_blocks[0]))
            if len(package_blocks) == 1
            else 0
        )
        if global_count != 1 or block_count != 1:
            findings.append(
                Finding(
                    "web-release-flake-package-mismatch",
                    flake_path,
                    1,
                    f"{token} must occur exactly once as a standalone package-list "
                    f"entry; observed global={global_count}, package-list={block_count}.",
                )
            )

    observed_lock_digest = hashlib.sha256(flake_lock).hexdigest()
    if observed_lock_digest != FLAKE_LOCK_SHA256:
        findings.append(
            Finding(
                "web-release-flake-lock-drift",
                lock_path,
                1,
                "Release-proof tool additions must not change flake.lock; "
                f"expected SHA256 {FLAKE_LOCK_SHA256}, observed "
                f"{observed_lock_digest}.",
            )
        )
    return findings


def is_negative_or_descriptive(line: str) -> bool:
    return bool(NEGATIVE_OR_DESCRIPTIVE_CONTEXT.search(line))


def scan_docs() -> list[Finding]:
    findings: list[Finding] = []
    for rel, lineno, line in iter_lines(git_files(PUBLIC_DOC_GLOBS)):
        if RETIRED_EDGE_RECIPE.search(line):
            findings.append(
                Finding(
                    "retired-edge-recipe",
                    rel,
                    lineno,
                    "Use just edge-zones-*; public docs must not advertise retired edge-* recipes.",
                )
            )
        if RAW_K8S_MUTATION.search(line) and not is_negative_or_descriptive(line):
            findings.append(
                Finding(
                    "copy-paste-k8s-mutation",
                    rel,
                    lineno,
                    "Use a Justfile recipe; public docs must not expose raw kubectl/kustomize mutation snippets.",
                )
            )
    return findings


def scan_workflow_text(
    text: str,
    path: Path,
    forbidden_recipes: set[str],
    known_recipes: set[str] | None = None,
    recipe_arities: dict[str, int] | None = None,
) -> list[Finding]:
    findings: list[Finding] = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        if RETIRED_ARC_KUBECONFIG_SECRET.search(line):
            findings.append(
                Finding(
                    "workflow-retired-arc-kubeconfig-secret",
                    path,
                    lineno,
                    "Hosted workflows must not carry retired ARC kubeconfig secrets; "
                    "ARC is operator-local.",
                )
            )
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if WORKFLOW_REPOSITORY_DISPATCH.match(line):
            findings.append(
                Finding(
                    "workflow-repository-dispatch-retired",
                    path,
                    lineno,
                    "TIN-3899 retired the repository_dispatch CD plane: no "
                    "workflow in this repository may consume a cross-repo "
                    "dispatch, because that is the trigger that let a push to "
                    "the public site repo mutate the live web Deployment "
                    "unattended.",
                )
            )
        if RAW_TOFU_WORKFLOW.search(line) and " just " not in f" {line} ":
            findings.append(
                Finding(
                    "workflow-raw-tofu",
                    path,
                    lineno,
                    "GitHub workflows must call Justfile recipes instead of raw tofu.",
                )
            )
        if RAW_K8S_MUTATION.search(line) and " just " not in f" {line} ":
            findings.append(
                Finding(
                    "workflow-raw-k8s-mutation",
                    path,
                    lineno,
                    "GitHub workflows must call Justfile recipes instead of raw kubectl/kustomize mutation commands.",
                )
            )

    calls, unresolved, multiple = parse_just_calls(
        text,
        known_recipes or forbidden_recipes,
        recipe_arities,
        ignore_help_echo=True,
    )
    arc_calls = sorted(calls & forbidden_recipes)
    if arc_calls:
        findings.append(
            Finding(
                "workflow-arc-operator-recipe",
                path,
                1,
                "Hosted workflows must not invoke ARC plan/init/apply, enrollment, "
                "readback, GitHub App Secret, consented list membership, ALTCHA "
                "Secret rotation, operator-held release proofs, or transitive "
                "operator recipes; "
                f"observed {arc_calls!r}.",
            )
        )
    unapproved_calls = sorted(calls - HOSTED_WORKFLOW_JUST_ALLOWLIST)
    if unapproved_calls:
        findings.append(
            Finding(
                "workflow-unapproved-just-recipe",
                path,
                1,
                "Hosted workflow Just recipes are a finite reviewed allowlist; "
                f"observed unapproved {unapproved_calls!r}.",
            )
        )
    if unresolved:
        findings.append(
            Finding(
                "workflow-unresolved-just-invocation",
                path,
                1,
                "Hosted workflows must use literal, statically resolvable Just recipe argv.",
            )
        )
    if multiple:
        findings.append(
            Finding(
                "workflow-multiple-just-recipes",
                path,
                1,
                "Hosted workflows must invoke one literal Just recipe per command.",
            )
        )
    return findings


def scan_web_generation40_bridge_contract(
    workflow_text: str, deployment_text: str
) -> list[Finding]:
    findings: list[Finding] = []
    observed_digest = hashlib.sha256(workflow_text.encode("utf-8")).hexdigest()
    if observed_digest != WEB_GENERATION40_BRIDGE_SHA256:
        findings.append(
            Finding(
                "web-generation40-bridge-bytes",
                WEB_GENERATION40_BRIDGE_WORKFLOW,
                1,
                "The temporary parity bridge changed outside its exact reviewed receipt; replace it only through the receiver-first GF-I09 cutover.",
            )
        )
    image_values = re.findall(
        r"^\s*image:\s*(ghcr\.io/great-falls-tool-bus/gftb-site@sha256:[0-9a-f]{64})\s*$",
        deployment_text,
        re.MULTILINE,
    )
    if image_values != [WEB_GENERATION40_TARGET_IMAGE]:
        findings.append(
            Finding(
                "web-generation40-desired-state-freeze",
                WEB_GENERATION40_DEPLOYMENT,
                1,
                "Until GF-I09 replaces the bridge, the web desired state must remain the exact generation-40 target; unrelated infra changes may proceed.",
            )
        )
    return findings


def scan_workflows() -> list[Finding]:
    findings: list[Finding] = []
    observed_calls: set[str] = set()
    justfile = (REPO / "Justfile").read_text(encoding="utf-8")
    forbidden_recipes, _ = all_operator_local_recipe_closure(justfile)
    known_recipes = set(all_just_recipe_blocks(justfile)) | set(
        all_just_aliases(justfile)
    )
    recipe_arities = just_recipe_arities(justfile)
    retired = REPO / RETIRED_ARC_WORKFLOW
    if retired.exists() or retired.is_symlink():
        findings.append(
            Finding(
                "retired-arc-workflow-retained",
                RETIRED_ARC_WORKFLOW,
                1,
                "Delete deploy-arc-runners.yml; sensitive ARC operations are operator-local.",
            )
        )
    retired_web_cd = REPO / RETIRED_WEB_CD_WORKFLOW
    if retired_web_cd.exists() or retired_web_cd.is_symlink():
        findings.append(
            Finding(
                "retired-web-cd-workflow-retained",
                RETIRED_WEB_CD_WORKFLOW,
                1,
                "Delete web-stack.yml; the legacy adapter-node CD carrier is "
                "retired (TIN-3899). Applying k8s/web is attended-operator-only "
                "and the reviewed forward path is the web-release-* chain.",
            )
        )

    bridge_path = REPO / WEB_GENERATION40_BRIDGE_WORKFLOW
    deployment_path = REPO / WEB_GENERATION40_DEPLOYMENT
    if not bridge_path.is_file() or not deployment_path.is_file():
        findings.append(
            Finding(
                "web-generation40-bridge-missing",
                WEB_GENERATION40_BRIDGE_WORKFLOW,
                1,
                "The temporary parity bridge and its frozen desired-state carrier must remain together until the receiver-first GF-I09 cutover.",
            )
        )
    else:
        findings.extend(
            scan_web_generation40_bridge_contract(
                bridge_path.read_text(encoding="utf-8"),
                deployment_path.read_text(encoding="utf-8"),
            )
        )

    workflow_paths = set(git_files(WORKFLOW_GLOBS))
    for pattern in WORKFLOW_GLOBS:
        workflow_paths.update(path.relative_to(REPO) for path in REPO.glob(pattern))
    for rel in sorted(workflow_paths):
        path = REPO / rel
        if not path.is_file():
            continue
        workflow_text = path.read_text(encoding="utf-8", errors="replace")
        calls, _, _ = parse_just_calls(
            workflow_text, known_recipes, recipe_arities
        )
        observed_calls.update(calls)
        scoped_forbidden = forbidden_recipes
        if rel == WEB_GENERATION40_BRIDGE_WORKFLOW:
            scoped_forbidden = forbidden_recipes - set(WEB_GENERATION40_BRIDGE_RECIPES)
        elif rel == WEB_GENERATION40_TRANSIENT_VALIDATE:
            observed_validate_digest = hashlib.sha256(workflow_text.encode("utf-8")).hexdigest()
            if observed_validate_digest != WEB_GENERATION40_TRANSIENT_VALIDATE_SHA256:
                findings.append(Finding("web-generation40-transient-validate-bytes", rel, 1, "Transient offline render proof changed outside its reviewed receipt."))
            scoped_forbidden = forbidden_recipes - {"web-release-plan"}
        findings.extend(
            scan_workflow_text(
                workflow_text,
                rel,
                scoped_forbidden,
                known_recipes,
                recipe_arities,
            )
        )
    if observed_calls != HOSTED_WORKFLOW_JUST_ALLOWLIST:
        findings.append(
            Finding(
                "workflow-just-allowlist-drift",
                Path(".github/workflows"),
                1,
                "Hosted Just call census changed: "
                f"missing={sorted(HOSTED_WORKFLOW_JUST_ALLOWLIST - observed_calls)!r}, "
                f"new={sorted(observed_calls - HOSTED_WORKFLOW_JUST_ALLOWLIST)!r}.",
            )
        )
    return findings


def workflow_step(path: Path, name: str) -> tuple[int, list[str]]:
    lines = (REPO / path).read_text(encoding="utf-8").splitlines()
    marker = f"      - name: {name}"
    try:
        start = lines.index(marker)
    except ValueError:
        return 1, []
    end = next(
        (
            index
            for index in range(start + 1, len(lines))
            if lines[index].startswith("      - name: ")
        ),
        len(lines),
    )
    return start + 1, lines[start:end]


def scan_edge_workflow_contract() -> list[Finding]:
    """Keep drift, plan, and apply on one secret-safe edge input contract."""
    findings: list[Finding] = []
    steps = [
        (Path(".github/workflows/edge-plan.yml"), "Plan edge zones"),
        (Path(".github/workflows/edge-plan.yml"), "Apply edge zones"),
        (
            Path(".github/workflows/edge-drift.yml"),
            "Plan edge zones (text-only, no persisted binary)",
        ),
    ]
    step_vars: list[tuple[Path, str, int, dict[str, str]]] = []
    for path, name in steps:
        line, block = workflow_step(path, name)
        if not block:
            findings.append(
                Finding(
                    "edge-workflow-step-missing",
                    path,
                    line,
                    f"Required edge workflow step {name!r} was not found.",
                )
            )
            continue
        variables = {
            match.group(1): match.group(2)
            for text in block
            if (match := WORKFLOW_ENV_ENTRY.match(text))
        }
        step_vars.append((path, name, line, variables))
        missing = EDGE_RUNTIME_TF_VARS - variables.keys()
        if missing:
            findings.append(
                Finding(
                    "edge-workflow-input-missing",
                    path,
                    line,
                    f"{name} is missing runtime input(s): {', '.join(sorted(missing))}.",
                )
            )

    if step_vars:
        baseline = step_vars[0][3]
        for path, name, line, variables in step_vars[1:]:
            if variables != baseline:
                findings.append(
                    Finding(
                        "edge-workflow-input-drift",
                        path,
                        line,
                        f"{name} TF_VAR_* inputs differ from the plan step.",
                    )
                )

    required_fragments = {
        "ENABLE_GOOGLE_SSO: ${{ vars.ENABLE_GOOGLE_SSO || 'false' }}": "expose ENABLE_GOOGLE_SSO to the presence-only preflight",
        "HAS_GOOGLE_SSO_CLIENT_ID: ${{ secrets.GOOGLE_SSO_CLIENT_ID != '' }}": "check GOOGLE_SSO_CLIENT_ID presence without reading its value",
        "HAS_GOOGLE_SSO_CLIENT_SECRET: ${{ secrets.GOOGLE_SSO_CLIENT_SECRET != '' }}": "check GOOGLE_SSO_CLIENT_SECRET presence without reading its value",
        'if [ "${ENABLE_GOOGLE_SSO}" = "true" ]; then': "fail closed when live Google SSO credentials are incomplete",
        'echo "::error::GOOGLE_SSO_CLIENT_ID is required when ENABLE_GOOGLE_SSO=true."\n'
        "              missing_edge=1\n"
        "              missing=1": "hard-fail when the enabled Google client id is absent",
        'echo "::error::GOOGLE_SSO_CLIENT_SECRET is required when ENABLE_GOOGLE_SSO=true."\n'
        "              missing_edge=1\n"
        "              missing=1": "hard-fail when the enabled Google client secret is absent",
        "TF_VAR_google_sso_apps_domain: ${{ vars.TF_VAR_GOOGLE_SSO_APPS_DOMAIN || 'sulliwood.org' }}": "map the documented Google Workspace domain override",
    }
    for path in {path for path, _ in steps}:
        text = (REPO / path).read_text(encoding="utf-8")
        for fragment, purpose in required_fragments.items():
            if fragment not in text:
                findings.append(
                    Finding(
                        "edge-google-sso-preflight-missing",
                        path,
                        1,
                        f"Workflow must {purpose}.",
                    )
                )
    return findings


def scan_operator_carrier_text(
    text: str,
    path: Path,
    forbidden_recipes: set[str],
    known_recipes: set[str],
    recipe_arities: dict[str, int] | None = None,
    *,
    fail_on_unresolved: bool,
) -> list[Finding]:
    findings: list[Finding] = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        if RETIRED_ARC_KUBECONFIG_SECRET.search(line):
            findings.append(
                Finding(
                    "carrier-retired-arc-kubeconfig-secret",
                    path,
                    lineno,
                    "Scripts and composite actions must not carry retired ARC kubeconfig inputs.",
                )
            )
    calls, unresolved, _ = parse_just_calls(text, known_recipes, recipe_arities)
    arc_calls = sorted(calls & forbidden_recipes)
    if arc_calls:
        findings.append(
            Finding(
                "carrier-arc-operator-recipe",
                path,
                1,
                "Scripts and composite actions must not invoke operator-local ARC "
                "or purpose-bound attended/release recipes or wrappers; "
                f"observed {arc_calls!r}.",
            )
        )
    if unresolved and fail_on_unresolved:
        findings.append(
            Finding(
                "carrier-unresolved-just-invocation",
                path,
                1,
                "Shell scripts and composite actions must use statically resolvable Just argv.",
            )
        )
    return findings


def scan_scripts() -> list[Finding]:
    findings: list[Finding] = []
    justfile = (REPO / "Justfile").read_text(encoding="utf-8")
    forbidden_recipes, _ = all_operator_local_recipe_closure(justfile)
    known_recipes = set(all_just_recipe_blocks(justfile)) | set(
        all_just_aliases(justfile)
    )
    recipe_arities = just_recipe_arities(justfile)
    paths = set(git_files(SCRIPT_GLOBS))
    paths.update(path.relative_to(REPO) for path in (REPO / "scripts").glob("**/*"))
    for rel in sorted(paths):
        if rel == SELF:
            continue
        path = REPO / rel
        if (
            not path.is_file()
            or "__pycache__" in rel.parts
            or path.suffix in {".pyc", ".pyo", ".pyd"}
        ):
            continue
        raw = path.read_bytes()
        if b"\x00" in raw:
            continue
        text = raw.decode("utf-8", errors="replace")
        for lineno, line in enumerate(text.splitlines(), start=1):
            if RAW_K8S_MUTATION.search(line):
                findings.append(
                    Finding(
                        "script-raw-k8s-mutation",
                        rel,
                        lineno,
                        "Helper scripts may validate/render, but live Kubernetes mutation belongs in the Justfile recipe surface.",
                    )
                )
        shell_script = path.suffix in {".sh", ".bash"} or text.startswith(
            ("#!/bin/sh", "#!/bin/bash", "#!/usr/bin/env bash", "#!/usr/bin/env sh")
        )
        findings.extend(
            scan_operator_carrier_text(
                text,
                rel,
                forbidden_recipes,
                known_recipes,
                recipe_arities,
                fail_on_unresolved=shell_script,
            )
        )
    return findings


def scan_composite_actions() -> list[Finding]:
    findings: list[Finding] = []
    justfile = (REPO / "Justfile").read_text(encoding="utf-8")
    forbidden_recipes, _ = all_operator_local_recipe_closure(justfile)
    known_recipes = set(all_just_recipe_blocks(justfile)) | set(
        all_just_aliases(justfile)
    )
    recipe_arities = just_recipe_arities(justfile)
    paths = set(git_files(COMPOSITE_ACTION_GLOBS))
    for pattern in COMPOSITE_ACTION_GLOBS:
        paths.update(path.relative_to(REPO) for path in REPO.glob(pattern))
    for rel in sorted(paths):
        path = REPO / rel
        if not path.is_file():
            continue
        findings.extend(
            scan_operator_carrier_text(
                path.read_text(encoding="utf-8", errors="replace"),
                rel,
                forbidden_recipes,
                known_recipes,
                recipe_arities,
                fail_on_unresolved=True,
            )
        )
    return findings


def extract_arc_scope_checker(justfile: str) -> str:
    """Extract the exact Python program embedded in arc-plan-scope-check."""
    recipe = just_recipe_block(justfile, "arc-plan-scope-check")
    if recipe is None:
        raise SystemExit("self-test FAILED: arc-plan-scope-check is missing")
    body_lines = recipe[2].splitlines()
    marker = 'python3 -I - "${plan_json}" <<\'PY\''
    try:
        start = next(
            index for index, line in enumerate(body_lines) if line.strip() == marker
        )
    except StopIteration as error:
        raise SystemExit(
            "self-test FAILED: exact ARC scope-checker heredoc was not found"
        ) from error
    try:
        end = next(
            index
            for index in range(start + 1, len(body_lines))
            if body_lines[index].strip() == "PY"
        )
    except StopIteration as error:
        raise SystemExit(
            "self-test FAILED: ARC scope-checker heredoc is unterminated"
        ) from error
    return textwrap.dedent("\n".join(body_lines[start + 1 : end])) + "\n"


# ARC scope fixtures. Every literal below was lifted verbatim from real
# OpenTofu 1.11.6 `tofu plan` + `tofu show -json` runs made against a
# `git archive` of the pinned GloriousFlywheel ARC roles (df510574 for the
# pre-cutover rendering, 11ace397 for the advanced pin) driven by this
# repository's tofu/stacks/arc-runners/great-falls-tool-bus.tfvars, a local
# backend, -refresh=false, and a throwaway 127.0.0.1:1 kubeconfig. No
# cluster, remote state, or credential was contacted. Only the Helm
# attributes the guard reads are retained; `fixture_output` is the one
# synthetic addition, a no-op scaffolding output the negative cases mutate
# without disturbing the reviewed runner-group output table.

ARC_BEFORE_VALUES = """\
"listenerTemplate":
  "spec":
    "containers":
    - "name": "listener"
    "nodeSelector":
      "kubernetes.io/hostname": "bumble"
    "tolerations":
    - "effect": "NoSchedule"
      "key": "dedicated.tinyland.dev/compute-expansion"
      "operator": "Equal"
      "value": "true"
"template":
  "spec":
    "containers":
    - "command":
      - "/home/runner/run.sh"
      "env":
      - "name": "NIX_CONFIG"
        "value": |-
          experimental-features = nix-command flakes
          extra-substituters = http://attic.nix-cache.svc.cluster.local/main
          extra-trusted-public-keys = main:eaUydxuDu7xBoy5cCo3MdknYAkVyTIASQ7DGuwxa+XA=
      - "name": "ATTIC_SERVER"
        "value": "http://attic.nix-cache.svc.cluster.local"
      - "name": "ATTIC_CACHE"
        "value": "main"
      - "name": "ATTIC_PUBLIC_KEY"
        "value": "main:eaUydxuDu7xBoy5cCo3MdknYAkVyTIASQ7DGuwxa+XA="
      - "name": "BAZEL_REMOTE_CACHE"
        "value": "grpc://bazel-cache.nix-cache.svc.cluster.local:9092"
      - "name": "GF_BAZEL_SUBSTRATE_MODE"
        "value": "shared-cache-backed"
      - "name": "RUNNER_ALLOW_RUNASROOT"
        "value": "1"
      - "name": "GF_REAPI_TOKEN_EXCHANGE_ENDPOINT"
        "value": "http://gf-reapi-token-exchange.gf-rbe.svc.cluster.local:8081/v1/token/exchange"
      - "name": "GF_REAPI_CACHE_FRONTDOOR_ENDPOINT"
        "value": "grpc://gf-reapi-cell.gf-rbe.svc.cluster.local:8980"
      "image": "ghcr.io/tinyland-inc/actions-runner-nix@sha256:086a6c5553f21a5ef59256ebe8fbf2d7b6bbf486def1d0f5ed1c05dcbdab084e"
      "name": "runner"
      "resources":
        "limits":
          "cpu": "4"
          "ephemeral-storage": "8Gi"
          "memory": "8Gi"
        "requests":
          "cpu": "500m"
          "ephemeral-storage": "4Gi"
          "memory": "1Gi"
      "securityContext":
        "allowPrivilegeEscalation": false
        "runAsGroup": 0
        "runAsUser": 0
    "imagePullSecrets":
    - "name": "ghcr-pull"
    "nodeSelector":
      "kubernetes.io/hostname": "sting"
    "tolerations":
    - "effect": "NoSchedule"
      "key": "dedicated.tinyland.dev/compute-expansion"
      "operator": "Equal"
      "value": "true"
"""

ARC_AFTER_VALUES = """\
"listenerTemplate":
  "spec":
    "containers":
    - "name": "listener"
    "nodeSelector":
      "kubernetes.io/hostname": "bumble"
    "tolerations":
    - "effect": "NoSchedule"
      "key": "dedicated.tinyland.dev/compute-expansion"
      "operator": "Equal"
      "value": "true"
"template":
  "spec":
    "containers":
    - "command":
      - "/home/runner/run.sh"
      "env":
      - "name": "NIX_CONFIG"
        "value": |-
          experimental-features = nix-command flakes
          extra-substituters = http://attic.nix-cache.svc.cluster.local/main
          extra-trusted-public-keys = main:eaUydxuDu7xBoy5cCo3MdknYAkVyTIASQ7DGuwxa+XA=
      - "name": "ATTIC_SERVER"
        "value": "http://attic.nix-cache.svc.cluster.local"
      - "name": "ATTIC_CACHE"
        "value": "main"
      - "name": "ATTIC_PUBLIC_KEY"
        "value": "main:eaUydxuDu7xBoy5cCo3MdknYAkVyTIASQ7DGuwxa+XA="
      - "name": "BAZEL_REMOTE_CACHE"
        "value": "grpc://bazel-cache.nix-cache.svc.cluster.local:9092"
      - "name": "GF_BAZEL_SUBSTRATE_MODE"
        "value": "shared-cache-backed"
      - "name": "RUNNER_ALLOW_RUNASROOT"
        "value": "1"
      - "name": "GF_REAPI_TOKEN_EXCHANGE_ENDPOINT"
        "value": "http://gf-reapi-token-exchange.gf-rbe.svc.cluster.local:8081/v1/token/exchange"
      - "name": "GF_REAPI_CACHE_FRONTDOOR_ENDPOINT"
        "value": "grpc://gf-reapi-cell.gf-rbe.svc.cluster.local:8980"
      "image": "ghcr.io/tinyland-inc/actions-runner-nix@sha256:086a6c5553f21a5ef59256ebe8fbf2d7b6bbf486def1d0f5ed1c05dcbdab084e"
      "name": "runner"
      "resources":
        "limits":
          "cpu": "4"
          "ephemeral-storage": "16Gi"
          "memory": "8Gi"
        "requests":
          "cpu": "500m"
          "ephemeral-storage": "8Gi"
          "memory": "1Gi"
      "securityContext":
        "allowPrivilegeEscalation": false
        "runAsGroup": 0
        "runAsUser": 0
    "imagePullSecrets":
    - "name": "ghcr-pull"
    "nodeSelector":
      "kubernetes.io/hostname": "sting"
    "tolerations":
    - "effect": "NoSchedule"
      "key": "dedicated.tinyland.dev/compute-expansion"
      "operator": "Equal"
      "value": "true"
"""

ARC_CUTOVER_VALUES = """\
"listenerTemplate":
  "spec":
    "containers":
    - "name": "listener"
    "nodeSelector":
      "kubernetes.io/hostname": "bumble"
    "tolerations":
    - "effect": "NoSchedule"
      "key": "dedicated.tinyland.dev/compute-expansion"
      "operator": "Equal"
      "value": "true"
"template":
  "spec":
    "containers":
    - "command":
      - "/home/runner/run.sh"
      "env":
      - "name": "NIX_CONFIG"
        "value": |-
          experimental-features = nix-command flakes
          extra-substituters = http://attic.nix-cache.svc.cluster.local/main
          extra-trusted-public-keys = main:eaUydxuDu7xBoy5cCo3MdknYAkVyTIASQ7DGuwxa+XA=
      - "name": "ATTIC_SERVER"
        "value": "http://attic.nix-cache.svc.cluster.local"
      - "name": "ATTIC_CACHE"
        "value": "main"
      - "name": "ATTIC_PUBLIC_KEY"
        "value": "main:eaUydxuDu7xBoy5cCo3MdknYAkVyTIASQ7DGuwxa+XA="
      - "name": "BAZEL_REMOTE_CACHE"
        "value": "grpc://bazel-cache.nix-cache.svc.cluster.local:9092"
      - "name": "GF_BAZEL_SUBSTRATE_MODE"
        "value": "shared-cache-backed"
      - "name": "GF_FLYWHEEL_PROFILE_STATE"
        "value": "shared-cache-backed"
      - "name": "RUNNER_ALLOW_RUNASROOT"
        "value": "1"
      - "name": "GF_REAPI_TOKEN_EXCHANGE_ENDPOINT"
        "value": "http://gf-reapi-token-exchange.gf-rbe.svc.cluster.local:8081/v1/token/exchange"
      - "name": "GF_REAPI_CACHE_FRONTDOOR_ENDPOINT"
        "value": "grpc://gf-reapi-cell.gf-rbe.svc.cluster.local:8980"
      "image": "ghcr.io/tinyland-inc/actions-runner-nix@sha256:1ccce66d92dadecb648ea5c509a4806bf319b73e9730828e234c19670325397b"
      "name": "runner"
      "resources":
        "limits":
          "cpu": "4"
          "ephemeral-storage": "16Gi"
          "memory": "8Gi"
        "requests":
          "cpu": "500m"
          "ephemeral-storage": "8Gi"
          "memory": "1Gi"
      "securityContext":
        "allowPrivilegeEscalation": false
        "runAsGroup": 0
        "runAsUser": 0
    "imagePullSecrets":
    - "name": "ghcr-pull"
    "nodeSelector":
      "kubernetes.io/hostname": "sting"
    "priorityClassName": "arc-runner"
    "tolerations":
    - "effect": "NoSchedule"
      "key": "dedicated.tinyland.dev/compute-expansion"
      "operator": "Equal"
      "value": "true"
"""

ARC_HELM_SET_DEFAULT = [{'name': 'controllerServiceAccount.name',
  'type': '',
  'value': 'arc-controller-gha-rs-controller'},
 {'name': 'controllerServiceAccount.namespace', 'type': '', 'value': 'arc-systems'},
 {'name': 'githubConfigSecret',
  'type': '',
  'value': 'github-app-secret-great-falls-tool-bus'},
 {'name': 'githubConfigUrl',
  'type': '',
  'value': 'https://github.com/Great-Falls-Tool-Bus'},
 {'name': 'maxRunners', 'type': '', 'value': '4'},
 {'name': 'minRunners', 'type': '', 'value': '0'},
 {'name': 'runnerGroup', 'type': '', 'value': 'default'},
 {'name': 'runnerScaleSetName', 'type': '', 'value': 'great-falls-tool-bus-nix'},
 {'name': 'scaleSetLabels[0]', 'type': '', 'value': 'tinyland-nix'},
 {'name': 'scaleSetLabels[1]', 'type': '', 'value': 'self-hosted'},
 {'name': 'scaleSetLabels[2]', 'type': '', 'value': 'nix'},
 {'name': 'scaleSetLabels[3]', 'type': '', 'value': 'linux'}]

ARC_HELM_SET_DEDICATED = [{'name': 'controllerServiceAccount.name',
  'type': '',
  'value': 'arc-controller-gha-rs-controller'},
 {'name': 'controllerServiceAccount.namespace', 'type': '', 'value': 'arc-systems'},
 {'name': 'githubConfigSecret',
  'type': '',
  'value': 'github-app-secret-great-falls-tool-bus'},
 {'name': 'githubConfigUrl',
  'type': '',
  'value': 'https://github.com/Great-Falls-Tool-Bus'},
 {'name': 'maxRunners', 'type': '', 'value': '4'},
 {'name': 'minRunners', 'type': '', 'value': '0'},
 {'name': 'runnerGroup', 'type': '', 'value': 'great-falls-tool-bus-infra'},
 {'name': 'runnerScaleSetName', 'type': '', 'value': 'great-falls-tool-bus-nix'},
 {'name': 'scaleSetLabels[0]', 'type': '', 'value': 'tinyland-nix'},
 {'name': 'scaleSetLabels[1]', 'type': '', 'value': 'self-hosted'},
 {'name': 'scaleSetLabels[2]', 'type': '', 'value': 'nix'},
 {'name': 'scaleSetLabels[3]', 'type': '', 'value': 'linux'}]

ARC_HELM_AFTER_UNKNOWN = {'metadata': True,
 'postrender': [],
 'set': [{}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}],
 'set_list': [],
 'set_sensitive': [],
 'values': [False]}

ARC_HELM_BEFORE_SENSITIVE = {'metadata': [{}],
 'postrender': [],
 'repository_password': True,
 'set': [{}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}],
 'set_list': [],
 'set_sensitive': [],
 'values': [False]}

ARC_HELM_AFTER_SENSITIVE = {'metadata': [],
 'postrender': [],
 'repository_password': True,
 'set': [{}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}],
 'set_list': [],
 'set_sensitive': [],
 'values': [False]}

ARC_CAPACITY_HELM_CHANGE = {
    "address": "module.gh_nix.helm_release.arc_runner",
    "module_address": "module.gh_nix",
    "mode": "managed",
    "type": "helm_release",
    "name": "arc_runner",
    "provider_name": "registry.opentofu.org/hashicorp/helm",
    "change": {
        "actions": ["update"],
        "before": {"set": copy.deepcopy(ARC_HELM_SET_DEFAULT), "values": [ARC_BEFORE_VALUES]},
        "after": {"set": copy.deepcopy(ARC_HELM_SET_DEFAULT), "values": [ARC_AFTER_VALUES]},
        "after_unknown": ARC_HELM_AFTER_UNKNOWN,
        "before_sensitive": ARC_HELM_BEFORE_SENSITIVE,
        "after_sensitive": ARC_HELM_AFTER_SENSITIVE,
    },
}

ARC_CUTOVER_HELM_CHANGE = {
    "address": "module.gh_nix.helm_release.arc_runner",
    "module_address": "module.gh_nix",
    "mode": "managed",
    "type": "helm_release",
    "name": "arc_runner",
    "provider_name": "registry.opentofu.org/hashicorp/helm",
    "change": {
        "actions": ["update"],
        "before": {"set": copy.deepcopy(ARC_HELM_SET_DEFAULT), "values": [ARC_BEFORE_VALUES]},
        "after": {"set": copy.deepcopy(ARC_HELM_SET_DEDICATED), "values": [ARC_CUTOVER_VALUES]},
        "after_unknown": ARC_HELM_AFTER_UNKNOWN,
        "before_sensitive": ARC_HELM_BEFORE_SENSITIVE,
        "after_sensitive": ARC_HELM_AFTER_SENSITIVE,
    },
}

ARC_ROLLBACK_HELM_CHANGE = {
    "address": "module.gh_nix.helm_release.arc_runner",
    "module_address": "module.gh_nix",
    "mode": "managed",
    "type": "helm_release",
    "name": "arc_runner",
    "provider_name": "registry.opentofu.org/hashicorp/helm",
    "change": {
        "actions": ["update"],
        "before": {"set": copy.deepcopy(ARC_HELM_SET_DEDICATED), "values": [ARC_CUTOVER_VALUES]},
        "after": {"set": copy.deepcopy(ARC_HELM_SET_DEFAULT), "values": [ARC_BEFORE_VALUES]},
        "after_unknown": ARC_HELM_AFTER_UNKNOWN,
        "before_sensitive": ARC_HELM_BEFORE_SENSITIVE,
        "after_sensitive": ARC_HELM_AFTER_SENSITIVE,
    },
}

# TIN-2299's capacity bump applied on 2026-08-17 as helm_release
# great-falls-tool-bus-nix revision 6 with runnerGroup still `default`,
# decomposing TIN-3902's combined cutover. The decomposed shapes reuse the
# verbatim literals above: ARC_AFTER_VALUES is byte-for-byte the live
# post-capacity pre-cutover rendering (8/16Gi storage, pre-cutover image
# digest, no GF_FLYWHEEL_PROFILE_STATE, no priorityClassName) and
# ARC_CUTOVER_VALUES the post-cutover rendering, so the group move carries
# zero storage delta on either side.
ARC_POST_CAPACITY_CUTOVER_HELM_CHANGE = {
    "address": "module.gh_nix.helm_release.arc_runner",
    "module_address": "module.gh_nix",
    "mode": "managed",
    "type": "helm_release",
    "name": "arc_runner",
    "provider_name": "registry.opentofu.org/hashicorp/helm",
    "change": {
        "actions": ["update"],
        "before": {"set": copy.deepcopy(ARC_HELM_SET_DEFAULT), "values": [ARC_AFTER_VALUES]},
        "after": {"set": copy.deepcopy(ARC_HELM_SET_DEDICATED), "values": [ARC_CUTOVER_VALUES]},
        "after_unknown": ARC_HELM_AFTER_UNKNOWN,
        "before_sensitive": ARC_HELM_BEFORE_SENSITIVE,
        "after_sensitive": ARC_HELM_AFTER_SENSITIVE,
    },
}

ARC_POST_CAPACITY_ROLLBACK_HELM_CHANGE = {
    "address": "module.gh_nix.helm_release.arc_runner",
    "module_address": "module.gh_nix",
    "mode": "managed",
    "type": "helm_release",
    "name": "arc_runner",
    "provider_name": "registry.opentofu.org/hashicorp/helm",
    "change": {
        "actions": ["update"],
        "before": {"set": copy.deepcopy(ARC_HELM_SET_DEDICATED), "values": [ARC_CUTOVER_VALUES]},
        "after": {"set": copy.deepcopy(ARC_HELM_SET_DEFAULT), "values": [ARC_AFTER_VALUES]},
        "after_unknown": ARC_HELM_AFTER_UNKNOWN,
        "before_sensitive": ARC_HELM_BEFORE_SENSITIVE,
        "after_sensitive": ARC_HELM_AFTER_SENSITIVE,
    },
}

ARC_POLICY_CREATE = {'address': 'terraform_data.runner_group_policy',
 'mode': 'managed',
 'type': 'terraform_data',
 'name': 'runner_group_policy',
 'provider_name': 'terraform.io/builtin/terraform',
 'change': {'actions': ['create'],
            'before': None,
            'after': {'input': {'legacy_expires': '',
                                'legacy_reason': '',
                                'legacy_receipt': {},
                                'policy': 'organization-restricted',
                                'scale_sets': [{'group': 'great-falls-tool-bus-infra',
                                                'name': 'great-falls-tool-bus-nix'}]},
                      'triggers_replace': None},
            'after_unknown': {'id': True,
                              'input': {'legacy_receipt': {}, 'scale_sets': [{}]},
                              'output': True},
            'before_sensitive': False,
            'after_sensitive': {'input': {'legacy_receipt': {}, 'scale_sets': [{}]},
                                'output': {}}}}

ARC_POLICY_DELETE = {'address': 'terraform_data.runner_group_policy',
 'mode': 'managed',
 'type': 'terraform_data',
 'name': 'runner_group_policy',
 'provider_name': 'terraform.io/builtin/terraform',
 'change': {'actions': ['delete'],
            'before': {'id': '0dbf1d02-9d3f-4b6f-9a1e-000000000001',
                       'input': {'legacy_expires': '',
                                 'legacy_reason': '',
                                 'legacy_receipt': {},
                                 'policy': 'organization-restricted',
                                 'scale_sets': [{'group': 'great-falls-tool-bus-infra',
                                                 'name': 'great-falls-tool-bus-nix'}]},
                       'output': {'legacy_expires': '',
                                  'legacy_reason': '',
                                  'legacy_receipt': {},
                                  'policy': 'organization-restricted',
                                  'scale_sets': [{'group': 'great-falls-tool-bus-infra',
                                                  'name': 'great-falls-tool-bus-nix'}]},
                       'triggers_replace': None},
            'after': None,
            'after_unknown': {},
            'before_sensitive': {'input': {'legacy_receipt': {}, 'scale_sets': [{}]},
                                 'output': {'legacy_receipt': {},
                                            'scale_sets': [{}]}},
            'after_sensitive': False},
 'action_reason': 'delete_because_no_resource_config'}

ARC_CUTOVER_OUTPUT_CHANGES = {'dind_runner_group': {'actions': ['create'],
                       'before': None,
                       'after': '',
                       'after_unknown': False,
                       'before_sensitive': False,
                       'after_sensitive': False},
 'docker_runner_group': {'actions': ['create'],
                         'before': None,
                         'after': '',
                         'after_unknown': False,
                         'before_sensitive': False,
                         'after_sensitive': False},
 'extra_runner_groups': {'actions': ['create'],
                         'before': None,
                         'after': {},
                         'after_unknown': False,
                         'before_sensitive': False,
                         'after_sensitive': False},
 'nix_runner_group': {'actions': ['create'],
                      'before': None,
                      'after': 'great-falls-tool-bus-infra',
                      'after_unknown': False,
                      'before_sensitive': False,
                      'after_sensitive': False},
 'overlay_tenant_legacy_shared_grant_owners': {'actions': ['create'],
                                               'before': None,
                                               'after': [],
                                               'after_unknown': False,
                                               'before_sensitive': False,
                                               'after_sensitive': False},
 'tofu_plan_cluster_role': {'actions': ['create'],
                            'before': None,
                            'after': '',
                            'after_unknown': False,
                            'before_sensitive': False,
                            'after_sensitive': False},
 'tofu_plan_secret_read_namespaces': {'actions': ['create'],
                                      'before': None,
                                      'after': [],
                                      'after_unknown': False,
                                      'before_sensitive': False,
                                      'after_sensitive': False},
 'tofu_plan_service_account': {'actions': ['create'],
                               'before': None,
                               'after': '',
                               'after_unknown': False,
                               'before_sensitive': False,
                               'after_sensitive': False},
 'tofu_plan_token_secret': {'actions': ['create'],
                            'before': None,
                            'after': '',
                            'after_unknown': False,
                            'before_sensitive': False,
                            'after_sensitive': False}}

ARC_ROLLBACK_OUTPUT_CHANGES = {'dind_runner_group': {'actions': ['delete'],
                       'before': '',
                       'after': None,
                       'after_unknown': False,
                       'before_sensitive': False,
                       'after_sensitive': False},
 'docker_runner_group': {'actions': ['delete'],
                         'before': '',
                         'after': None,
                         'after_unknown': False,
                         'before_sensitive': False,
                         'after_sensitive': False},
 'extra_runner_groups': {'actions': ['delete'],
                         'before': {},
                         'after': None,
                         'after_unknown': False,
                         'before_sensitive': False,
                         'after_sensitive': False},
 'nix_runner_group': {'actions': ['delete'],
                      'before': 'great-falls-tool-bus-infra',
                      'after': None,
                      'after_unknown': False,
                      'before_sensitive': False,
                      'after_sensitive': False},
 'overlay_tenant_legacy_shared_grant_owners': {'actions': ['delete'],
                                               'before': [],
                                               'after': None,
                                               'after_unknown': False,
                                               'before_sensitive': False,
                                               'after_sensitive': False},
 'tofu_plan_cluster_role': {'actions': ['delete'],
                            'before': '',
                            'after': None,
                            'after_unknown': False,
                            'before_sensitive': False,
                            'after_sensitive': False},
 'tofu_plan_secret_read_namespaces': {'actions': ['delete'],
                                      'before': [],
                                      'after': None,
                                      'after_unknown': False,
                                      'before_sensitive': False,
                                      'after_sensitive': False},
 'tofu_plan_service_account': {'actions': ['delete'],
                               'before': '',
                               'after': None,
                               'after_unknown': False,
                               'before_sensitive': False,
                               'after_sensitive': False},
 'tofu_plan_token_secret': {'actions': ['delete'],
                            'before': '',
                            'after': None,
                            'after_unknown': False,
                            'before_sensitive': False,
                            'after_sensitive': False}}

ARC_SCAFFOLDING_OUTPUT = {
    "fixture_output": {
        "actions": ["no-op"],
        "before": "opaque-fixture-value",
        "after": "opaque-fixture-value",
        "after_unknown": False,
        "before_sensitive": False,
        "after_sensitive": False,
    }
}


def arc_scope_plan(
    resource_changes: list[dict[str, object]], outputs: dict[str, object]
) -> dict[str, object]:
    """Assemble the plan fields the ARC scope guard actually reads."""
    output_changes: dict[str, object] = copy.deepcopy(ARC_SCAFFOLDING_OUTPUT)
    output_changes.update(copy.deepcopy(outputs))
    return {
        "format_version": "1.2",
        "terraform_version": "1.11.6",
        "errored": False,
        "resource_drift": [],
        "output_changes": output_changes,
        "resource_changes": copy.deepcopy(resource_changes),
    }


def valid_arc_scope_plan() -> dict[str, object]:
    """The reviewed 4/8Gi -> 8/16Gi capacity promotion, unchanged by TIN-3902."""
    return arc_scope_plan([ARC_CAPACITY_HELM_CHANGE], {})


def valid_arc_cutover_plan() -> dict[str, object]:
    """The reviewed TIN-3902 runner-group cutover."""
    return arc_scope_plan(
        [ARC_POLICY_CREATE, ARC_CUTOVER_HELM_CHANGE], ARC_CUTOVER_OUTPUT_CHANGES
    )


def valid_arc_rollback_plan() -> dict[str, object]:
    """The reviewed TIN-3902 runner-group rollback: the cutover, exactly reversed."""
    return arc_scope_plan(
        [ARC_POLICY_DELETE, ARC_ROLLBACK_HELM_CHANGE], ARC_ROLLBACK_OUTPUT_CHANGES
    )


def valid_arc_post_capacity_cutover_plan() -> dict[str, object]:
    """The TIN-3902 cutover decomposed by the applied capacity bump: group move only."""
    return arc_scope_plan(
        [ARC_POLICY_CREATE, ARC_POST_CAPACITY_CUTOVER_HELM_CHANGE],
        ARC_CUTOVER_OUTPUT_CHANGES,
    )


def valid_arc_post_capacity_rollback_plan() -> dict[str, object]:
    """That decomposed cutover exactly reversed: the ratified fallback from the post-cutover state."""
    return arc_scope_plan(
        [ARC_POLICY_DELETE, ARC_POST_CAPACITY_ROLLBACK_HELM_CHANGE],
        ARC_ROLLBACK_OUTPUT_CHANGES,
    )


def run_arc_scope_checker(source: str, plan: dict[str, object]) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory(prefix="gftb-arc-scope-selftest.") as directory:
        path = Path(directory) / "plan.json"
        path.write_text(json.dumps(plan), encoding="utf-8")
        return subprocess.run(
            [sys.executable, "-I", "-", str(path)],
            input=source,
            text=True,
            capture_output=True,
            check=False,
        )


def expect_scope_rejection(
    source: str,
    label: str,
    plan: dict[str, object],
    message_fragment: str | None = None,
) -> None:
    result = run_arc_scope_checker(source, plan)
    if result.returncode == 0:
        raise SystemExit(f"self-test FAILED: ARC scope accepted {label}")
    diagnostic = result.stdout + result.stderr
    if message_fragment is not None and message_fragment not in diagnostic:
        raise SystemExit(
            f"self-test FAILED: ARC scope rejected {label} for the wrong reason: "
            f"{diagnostic.strip()!r}"
        )


def mutate_recipe_body(
    text: str, name: str, old: str, new: str, label: str
) -> str:
    recipe = just_recipe_block(text, name)
    if recipe is None or old not in recipe[2]:
        raise SystemExit(f"self-test FAILED: could not construct {label} fixture")
    body = recipe[2]
    mutated_body = body.replace(old, new, 1)
    return text.replace(body, mutated_body, 1)


def mutate_recipe_dependencies(
    text: str, name: str, dependencies: tuple[str, ...], label: str
) -> str:
    recipe = just_recipe_block(text, name)
    if recipe is None:
        raise SystemExit(f"self-test FAILED: could not construct {label} fixture")
    lines = text.splitlines()
    suffix = " " + " ".join(dependencies) if dependencies else ""
    lines[recipe[0] - 1] = f"{name}:{suffix}"
    return "\n".join(lines) + ("\n" if text.endswith("\n") else "")


def expect_arc_contract_rejection(
    text: str, label: str, expected_rule: str
) -> None:
    findings = scan_arc_operator_contract_text(text, Path("Justfile"))
    if not any(finding.rule == expected_rule for finding in findings):
        observed = sorted({finding.rule for finding in findings})
        raise SystemExit(
            f"self-test FAILED: ARC contract accepted {label}; findings={observed!r}"
        )


def expect_attended_contract_rejection(
    text: str, label: str, expected_rule: str
) -> None:
    findings = scan_attended_operator_contract_text(text, Path("Justfile"))
    if not any(finding.rule == expected_rule for finding in findings):
        observed = sorted({finding.rule for finding in findings})
        raise SystemExit(
            f"self-test FAILED: attended contract accepted {label}; "
            f"findings={observed!r}"
        )


def expect_web_release_contract_rejection(
    text: str, label: str, expected_rule: str
) -> None:
    findings = scan_web_release_operator_contract_text(text, Path("Justfile"))
    if not any(finding.rule == expected_rule for finding in findings):
        observed = sorted({finding.rule for finding in findings})
        raise SystemExit(
            f"self-test FAILED: web release contract accepted {label}; "
            f"findings={observed!r}"
        )


def check_critical_recipe_shell_syntax() -> None:
    """Ask Just to expand dependency chains, then parse the exact shell output."""
    for name in (
        *ARC_RECIPE_DEPENDENCIES,
        *ATTENDED_RECIPE_DEPENDENCIES,
        *WEB_RELEASE_RECIPE_DEPENDENCIES,
        WEB_STACK_PROMOTION_INTERLOCK,
    ):
        dry_run = subprocess.run(
            ["just", "--dry-run", name],
            cwd=REPO,
            text=True,
            capture_output=True,
            check=False,
        )
        if dry_run.returncode != 0:
            raise SystemExit(
                f"self-test FAILED: just --dry-run {name} failed: "
                f"{(dry_run.stdout + dry_run.stderr).strip()}"
            )
        expanded = dry_run.stdout + dry_run.stderr
        syntax = subprocess.run(
            ["bash", "-n"],
            input=expanded,
            text=True,
            capture_output=True,
            check=False,
        )
        if syntax.returncode != 0:
            raise SystemExit(
                f"self-test FAILED: expanded {name} is not valid Bash: "
                f"{syntax.stderr.strip()}"
            )


WEB_RELEASE_FIXTURE_SHA = "b" * 40
WEB_RELEASE_FIXTURE_DIGEST = "sha256:" + "a" * 64
WEB_RELEASE_FIXTURE_IMAGE = (
    "ghcr.io/great-falls-tool-bus/gftb-site@" + WEB_RELEASE_FIXTURE_DIGEST
)
# The one tag web-release-resolve-candidate is allowed to construct. The mock
# registry only answers `crane digest` for this exact reference, so a resolver
# that widened the tag it reads would fail the fixture rather than pass it.
WEB_RELEASE_FIXTURE_TAG = (
    "ghcr.io/great-falls-tool-bus/gftb-site:sha-" + WEB_RELEASE_FIXTURE_SHA
)

WEB_RELEASE_RENDER_FIXTURE = """\
apiVersion: apps/v1
kind: Deployment
metadata:
  name: greatfallstoolbus-org
  namespace: greatfallstoolbus-org-production
spec:
  replicas: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: greatfallstoolbus-org
      app.kubernetes.io/component: web
  template:
    metadata:
      annotations: {}
      labels:
        app.kubernetes.io/name: greatfallstoolbus-org
        app.kubernetes.io/component: web
        app.kubernetes.io/part-of: great-falls-tool-bus
    spec:
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: greatfallstoolbus-org
          image: PLACEHOLDER
          ports:
            - name: http
              containerPort: 3000
              protocol: TCP
          command: ["node"]
          args: ["build/index.js"]
          env:
            - name: PORT
              value: "3000"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
---
apiVersion: v1
kind: Service
metadata:
  name: greatfallstoolbus-org
  namespace: greatfallstoolbus-org-production
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: greatfallstoolbus-org
    app.kubernetes.io/component: web
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
"""


def write_fixture_executable(path: Path, source: str) -> None:
    path.write_text(textwrap.dedent(source).lstrip(), encoding="utf-8")
    path.chmod(0o700)


def web_release_runtime_objects() -> tuple[dict[str, object], ...]:
    deployment_uid = "11111111-1111-4111-8111-111111111111"
    active_uid = "22222222-2222-4222-8222-222222222222"
    old_uid = "33333333-3333-4333-8333-333333333333"
    labels = {
        "app.kubernetes.io/name": "greatfallstoolbus-org",
        "app.kubernetes.io/component": "web",
        "app.kubernetes.io/part-of": "great-falls-tool-bus",
    }
    container = {
        "name": "greatfallstoolbus-org",
        "image": WEB_RELEASE_FIXTURE_IMAGE,
        "ports": [{"name": "http", "containerPort": 3000, "protocol": "TCP"}],
        "securityContext": {
            "allowPrivilegeEscalation": False,
            "readOnlyRootFilesystem": True,
            "capabilities": {"drop": ["ALL"]},
        },
    }
    pod_spec = {
        "automountServiceAccountToken": False,
        "enableServiceLinks": False,
        "securityContext": {
            "runAsNonRoot": True,
            "runAsUser": 65532,
            "runAsGroup": 65532,
            "fsGroup": 65532,
            "seccompProfile": {"type": "RuntimeDefault"},
        },
        "containers": [container],
    }
    deployment = {
        "metadata": {
            "name": "greatfallstoolbus-org",
            "namespace": "greatfallstoolbus-org-production",
            "uid": deployment_uid,
            "generation": 7,
            "annotations": {"deployment.kubernetes.io/revision": "3"},
        },
        "spec": {
            "replicas": 2,
            "selector": {
                "matchLabels": {
                    "app.kubernetes.io/name": "greatfallstoolbus-org",
                    "app.kubernetes.io/component": "web",
                }
            },
            "template": {
                "metadata": {
                    "annotations": {
                        "app.tinyland.dev/source-sha": WEB_RELEASE_FIXTURE_SHA
                    },
                    "labels": labels,
                },
                "spec": pod_spec,
            },
        },
        "status": {
            "observedGeneration": 7,
            "replicas": 2,
            "updatedReplicas": 2,
            "readyReplicas": 2,
            "availableReplicas": 2,
            "conditions": [
                {"type": "Available", "status": "True"},
                {"type": "Progressing", "status": "True"},
            ],
        },
    }
    active_labels = {**labels, "pod-template-hash": "abc123"}
    active_rs = {
        "metadata": {
            "name": "greatfallstoolbus-org-abc123",
            "namespace": "greatfallstoolbus-org-production",
            "uid": active_uid,
            "labels": active_labels,
            "annotations": {"deployment.kubernetes.io/revision": "3"},
            "ownerReferences": [{"uid": deployment_uid, "controller": True}],
        },
        "spec": {
            "replicas": 2,
            "selector": {"matchLabels": active_labels},
            "template": {
                "metadata": {
                    "annotations": {
                        "app.tinyland.dev/source-sha": WEB_RELEASE_FIXTURE_SHA
                    },
                    "labels": active_labels,
                },
                "spec": pod_spec,
            },
        },
        "status": {
            "replicas": 2,
            "readyReplicas": 2,
            "availableReplicas": 2,
            "fullyLabeledReplicas": 2,
        },
    }
    old_rs = {
        "metadata": {
            "name": "greatfallstoolbus-org-old",
            "namespace": "greatfallstoolbus-org-production",
            "uid": old_uid,
            "labels": {**labels, "pod-template-hash": "old123"},
            "annotations": {"deployment.kubernetes.io/revision": "2"},
            "ownerReferences": [{"uid": deployment_uid, "controller": True}],
        },
        "spec": {"replicas": 0},
        "status": {"replicas": 0},
    }

    def pod(index: int) -> dict[str, object]:
        pod_ip = f"10.0.0.{index}"
        return {
            "metadata": {
                "name": f"greatfallstoolbus-org-abc123-{index}",
                "namespace": "greatfallstoolbus-org-production",
                "uid": f"44444444-4444-4444-8444-44444444444{index}",
                "labels": active_labels,
                "annotations": {
                    "app.tinyland.dev/source-sha": WEB_RELEASE_FIXTURE_SHA
                },
                "ownerReferences": [{"uid": active_uid, "controller": True}],
            },
            "spec": pod_spec,
            "status": {
                "phase": "Running",
                "podIP": pod_ip,
                "podIPs": [{"ip": pod_ip}],
                "conditions": [
                    {"type": "Ready", "status": "True"},
                    {"type": "ContainersReady", "status": "True"},
                ],
                "containerStatuses": [
                    {
                        "name": "greatfallstoolbus-org",
                        "ready": True,
                        "started": True,
                        "restartCount": 0,
                        "state": {
                            "running": {"startedAt": "2026-08-17T20:00:00Z"}
                        },
                        "imageID": WEB_RELEASE_FIXTURE_IMAGE,
                    }
                ],
            },
        }

    replicasets = {"items": [active_rs, old_rs]}
    pods = {"items": [pod(1), pod(2)]}
    service_uid = "77777777-7777-4777-8777-777777777777"
    service = {
        "metadata": {
            "name": "greatfallstoolbus-org",
            "namespace": "greatfallstoolbus-org-production",
            "uid": service_uid,
        },
        "spec": {
            "type": "ClusterIP",
            "clusterIP": "10.96.0.80",
            "selector": {
                "app.kubernetes.io/name": "greatfallstoolbus-org",
                "app.kubernetes.io/component": "web",
            },
            "ports": [
                {
                    "name": "http",
                    "port": 80,
                    "targetPort": "http",
                    "protocol": "TCP",
                }
            ],
        },
    }
    endpoint_slices = {
        "items": [
            {
                "metadata": {
                    "name": "greatfallstoolbus-org-abc123",
                    "namespace": "greatfallstoolbus-org-production",
                    "uid": "88888888-8888-4888-8888-888888888888",
                    "labels": {
                        "kubernetes.io/service-name": "greatfallstoolbus-org"
                    },
                    "ownerReferences": [
                        {
                            "apiVersion": "v1",
                            "kind": "Service",
                            "name": "greatfallstoolbus-org",
                            "uid": service_uid,
                            "controller": True,
                        }
                    ],
                },
                "addressType": "IPv4",
                "ports": [{"name": "http", "port": 3000, "protocol": "TCP"}],
                "endpoints": [
                    {
                        "addresses": [f"10.0.0.{index}"],
                        "conditions": {
                            "ready": True,
                            "serving": True,
                            "terminating": False,
                        },
                        "targetRef": {
                            "kind": "Pod",
                            "namespace": "greatfallstoolbus-org-production",
                            "uid": f"44444444-4444-4444-8444-44444444444{index}",
                        },
                    }
                    for index in (1, 2)
                ],
            }
        ]
    }
    policy_labels = {
        "app.kubernetes.io/managed-by": "great-falls-tool-bus-infra",
        "app.kubernetes.io/name": "greatfallstoolbus-org",
        "app.kubernetes.io/part-of": "great-falls-tool-bus",
        "app.tinyland.dev/lifecycle": "declare-only",
        "app.tinyland.dev/tenant": "great-falls-tool-bus",
    }
    policy_selector = {
        "matchLabels": {
            "app.kubernetes.io/component": "web",
            "app.kubernetes.io/name": "greatfallstoolbus-org",
        }
    }

    def network_policy(
        index: int, name: str, spec: dict[str, object], *, app_label: bool = True
    ) -> dict[str, object]:
        metadata_labels = dict(policy_labels)
        if not app_label:
            metadata_labels.pop("app.kubernetes.io/name")
        return {
            "apiVersion": "networking.k8s.io/v1",
            "kind": "NetworkPolicy",
            "metadata": {
                "name": name,
                "namespace": "greatfallstoolbus-org-production",
                "uid": f"99999999-9999-4999-8999-99999999999{index}",
                "labels": metadata_labels,
            },
            "spec": spec,
        }

    render_base_network_policies = {
        "items": [
            network_policy(
                1,
                "allow-cloudflared-tunnel-ingress",
                {
                    "podSelector": policy_selector,
                    "policyTypes": ["Ingress"],
                    "ingress": [
                        {
                            "from": [
                                {
                                    "namespaceSelector": {
                                        "matchLabels": {
                                            "kubernetes.io/metadata.name": "cloudflared"
                                        }
                                    }
                                }
                            ],
                            "ports": [{"port": 3000, "protocol": "TCP"}],
                        }
                    ],
                },
            ),
            network_policy(
                2,
                "allow-egress-discuss-archive",
                {
                    "podSelector": policy_selector,
                    "policyTypes": ["Egress"],
                    "egress": [
                        {
                            "to": [
                                {
                                    "namespaceSelector": {
                                        "matchLabels": {
                                            "kubernetes.io/metadata.name": (
                                                "latoolb-us-production"
                                            )
                                        }
                                    },
                                    "podSelector": {
                                        "matchLabels": {
                                            "app.kubernetes.io/name": "mailman-core"
                                        }
                                    },
                                }
                            ],
                            "ports": [{"port": 8000, "protocol": "TCP"}],
                        }
                    ],
                },
            ),
            network_policy(
                3,
                "allow-egress-dns",
                {
                    "podSelector": policy_selector,
                    "policyTypes": ["Egress"],
                    "egress": [
                        {
                            "ports": [
                                {"port": 53, "protocol": "TCP"},
                                {"port": 53, "protocol": "UDP"},
                            ]
                        }
                    ],
                },
            ),
            network_policy(
                4,
                "allow-prometheus-scrape",
                {
                    "podSelector": policy_selector,
                    "policyTypes": ["Ingress"],
                    "ingress": [
                        {
                            "from": [
                                {
                                    "namespaceSelector": {
                                        "matchLabels": {
                                            "kubernetes.io/metadata.name": (
                                                "tinyland-dev-production"
                                            )
                                        }
                                    },
                                    "podSelector": {
                                        "matchLabels": {
                                            "app.kubernetes.io/name": "prometheus"
                                        }
                                    },
                                }
                            ],
                            "ports": [{"port": 3000, "protocol": "TCP"}],
                        }
                    ],
                },
            ),
            network_policy(
                5,
                "default-deny-ingress",
                {"podSelector": {}, "policyTypes": ["Ingress"]},
                app_label=False,
            ),
        ]
    }
    network_policies = {
        "items": [
            copy.deepcopy(policy)
            for policy in render_base_network_policies["items"]
            if policy["metadata"]["name"]
            not in {"allow-egress-dns", "allow-egress-discuss-archive"}
        ]
    }
    network_policies["items"].append(
        network_policy(
            6,
            "default-deny-egress",
            {
                "podSelector": policy_selector,
                "policyTypes": ["Egress"],
                "egress": [],
            },
            app_label=False,
        )
    )
    return (
        deployment,
        replicasets,
        pods,
        service,
        endpoint_slices,
        network_policies,
        render_base_network_policies,
    )


def web_release_ssrr_fixture() -> dict[str, object]:
    return {
        "apiVersion": "authorization.k8s.io/v1",
        "kind": "SelfSubjectRulesReview",
        "status": {
            "incomplete": False,
            "evaluationError": "",
            "resourceRules": [
                {"apiGroups": [""], "resources": ["namespaces"], "verbs": ["get"]},
                {"apiGroups": [""], "resources": ["pods"], "verbs": ["list"]},
                {"apiGroups": [""], "resources": ["services"], "verbs": ["get"]},
                {
                    "apiGroups": ["apps"],
                    "resources": ["deployments"],
                    "verbs": ["get"],
                },
                {
                    "apiGroups": ["apps"],
                    "resources": ["replicasets"],
                    "verbs": ["list"],
                },
                {
                    "apiGroups": ["authentication.k8s.io"],
                    "resources": ["selfsubjectreviews"],
                    "verbs": ["create"],
                },
                {
                    "apiGroups": ["authorization.k8s.io"],
                    "resources": ["selfsubjectaccessreviews"],
                    "verbs": ["create"],
                },
                {
                    "apiGroups": ["authorization.k8s.io"],
                    "resources": ["selfsubjectrulesreviews"],
                    "verbs": ["create"],
                },
                {
                    "apiGroups": ["discovery.k8s.io"],
                    "resources": ["endpointslices"],
                    "verbs": ["list"],
                },
                {
                    "apiGroups": ["networking.k8s.io"],
                    "resources": ["networkpolicies"],
                    "verbs": ["list"],
                },
            ],
            "nonResourceRules": [
                {
                    "nonResourceURLs": [
                        "/.well-known/openid-configuration",
                        "/.well-known/openid-configuration/",
                        "/openid/v1/jwks",
                        "/openid/v1/jwks/",
                    ],
                    "verbs": ["get"],
                }
            ],
        },
    }


def normalized_ssrr_snapshot(response: dict[str, object]) -> str:
    status = response["status"]
    if not isinstance(status, dict):
        raise TypeError("fixture SSRR status must be an object")
    resource_rules = []
    for raw_rule in status.get("resourceRules", []):
        if not isinstance(raw_rule, dict):
            raise TypeError("fixture SSRR resource rule must be an object")
        resource_rules.append(
            {
                "apiGroups": sorted(set(raw_rule.get("apiGroups", []))),
                "resources": sorted(set(raw_rule.get("resources", []))),
                "resourceNames": sorted(set(raw_rule.get("resourceNames", []))),
                "verbs": sorted(set(raw_rule.get("verbs", []))),
            }
        )
    non_resource_rules = []
    for raw_rule in status.get("nonResourceRules", []):
        if not isinstance(raw_rule, dict):
            raise TypeError("fixture SSRR non-resource rule must be an object")
        non_resource_rules.append(
            {
                "nonResourceURLs": sorted(
                    set(raw_rule.get("nonResourceURLs", []))
                ),
                "verbs": sorted(set(raw_rule.get("verbs", []))),
            }
        )
    snapshot = {
        "incomplete": status.get("incomplete"),
        "evaluationError": status.get("evaluationError", ""),
        "resourceRules": sorted(
            {json.dumps(rule, sort_keys=True, separators=(",", ":")) for rule in resource_rules}
        ),
        "nonResourceRules": sorted(
            {
                json.dumps(rule, sort_keys=True, separators=(",", ":"))
                for rule in non_resource_rules
            }
        ),
    }
    snapshot["resourceRules"] = [
        json.loads(rule) for rule in snapshot["resourceRules"]
    ]
    snapshot["nonResourceRules"] = [
        json.loads(rule) for rule in snapshot["nonResourceRules"]
    ]
    return json.dumps(snapshot, sort_keys=True, separators=(",", ":"))


def install_web_release_fixture_mocks(
    root: Path,
) -> tuple[Path, Path, Path, Path]:
    mock_bin = root / "bin"
    fixture_dir = root / "fixtures"
    mock_bin.mkdir(mode=0o700)
    fixture_dir.mkdir(mode=0o700)
    safe_commands = (
        "awk",
        "bash",
        "cat",
        "chmod",
        "env",
        "grep",
        "jq",
        "mkdir",
        "mktemp",
        "python3",
        "rm",
        "sort",
        "tail",
        "tr",
        "yq",
    )
    for command in safe_commands:
        resolved = shutil.which(command)
        if resolved is None:
            raise SystemExit(
                f"self-test FAILED: web release fixture requires {command}; "
                "run inside `nix develop` (the repo devshell provides yq, jq, "
                "kubectl, crane and the rest of the release toolchain)"
            )
        (mock_bin / command).symlink_to(Path(resolved).resolve())
    fixture_bash = Path("/bin/bash")
    if not fixture_bash.is_file():
        resolved_bash = shutil.which("bash")
        if resolved_bash is None:
            raise SystemExit("self-test FAILED: web release fixture requires bash")
        fixture_bash = Path(resolved_bash).resolve()
    state_path = fixture_dir / "state"
    log_path = fixture_dir / "calls.log"
    state_path.write_text("ok\n", encoding="utf-8")
    log_path.write_text("", encoding="utf-8")
    # Which directory the mocked `git rev-parse --show-toplevel` reports. The
    # proof fixtures run against the real REPO; the mutation fixtures point it at
    # a symlink sandbox so `web-release-plan` writes its .k8s-plans/ receipt
    # OUTSIDE the operator's checkout and can never clobber a real recorded plan.
    toplevel_path = fixture_dir / "toplevel"
    toplevel_path.write_text(str(REPO) + "\n", encoding="utf-8")

    (
        deployment,
        replicasets,
        pods,
        service,
        endpoint_slices,
        network_policies,
        render_base_network_policies,
    ) = web_release_runtime_objects()
    (fixture_dir / "deployment.json").write_text(
        json.dumps(deployment), encoding="utf-8"
    )
    (fixture_dir / "replicasets.json").write_text(
        json.dumps(replicasets), encoding="utf-8"
    )
    (fixture_dir / "pods.json").write_text(json.dumps(pods), encoding="utf-8")
    (fixture_dir / "service.json").write_text(
        json.dumps(service), encoding="utf-8"
    )
    (fixture_dir / "endpointslices.json").write_text(
        json.dumps(endpoint_slices), encoding="utf-8"
    )
    (fixture_dir / "networkpolicies.json").write_text(
        json.dumps(network_policies), encoding="utf-8"
    )
    (fixture_dir / "render-base-networkpolicies.json").write_text(
        json.dumps(render_base_network_policies), encoding="utf-8"
    )
    ssrr = web_release_ssrr_fixture()
    (fixture_dir / "ssrr.json").write_text(json.dumps(ssrr), encoding="utf-8")
    authority_digest = hashlib.sha256(
        normalized_ssrr_snapshot(ssrr).encode("utf-8")
    ).hexdigest()
    rendered_policies = copy.deepcopy(render_base_network_policies["items"])
    if not isinstance(rendered_policies, list):
        raise TypeError("fixture NetworkPolicy items must be a list")
    for policy in rendered_policies:
        if not isinstance(policy, dict) or not isinstance(
            policy.get("metadata"), dict
        ):
            raise TypeError("fixture NetworkPolicy must have metadata")
        policy["metadata"].pop("uid", None)
    render_fixture = WEB_RELEASE_RENDER_FIXTURE + "".join(
        "---\n" + json.dumps(policy, sort_keys=True) + "\n"
        for policy in rendered_policies
    )
    (fixture_dir / "render.yaml").write_text(render_fixture, encoding="utf-8")
    manifest = {
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "config": {"digest": "sha256:" + "c" * 64, "size": 123},
        "layers": [{"digest": "sha256:" + "d" * 64, "size": 456}],
    }
    config = {
        "os": "linux",
        "architecture": "amd64",
        "config": {
            "User": "65532:65532",
            "Entrypoint": ["/bin/dumb-init", "--"],
            "Cmd": [
                "/bin/caddy",
                "run",
                "--config",
                "/etc/caddy/Caddyfile",
                "--adapter",
                "caddyfile",
            ],
            "WorkingDir": "/srv",
            "Env": [
                "HOME=/tmp",
                "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt",
                "XDG_CONFIG_HOME=/tmp",
                "XDG_DATA_HOME=/tmp",
            ],
            "ExposedPorts": {"3000/tcp": {}},
            "Labels": {
                "org.opencontainers.image.source": (
                    "https://github.com/Great-Falls-Tool-Bus/gftb-site"
                ),
                "org.opencontainers.image.revision": WEB_RELEASE_FIXTURE_SHA,
            },
        },
    }
    (fixture_dir / "manifest.json").write_text(
        json.dumps(manifest), encoding="utf-8"
    )
    (fixture_dir / "config.json").write_text(
        json.dumps(config), encoding="utf-8"
    )

    replacements = {
        "__FIXTURES__": repr(str(fixture_dir)),
        "__STATE__": repr(str(state_path)),
        "__LOG__": repr(str(log_path)),
        "__DIGEST__": repr(WEB_RELEASE_FIXTURE_DIGEST),
        "__SHA__": repr(WEB_RELEASE_FIXTURE_SHA),
        "__IMAGE__": repr(WEB_RELEASE_FIXTURE_IMAGE),
        "__TAG__": repr(WEB_RELEASE_FIXTURE_TAG),
        "__REPO__": repr(str(REPO)),
        "__TOPLEVEL__": repr(str(toplevel_path)),
        "__REAL_JUST__": repr(shutil.which("just") or ""),
        "__AUTHORITY_DIGEST__": repr(authority_digest),
        "__KUBECTL_BACKEND__": shlex.quote(str(mock_bin / "kubectl-python")),
        "__FIXTURE_BASH__": str(fixture_bash),
        "__FIXTURE_PYTHON__": str(Path(sys.executable).resolve()),
    }

    def materialize(source: str) -> str:
        for old, new in replacements.items():
            source = source.replace(old, new)
        return source

    write_fixture_executable(
        mock_bin / "crane",
        materialize(
            """
            #!__FIXTURE_PYTHON__
            import json
            import os
            import pathlib
            import sys

            fixtures = pathlib.Path(__FIXTURES__)
            state = pathlib.Path(__STATE__).read_text(encoding="utf-8").strip()
            log = pathlib.Path(__LOG__)
            with log.open("a", encoding="utf-8") as stream:
                stream.write("crane " + " ".join(sys.argv[1:]) + "\\n")
            forbidden = {
                "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
                "http_proxy", "https_proxy", "all_proxy", "no_proxy",
            }
            if forbidden & os.environ.keys():
                raise SystemExit("mock crane received proxy environment")
            if any(
                marker in name.upper()
                for name in os.environ
                for marker in ("TOKEN", "PASSWORD", "AUTH", "CREDENTIAL")
            ):
                raise SystemExit("mock crane received credential-shaped environment")
            for name in ("HOME", "XDG_CONFIG_HOME", "DOCKER_CONFIG"):
                path = pathlib.Path(os.environ[name])
                if not path.is_dir() or (path.stat().st_mode & 0o777) != 0o700:
                    raise SystemExit("mock crane received a non-private " + name)
            docker = pathlib.Path(os.environ["DOCKER_CONFIG"]) / "config.json"
            if (
                docker.read_text(encoding="utf-8").strip() != "{}"
                or (docker.stat().st_mode & 0o777) != 0o600
            ):
                raise SystemExit("mock crane did not receive an empty credential root")
            operation = sys.argv[1] if len(sys.argv) > 1 else ""
            target = sys.argv[2] if len(sys.argv) > 2 else ""
            if operation == "digest":
                if sys.argv[1:] not in ([operation, __IMAGE__], [operation, __TAG__]):
                    raise SystemExit("unexpected crane argv")
            elif operation in {"manifest", "config"}:
                if sys.argv[1:] != [operation, __IMAGE__]:
                    raise SystemExit("unexpected crane argv")
            elif operation == "pull":
                if len(sys.argv) != 4 or sys.argv[2] != __IMAGE__:
                    raise SystemExit("unexpected crane pull argv")
            else:
                raise SystemExit("unexpected crane operation: " + operation)
            # Which of the resolver's two tag reads this is: the first happens
            # before the nested candidate proof, the second after it.
            tag_call = operation == "digest" and target == __TAG__
            tag_call_number = sum(
                line == "crane digest " + __TAG__
                for line in log.read_text(encoding="utf-8").splitlines()
            )
            if tag_call and state == "resolver-first-crane-failure" and tag_call_number == 1:
                print("resolver registry stderr canary", file=sys.stderr)
                raise SystemExit(23)
            if operation == "digest":
                if state == "candidate-wrong-digest" and target == __IMAGE__:
                    print("sha256:" + "e" * 64)
                elif tag_call and state == "resolver-malformed-digest":
                    print("not-a-digest")
                elif tag_call and state == "resolver-tag-moved" and tag_call_number == 2:
                    print("sha256:" + "e" * 64)
                else:
                    print(__DIGEST__)
            elif operation == "manifest":
                print((fixtures / "manifest.json").read_text(encoding="utf-8"))
            elif operation == "config":
                config = json.loads((fixtures / "config.json").read_text(encoding="utf-8"))
                if state in {"candidate-wrong-revision", "resolver-wrong-revision"}:
                    config["config"]["Labels"]["org.opencontainers.image.revision"] = "0" * 40
                print(json.dumps(config))
            elif operation == "pull":
                pathlib.Path(sys.argv[-1]).write_bytes(b"fixture image archive")
            """
        ),
    )

    write_fixture_executable(
        mock_bin / "kubectl-python",
        materialize(
            """
            #!__FIXTURE_PYTHON__
            import copy
            import hashlib
            import json
            import os
            import pathlib
            import sys

            fixtures = pathlib.Path(__FIXTURES__)
            state = pathlib.Path(__STATE__).read_text(encoding="utf-8").strip()
            with pathlib.Path(__LOG__).open("a", encoding="utf-8") as stream:
                stream.write("kubectl " + " ".join(sys.argv[1:]) + "\\n")
            args = sys.argv[1:]
            if args == ["kustomize", "k8s/web/greatfallstoolbus-org-production"]:
                rendered = (fixtures / "render.yaml").read_text(encoding="utf-8")
                kustomize_calls = sum(
                    line == "kubectl kustomize k8s/web/greatfallstoolbus-org-production"
                    for line in pathlib.Path(__LOG__).read_text(encoding="utf-8").splitlines()
                )
                if state == "render-missing-default-ingress" and kustomize_calls == 2:
                    rendered = "---\\n".join(
                        document
                        for document in rendered.split("---\\n")
                        if '"name": "default-deny-ingress"' not in document
                    )
                if state == "render-retained-legacy-egress" and kustomize_calls == 2:
                    rendered = rendered.replace(
                        '"name": "allow-egress-dns"',
                        '"name": "allow-egress-dns-retained"',
                        1,
                    )
                if state == "render-secret":
                    rendered += "---\\napiVersion: v1\\nkind: Secret\\nmetadata:\\n  name: injected\\n  namespace: greatfallstoolbus-org-production\\n"
                if state == "render-env-from":
                    rendered = rendered.replace(
                        "          securityContext:\\n",
                        "          envFrom:\\n            - secretRef:\\n                name: injected\\n          securityContext:\\n",
                        1,
                    )
                if state == "render-init-container":
                    rendered = rendered.replace(
                        "      containers:\\n",
                        "      initContainers:\\n        - name: injected\\n          image: busybox\\n      containers:\\n",
                        1,
                    )
                if state == "render-ephemeral-container":
                    rendered = rendered.replace(
                        "      containers:\\n",
                        "      ephemeralContainers:\\n        - name: injected\\n          image: busybox\\n      containers:\\n",
                        1,
                    )
                if state == "render-image-pull-secret":
                    rendered = rendered.replace(
                        "      containers:\\n",
                        "      imagePullSecrets:\\n        - name: injected\\n      containers:\\n",
                        1,
                    )
                if kustomize_calls == 2:
                    service_selector = (
                        "  selector:\\n"
                        "    app.kubernetes.io/name: greatfallstoolbus-org\\n"
                        "    app.kubernetes.io/component: web\\n"
                    )
                    if state == "render-service-selector":
                        service_prefix, service_suffix = rendered.rsplit(
                            service_selector, 1
                        )
                        rendered = (
                            service_prefix
                            + service_selector.replace(
                                "component: web", "component: rogue"
                            )
                            + service_suffix
                        )
                    if state == "render-service-protocol":
                        rendered = rendered.rsplit("      protocol: TCP", 1)[0] + (
                            "      protocol: UDP"
                            + rendered.rsplit("      protocol: TCP", 1)[1]
                        )
                    if state == "render-service-external":
                        rendered = rendered.replace(
                            "  type: ClusterIP\\n",
                            "  type: NodePort\\n",
                            1,
                        )
                    if state == "render-service-extra-key":
                        rendered = rendered.replace(
                            "  type: ClusterIP\\n",
                            "  type: ClusterIP\\n  sessionAffinity: None\\n",
                            1,
                        )
                sys.stdout.write(rendered)
                raise SystemExit(0)
            if len(args) < 2 or args[0] != "--kubeconfig":
                raise SystemExit("mock kubectl requires an explicit kubeconfig")
            kubeconfig = args[1]
            if not pathlib.Path(kubeconfig).is_file():
                raise SystemExit("mock kubectl received a missing kubeconfig")
            prefix = ["--kubeconfig", kubeconfig]
            namespace_prefix = prefix + [
                "--namespace", "greatfallstoolbus-org-production"
            ]
            ssrr_prefix = prefix + [
                "create",
                "--raw",
                "/apis/authorization.k8s.io/v1/selfsubjectrulesreviews",
                "-f",
            ]
            ssar_prefix = prefix + [
                "create",
                "--raw",
                "/apis/authorization.k8s.io/v1/selfsubjectaccessreviews",
                "-f",
            ]
            if args[: len(ssrr_prefix)] == ssrr_prefix and len(args) == len(ssrr_prefix) + 1:
                request = pathlib.Path(args[-1])
                expected_request = {
                    "apiVersion": "authorization.k8s.io/v1",
                    "kind": "SelfSubjectRulesReview",
                    "spec": {"namespace": "greatfallstoolbus-org-production"},
                }
                if (
                    json.loads(request.read_text(encoding="utf-8")) != expected_request
                    or (request.stat().st_mode & 0o777) != 0o600
                ):
                    raise SystemExit("mock kubectl rejected the SSRR request")
                value = json.loads((fixtures / "ssrr.json").read_text(encoding="utf-8"))
                if state == "kube-effective-extra-resource":
                    value["status"]["resourceRules"].append(
                        {
                            "apiGroups": ["batch"],
                            "resources": ["jobs"],
                            "verbs": ["get"],
                        }
                    )
                if state == "kube-ssrr-incomplete":
                    value["status"]["incomplete"] = True
                if state == "kube-ssrr-unrelated-url":
                    value["status"]["nonResourceRules"][0][
                        "nonResourceURLs"
                    ].append("/metrics")
                if state == "pinned-final-authority-drift":
                    value["status"]["nonResourceRules"][0]["verbs"].append("head")
                sys.stdout.write(json.dumps(value))
                raise SystemExit(0)
            if args[: len(ssar_prefix)] == ssar_prefix and len(args) == len(ssar_prefix) + 1:
                request = pathlib.Path(args[-1])
                value = json.loads(request.read_text(encoding="utf-8"))
                attributes = value.get("spec", {}).get("resourceAttributes", {})
                if (
                    value.get("apiVersion") != "authorization.k8s.io/v1"
                    or value.get("kind") != "SelfSubjectAccessReview"
                    or set(value) != {"apiVersion", "kind", "spec"}
                    or set(value.get("spec", {})) != {"resourceAttributes"}
                    or set(attributes) != {"verb", "group", "resource"}
                    or attributes.get("verb") not in {"approve", "attest", "sign"}
                    or attributes.get("group") != "certificates.k8s.io"
                    or attributes.get("resource") != "signers"
                    or (request.stat().st_mode & 0o777) != 0o600
                ):
                    raise SystemExit("mock kubectl rejected the raw SSAR request")
                verb = attributes["verb"]
                with pathlib.Path(__LOG__).open("a", encoding="utf-8") as stream:
                    stream.write(
                        "raw-ssar "
                        + verb
                        + " certificates.k8s.io signers\\n"
                    )
                if state == "kube-raw-ssar-transport-error" and verb == "approve":
                    sys.stderr.write("mock raw SSAR transport failure\\n")
                    raise SystemExit(2)
                allowed = state == "kube-allows-signer" and verb == "approve"
                response = {
                    "apiVersion": "authorization.k8s.io/v1",
                    "kind": "SelfSubjectAccessReview",
                    "status": {
                        "allowed": allowed,
                        "denied": not allowed,
                        "evaluationError": "",
                    },
                }
                if state == "kube-raw-ssar-malformed" and verb == "approve":
                    response["status"]["evaluationError"] = "fixture error"
                sys.stdout.write(json.dumps(response))
                raise SystemExit(0)
            discovery_prefix = prefix + ["api-resources", "--cached=false"]
            if args[: len(discovery_prefix)] == discovery_prefix:
                if len(args) != len(discovery_prefix) + 4:
                    raise SystemExit("mock kubectl rejected malformed discovery argv")
                scope_arg, verb_arg, output_flag, output_value = args[len(discovery_prefix) :]
                if (
                    scope_arg not in {"--namespaced=true", "--namespaced=false"}
                    or not verb_arg.startswith("--verbs=")
                    or verb_arg.removeprefix("--verbs=")
                    not in {"create", "update", "patch", "delete", "deletecollection"}
                    or [output_flag, output_value] != ["-o", "name"]
                ):
                    raise SystemExit("mock kubectl rejected malformed discovery argv")
                verb = verb_arg.removeprefix("--verbs=")
                if scope_arg == "--namespaced=true":
                    resources = ["deployments.apps", "jobs.batch"]
                    if verb == "update":
                        resources.append("pods/exec")
                    if verb == "create":
                        resources.append("deployments/scale.apps")
                else:
                    resources = ["namespaces"]
                    if verb == "create":
                        resources.extend(
                            [
                                "selfsubjectaccessreviews.authorization.k8s.io",
                                "selfsubjectrulesreviews.authorization.k8s.io",
                                "selfsubjectreviews.authentication.k8s.io",
                            ]
                        )
                sys.stdout.write("\\n".join(resources) + "\\n")
                raise SystemExit(0)

            auth_args = args[len(prefix) :]
            if auth_args[:2] == ["auth", "can-i"]:
                scoped_args = auth_args[2:]
                scope = None
                if scoped_args[-2:] == [
                    "--namespace",
                    "greatfallstoolbus-org-production",
                ]:
                    scoped_args = scoped_args[:-2]
                    scope = "namespaced"
                elif scoped_args[-1:] == [
                    "--namespace=greatfallstoolbus-org-production"
                ]:
                    scoped_args = scoped_args[:-1]
                    scope = "namespaced"
                elif scoped_args[-1:] == ["--all-namespaces"]:
                    scoped_args = scoped_args[:-1]
                    scope = "cluster"
                if scope is None or len(scoped_args) not in {2, 3}:
                    raise SystemExit("mock kubectl rejected malformed auth can-i argv")
                verb, resource = scoped_args[:2]
                subresource = None
                if len(scoped_args) == 3:
                    if not scoped_args[2].startswith("--subresource="):
                        raise SystemExit(
                            "mock kubectl rejected malformed auth subresource argv"
                        )
                    subresource = scoped_args[2].removeprefix("--subresource=")
                    if not subresource:
                        raise SystemExit(
                            "mock kubectl rejected malformed auth subresource target"
                        )
                resource_parts = resource.split("/", 1)
                base_resource = resource_parts[0]
                resource_name = (
                    resource_parts[1] if len(resource_parts) == 2 else None
                )
                if resource_name == "":
                    raise SystemExit("mock kubectl rejected an empty resource name")
                allowed = (
                    resource_name is None
                    and subresource is None
                    and (scope, verb, base_resource) in {
                    ("namespaced", "get", "deployments"),
                    ("namespaced", "list", "replicasets"),
                    ("namespaced", "list", "pods"),
                    ("namespaced", "get", "services"),
                    ("namespaced", "list", "endpointslices.discovery.k8s.io"),
                    (
                        "namespaced",
                        "list",
                        "networkpolicies.networking.k8s.io",
                    ),
                    ("cluster", "get", "namespaces"),
                    (
                        "cluster",
                        "create",
                        "selfsubjectaccessreviews.authorization.k8s.io",
                    ),
                    (
                        "cluster",
                        "create",
                        "selfsubjectrulesreviews.authorization.k8s.io",
                    ),
                    (
                        "cluster",
                        "create",
                        "selfsubjectreviews.authentication.k8s.io",
                    ),
                    }
                )
                if state == "kube-allows-patch" and (
                    verb,
                    base_resource,
                ) in {("patch", "deployments"), ("patch", "deployments.apps")}:
                    allowed = True
                if state == "kube-allows-job-create" and (
                    verb,
                    base_resource,
                ) == ("create", "jobs.batch"):
                    allowed = True
                if state == "kube-allows-scale" and (
                    verb,
                    base_resource,
                    subresource,
                ) == (
                    "patch",
                    "deployments",
                    "scale",
                ) and resource_name is None:
                    allowed = True
                if state == "kube-allows-ephemeral" and (
                    verb,
                    base_resource,
                    subresource,
                ) == (
                    "update",
                    "pods",
                    "ephemeralcontainers",
                ) and resource_name is None:
                    allowed = True
                if state == "kube-allows-bind" and (verb, resource) == (
                    "bind",
                    "roles.rbac.authorization.k8s.io",
                ) and resource_name is None:
                    allowed = True
                if state == "kube-allows-exec" and (
                    verb,
                    base_resource,
                    subresource,
                ) == (
                    "create",
                    "pods",
                    "exec",
                ) and resource_name is None:
                    allowed = True
                if state == "kube-subresource-transport-error" and (
                    verb,
                    base_resource,
                    subresource,
                ) == ("create", "pods", "exec") and resource_name is None:
                    sys.stderr.write("mock authorization transport failure\\n")
                    raise SystemExit(2)
                if state == "kube-allows-named-deployment" and (
                    scope,
                    verb,
                    base_resource,
                    resource_name,
                    subresource,
                ) == (
                    "namespaced",
                    "patch",
                    "deployments.apps",
                    "greatfallstoolbus-org",
                    None,
                ):
                    allowed = True
                if state == "kube-allows-named-service-proxy" and (
                    scope,
                    verb,
                    base_resource,
                    resource_name,
                    subresource,
                ) == (
                    "namespaced",
                    "create",
                    "services",
                    "greatfallstoolbus-org",
                    "proxy",
                ):
                    allowed = True
                if state == "kube-named-auth-transport-error" and (
                    scope,
                    verb,
                    base_resource,
                    resource_name,
                    subresource,
                ) == (
                    "namespaced",
                    "update",
                    "deployments.apps",
                    "greatfallstoolbus-org",
                    None,
                ):
                    sys.stderr.write("mock named authorization transport failure\\n")
                    raise SystemExit(2)
                if state == "pinned-allows-observed-pod-patch" and (
                    scope,
                    verb,
                    base_resource,
                    resource_name,
                    subresource,
                ) == (
                    "namespaced",
                    "patch",
                    "pods",
                    "greatfallstoolbus-org-abc123-1",
                    None,
                ):
                    allowed = True
                if state == "pinned-allows-observed-pod-exec" and (
                    scope,
                    verb,
                    base_resource,
                    resource_name,
                    subresource,
                ) == (
                    "namespaced",
                    "create",
                    "pods",
                    "greatfallstoolbus-org-abc123-1",
                    "exec",
                ):
                    allowed = True
                if state == "pinned-named-auth-transport-error" and (
                    scope,
                    verb,
                    base_resource,
                    resource_name,
                    subresource,
                ) == (
                    "namespaced",
                    "update",
                    "pods",
                    "greatfallstoolbus-org-abc123-1",
                    None,
                ):
                    sys.stderr.write("mock named authorization transport failure\\n")
                    raise SystemExit(2)
                if state == "kube-allows-wildcard" and (verb, resource) == (
                    "*",
                    "*",
                ):
                    allowed = True
                sys.stdout.write("yes\\n" if allowed else "no\\n")
                raise SystemExit(0 if allowed else 1)
            if args == prefix + [
                "get", "namespace", "kube-system", "-o", "jsonpath={.metadata.uid}"
            ]:
                value = (
                    "00000000-0000-4000-8000-000000000000"
                    if state == "kube-wrong-cluster"
                    else "cc121476-7a95-4b24-aa61-79d1f45713bd"
                )
                sys.stdout.write(value)
                raise SystemExit(0)
            if args == namespace_prefix + [
                "get", "deployment/greatfallstoolbus-org", "-o", "json"
            ]:
                value = json.loads((fixtures / "deployment.json").read_text(encoding="utf-8"))
                deployment_calls = sum(
                    " get deployment/greatfallstoolbus-org -o json" in line
                    for line in pathlib.Path(__LOG__).read_text(encoding="utf-8").splitlines()
                )
                if state == "pinned-final-degraded" and deployment_calls == 2:
                    value["status"]["readyReplicas"] = 1
                    value["status"]["availableReplicas"] = 1
                    value["status"]["unavailableReplicas"] = 1
                if state == "pinned-privileged":
                    value["spec"]["template"]["spec"]["containers"][0]["securityContext"]["privileged"] = True
                if state == "pinned-capabilities-add":
                    value["spec"]["template"]["spec"]["containers"][0]["securityContext"]["capabilities"]["add"] = ["NET_ADMIN"]
                if state == "pinned-host-network":
                    value["spec"]["template"]["spec"]["hostNetwork"] = True
                if state == "pinned-host-port":
                    value["spec"]["template"]["spec"]["containers"][0]["ports"] = [{"name": "http", "containerPort": 3000, "hostPort": 3000}]
                sys.stdout.write(json.dumps(value))
                raise SystemExit(0)
            if args == namespace_prefix + ["get", "replicasets", "-o", "json"]:
                value = json.loads((fixtures / "replicasets.json").read_text(encoding="utf-8"))
                replica_set_calls = sum(
                    " get replicasets -o json" in line
                    for line in pathlib.Path(__LOG__).read_text(encoding="utf-8").splitlines()
                )
                if state == "pinned-old-rs-live":
                    value["items"][1]["spec"]["replicas"] = 1
                    value["items"][1]["status"]["replicas"] = 1
                if state == "pinned-duplicate-active-rs":
                    duplicate = copy.deepcopy(value["items"][0])
                    duplicate["metadata"]["name"] += "-duplicate"
                    duplicate["metadata"]["uid"] = "66666666-6666-4666-8666-666666666666"
                    value["items"].append(duplicate)
                if state == "pinned-list-envelope-drift" and replica_set_calls == 2:
                    value["metadata"] = {"resourceVersion": "fixture-rs-list-drift"}
                sys.stdout.write(json.dumps(value))
                raise SystemExit(0)
            if args == namespace_prefix + [
                "get", "service/greatfallstoolbus-org", "-o", "json"
            ]:
                value = json.loads((fixtures / "service.json").read_text(encoding="utf-8"))
                service_calls = sum(
                    " get service/greatfallstoolbus-org -o json" in line
                    for line in pathlib.Path(__LOG__).read_text(encoding="utf-8").splitlines()
                )
                if state == "pinned-service-divergence":
                    value["spec"]["ports"][0]["targetPort"] = "wrong"
                if state == "pinned-final-service-drift" and service_calls == 2:
                    value["spec"]["clusterIP"] = "10.96.0.81"
                sys.stdout.write(json.dumps(value))
                raise SystemExit(0)
            if args == namespace_prefix + [
                "get",
                "endpointslices.discovery.k8s.io",
                "--selector",
                "kubernetes.io/service-name=greatfallstoolbus-org",
                "-o",
                "json",
            ]:
                value = json.loads((fixtures / "endpointslices.json").read_text(encoding="utf-8"))
                endpoint_calls = sum(
                    " get endpointslices.discovery.k8s.io " in line
                    for line in pathlib.Path(__LOG__).read_text(encoding="utf-8").splitlines()
                )
                if state == "pinned-rogue-endpoint-ip":
                    value["items"][0]["endpoints"][0]["addresses"] = ["10.0.0.99"]
                if state == "pinned-deleting-endpoint-slice":
                    value["items"][0]["metadata"]["deletionTimestamp"] = (
                        "2026-08-17T21:00:00Z"
                    )
                    value["items"][0]["metadata"]["finalizers"] = [
                        "discovery.kubernetes.io/endpoint-slice-cleanup"
                    ]
                if state == "pinned-final-endpoint-drift" and endpoint_calls == 2:
                    value["items"][0]["endpoints"][0]["conditions"]["ready"] = False
                if state == "pinned-list-envelope-drift" and endpoint_calls == 2:
                    value["metadata"] = {"resourceVersion": "fixture-eps-list-drift"}
                sys.stdout.write(json.dumps(value))
                raise SystemExit(0)
            if args == namespace_prefix + ["get", "pods", "-o", "json"]:
                value = json.loads((fixtures / "pods.json").read_text(encoding="utf-8"))
                pod_calls = sum(
                    " get pods -o json" in line
                    for line in pathlib.Path(__LOG__).read_text(encoding="utf-8").splitlines()
                )
                if state == "pinned-restart":
                    value["items"][0]["status"]["containerStatuses"][0]["restartCount"] = 1
                if state == "pinned-wrong-image-id":
                    value["items"][0]["status"]["containerStatuses"][0]["imageID"] = "ghcr.io/great-falls-tool-bus/gftb-site@sha256:" + "f" * 64
                if state == "pinned-extra-labeled-pod":
                    extra = copy.deepcopy(value["items"][0])
                    extra["metadata"]["name"] = "greatfallstoolbus-org-foreign"
                    extra["metadata"]["uid"] = "55555555-5555-4555-8555-555555555555"
                    extra["metadata"]["ownerReferences"][0]["uid"] = "33333333-3333-4333-8333-333333333333"
                    value["items"].append(extra)
                if state == "pinned-list-envelope-drift" and pod_calls == 2:
                    value["metadata"] = {"resourceVersion": "fixture-pod-list-drift"}
                if state == "pinned-final-pod-resource-version-drift" and pod_calls == 2:
                    value["items"][0]["metadata"]["resourceVersion"] = "fixture-object-drift"
                sys.stdout.write(json.dumps(value))
                raise SystemExit(0)
            if args == namespace_prefix + [
                "get", "networkpolicies.networking.k8s.io", "-o", "json"
            ]:
                value = json.loads(
                    (fixtures / "networkpolicies.json").read_text(encoding="utf-8")
                )
                policy_calls = sum(
                    " get networkpolicies.networking.k8s.io -o json" in line
                    for line in pathlib.Path(__LOG__).read_text(encoding="utf-8").splitlines()
                )
                if state == "pinned-network-policy-content":
                    value["items"][0]["spec"]["ingress"][0]["ports"][0]["port"] = 3001
                if state == "pinned-network-policy-missing-deny":
                    value["items"] = [
                        policy
                        for policy in value["items"]
                        if policy["metadata"]["name"] != "default-deny-egress"
                    ]
                if state == "pinned-network-policy-retained-legacy":
                    legacy = json.loads(
                        (fixtures / "render-base-networkpolicies.json").read_text(
                            encoding="utf-8"
                        )
                    )
                    value["items"].append(
                        next(
                            policy
                            for policy in legacy["items"]
                            if policy["metadata"]["name"] == "allow-egress-dns"
                        )
                    )
                if state == "pinned-network-policy-permissive-egress":
                    next(
                        policy
                        for policy in value["items"]
                        if policy["metadata"]["name"] == "default-deny-egress"
                    )["spec"]["egress"] = [{}]
                if state == "pinned-network-policy-wrong-selector":
                    next(
                        policy
                        for policy in value["items"]
                        if policy["metadata"]["name"] == "default-deny-egress"
                    )["spec"]["podSelector"] = {}
                if state == "pinned-final-network-policy-drift" and policy_calls == 2:
                    value["items"][0]["spec"]["ingress"][0]["ports"][0]["port"] = 3001
                if state == "pinned-list-envelope-drift" and policy_calls == 2:
                    value["metadata"] = {"resourceVersion": "fixture-np-list-drift"}
                sys.stdout.write(json.dumps(value))
                raise SystemExit(0)
            # --- the mutating half (web-release-apply / the legacy interlock) ---
            interlock_jsonpath = (
                "jsonpath={.spec.template.spec.containers"
                '[?(@.name=="greatfallstoolbus-org")].image}'
            )
            if args == namespace_prefix + [
                "get",
                "deployment/greatfallstoolbus-org",
                "--ignore-not-found",
                "-o",
                interlock_jsonpath,
            ]:
                if state == "stack-live-absent":
                    sys.stdout.write("")
                elif state == "stack-live-promoted":
                    sys.stdout.write(__IMAGE__)
                else:
                    sys.stdout.write(
                        "ghcr.io/great-falls-tool-bus/greatfallstoolbus.org@sha256:"
                        + "9" * 64
                    )
                raise SystemExit(0)
            if args[: len(namespace_prefix) + 1] == namespace_prefix + ["apply"]:
                apply_args = args[len(namespace_prefix) + 1 :]
                dry_run = apply_args[:1] == ["--dry-run=server"]
                if dry_run:
                    apply_args = apply_args[1:]
                if len(apply_args) != 2 or apply_args[0] != "-f":
                    raise SystemExit("mock kubectl rejected unexpected apply argv")
                plan = pathlib.Path(apply_args[1])
                if not plan.is_file() or (plan.stat().st_mode & 0o777) != 0o600:
                    raise SystemExit(
                        "mock kubectl received a missing or world-readable plan"
                    )
                recorded_digest = (
                    (plan.parent / "web-release.render-sha256")
                    .read_text(encoding="utf-8")
                    .strip()
                )
                if (
                    hashlib.sha256(plan.read_bytes()).hexdigest()
                    != recorded_digest
                ):
                    raise SystemExit("mock kubectl received unrecorded bytes")
                sys.stdout.write(
                    "deployment.apps/greatfallstoolbus-org configured"
                    + (" (server dry run)" if dry_run else "")
                    + "\\n"
                )
                raise SystemExit(0)
            if args == namespace_prefix + [
                "delete",
                "networkpolicy",
                "allow-egress-dns",
                "allow-egress-discuss-archive",
                "--ignore-not-found",
            ]:
                if state == "apply-delete-fails":
                    sys.stderr.write(
                        'Error from server (Forbidden): networkpolicies '
                        '"allow-egress-dns" is forbidden\\n'
                    )
                    raise SystemExit(1)
                sys.stdout.write(
                    'networkpolicy.networking.k8s.io "allow-egress-dns" deleted\\n'
                )
                raise SystemExit(0)
            if args == namespace_prefix + [
                "rollout",
                "status",
                "deployment/greatfallstoolbus-org",
                "--timeout=300s",
            ]:
                sys.stdout.write(
                    'deployment "greatfallstoolbus-org" successfully rolled out\\n'
                )
                raise SystemExit(0)
            raise SystemExit("mock kubectl rejected unexpected argv: " + " ".join(args))
            """
        ),
    )

    # Authorization dominates this fixture's call volume. Keep those hundreds
    # of exact yes/no checks in a fail-closed Bash front end so the self-test
    # remains practical; all object/discovery/raw-review behavior stays in the
    # stricter Python backend below it.
    write_fixture_executable(
        mock_bin / "kubectl",
        materialize(
            """
            #!__FIXTURE_BASH__
            set -euo pipefail
            if [[ "$#" -ge 4 && "$1" == "--kubeconfig" && -f "$2" && "$3" == "auth" && "$4" == "can-i" ]]; then
              {
                printf 'kubectl'
                printf ' %s' "$@"
                printf '\\n'
              } >> __LOG__
              state="$(< __STATE__)"
              shift 4
              [[ "$#" -ge 3 ]] || { echo "mock kubectl rejected malformed auth can-i argv" >&2; exit 2; }
              verb="$1"
              resource="$2"
              shift 2
              subresource=""
              if [[ "$1" == --subresource=* ]]; then
                subresource="${1#--subresource=}"
                [[ -n "${subresource}" ]] || { echo "mock kubectl rejected an empty auth subresource" >&2; exit 2; }
                shift
              fi
              scope=""
              if [[ "$#" -eq 2 && "$1" == "--namespace" && "$2" == "greatfallstoolbus-org-production" ]]; then
                scope="namespaced"
              elif [[ "$#" -eq 1 && "$1" == "--namespace=greatfallstoolbus-org-production" ]]; then
                scope="namespaced"
              elif [[ "$#" -eq 1 && "$1" == "--all-namespaces" ]]; then
                scope="cluster"
              else
                echo "mock kubectl rejected malformed or non-tail auth scope argv" >&2
                exit 2
              fi
              base_resource="${resource%%/*}"
              resource_name=""
              if [[ "${resource}" == */* ]]; then
                resource_name="${resource#*/}"
                [[ -n "${resource_name}" ]] || { echo "mock kubectl rejected an empty resource name" >&2; exit 2; }
              fi
              allowed=0
              if [[ -z "${resource_name}" && -z "${subresource}" ]]; then
                case "${scope}:${verb}:${base_resource}" in
                  namespaced:get:deployments|namespaced:list:replicasets|namespaced:list:pods|namespaced:get:services|namespaced:list:endpointslices.discovery.k8s.io|namespaced:list:networkpolicies.networking.k8s.io|cluster:get:namespaces|cluster:create:selfsubjectaccessreviews.authorization.k8s.io|cluster:create:selfsubjectrulesreviews.authorization.k8s.io|cluster:create:selfsubjectreviews.authentication.k8s.io) allowed=1 ;;
                esac
              fi
              if [[ "${state}" == "kube-allows-patch" && "${verb}" == "patch" && ( "${base_resource}" == "deployments" || "${base_resource}" == "deployments.apps" ) && -z "${resource_name}" && -z "${subresource}" ]]; then allowed=1; fi
              if [[ "${state}" == "kube-allows-job-create" && "${verb}:${base_resource}" == "create:jobs.batch" && -z "${resource_name}" && -z "${subresource}" ]]; then allowed=1; fi
              if [[ "${state}" == "kube-allows-scale" && "${verb}" == "patch" && ( "${base_resource}" == "deployments" || "${base_resource}" == "deployments.apps" ) && "${subresource}" == "scale" && -z "${resource_name}" ]]; then allowed=1; fi
              if [[ "${state}" == "kube-allows-ephemeral" && "${verb}:${base_resource}:${subresource}" == "update:pods:ephemeralcontainers" && -z "${resource_name}" ]]; then allowed=1; fi
              if [[ "${state}" == "kube-allows-bind" && "${verb}:${resource}" == "bind:roles.rbac.authorization.k8s.io" ]]; then allowed=1; fi
              if [[ "${state}" == "kube-allows-exec" && "${verb}:${base_resource}:${subresource}" == "create:pods:exec" && -z "${resource_name}" ]]; then allowed=1; fi
              if [[ "${state}" == "kube-subresource-transport-error" && "${verb}:${base_resource}:${subresource}" == "create:pods:exec" && -z "${resource_name}" ]]; then echo "mock authorization transport failure" >&2; exit 2; fi
              if [[ "${state}" == "kube-allows-named-deployment" && "${scope}:${verb}:${base_resource}:${resource_name}:${subresource}" == "namespaced:patch:deployments.apps:greatfallstoolbus-org:" ]]; then allowed=1; fi
              if [[ "${state}" == "kube-allows-named-service-proxy" && "${scope}:${verb}:${base_resource}:${resource_name}:${subresource}" == "namespaced:create:services:greatfallstoolbus-org:proxy" ]]; then allowed=1; fi
              if [[ "${state}" == "kube-named-auth-transport-error" && "${scope}:${verb}:${base_resource}:${resource_name}:${subresource}" == "namespaced:update:deployments.apps:greatfallstoolbus-org:" ]]; then echo "mock named authorization transport failure" >&2; exit 2; fi
              if [[ "${state}" == "pinned-allows-observed-pod-patch" && "${scope}:${verb}:${base_resource}:${resource_name}:${subresource}" == "namespaced:patch:pods:greatfallstoolbus-org-abc123-1:" ]]; then allowed=1; fi
              if [[ "${state}" == "pinned-allows-observed-pod-exec" && "${scope}:${verb}:${base_resource}:${resource_name}:${subresource}" == "namespaced:create:pods:greatfallstoolbus-org-abc123-1:exec" ]]; then allowed=1; fi
              if [[ "${state}" == "pinned-named-auth-transport-error" && "${scope}:${verb}:${base_resource}:${resource_name}:${subresource}" == "namespaced:update:pods:greatfallstoolbus-org-abc123-1:" ]]; then echo "mock named authorization transport failure" >&2; exit 2; fi
              if [[ "${state}" == "kube-allows-wildcard" && "${verb}:${resource}" == "*:*" ]]; then allowed=1; fi
              # The APPLY identity's grant matrix. Scoped to apply-* states so it
              # cannot loosen the proof-only identity the mutation-denial proof
              # depends on.
              if [[ "${state}" == apply-* && "${scope}" == "namespaced" && -z "${resource_name}" && -z "${subresource}" ]]; then
                case "${verb}:${base_resource}" in
                  get:deployments.apps|list:deployments.apps|watch:deployments.apps|create:deployments.apps|update:deployments.apps|patch:deployments.apps|get:services|create:services|update:services|patch:services|get:networkpolicies.networking.k8s.io|create:networkpolicies.networking.k8s.io|update:networkpolicies.networking.k8s.io|patch:networkpolicies.networking.k8s.io|delete:networkpolicies.networking.k8s.io) allowed=1 ;;
                esac
              fi
              if [[ "${state}" == "apply-authz-denied-delete" && "${verb}:${base_resource}" == "delete:networkpolicies.networking.k8s.io" ]]; then allowed=0; fi
              if [[ "${state}" == "apply-authz-denied-create-policy" && "${verb}:${base_resource}" == "create:networkpolicies.networking.k8s.io" ]]; then allowed=0; fi
              if [[ "${state}" == "apply-authz-transport-error" && "${verb}:${base_resource}" == "delete:networkpolicies.networking.k8s.io" ]]; then echo "mock authorization transport failure" >&2; exit 2; fi
              if [[ "${allowed}" -eq 1 ]]; then printf 'yes\\n'; exit 0; fi
              printf 'no\\n'
              exit 1
            fi
            exec __KUBECTL_BACKEND__ "$@"
            """
        ),
    )

    write_fixture_executable(
        mock_bin / "curl",
        materialize(
            """
            #!__FIXTURE_PYTHON__
            import pathlib
            import sys
            from urllib.parse import quote, urlsplit

            state = pathlib.Path(__STATE__).read_text(encoding="utf-8").strip()
            with pathlib.Path(__LOG__).open("a", encoding="utf-8") as stream:
                stream.write("curl " + " ".join(sys.argv[1:]) + "\\n")
            args = sys.argv[1:]
            expected_prefix = [
                "--disable", "--silent", "--show-error",
                "--connect-timeout", "10", "--max-time", "20",
                "--max-filesize", "1048576", "--max-redirs", "0", "--output",
            ]
            if args[:12] != expected_prefix or len(args) not in {18, 20}:
                raise SystemExit("mock curl rejected unsafe or unexpected argv")
            body = pathlib.Path(args[12])
            if args[13] != "--dump-header" or args[15:17] != ["--write-out", "%{http_code}"]:
                raise SystemExit("mock curl rejected output argv")
            headers = pathlib.Path(args[14])
            if len(args) == 20:
                cookie = pathlib.Path(args[18])
                if (
                    args[17] != "--cookie"
                    or not cookie.is_file()
                    or cookie.name != "access.cookies"
                    or (cookie.stat().st_mode & 0o777) != 0o600
                ):
                    raise SystemExit("mock curl rejected cookie argv")
                authenticated = True
            else:
                authenticated = False
            url = args[-1]
            parsed = urlsplit(url)
            if parsed.scheme != "https" or parsed.netloc != "greatfallstoolbus.org":
                raise SystemExit("mock curl rejected unexpected origin")
            if not authenticated and state.startswith("served-gated"):
                host = (
                    "evil.example"
                    if state == "served-gated-unsafe-redirect"
                    else "sulliwood.cloudflareaccess.com"
                )
                login_path = (
                    "/cdn-cgi/access/login/greatfallstoolbus.org.evil"
                    if state == "served-gated-prefix-suffix"
                    else "/cdn-cgi/access/login/greatfallstoolbus.org"
                )
                location = (
                    "https://" + host + login_path + "?redirect_url="
                    + quote(parsed.path, safe="")
                )
                body.write_bytes(b"")
                header = "HTTP/1.1 302 Found\\r\\nLocation: " + location + "\\r\\n"
                if state == "served-gated-duplicate-location":
                    header += "Location: " + location + "\\r\\n"
                headers.write_text(header + "\\r\\n", encoding="utf-8")
                sys.stdout.write("302")
                raise SystemExit(0)
            payloads = {
                "/": b"<!doctype html><title>Great Falls Tool Bus</title>",
                "/health": b"ok",
                "/health.sha": __SHA__.encode("ascii"),
                "/qr/greatfallstoolbus-apex.svg": b"<svg xmlns='http://www.w3.org/2000/svg'></svg>",
            }
            payload = payloads.get(parsed.path)
            if payload is None:
                raise SystemExit("mock curl rejected unexpected path: " + parsed.path)
            if state == "served-wrong-sha" and parsed.path == "/health.sha":
                payload = b"0" * 40
            if state == "served-health-newline" and parsed.path == "/health":
                payload += b"\\n"
            body.write_bytes(payload)
            content_type = "image/svg+xml" if parsed.path.endswith(".svg") else "text/plain"
            if state == "served-wrong-qr-type" and parsed.path.endswith(".svg"):
                content_type = "text/html"
            headers.write_text(
                "HTTP/1.1 200 OK\\r\\nContent-Type: " + content_type + "\\r\\n\\r\\n",
                encoding="utf-8",
            )
            sys.stdout.write("200")
            """
        ),
    )

    write_fixture_executable(
        mock_bin / "just",
        materialize(
            """
            #!__FIXTURE_PYTHON__
            import os
            import pathlib
            import sys

            with pathlib.Path(__LOG__).open("a", encoding="utf-8") as stream:
                stream.write("nested-just " + " ".join(sys.argv[1:]) + "\\n")
            state = pathlib.Path(__STATE__).read_text(encoding="utf-8").strip()
            toplevel = pathlib.Path(__TOPLEVEL__).read_text(encoding="utf-8").strip()
            def child(recipe):
                return [
                    "--justfile",
                    str(pathlib.Path(toplevel) / "Justfile"),
                    "--working-directory",
                    toplevel,
                    recipe,
                ]
            helper_argv = child("_web-release-kubeconfig-inputs")
            render_argv = child("web-release-render")
            if sys.argv[1:] == helper_argv and state.startswith("pinned-"):
                print(
                    "reviewed stable web release-object mutation denial: "
                    "Honey/greatfallstoolbus-org-production authority="
                    + __AUTHORITY_DIGEST__
                )
                raise SystemExit(0)
            # web-release-resolve-candidate re-enters the reviewed proof by bare
            # recipe name; the mock forwards exactly that argv and nothing wider.
            # The silent-callee state stands in for a renamed or skipped recipe
            # that exits 0 without running (JUST_ALLOW_MISSING and friends): the
            # resolver must notice the missing proof receipt rather than trust
            # the exit status.
            if (
                sys.argv[1:] == ["web-release-candidate-proof"]
                and state == "resolver-silent-callee"
            ):
                raise SystemExit(0)
            if sys.argv[1:] in (
                ["web-stack-validate"],
                ["web-release-candidate-proof"],
                helper_argv,
                render_argv,
            ):
                os.execv(__REAL_JUST__, [__REAL_JUST__, *sys.argv[1:]])
            raise SystemExit("mock nested just rejected unexpected argv")
            """
        ),
    )
    write_fixture_executable(
        mock_bin / "git",
        materialize(
            """
            #!__FIXTURE_PYTHON__
            import pathlib
            import sys

            with pathlib.Path(__LOG__).open("a", encoding="utf-8") as stream:
                stream.write("git " + " ".join(sys.argv[1:]) + "\\n")
            toplevel = pathlib.Path(__TOPLEVEL__).read_text(encoding="utf-8").strip()
            head = "1" * 40
            canonical = (
                "https://github.com/Great-Falls-Tool-Bus/"
                "great-falls-tool-bus-infra.git"
            )
            args = sys.argv[1:]
            if args[:2] == ["-C", toplevel]:
                args = args[2:]
            if args == ["rev-parse", "--show-toplevel"]:
                print(toplevel)
            elif args in (["rev-parse", "HEAD"], ["rev-parse", "origin/main"]):
                print(head)
            elif args == ["branch", "--show-current"]:
                print("main")
            elif args in (["status", "--porcelain"], ["ls-files", "-v"]):
                pass
            elif args == ["remote", "get-url", "origin"]:
                print(canonical)
            elif args == [
                "show-ref", "--verify", "--quiet", "refs/remotes/origin/main"
            ]:
                pass
            elif args[:2] == ["ls-remote", "--exit-code"] and args[3:] == [
                "refs/heads/main"
            ]:
                print(head + "\\trefs/heads/main")
            elif args == ["verify-commit", head]:
                pass
            else:
                raise SystemExit(
                    "mock git rejected unexpected argv: " + " ".join(sys.argv[1:])
                )
            """
        ),
    )
    return mock_bin, state_path, log_path, toplevel_path


def expect_web_release_fixture_result(
    just_binary: str,
    recipe: str,
    state_path: Path,
    log_path: Path,
    environment: dict[str, str],
    state: str,
    *,
    success: bool,
    diagnostic: str,
) -> subprocess.CompletedProcess[str]:
    state_path.write_text(state + "\n", encoding="utf-8")
    log_path.write_text("", encoding="utf-8")
    result = subprocess.run(
        [just_binary, recipe],
        cwd=REPO,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
        timeout=240,
    )
    output = result.stdout + result.stderr
    if success and result.returncode != 0:
        raise SystemExit(
            f"self-test FAILED: valid {recipe} fixture was rejected in state "
            f"{state!r}: {output.strip()!r}"
        )
    if not success and result.returncode == 0:
        raise SystemExit(
            f"self-test FAILED: {recipe} accepted adversarial state {state!r}"
        )
    if diagnostic not in output:
        raise SystemExit(
            f"self-test FAILED: {recipe} state {state!r} did not emit "
            f"{diagnostic!r}: {output.strip()!r}"
        )
    return result


def run_web_release_semantic_fixtures() -> None:
    just_binary = shutil.which("just")
    if just_binary is None:
        raise SystemExit("self-test FAILED: just is required for release fixtures")
    with tempfile.TemporaryDirectory(
        prefix="gftb-web-release-selftest."
    ) as directory:
        root = Path(directory)
        mock_bin, state_path, log_path, _ = install_web_release_fixture_mocks(
            root
        )
        home = root / "home"
        temporary = root / "tmp"
        home.mkdir(mode=0o700)
        temporary.mkdir(mode=0o700)
        kubeconfig = root / "web-release.kubeconfig"
        kubeconfig.write_text(
            textwrap.dedent(
                """\
                apiVersion: v1
                kind: Config
                preferences: {}
                clusters:
                  - name: honey
                    cluster:
                      server: https://127.0.0.1:9
                      certificate-authority-data: Y2VydGlmaWNhdGUtZGF0YQ==
                contexts:
                  - name: honey-web-readonly
                    context:
                      cluster: honey
                      user: web-readonly
                      namespace: greatfallstoolbus-org-production
                current-context: honey-web-readonly
                users:
                  - name: web-readonly
                    user:
                      token: aaaaaaaaaa.bbbbbbbbbb.cccccccccc
                """
            ),
            encoding="utf-8",
        )
        kubeconfig.chmod(0o600)
        cookie = root / "access.cookies"
        cookie.write_text("# fixture cookie; mock curl only\n", encoding="utf-8")
        cookie.chmod(0o600)
        function_marker = root / "imported-shell-function-ran"
        startup_poison = root / "startup-poison.sh"
        startup_poison.write_text(
            "printf '%s' startup > " + shlex.quote(str(function_marker)) + "\n",
            encoding="utf-8",
        )
        startup_poison.chmod(0o600)
        poison_environment = {
            "BASH_ENV": str(startup_poison),
            "ENV": str(startup_poison),
        }
        for command in (
            "env",
            "kubectl",
            "curl",
            "crane",
            "yq",
            "jq",
            "python3",
            "git",
            "just",
            "mktemp",
        ):
            poison_environment[f"BASH_FUNC_{command}%%"] = (
                "() { printf '%s' "
                + shlex.quote(command)
                + " > "
                + shlex.quote(str(function_marker))
                + f"; unset -f {command}; command {command} \"$@\"; }}"
            )
        base_environment = {
            "PATH": str(mock_bin),
            "HOME": str(home),
            "TMPDIR": str(temporary),
            "LANG": "C",
            "LC_ALL": "C",
            "WEB_APPLY_IMAGE": WEB_RELEASE_FIXTURE_IMAGE,
            "WEB_APPLY_SHA": WEB_RELEASE_FIXTURE_SHA,
            "WEB_APPLY_REPLICAS": "2",
            "WEB_RELEASE_KUBECONFIG": str(kubeconfig),
            **poison_environment,
        }

        def assert_no_imported_function(stage: str) -> None:
            if function_marker.exists():
                source = function_marker.read_text(encoding="utf-8")
                raise SystemExit(
                    "self-test FAILED: release proof imported a poisoned shell "
                    f"startup hook/function {source!r} during {stage}"
                )

        expect_web_release_fixture_result(
            just_binary,
            "web-release-candidate-proof",
            state_path,
            log_path,
            base_environment,
            "ok",
            success=True,
            diagnostic="anonymous candidate proof passed",
        )
        assert_no_imported_function("candidate proof")
        if [
            line.split(" ", 2)[1]
            for line in log_path.read_text(encoding="utf-8").splitlines()
            if line.startswith("crane ")
        ] != ["digest", "manifest", "config", "pull"]:
            raise SystemExit(
                "self-test FAILED: candidate fixture did not exercise "
                "digest -> manifest -> config -> pull"
            )
        for state, diagnostic in (
            ("candidate-wrong-digest", "anonymous digest mismatch"),
            ("candidate-wrong-revision", "candidate OCI runtime/source contract mismatch"),
        ):
            expect_web_release_fixture_result(
                just_binary,
                "web-release-candidate-proof",
                state_path,
                log_path,
                base_environment,
                state,
                success=False,
                diagnostic=diagnostic,
            )

        # web-release-resolve-candidate is the digest-DISCOVERY entrypoint: the
        # operator supplies only the source commit, so the resolver has to
        # construct the one allowed tag itself, prove whatever digest that tag
        # resolves to, and read the tag a second time afterwards.
        resolver_environment = {
            name: value
            for name, value in base_environment.items()
            if name != "WEB_APPLY_IMAGE"
        }
        resolver_receipt = (
            "resolved candidate: source="
            + WEB_RELEASE_FIXTURE_SHA
            + " tag="
            + WEB_RELEASE_FIXTURE_TAG
            + " digest="
            + WEB_RELEASE_FIXTURE_DIGEST
        )
        resolved = expect_web_release_fixture_result(
            just_binary,
            "web-release-resolve-candidate",
            state_path,
            log_path,
            resolver_environment,
            "ok",
            success=True,
            diagnostic=resolver_receipt,
        )
        assert_no_imported_function("candidate resolver")
        # Both receipts, in order, and nothing else: the captured proof receipt
        # first, the resolver's own line last.
        if resolved.stdout.splitlines() != [
            "anonymous candidate proof passed: source="
            + WEB_RELEASE_FIXTURE_SHA
            + " digest="
            + WEB_RELEASE_FIXTURE_DIGEST,
            resolver_receipt,
        ]:
            raise SystemExit(
                "self-test FAILED: resolver stdout must be the captured proof "
                f"receipt then its own receipt line: {resolved.stdout!r}"
            )
        resolver_log = log_path.read_text(encoding="utf-8").splitlines()
        resolver_crane_calls = [
            line.split(" ") for line in resolver_log if line.startswith("crane ")
        ]
        expected_crane_calls = [
            ["crane", "digest", WEB_RELEASE_FIXTURE_TAG],
            ["crane", "digest", WEB_RELEASE_FIXTURE_IMAGE],
            ["crane", "manifest", WEB_RELEASE_FIXTURE_IMAGE],
            ["crane", "config", WEB_RELEASE_FIXTURE_IMAGE],
            ["crane", "pull", WEB_RELEASE_FIXTURE_IMAGE],
            ["crane", "digest", WEB_RELEASE_FIXTURE_TAG],
        ]
        if [call[:3] for call in resolver_crane_calls] != expected_crane_calls:
            raise SystemExit(
                "self-test FAILED: resolver did not read the tag, prove the "
                "resolved digest, then re-read the same tag: "
                f"{resolver_crane_calls!r}"
            )
        if "nested-just web-release-candidate-proof" not in resolver_log:
            raise SystemExit(
                "self-test FAILED: resolver did not re-enter the reviewed "
                "candidate proof by recipe name"
            )
        # Single entrypoint: a pre-set WEB_APPLY_IMAGE would let a hand-copied
        # digest ride through the resolver's receipt, so it is refused outright.
        expect_web_release_fixture_result(
            just_binary,
            "web-release-resolve-candidate",
            state_path,
            log_path,
            base_environment,
            "ok",
            success=False,
            diagnostic="WEB_APPLY_IMAGE must be unset",
        )
        # The resolver contributes no proxy scrubbing of its own; the claim is
        # that the nested guard re-enters on the operator's REAL environment.
        # Pin it: an ambient HTTPS_PROXY must surface through the resolver.
        expect_web_release_fixture_result(
            just_binary,
            "web-release-resolve-candidate",
            state_path,
            log_path,
            {**resolver_environment, "HTTPS_PROXY": "http://resolver-proxy-canary.invalid"},
            "ok",
            success=False,
            diagnostic="Refusing ambient HTTPS_PROXY",
        )
        # (state, diagnostic, must the nested candidate proof have been reached?)
        # A bad FIRST tag read has to fail before any callee runs; the remaining
        # states are refusals of what the callee did or did not report.
        for state, diagnostic, reaches_callee in (
            (
                "resolver-first-crane-failure",
                "candidate tag first resolution failed",
                False,
            ),
            (
                "resolver-malformed-digest",
                "candidate tag first digest is malformed",
                False,
            ),
            (
                "resolver-silent-callee",
                "nested candidate proof did not emit its receipt",
                True,
            ),
            (
                "resolver-wrong-revision",
                "candidate OCI runtime/source contract mismatch",
                True,
            ),
        ):
            refused = expect_web_release_fixture_result(
                just_binary,
                "web-release-resolve-candidate",
                state_path,
                log_path,
                resolver_environment,
                state,
                success=False,
                diagnostic=diagnostic,
            )
            if refused.stdout.strip():
                raise SystemExit(
                    f"self-test FAILED: refused resolver state {state!r} still "
                    f"emitted stdout: {refused.stdout!r}"
                )
            nested = "nested-just web-release-candidate-proof" in log_path.read_text(
                encoding="utf-8"
            )
            if nested != reaches_callee:
                raise SystemExit(
                    f"self-test FAILED: resolver state {state!r} nested-callee "
                    f"reach was {nested}, expected {reaches_callee}"
                )
        # Tag movement is caught AFTER a fully passing proof, so this is the
        # state that proves no green output escapes before the last gate.
        moved = expect_web_release_fixture_result(
            just_binary,
            "web-release-resolve-candidate",
            state_path,
            log_path,
            resolver_environment,
            "resolver-tag-moved",
            success=False,
            diagnostic="candidate tag moved during the proof; refusing",
        )
        if moved.stdout.strip() or "anonymous candidate proof passed" in moved.stdout:
            raise SystemExit(
                "self-test FAILED: resolver leaked the passing proof receipt "
                f"before refusing a moved tag: {moved.stdout!r}"
            )

        render = expect_web_release_fixture_result(
            just_binary,
            "web-release-render",
            state_path,
            log_path,
            base_environment,
            "ok",
            success=True,
            diagnostic=WEB_RELEASE_FIXTURE_IMAGE,
        )
        assert_no_imported_function("render proof")
        if "app.tinyland.dev/source-sha: " + WEB_RELEASE_FIXTURE_SHA not in render.stdout:
            raise SystemExit(
                "self-test FAILED: render fixture omitted the exact source annotation"
            )
        if (
            "default-deny-egress" not in render.stdout
            or "allow-egress-dns" in render.stdout
            or "allow-egress-discuss-archive" in render.stdout
        ):
            raise SystemExit(
                "self-test FAILED: render fixture did not replace legacy egress "
                "allows with the exact default-deny policy"
            )
        render_log = log_path.read_text(encoding="utf-8").splitlines()
        if render_log.count("nested-just web-stack-validate") != 1 or sum(
            line == "kubectl kustomize k8s/web/greatfallstoolbus-org-production"
            for line in render_log
        ) != 2:
            raise SystemExit(
                "self-test FAILED: render fixture did not execute the reviewed "
                "validator and exact local kustomize path"
            )
        render_env_from = expect_web_release_fixture_result(
            just_binary,
            "web-release-render",
            state_path,
            log_path,
            base_environment,
            "render-env-from",
            success=True,
            diagnostic=WEB_RELEASE_FIXTURE_IMAGE,
        )
        if "envFrom:" in render_env_from.stdout:
            raise SystemExit(
                "self-test FAILED: render fixture retained an injected envFrom"
            )
        for state, diagnostic in (
            ("render-secret", "rendered object census mismatch"),
            ("render-missing-default-ingress", "rendered object census mismatch"),
            ("render-retained-legacy-egress", "rendered object census mismatch"),
            (
                "render-init-container",
                "rendered static-Caddy workload contract mismatch",
            ),
            (
                "render-ephemeral-container",
                "rendered static-Caddy workload contract mismatch",
            ),
            (
                "render-image-pull-secret",
                "rendered static-Caddy workload contract mismatch",
            ),
            (
                "render-service-selector",
                "rendered static-Caddy workload contract mismatch",
            ),
            (
                "render-service-protocol",
                "rendered static-Caddy workload contract mismatch",
            ),
            (
                "render-service-external",
                "rendered static-Caddy workload contract mismatch",
            ),
            (
                "render-service-extra-key",
                "rendered static-Caddy workload contract mismatch",
            ),
        ):
            expect_web_release_fixture_result(
                just_binary,
                "web-release-render",
                state_path,
                log_path,
                base_environment,
                state,
                success=False,
                diagnostic=diagnostic,
            )

        expect_web_release_fixture_result(
            just_binary,
            "_web-release-kubeconfig-inputs",
            state_path,
            log_path,
            base_environment,
            "ok",
            success=True,
            diagnostic="reviewed stable web release-object mutation denial",
        )
        assert_no_imported_function("kubeconfig proof")
        kube_log = log_path.read_text(encoding="utf-8").splitlines()
        kube_calls = [line for line in kube_log if line.startswith("kubectl ")]
        namespace_scope = "--namespace greatfallstoolbus-org-production"
        cluster_scope = "--all-namespaces"

        def expected_auth_operation(
            verb: str,
            resource: str,
            scope_flag: str,
            subresource: str | None = None,
        ) -> str:
            operation = f"auth can-i {verb} {resource}"
            if subresource is not None:
                operation += f" --subresource={subresource}"
            return operation + " " + scope_flag

        expected_kube_operations = [
            "get namespace kube-system -o jsonpath={.metadata.uid}",
            *[
                expected_auth_operation(verb, resource, namespace_scope)
                for verb, resource in (
                    ("get", "deployments"),
                    ("list", "replicasets"),
                    ("list", "pods"),
                    ("get", "services"),
                    ("list", "endpointslices.discovery.k8s.io"),
                    ("list", "networkpolicies.networking.k8s.io"),
                )
            ],
            expected_auth_operation("get", "namespaces", cluster_scope),
            "create --raw /apis/authorization.k8s.io/v1/"
            "selfsubjectrulesreviews -f <rules-request>",
        ]
        mutation_verbs = ("create", "update", "patch", "delete", "deletecollection")
        for namespaced, scope_flag in (
            (True, namespace_scope),
            (False, cluster_scope),
        ):
            for verb in mutation_verbs:
                expected_kube_operations.append(
                    "api-resources --cached=false "
                    f"--namespaced={'true' if namespaced else 'false'} "
                    f"--verbs={verb} -o name"
                )
                discovered = (
                    (
                        "deployments.apps",
                        "jobs.batch",
                        *((("pods", "exec"),) if verb == "update" else ()),
                        *(
                            (("deployments.apps", "scale"),)
                            if verb == "create"
                            else ()
                        ),
                    )
                    if namespaced
                    else (
                        (
                            "namespaces",
                            "selfsubjectaccessreviews.authorization.k8s.io",
                            "selfsubjectrulesreviews.authorization.k8s.io",
                            "selfsubjectreviews.authentication.k8s.io",
                        )
                        if verb == "create"
                        else ("namespaces",)
                    )
                )
                expected_kube_operations.extend(
                    (
                        expected_auth_operation(
                            verb,
                            resource[0],
                            scope_flag,
                            resource[1],
                        )
                        if isinstance(resource, tuple)
                        else expected_auth_operation(verb, resource, scope_flag)
                    )
                    for resource in discovered
                )
        sensitive_verbs = (
            "get",
            "list",
            "watch",
            "create",
            "update",
            "patch",
            "delete",
            "deletecollection",
        )
        expected_kube_operations.extend(
            expected_auth_operation(verb, resource, namespace_scope)
            for resource in (
                "secrets",
                "configmaps",
                "serviceaccounts",
                "roles.rbac.authorization.k8s.io",
                "rolebindings.rbac.authorization.k8s.io",
            )
            for verb in sensitive_verbs
        )
        expected_kube_operations.extend(
            expected_auth_operation(verb, resource, cluster_scope)
            for resource in (
                "clusterroles.rbac.authorization.k8s.io",
                "clusterrolebindings.rbac.authorization.k8s.io",
            )
            for verb in sensitive_verbs
        )
        expected_kube_operations.extend(
            expected_auth_operation(
                verb,
                f"{resource}/{resource_name}",
                scope_flag,
            )
            for resource, resource_name, scope_flag in (
                (
                    "namespaces",
                    "greatfallstoolbus-org-production",
                    cluster_scope,
                ),
                (
                    "deployments.apps",
                    "greatfallstoolbus-org",
                    namespace_scope,
                ),
                ("services", "greatfallstoolbus-org", namespace_scope),
                *(
                    (
                        "networkpolicies.networking.k8s.io",
                        name,
                        namespace_scope,
                    )
                    for name in (
                        "allow-cloudflared-tunnel-ingress",
                        "allow-prometheus-scrape",
                        "default-deny-egress",
                        "default-deny-ingress",
                        "allow-egress-dns",
                        "allow-egress-discuss-archive",
                    )
                ),
            )
            for verb in ("update", "patch", "delete")
        )
        expected_kube_operations.extend(
            expected_auth_operation(
                verb,
                f"{resource}/{resource_name}",
                scope_flag,
                subresource,
            )
            for resource, resource_name, subresource, scope_flag, verbs in (
                (
                    "namespaces",
                    "greatfallstoolbus-org-production",
                    "status",
                    cluster_scope,
                    ("update", "patch"),
                ),
                (
                    "namespaces",
                    "greatfallstoolbus-org-production",
                    "finalize",
                    cluster_scope,
                    ("update", "patch"),
                ),
                (
                    "deployments.apps",
                    "greatfallstoolbus-org",
                    "status",
                    namespace_scope,
                    ("update", "patch"),
                ),
                (
                    "deployments.apps",
                    "greatfallstoolbus-org",
                    "scale",
                    namespace_scope,
                    ("update", "patch"),
                ),
                (
                    "services",
                    "greatfallstoolbus-org",
                    "status",
                    namespace_scope,
                    ("update", "patch"),
                ),
                (
                    "services",
                    "greatfallstoolbus-org",
                    "proxy",
                    namespace_scope,
                    ("get", "create", "update", "patch", "delete"),
                ),
            )
            for verb in verbs
        )
        expected_kube_operations.extend(
            expected_auth_operation(
                verb,
                resource,
                scope_flag,
                subresource,
            )
            for resource, subresource, scope_flag in (
                ("deployments", "scale", namespace_scope),
                ("deployments", "status", namespace_scope),
                ("replicasets", "scale", namespace_scope),
                ("replicasets", "status", namespace_scope),
                ("pods", "exec", namespace_scope),
                ("pods", "attach", namespace_scope),
                ("pods", "portforward", namespace_scope),
                ("pods", "ephemeralcontainers", namespace_scope),
                ("pods", "eviction", namespace_scope),
                ("pods", "binding", namespace_scope),
                ("pods", "log", namespace_scope),
                ("pods", "proxy", namespace_scope),
                ("pods", "resize", namespace_scope),
                ("pods", "status", namespace_scope),
                ("services", "proxy", namespace_scope),
                ("services", "status", namespace_scope),
                ("namespaces", "finalize", cluster_scope),
                ("namespaces", "status", cluster_scope),
                ("nodes", "log", cluster_scope),
                ("nodes", "metrics", cluster_scope),
                ("nodes", "proxy", cluster_scope),
                ("nodes", "stats", cluster_scope),
                (
                    "endpointslices.discovery.k8s.io",
                    "status",
                    namespace_scope,
                ),
                (
                    "networkpolicies.networking.k8s.io",
                    "status",
                    namespace_scope,
                ),
                ("serviceaccounts", "token", namespace_scope),
            )
            for verb in sensitive_verbs
        )
        expected_kube_operations.extend(
            expected_auth_operation(verb, resource, scope_flag)
            for verb, resource, scope_flag in (
                ("bind", "roles.rbac.authorization.k8s.io", namespace_scope),
                ("bind", "clusterroles.rbac.authorization.k8s.io", cluster_scope),
                ("escalate", "roles.rbac.authorization.k8s.io", namespace_scope),
                (
                    "escalate",
                    "clusterroles.rbac.authorization.k8s.io",
                    cluster_scope,
                ),
                ("impersonate", "users", cluster_scope),
                ("impersonate", "groups", cluster_scope),
                ("impersonate", "serviceaccounts", cluster_scope),
            )
        )
        expected_kube_operations.extend(
            "create --raw /apis/authorization.k8s.io/v1/"
            "selfsubjectaccessreviews -f <raw-ssar-request>"
            for _ in ("approve", "attest", "sign")
        )
        expected_kube_operations.extend(
            (
                "auth can-i * * --namespace=greatfallstoolbus-org-production",
                expected_auth_operation("*", "*", cluster_scope),
            )
        )
        observed_kube_operations = []
        for line in kube_calls:
            fields = line.split(" ", 3)
            if len(fields) != 4 or fields[1] != "--kubeconfig":
                raise SystemExit(
                    "self-test FAILED: kubeconfig fixture logged malformed kubectl argv"
                )
            operation = re.sub(
                r" -f \S*/rules-request\.json$",
                " -f <rules-request>",
                fields[3],
            )
            operation = re.sub(
                r" -f \S*/raw-ssar-request\.json$",
                " -f <raw-ssar-request>",
                operation,
            )
            observed_kube_operations.append(operation)
        if (
            observed_kube_operations != expected_kube_operations
            or not all("--kubeconfig " in line for line in kube_calls)
        ):
            mismatch = next(
                (
                    index
                    for index in range(
                        max(
                            len(observed_kube_operations),
                            len(expected_kube_operations),
                        )
                    )
                    if index >= len(observed_kube_operations)
                    or index >= len(expected_kube_operations)
                    or observed_kube_operations[index]
                    != expected_kube_operations[index]
                ),
                None,
            )
            expected = (
                expected_kube_operations[mismatch]
                if mismatch is not None and mismatch < len(expected_kube_operations)
                else "<end>"
            )
            observed = (
                observed_kube_operations[mismatch]
                if mismatch is not None and mismatch < len(observed_kube_operations)
                else "<end>"
            )
            raise SystemExit(
                "self-test FAILED: kubeconfig fixture did not execute the exact "
                "Honey/read-only RBAC census; first mismatch at "
                f"{mismatch}: expected {expected!r}, observed {observed!r}"
            )
        if [line for line in kube_log if line.startswith("raw-ssar ")] != [
            "raw-ssar approve certificates.k8s.io signers",
            "raw-ssar attest certificates.k8s.io signers",
            "raw-ssar sign certificates.k8s.io signers",
        ]:
            raise SystemExit(
                "self-test FAILED: kubeconfig fixture did not issue the exact "
                "raw signer SelfSubjectAccessReviews"
            )
        for state, diagnostic in (
            (
                "kube-allows-patch",
                "can mutate namespaced resource deployments.apps (patch)",
            ),
            (
                "kube-allows-job-create",
                "can mutate namespaced resource jobs.batch (create)",
            ),
            (
                "kube-allows-scale",
                "must not access privileged subresource deployments/scale",
            ),
            (
                "kube-allows-exec",
                "must not access privileged subresource pods/exec",
            ),
            (
                "kube-allows-ephemeral",
                "must not access privileged subresource pods/ephemeralcontainers",
            ),
            (
                "kube-subresource-transport-error",
                "Kubernetes authorization decision was not an exact yes/no result",
            ),
            (
                "kube-allows-bind",
                "must not bind roles.rbac.authorization.k8s.io",
            ),
            (
                "kube-allows-named-deployment",
                "must not mutate named release object "
                "deployments.apps/greatfallstoolbus-org (patch)",
            ),
            (
                "kube-allows-named-service-proxy",
                "must not access named release subresource "
                "services/greatfallstoolbus-org/proxy (create)",
            ),
            (
                "kube-named-auth-transport-error",
                "Kubernetes authorization decision was not an exact yes/no result",
            ),
            (
                "kube-allows-signer",
                "must not approve certificates.k8s.io signers",
            ),
            (
                "kube-raw-ssar-malformed",
                "Kubernetes raw authorization review was malformed",
            ),
            (
                "kube-raw-ssar-transport-error",
                "Kubernetes authorization/discovery request failed",
            ),
            ("kube-allows-wildcard", "must not hold wildcard authority"),
            (
                "kube-effective-extra-resource",
                "unexpected reported resource authority: batch/jobs:get",
            ),
            (
                "kube-ssrr-incomplete",
                "SelfSubjectRulesReview is incomplete or reported an evaluation error",
            ),
            (
                "kube-ssrr-unrelated-url",
                "unexpected reported non-resource URL authority",
            ),
            ("kube-wrong-cluster", "does not target the reviewed Honey cluster"),
        ):
            expect_web_release_fixture_result(
                just_binary,
                "_web-release-kubeconfig-inputs",
                state_path,
                log_path,
                base_environment,
                state,
                success=False,
                diagnostic=diagnostic,
            )

        repo_temp_patterns = (
            "gftb-web-kubeconfig.*",
            "gftb-web-running.*",
            "gftb-web-served.*",
        )
        repo_temp_before = {
            path
            for pattern in repo_temp_patterns
            for path in REPO.glob(pattern)
        }
        repo_tmp_environment = {**base_environment, "TMPDIR": str(REPO)}
        for recipe, environment in (
            ("_web-release-kubeconfig-inputs", repo_tmp_environment),
            ("web-release-pinned-running-proof", repo_tmp_environment),
            (
                "web-release-served-proof",
                {**repo_tmp_environment, "WEB_ACCESS_STATE": "public"},
            ),
        ):
            expect_web_release_fixture_result(
                just_binary,
                recipe,
                state_path,
                log_path,
                environment,
                "ok",
                success=False,
                diagnostic="TMPDIR must remain outside the public repository",
            )
        repo_temp_after = {
            path
            for pattern in repo_temp_patterns
            for path in REPO.glob(pattern)
        }
        if repo_temp_after != repo_temp_before:
            raise SystemExit(
                "self-test FAILED: repo-local TMPDIR rejection wrote release "
                "proof material before failing"
            )

        expect_web_release_fixture_result(
            just_binary,
            "web-release-pinned-running-proof",
            state_path,
            log_path,
            base_environment,
            "ok",
            success=True,
            diagnostic="PINNED/RUNNING proof passed",
        )
        assert_no_imported_function("PINNED/RUNNING proof")
        running_log = log_path.read_text(encoding="utf-8").splitlines()
        read_markers = (
            ("deployment", " get deployment/greatfallstoolbus-org -o json"),
            ("replicasets", " get replicasets -o json"),
            ("pods", " get pods -o json"),
            ("service", " get service/greatfallstoolbus-org -o json"),
            (
                "endpointslices",
                " get endpointslices.discovery.k8s.io --selector "
                "kubernetes.io/service-name=greatfallstoolbus-org -o json",
            ),
            (
                "networkpolicies",
                " get networkpolicies.networking.k8s.io -o json",
            ),
        )
        running_read_sequence = [
            name
            for line in running_log
            for name, marker in read_markers
            if marker in line
        ]
        if (
            running_read_sequence
            != [name for name, _ in read_markers] * 2
            or sum(
                " create --raw /apis/authorization.k8s.io/v1/"
                "selfsubjectrulesreviews " in line
                for line in running_log
            )
            != 2
            or running_log.count(
                "nested-just --justfile "
                + str(REPO / "Justfile")
                + " --working-directory "
                + str(REPO)
                + " _web-release-kubeconfig-inputs"
            )
            != 1
        ):
            raise SystemExit(
                "self-test FAILED: PINNED/RUNNING fixture did not execute the "
                "staged kubeconfig and complete final-reread census"
            )
        running_kube_operations = []
        for line in running_log:
            if not line.startswith("kubectl "):
                continue
            fields = line.split(" ", 3)
            if len(fields) != 4 or fields[1] != "--kubeconfig":
                raise SystemExit(
                    "self-test FAILED: PINNED/RUNNING fixture logged malformed "
                    "kubectl argv"
                )
            running_kube_operations.append(
                re.sub(
                    r" -f \S*/rules-request\.json$",
                    " -f <rules-request>",
                    fields[3],
                )
            )
        pinned_reads = [
            f"{namespace_scope} get deployment/greatfallstoolbus-org -o json",
            f"{namespace_scope} get replicasets -o json",
            f"{namespace_scope} get pods -o json",
            f"{namespace_scope} get service/greatfallstoolbus-org -o json",
            f"{namespace_scope} get endpointslices.discovery.k8s.io --selector "
            "kubernetes.io/service-name=greatfallstoolbus-org -o json",
            f"{namespace_scope} get networkpolicies.networking.k8s.io -o json",
        ]
        expected_pinned_operations = list(pinned_reads)
        for resource_name in (
            "greatfallstoolbus-org-abc123",
            "greatfallstoolbus-org-old",
        ):
            expected_pinned_operations.extend(
                expected_auth_operation(
                    verb,
                    f"replicasets.apps/{resource_name}",
                    namespace_scope,
                )
                for verb in ("update", "patch", "delete")
            )
            for subresource in ("status", "scale"):
                expected_pinned_operations.extend(
                    expected_auth_operation(
                        verb,
                        f"replicasets.apps/{resource_name}",
                        namespace_scope,
                        subresource,
                    )
                    for verb in ("update", "patch")
                )
        for resource_name in (
            "greatfallstoolbus-org-abc123-1",
            "greatfallstoolbus-org-abc123-2",
        ):
            expected_pinned_operations.extend(
                expected_auth_operation(
                    verb,
                    f"pods/{resource_name}",
                    namespace_scope,
                )
                for verb in ("update", "patch", "delete")
            )
            for subresource, verbs in (
                ("status", ("update", "patch")),
                ("ephemeralcontainers", ("update", "patch")),
                ("eviction", ("create",)),
                ("binding", ("create",)),
                ("exec", ("get", "create")),
                ("attach", ("get", "create")),
                ("portforward", ("get", "create")),
                ("log", ("get",)),
                ("proxy", ("get", "create", "update", "patch", "delete")),
                ("resize", ("update", "patch")),
            ):
                expected_pinned_operations.extend(
                    expected_auth_operation(
                        verb,
                        f"pods/{resource_name}",
                        namespace_scope,
                        subresource,
                    )
                    for verb in verbs
                )
        expected_pinned_operations.extend(
            expected_auth_operation(
                verb,
                "endpointslices.discovery.k8s.io/"
                "greatfallstoolbus-org-abc123",
                namespace_scope,
            )
            for verb in ("update", "patch", "delete")
        )
        expected_pinned_operations.extend(
            expected_auth_operation(
                verb,
                "endpointslices.discovery.k8s.io/"
                "greatfallstoolbus-org-abc123",
                namespace_scope,
                "status",
            )
            for verb in ("update", "patch")
        )
        expected_pinned_operations.extend(pinned_reads)
        expected_pinned_operations.append(
            "create --raw /apis/authorization.k8s.io/v1/"
            "selfsubjectrulesreviews -f <rules-request>"
        )
        try:
            first_pinned_call = running_kube_operations.index(pinned_reads[0])
        except ValueError as error:
            raise SystemExit(
                "self-test FAILED: PINNED/RUNNING fixture omitted its first "
                "Deployment read"
            ) from error
        observed_pinned_operations = running_kube_operations[first_pinned_call:]
        if observed_pinned_operations != expected_pinned_operations:
            mismatch = next(
                index
                for index in range(
                    max(
                        len(observed_pinned_operations),
                        len(expected_pinned_operations),
                    )
                )
                if index >= len(observed_pinned_operations)
                or index >= len(expected_pinned_operations)
                or observed_pinned_operations[index]
                != expected_pinned_operations[index]
            )
            expected = (
                expected_pinned_operations[mismatch]
                if mismatch < len(expected_pinned_operations)
                else "<end>"
            )
            observed = (
                observed_pinned_operations[mismatch]
                if mismatch < len(observed_pinned_operations)
                else "<end>"
            )
            raise SystemExit(
                "self-test FAILED: PINNED/RUNNING fixture did not execute the "
                "exact observed-object mutation-denial census; first mismatch "
                f"at {mismatch}: expected {expected!r}, observed {observed!r}"
            )
        expect_web_release_fixture_result(
            just_binary,
            "web-release-pinned-running-proof",
            state_path,
            log_path,
            base_environment,
            "pinned-list-envelope-drift",
            success=True,
            diagnostic="PINNED/RUNNING proof passed",
        )
        for state, diagnostic in (
            ("pinned-old-rs-live", "old ReplicaSet is not fully scaled down"),
            ("pinned-duplicate-active-rs", "expected exactly one active ReplicaSet"),
            ("pinned-restart", "pod ownership/readiness/image contract mismatch"),
            (
                "pinned-wrong-image-id",
                "pod ownership/readiness/image contract mismatch",
            ),
            (
                "pinned-extra-labeled-pod",
                "pod ownership/readiness/image contract mismatch",
            ),
            (
                "pinned-final-degraded",
                "RUNNING Deployment changed or degraded during readback",
            ),
            (
                "pinned-rogue-endpoint-ip",
                "RUNNING Service EndpointSlice does not bind the two reviewed pods",
            ),
            (
                "pinned-deleting-endpoint-slice",
                "RUNNING Service EndpointSlice does not bind the two reviewed pods",
            ),
            (
                "pinned-network-policy-content",
                "RUNNING NetworkPolicy semantic content mismatch",
            ),
            (
                "pinned-network-policy-missing-deny",
                "RUNNING NetworkPolicy object census/identity mismatch",
            ),
            (
                "pinned-network-policy-retained-legacy",
                "RUNNING NetworkPolicy object census/identity mismatch",
            ),
            (
                "pinned-network-policy-permissive-egress",
                "RUNNING NetworkPolicy semantic content mismatch",
            ),
            (
                "pinned-network-policy-wrong-selector",
                "RUNNING NetworkPolicy semantic content mismatch",
            ),
            (
                "pinned-final-network-policy-drift",
                "RUNNING NetworkPolicy state changed during readback",
            ),
            (
                "pinned-final-pod-resource-version-drift",
                "RUNNING pod state changed during readback",
            ),
            (
                "pinned-final-authority-drift",
                "WEB_RELEASE_KUBECONFIG authority changed during readback",
            ),
            ("pinned-privileged", "PINNED Deployment contract mismatch"),
            (
                "pinned-capabilities-add",
                "PINNED Deployment contract mismatch",
            ),
            ("pinned-host-network", "PINNED Deployment contract mismatch"),
            ("pinned-host-port", "PINNED Deployment contract mismatch"),
            (
                "pinned-allows-observed-pod-patch",
                "can mutate observed release object "
                "pods/greatfallstoolbus-org-abc123-1 (patch)",
            ),
            (
                "pinned-allows-observed-pod-exec",
                "can access observed release subresource "
                "pods/greatfallstoolbus-org-abc123-1/exec (create)",
            ),
            (
                "pinned-named-auth-transport-error",
                "Kubernetes named-object authorization review returned diagnostics",
            ),
        ):
            expect_web_release_fixture_result(
                just_binary,
                "web-release-pinned-running-proof",
                state_path,
                log_path,
                base_environment,
                state,
                success=False,
                diagnostic=diagnostic,
            )

        public_environment = {**base_environment, "WEB_ACCESS_STATE": "public"}
        expect_web_release_fixture_result(
            just_binary,
            "web-release-served-proof",
            state_path,
            log_path,
            public_environment,
            "ok",
            success=True,
            diagnostic="SERVED source proof passed",
        )
        assert_no_imported_function("public SERVED proof")
        public_curl = [
            line
            for line in log_path.read_text(encoding="utf-8").splitlines()
            if line.startswith("curl ")
        ]
        expected_urls = [
            "https://greatfallstoolbus.org/",
            "https://greatfallstoolbus.org/health",
            "https://greatfallstoolbus.org/health.sha",
            "https://greatfallstoolbus.org/qr/greatfallstoolbus-apex.svg",
        ]
        if (
            [line.rsplit(" ", 1)[-1] for line in public_curl] != expected_urls
            or any(" --cookie " in line for line in public_curl)
        ):
            raise SystemExit(
                "self-test FAILED: public SERVED fixture did not make exactly "
                "four anonymous requests"
            )
        for state, diagnostic in (
            ("served-wrong-sha", "SERVED source SHA mismatch"),
            ("served-health-newline", "SERVED health body mismatch"),
            ("served-wrong-qr-type", "SERVED QR content type mismatch"),
        ):
            expect_web_release_fixture_result(
                just_binary,
                "web-release-served-proof",
                state_path,
                log_path,
                public_environment,
                state,
                success=False,
                diagnostic=diagnostic,
            )
        public_with_cookie = {
            **public_environment,
            "CF_ACCESS_COOKIE_JAR": str(cookie),
        }
        expect_web_release_fixture_result(
            just_binary,
            "web-release-served-proof",
            state_path,
            log_path,
            public_with_cookie,
            "ok",
            success=False,
            diagnostic="public served proof must not use an Access cookie jar",
        )

        gated_environment = {
            **base_environment,
            "WEB_ACCESS_STATE": "gated",
            "CF_ACCESS_COOKIE_JAR": str(cookie),
        }
        expect_web_release_fixture_result(
            just_binary,
            "web-release-served-proof",
            state_path,
            log_path,
            gated_environment,
            "served-gated",
            success=True,
            diagnostic="SERVED source proof passed",
        )
        assert_no_imported_function("gated SERVED proof")
        gated_curl = [
            line
            for line in log_path.read_text(encoding="utf-8").splitlines()
            if line.startswith("curl ")
        ]
        if (
            [line.rsplit(" ", 1)[-1] for line in gated_curl]
            != expected_urls * 2
            or any(" --cookie " in line for line in gated_curl[:4])
            or not all(" --cookie " in line for line in gated_curl[4:])
        ):
            raise SystemExit(
                "self-test FAILED: gated SERVED fixture did not make four "
                "anonymous redirects followed by four cookie-authenticated requests"
            )
        for state, diagnostic in (
            (
                "served-gated-unsafe-redirect",
                "unexpected Cloudflare Access redirect",
            ),
            (
                "served-gated-prefix-suffix",
                "unexpected Cloudflare Access redirect",
            ),
            (
                "served-gated-duplicate-location",
                "Access response must contain exactly one Location header",
            ),
        ):
            expect_web_release_fixture_result(
                just_binary,
                "web-release-served-proof",
                state_path,
                log_path,
                gated_environment,
                state,
                success=False,
                diagnostic=diagnostic,
            )
        for name, value in (
            ("GODEBUG", "http2debug=1"),
            ("SSLKEYLOGFILE", str(root / "tls.keys")),
        ):
            expect_web_release_fixture_result(
                just_binary,
                "web-release-served-proof",
                state_path,
                log_path,
                {**public_environment, name: value},
                "ok",
                success=False,
                diagnostic=f"Refusing ambient {name}",
            )



# The verbs web-release-apply's identity must hold before it touches anything,
# in the exact order _web-release-apply-kubeconfig-contract asks for them.
WEB_RELEASE_APPLY_AUTHZ_CONTRACT: tuple[tuple[str, str], ...] = (
    ("get", "deployments.apps"),
    ("list", "deployments.apps"),
    ("watch", "deployments.apps"),
    ("create", "deployments.apps"),
    ("update", "deployments.apps"),
    ("patch", "deployments.apps"),
    ("get", "services"),
    ("create", "services"),
    ("update", "services"),
    ("patch", "services"),
    ("get", "networkpolicies.networking.k8s.io"),
    ("create", "networkpolicies.networking.k8s.io"),
    ("update", "networkpolicies.networking.k8s.io"),
    ("patch", "networkpolicies.networking.k8s.io"),
    ("delete", "networkpolicies.networking.k8s.io"),
)


def build_web_release_sandbox_repo(root: Path) -> Path:
    """A symlink view of the repository for the mutation fixtures.

    `web-release-plan` writes its receipt to `$(git rev-parse --show-toplevel)/
    .k8s-plans`. Pointing the mocked toplevel at this sandbox keeps the self-test
    from ever writing into -- or clobbering a real recorded plan in -- the
    operator's own checkout.
    """
    sandbox = root / "repo"
    sandbox.mkdir(mode=0o700)
    for child in sorted(REPO.iterdir()):
        if child.name in {".git", ".k8s-plans", ".tofu-plans"}:
            continue
        (sandbox / child.name).symlink_to(child)
    return sandbox


def run_web_release_mutation_fixtures() -> None:
    """Exercise the MUTATING half as real children against mocked binaries.

    The proof recipes have had this coverage since PR #109; the plan/dry-run/
    apply chain and the legacy-carrier promotion interlock did not. These
    fixtures assert behavior a body digest cannot: argument order, that the
    authorization preflight runs before anything is applied, that the legacy
    egress prune carries --ignore-not-found and happens AFTER the apply and
    BEFORE the rollout wait, and that every refusal path refuses before the
    first mutation.
    """
    just_binary = shutil.which("just")
    if just_binary is None:
        raise SystemExit("self-test FAILED: just is required for release fixtures")
    namespace = "greatfallstoolbus-org-production"
    with tempfile.TemporaryDirectory(
        prefix="gftb-web-mutation-selftest."
    ) as directory:
        root = Path(directory)
        (
            mock_bin,
            state_path,
            log_path,
            toplevel_path,
        ) = install_web_release_fixture_mocks(root)
        sandbox = build_web_release_sandbox_repo(root)
        toplevel_path.write_text(str(sandbox) + "\n", encoding="utf-8")
        home = root / "home"
        temporary = root / "tmp"
        home.mkdir(mode=0o700)
        temporary.mkdir(mode=0o700)
        kubeconfig = root / "web-apply.kubeconfig"
        kubeconfig.write_text(
            "apiVersion: v1\nkind: Config\npreferences: {}\n", encoding="utf-8"
        )
        kubeconfig.chmod(0o600)
        plan_root = sandbox / ".k8s-plans"
        plan = plan_root / "web-release.rendered.yaml"
        environment = {
            "PATH": str(mock_bin),
            "HOME": str(home),
            "TMPDIR": str(temporary),
            "LANG": "C",
            "LC_ALL": "C",
            "WEB_APPLY_IMAGE": WEB_RELEASE_FIXTURE_IMAGE,
            "WEB_APPLY_SHA": WEB_RELEASE_FIXTURE_SHA,
            "WEB_APPLY_REPLICAS": "2",
            "WEB_APPLY_KUBECONFIG": str(kubeconfig),
            "GFTB_APPLY_CONFIRM": "apply",
        }

        def kubectl_calls() -> list[str]:
            return [
                line.removeprefix("kubectl ")
                for line in log_path.read_text(encoding="utf-8").splitlines()
                if line.startswith("kubectl ")
            ]

        def authorization_calls(calls: list[str]) -> list[str]:
            return [call for call in calls if " auth can-i " in call]

        def cluster_mutations(calls: list[str]) -> list[str]:
            return [
                call
                for call in calls
                if f" --namespace {namespace} " in call
                and " auth can-i " not in call
            ]

        expected_authorization = [
            f"--kubeconfig {kubeconfig} auth can-i {verb} {resource} "
            f"--namespace {namespace}"
            for verb, resource in WEB_RELEASE_APPLY_AUTHZ_CONTRACT
        ]

        # PLAN is offline: it may render, and it may not reach the cluster.
        expect_web_release_fixture_result(
            just_binary,
            "web-release-plan",
            state_path,
            log_path,
            environment,
            "apply-ok",
            success=True,
            diagnostic="web release plan recorded",
        )
        plan_calls = kubectl_calls()
        if authorization_calls(plan_calls) or cluster_mutations(plan_calls):
            raise SystemExit(
                "self-test FAILED: web-release-plan contacted the cluster: "
                f"{plan_calls!r}"
            )
        for artifact in (
            "rendered.yaml",
            "render-sha256",
            "image",
            "source-sha",
            "carrier-sha",
        ):
            recorded = plan_root / f"web-release.{artifact}"
            if not recorded.is_file() or (recorded.stat().st_mode & 0o777) != 0o600:
                raise SystemExit(
                    f"self-test FAILED: plan artifact {artifact} is missing or "
                    "not operator-private"
                )

        expect_web_release_fixture_result(
            just_binary,
            "_web-release-plan-preflight",
            state_path,
            log_path,
            environment,
            "apply-ok",
            success=True,
            diagnostic="web release plan preflight passed",
        )

        # SERVER DRY-RUN: authorize first, then dry-run the recorded bytes, and
        # mutate nothing.
        expect_web_release_fixture_result(
            just_binary,
            "web-release-server-dry-run",
            state_path,
            log_path,
            environment,
            "apply-ok",
            success=True,
            diagnostic="web release apply authorization preflight passed",
        )
        dry_run_calls = kubectl_calls()
        if authorization_calls(dry_run_calls) != expected_authorization:
            raise SystemExit(
                "self-test FAILED: server dry-run did not run the exact "
                f"authorization preflight: {authorization_calls(dry_run_calls)!r}"
            )
        if cluster_mutations(dry_run_calls) != [
            f"--kubeconfig {kubeconfig} --namespace {namespace} apply "
            f"--dry-run=server -f {plan}"
        ]:
            raise SystemExit(
                "self-test FAILED: server dry-run touched the cluster beyond a "
                f"server-side dry-run: {cluster_mutations(dry_run_calls)!r}"
            )

        # APPLY: the full ordered chain.
        expect_web_release_fixture_result(
            just_binary,
            "web-release-apply",
            state_path,
            log_path,
            environment,
            "apply-ok",
            success=True,
            diagnostic="web release applied",
        )
        apply_calls = kubectl_calls()
        if not apply_calls or " auth can-i " not in apply_calls[0]:
            raise SystemExit(
                "self-test FAILED: the first cluster call web-release-apply "
                f"makes is not an authorization review: {apply_calls[:1]!r}"
            )
        if authorization_calls(apply_calls) != expected_authorization:
            raise SystemExit(
                "self-test FAILED: web-release-apply did not run the exact "
                f"authorization preflight: {authorization_calls(apply_calls)!r}"
            )
        last_authorization = max(
            index
            for index, call in enumerate(apply_calls)
            if " auth can-i " in call
        )
        first_mutation = min(
            index
            for index, call in enumerate(apply_calls)
            if f" --namespace {namespace} " in call and " auth can-i " not in call
        )
        if last_authorization > first_mutation:
            raise SystemExit(
                "self-test FAILED: web-release-apply mutated before finishing "
                "its authorization preflight"
            )
        expected_mutations = [
            f"--kubeconfig {kubeconfig} --namespace {namespace} apply "
            f"--dry-run=server -f {plan}",
            f"--kubeconfig {kubeconfig} --namespace {namespace} apply -f {plan}",
            f"--kubeconfig {kubeconfig} --namespace {namespace} delete "
            "networkpolicy allow-egress-dns allow-egress-discuss-archive "
            "--ignore-not-found",
            f"--kubeconfig {kubeconfig} --namespace {namespace} rollout status "
            "deployment/greatfallstoolbus-org --timeout=300s",
        ]
        if cluster_mutations(apply_calls) != expected_mutations:
            raise SystemExit(
                "self-test FAILED: web-release-apply did not dry-run, apply the "
                "recorded bytes, prune the legacy egress policies with "
                "--ignore-not-found, and then wait for the rollout, in that "
                f"order: {cluster_mutations(apply_calls)!r}"
            )

        # REFUSALS. Each must refuse with nothing applied.
        for state, diagnostic in (
            (
                "apply-authz-denied-delete",
                f"cannot delete networkpolicies.networking.k8s.io in {namespace}",
            ),
            (
                "apply-authz-denied-create-policy",
                f"cannot create networkpolicies.networking.k8s.io in {namespace}",
            ),
            (
                "apply-authz-transport-error",
                "emitted diagnostics; refusing before any mutation",
            ),
        ):
            expect_web_release_fixture_result(
                just_binary,
                "web-release-apply",
                state_path,
                log_path,
                environment,
                state,
                success=False,
                diagnostic=diagnostic,
            )
            if cluster_mutations(kubectl_calls()):
                raise SystemExit(
                    f"self-test FAILED: web-release-apply state {state!r} "
                    "reached the cluster after refusing: "
                    f"{cluster_mutations(kubectl_calls())!r}"
                )

        # A denied delete is caught by the preflight, so the half-done promotion
        # the preflight exists to prevent must be unreachable; prove the recipe
        # would in fact abort there if it ever were.
        expect_web_release_fixture_result(
            just_binary,
            "web-release-apply",
            state_path,
            log_path,
            environment,
            "apply-delete-fails",
            success=False,
            diagnostic="is forbidden",
        )
        if any(
            "rollout status" in call for call in cluster_mutations(kubectl_calls())
        ):
            raise SystemExit(
                "self-test FAILED: web-release-apply reported a rollout after a "
                "failed egress prune"
            )

        # THE LEGACY-CD PROMOTION INTERLOCK.
        expect_web_release_fixture_result(
            just_binary,
            "_web-stack-promotion-interlock",
            state_path,
            log_path,
            environment,
            "stack-live-promoted",
            success=False,
            diagnostic="already carries the promoted gftb-site origin",
        )
        for state in ("ok", "stack-live-absent"):
            expect_web_release_fixture_result(
                just_binary,
                "_web-stack-promotion-interlock",
                state_path,
                log_path,
                environment,
                state,
                success=True,
                diagnostic="the legacy carrier may proceed",
            )

def self_test() -> None:
    if not RETIRED_EDGE_RECIPE.search("just edge-plan"):
        raise SystemExit("self-test FAILED: retired edge recipe was not detected")
    if RETIRED_EDGE_RECIPE.search("just edge-zones-plan"):
        raise SystemExit("self-test FAILED: edge-zones recipe was falsely detected")
    if not RAW_K8S_MUTATION.search("kubectl --namespace x apply -k k8s/mail"):
        raise SystemExit("self-test FAILED: kubectl apply -k was not detected")
    if not RAW_K8S_MUTATION.search("kustomize build k8s | kubectl apply -f -"):
        raise SystemExit("self-test FAILED: kustomize|kubectl apply was not detected")
    if RAW_K8S_MUTATION.search("kubectl kustomize k8s/mail >/dev/null"):
        raise SystemExit("self-test FAILED: render-only kubectl kustomize was flagged")
    if not is_negative_or_descriptive("No `kubectl apply` is supported here."):
        raise SystemExit("self-test FAILED: negative docs context was not allowed")
    if not RAW_TOFU_WORKFLOW.search("tofu -chdir=tofu/stacks/edge plan"):
        raise SystemExit("self-test FAILED: raw workflow tofu was not detected")

    justfile = (REPO / "Justfile").read_text(encoding="utf-8")
    baseline = scan_arc_operator_contract_text(justfile, Path("Justfile"))
    if baseline:
        rules = ", ".join(sorted({finding.rule for finding in baseline}))
        raise SystemExit(f"self-test FAILED: ARC baseline is invalid ({rules})")

    attended_baseline = scan_attended_operator_contract_text(
        justfile, Path("Justfile")
    )
    if attended_baseline:
        rules = ", ".join(
            sorted({finding.rule for finding in attended_baseline})
        )
        raise SystemExit(
            f"self-test FAILED: attended baseline is invalid ({rules})"
        )

    web_release_baseline = scan_web_release_operator_contract_text(
        justfile, Path("Justfile")
    )
    if web_release_baseline:
        rules = ", ".join(
            sorted({finding.rule for finding in web_release_baseline})
        )
        raise SystemExit(
            f"self-test FAILED: web release baseline is invalid ({rules})"
        )
    validation_script = (REPO / WEB_RELEASE_VALIDATION_SCRIPT).read_bytes()
    validation_script_baseline = scan_web_release_validation_script_bytes(
        validation_script
    )
    if validation_script_baseline:
        raise SystemExit(
            "self-test FAILED: web release validation-script baseline is invalid"
        )
    weakened_validation_script = validation_script.replace(
        b"set -euo pipefail", b"set -eu", 1
    )
    if weakened_validation_script == validation_script or not any(
        finding.rule == "web-release-validation-script-receipt-mismatch"
        for finding in scan_web_release_validation_script_bytes(
            weakened_validation_script
        )
    ):
        raise SystemExit(
            "self-test FAILED: release validator accepted validation-script drift"
        )

    flake_text = (REPO / "flake.nix").read_text(encoding="utf-8")
    flake_lock = (REPO / "flake.lock").read_bytes()
    toolchain_baseline = scan_web_release_toolchain_text(flake_text, flake_lock)
    if toolchain_baseline:
        rules = ", ".join(
            sorted({finding.rule for finding in toolchain_baseline})
        )
        raise SystemExit(
            f"self-test FAILED: web release toolchain baseline is invalid ({rules})"
        )
    for label, mutated_flake in (
        ("missing crane", flake_text.replace("              pkgs.crane\n", "", 1)),
        (
            "duplicate curl",
            flake_text.replace(
                "              pkgs.curl\n",
                "              pkgs.curl\n              pkgs.curl\n",
                1,
            ),
        ),
    ):
        if not any(
            finding.rule == "web-release-flake-package-mismatch"
            for finding in scan_web_release_toolchain_text(
                mutated_flake, flake_lock
            )
        ):
            raise SystemExit(
                f"self-test FAILED: release toolchain accepted {label}"
            )
    if not any(
        finding.rule == "web-release-flake-lock-drift"
        for finding in scan_web_release_toolchain_text(
            flake_text, flake_lock + b"\n"
        )
    ):
        raise SystemExit("self-test FAILED: release toolchain accepted flake.lock drift")

    release_dependency_drift = mutate_recipe_dependencies(
        justfile,
        "web-release-render",
        (),
        "release render input-guard removal",
    )
    expect_web_release_contract_rejection(
        release_dependency_drift,
        "release render input-guard removal",
        "web-release-recipe-dependencies-mismatch",
    )
    # The resolver must stay dependency-free: taking _web-release-candidate-inputs
    # would demand the very WEB_APPLY_IMAGE it exists to discover, and the only
    # way to satisfy that guard would be to hand-copy a digest again.
    resolver_dependency_drift = mutate_recipe_dependencies(
        justfile,
        "web-release-resolve-candidate",
        ("_web-release-candidate-inputs",),
        "release resolver dependency drift",
    )
    expect_web_release_contract_rejection(
        resolver_dependency_drift,
        "release resolver dependency drift",
        "web-release-recipe-dependencies-mismatch",
    )
    callee_dependency_drift = mutate_recipe_dependencies(
        justfile,
        WEB_RELEASE_VALIDATION_CALLEE,
        ("_web-release-candidate-inputs",),
        "release validation-callee dependency drift",
    )
    expect_web_release_contract_rejection(
        callee_dependency_drift,
        "release validation-callee dependency drift",
        "web-release-validation-callee-dependencies-mismatch",
    )
    callee_body_drift = mutate_recipe_body(
        justfile,
        WEB_RELEASE_VALIDATION_CALLEE,
        "    bash scripts/validate-web-stack.sh {{ web_stack_dir }}\n",
        "    true # validation bypassed\n",
        "release validation-callee body drift",
    )
    expect_web_release_contract_rejection(
        callee_body_drift,
        "release validation-callee body drift",
        "web-release-validation-callee-receipt-mismatch",
    )
    release_body_mutations = (
        (
            "_web-release-candidate-inputs",
            '    [[ "${WEB_APPLY_REPLICAS:-2}" == "2" ]] ||',
            '    [[ "${WEB_APPLY_REPLICAS:-2}" -ge "1" ]] ||',
            "release replica cardinality weakening",
        ),
        (
            "web-release-candidate-proof",
            "    #!/usr/bin/env -S BASH_ENV= ENV= SHELLOPTS= BASHOPTS= bash -p\n",
            "    #!/bin/sh\n",
            "release shebang drift",
        ),
        (
            "_web-release-kubeconfig-inputs",
            "    raw = Path(sys.argv[1])\n",
            "      raw = Path(sys.argv[1])\n",
            "release embedded-Python indentation drift",
        ),
        # The resolver's whole value is that the operator cannot choose the
        # reference: it constructs exactly one tag from WEB_APPLY_SHA, and it
        # re-reads that tag after the proof. Both are receipted.
        (
            "web-release-resolve-candidate",
            '    candidate_tag="ghcr.io/great-falls-tool-bus/gftb-site:sha-${source_sha}"\n',
            '    candidate_tag="${WEB_APPLY_TAG:-ghcr.io/great-falls-tool-bus/gftb-site:sha-${source_sha}}"\n',
            "release resolver tag widening",
        ),
        (
            "web-release-resolve-candidate",
            '    [[ "${second_digest}" == "${first_digest}" ]] ||',
            '    [[ -n "${second_digest}" ]] ||',
            "release resolver tag-movement guard weakening",
        ),
    )
    for name, old, new, label in release_body_mutations:
        mutated = mutate_recipe_body(justfile, name, old, new, label)
        expect_web_release_contract_rejection(
            mutated,
            label,
            "web-release-recipe-executable-receipt-mismatch",
        )

    release_duplicate = (
        justfile
        + "\nweb-release-render: _web-release-candidate-inputs\n    true\n"
    )
    expect_web_release_contract_rejection(
        release_duplicate,
        "duplicate web release recipe",
        "web-release-operator-recipe-missing",
    )
    release_alias = (
        justfile
        + "\nalias web-release-render := web-release-candidate-proof\n"
    )
    expect_web_release_contract_rejection(
        release_alias,
        "web release alias collision",
        "web-release-operator-recipe-missing",
    )
    release_parameter = justfile.replace(
        "web-release-render: _web-release-candidate-inputs",
        "web-release-render target: _web-release-candidate-inputs",
        1,
    )
    expect_web_release_contract_rejection(
        release_parameter,
        "web release recipe parameter",
        "web-release-recipe-header-mismatch",
    )
    release_attribute = justfile.replace(
        "web-release-render: _web-release-candidate-inputs",
        "[no-cd]\nweb-release-render: _web-release-candidate-inputs",
        1,
    )
    expect_web_release_contract_rejection(
        release_attribute,
        "web release recipe attribute",
        "web-release-recipe-attribute-mismatch",
    )
    release_shell_drift = justfile.replace(
        'set shell := ["bash", "-eu", "-o", "pipefail", "-c"]',
        'set shell := ["bash", "-c"]',
        1,
    )
    expect_web_release_contract_rejection(
        release_shell_drift,
        "release Just shell weakening",
        "web-release-just-global-contract-mismatch",
    )

    # --- the mutating half of the release chain -----------------------------
    # Every named way the reviewed apply chain could be silently weakened must
    # produce a finding. Dependency edits are caught by the ordered dependency
    # contract; body edits are caught by the exact executable receipt; stack
    # redirection is caught by the pinned Just globals; and an imperative pin is
    # caught anywhere in the file, including in a brand-new unlisted recipe.
    apply_dependency_mutations = (
        (
            (
                "_operator-apply-confirm",
                "_web-release-apply-kubeconfig-contract",
                "_web-release-plan-preflight",
            ),
            "apply without the reviewed-clean-main carrier check",
        ),
        (
            (
                "_reviewed-clean-main",
                "_web-release-apply-kubeconfig-contract",
                "_web-release-plan-preflight",
            ),
            "apply without the operator confirmation",
        ),
        (
            (
                "_reviewed-clean-main",
                "_web-release-apply-kubeconfig-contract",
                "_web-release-plan-preflight",
                "_operator-apply-confirm",
            ),
            "apply with the confirmation moved after the plan preflight",
        ),
        (
            (
                "_reviewed-clean-main",
                "_operator-apply-confirm",
                "_web-release-apply-kubeconfig-contract",
            ),
            "apply without the plan preflight",
        ),
    )
    for dependencies, label in apply_dependency_mutations:
        expect_web_release_contract_rejection(
            mutate_recipe_dependencies(
                justfile, "web-release-apply", dependencies, label
            ),
            label,
            "web-release-recipe-dependencies-mismatch",
        )

    apply_body_mutations = (
        (
            "web-release-apply",
            '    kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" --namespace {{ web_stack_ns }} apply -f "${plan}"\n',
            '    kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" --namespace {{ web_stack_ns }} apply -k {{ web_stack_dir }}\n',
            "apply detached from the recorded plan bytes",
        ),
        (
            "_web-release-plan-preflight",
            '    just --justfile "${repo_root}/Justfile" --working-directory "${repo_root}" web-release-render > "${recheck}"\n',
            "    : re-render skipped\n",
            "plan preflight without the re-render equality proof",
        ),
        (
            "_web-release-plan-preflight",
            '    [[ "$(git -C "${repo_root}" rev-parse HEAD)" == "$(tr -d \'\\n\' < "${plan_root}/web-release.carrier-sha")" ]] ||',
            '    [[ -n "$(git -C "${repo_root}" rev-parse HEAD)" ]] ||',
            "plan preflight without the carrier binding",
        ),
        (
            "_web-release-apply-kubeconfig-contract",
            "    if stat.S_IMODE(metadata.st_mode) != 0o600:\n",
            "    if False:\n",
            "kubeconfig custody without the mode check",
        ),
        (
            "web-release-plan",
            '    just --justfile "${repo_root}/Justfile" --working-directory "${repo_root}" web-release-render > "${plan_root}/web-release.rendered.yaml"\n',
            '    kubectl kustomize {{ web_stack_dir }} > "${plan_root}/web-release.rendered.yaml"\n',
            "plan rendered by a second renderer",
        ),
    )
    for name, old, new, label in apply_body_mutations:
        expect_web_release_contract_rejection(
            mutate_recipe_body(justfile, name, old, new, label),
            label,
            "web-release-recipe-executable-receipt-mismatch",
        )

    for global_name, weakened in (
        ('web_stack_dir := "k8s/web/greatfallstoolbus-org-production"', 'web_stack_dir := "k8s/web"'),
        ('web_stack_ns := "greatfallstoolbus-org-production"', 'web_stack_ns := "default"'),
    ):
        expect_web_release_contract_rejection(
            justfile.replace(global_name, weakened, 1),
            f"redirected release stack global {weakened!r}",
            "web-release-stack-global-contract-mismatch",
        )

    if scan_imperative_pin_text(justfile, Path("Justfile")):
        raise SystemExit(
            "self-test FAILED: the committed Justfile already trips the "
            "imperative-pin scan"
        )
    imperative_pin_cases = (
        (
            "unlisted hotfix recipe",
            justfile
            + "\nweb-release-hotfix:\n"
            + '    kubectl --namespace {{ web_stack_ns }} set image deployment/greatfallstoolbus-org greatfallstoolbus-org="${IMAGE}"\n',
        ),
        (
            "unlisted scale recipe",
            justfile
            + "\nweb-release-scale:\n"
            + "    kubectl --namespace {{ web_stack_ns }} scale deployment/greatfallstoolbus-org --replicas=3\n",
        ),
        (
            "unlisted replica patch recipe",
            justfile
            + "\nweb-release-bump:\n"
            + '    kubectl --namespace {{ web_stack_ns }} patch deployment/greatfallstoolbus-org --type merge --patch \'{"spec":{"replicas":3}}\'\n',
        ),
        (
            "imperative pin injected into the reviewed apply",
            mutate_recipe_body(
                justfile,
                "web-release-apply",
                '    kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" --namespace {{ web_stack_ns }} apply -f "${plan}"\n',
                '    kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" --namespace {{ web_stack_ns }} set image deployment/greatfallstoolbus-org greatfallstoolbus-org="${WEB_APPLY_IMAGE}"\n',
                "imperative pin injected into the reviewed apply",
            ),
        ),
        # Evasions the earlier line- and literal-`kubectl`-anchored scan missed.
        (
            "backslash line continuation",
            justfile
            + "\nweb-release-hotfix:\n"
            + '    kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" \\\n'
            + '      set image deployment/greatfallstoolbus-org app="${IMAGE}"\n',
        ),
        (
            "kubectl_clean wrapper",
            justfile
            + "\nweb-release-hotfix:\n"
            + '    kubectl_clean set image deployment/greatfallstoolbus-org app="${IMAGE}"\n',
        ),
        (
            "rollout undo",
            justfile
            + "\nweb-release-revert:\n"
            + "    kubectl --namespace {{ web_stack_ns }} rollout undo deployment/greatfallstoolbus-org\n",
        ),
        (
            "replace -f",
            justfile
            + "\nweb-release-force:\n"
            + "    kubectl --namespace {{ web_stack_ns }} replace -f /tmp/rendered.yaml\n",
        ),
        (
            "delete deployment",
            justfile
            + "\nweb-release-nuke:\n"
            + "    kubectl --namespace {{ web_stack_ns }} delete deployment greatfallstoolbus-org\n",
        ),
        (
            "scale --all without the literal deployment",
            justfile
            + "\nweb-release-scale-all:\n"
            + "    kubectl --namespace {{ web_stack_ns }} scale --all --replicas=5\n",
        ),
        (
            "JSON patch of the container image path",
            justfile
            + "\nweb-release-jsonpatch:\n"
            + "    kubectl --namespace {{ web_stack_ns }} patch deployment/greatfallstoolbus-org --type json"
            + ' -p \'[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"x"}]\'\n',
        ),
        (
            "merge patch of the container image",
            justfile
            + "\nweb-release-mergepatch:\n"
            + "    kubectl --namespace {{ web_stack_ns }} patch deployment/greatfallstoolbus-org --type merge"
            + ' -p \'{"spec":{"template":{"spec":{"containers":[{"name":"greatfallstoolbus-org","image":"x"}]}}}}\'\n',
        ),
        (
            "delete -f",
            justfile
            + "\nweb-release-unapply:\n"
            + "    kubectl --namespace {{ web_stack_ns }} delete -f /tmp/rendered.yaml\n",
        ),
        (
            "delete --filename",
            justfile
            + "\nweb-release-unapply-long:\n"
            + "    kubectl --namespace {{ web_stack_ns }} delete --filename /tmp/rendered.yaml\n",
        ),
        (
            "edit deployment",
            justfile
            + "\nweb-release-edit:\n"
            + "    kubectl --namespace {{ web_stack_ns }} edit deployment/greatfallstoolbus-org\n",
        ),
    )
    for label, fixture in imperative_pin_cases:
        if not any(
            finding.rule == "imperative-pin"
            for finding in scan_imperative_pin_text(fixture, Path("Justfile"))
        ):
            raise SystemExit(
                f"self-test FAILED: imperative-pin scan accepted {label}"
            )
    web_stack_tree_apply_cases = (
        (
            "apply -k of the web stack tree from an unlisted recipe",
            justfile
            + "\nweb-stack-hotfix:\n"
            + '    kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" --namespace {{ web_stack_ns }} apply -k {{ web_stack_dir }}\n',
        ),
        (
            "apply -f of the web stack tree from an unlisted recipe",
            justfile
            + "\nweb-stack-hotfix:\n"
            + '    kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" --namespace {{ web_stack_ns }} apply -f {{ web_stack_dir }}/deployment.yaml\n',
        ),
        (
            "apply --kustomize of the literal web stack path",
            justfile
            + "\nweb-stack-hotfix:\n"
            + "    kubectl --namespace {{ web_stack_ns }} apply --kustomize k8s/web/greatfallstoolbus-org-production\n",
        ),
        (
            "apply -k of the tree across a backslash continuation",
            justfile
            + "\nweb-stack-hotfix:\n"
            + '    kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" \\\n'
            + "      apply -k {{ web_stack_dir }}\n",
        ),
        (
            "apply -k of the tree injected into the reviewed apply",
            mutate_recipe_body(
                justfile,
                "web-release-apply",
                '    kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" --namespace {{ web_stack_ns }} apply -f "${plan}"\n',
                '    kubectl --kubeconfig "${WEB_APPLY_KUBECONFIG}" --namespace {{ web_stack_ns }} apply -k {{ web_stack_dir }}\n',
                "apply -k of the tree injected into the reviewed apply",
            ),
        ),
    )
    for label, fixture in web_stack_tree_apply_cases:
        if not any(
            finding.rule == "web-stack-tree-apply"
            for finding in scan_imperative_pin_text(fixture, Path("Justfile"))
        ):
            raise SystemExit(
                f"self-test FAILED: web-stack-tree-apply scan accepted {label}"
            )
    stale_tree_allowlist = justfile.replace(
        "web-stack-server-dry-run: web-stack-validate _web-apply-inputs",
        "web-stack-server-dry-run-renamed: web-stack-validate _web-apply-inputs",
        1,
    )
    if not any(
        finding.rule == "imperative-pin-allowlist-stale"
        for finding in scan_imperative_pin_text(stale_tree_allowlist, Path("Justfile"))
    ):
        raise SystemExit(
            "self-test FAILED: web-stack-tree-apply allowlist survived the "
            "removal of the recipe it names"
        )
    stale_allowlist = justfile.replace(
        "web-stack-apply: _web-stack-promotion-interlock",
        "web-stack-apply-renamed: _web-stack-promotion-interlock",
        1,
    )
    if not any(
        finding.rule == "imperative-pin-allowlist-stale"
        for finding in scan_imperative_pin_text(stale_allowlist, Path("Justfile"))
    ):
        raise SystemExit(
            "self-test FAILED: imperative-pin allowlist survived the removal of "
            "the recipe it names"
        )

    # The legacy-CD promotion interlock: it must exist, keep reading live state,
    # and stay the FIRST thing web-stack-apply does.
    if scan_web_stack_promotion_interlock_text(justfile, Path("Justfile")):
        raise SystemExit(
            "self-test FAILED: the committed tree fails its own promotion "
            "interlock contract"
        )
    interlock_cases = (
        (
            "interlock removed",
            re.sub(
                r"\n_web-stack-promotion-interlock:.*?\n(?=\n# Operator-gated)",
                "\n",
                justfile,
                count=1,
                flags=re.DOTALL,
            ),
            "web-stack-promotion-interlock-missing",
        ),
        (
            "interlock stops reading live state",
            mutate_recipe_body(
                justfile,
                "_web-stack-promotion-interlock",
                "get deployment/greatfallstoolbus-org",
                "get service/greatfallstoolbus-org",
                "interlock stops reading live state",
            ),
            "web-stack-promotion-interlock-weakened",
        ),
        (
            "interlock detached from the legacy carrier",
            justfile.replace(
                "web-stack-apply: _web-stack-promotion-interlock "
                "web-stack-server-dry-run",
                "web-stack-apply: web-stack-server-dry-run",
                1,
            ),
            "web-stack-promotion-interlock-detached",
        ),
        (
            "interlock body edited without a receipt update",
            justfile.replace(
                'echo "promotion interlock: live image',
                'echo "promotion interlock (edited): live image',
                1,
            ),
            "web-stack-promotion-interlock-receipt-mismatch",
        ),
        (
            "interlock demoted behind the dry-run",
            justfile.replace(
                "web-stack-apply: _web-stack-promotion-interlock "
                "web-stack-server-dry-run",
                "web-stack-apply: web-stack-server-dry-run "
                "_web-stack-promotion-interlock",
                1,
            ),
            "web-stack-promotion-interlock-detached",
        ),
    )
    for label, fixture, rule in interlock_cases:
        if fixture == justfile:
            raise SystemExit(
                f"self-test FAILED: promotion interlock mutation {label!r} did "
                "not change the Justfile"
            )
        if not any(
            finding.rule == rule
            for finding in scan_web_stack_promotion_interlock_text(
                fixture, Path("Justfile")
            )
        ):
            raise SystemExit(
                f"self-test FAILED: promotion interlock scan accepted {label}"
            )

    release_wrapper_cases = (
        "web-release-ci: web-release-candidate-proof\n    true\n",
        "web-release-ci:\n    just web-release-candidate-proof\n",
        "web-release-ci:\n    echo ok; just web-release-candidate-proof\n",
        "web-release-ci:\n    printf ok && env just web-release-candidate-proof\n",
        "web-release-ci:\n    echo \"$(just web-release-candidate-proof)\"\n",
        "web-release-ci:\n    echo \"$(env just web-release-candidate-proof)\"\n",
        "web-release-ci:\n    echo \"`just web-release-candidate-proof`\"\n",
        "web-release-ci:\n    echo ok; VAR=x just web-release-candidate-proof\n",
        "web-release-ci:\n    echo ok; (just web-release-candidate-proof)\n",
        "web-release-ci:\n    runner=just\n    \"$runner\" web-release-candidate-proof\n",
        "web-release-ci:\n    just\n",
    )
    for index, wrapper in enumerate(release_wrapper_cases, start=1):
        fixture = justfile + "\n" + wrapper
        all_forbidden, _ = all_operator_local_recipe_closure(fixture)
        if "web-release-ci" not in all_forbidden:
            raise SystemExit(
                "self-test FAILED: operator closure accepted web release "
                f"wrapper case {index}"
            )
        expect_web_release_contract_rejection(
            fixture,
            f"unreceipted web release wrapper case {index}",
            "web-release-unreceipted-operator-wrapper",
        )

    release_forbidden, _ = all_operator_local_recipe_closure(justfile)
    release_known = set(all_just_recipe_blocks(justfile)) | set(
        all_just_aliases(justfile)
    )
    release_arities = just_recipe_arities(justfile)
    for recipe in WEB_RELEASE_RECIPE_DEPENDENCIES:
        if not any(
            finding.rule == "workflow-arc-operator-recipe"
            for finding in scan_workflow_text(
                f"steps:\n  - run: just {recipe}\n",
                Path(".github/workflows/fixture.yml"),
                release_forbidden,
                release_known,
                release_arities,
            )
        ):
            raise SystemExit(
                f"self-test FAILED: workflow accepted release recipe {recipe}"
            )
    for label, carrier, carrier_path in (
        (
            "script",
            "#!/usr/bin/env bash\njust web-release-pinned-running-proof\n",
            Path("scripts/release-proof.sh"),
        ),
        (
            "composite",
            "runs:\n  using: composite\n  steps:\n    - shell: bash\n"
            "      run: just web-release-served-proof\n",
            Path(".github/actions/release-proof/action.yml"),
        ),
    ):
        if not any(
            finding.rule == "carrier-arc-operator-recipe"
            for finding in scan_operator_carrier_text(
                carrier,
                carrier_path,
                release_forbidden,
                release_known,
                release_arities,
                fail_on_unresolved=True,
            )
        ):
            raise SystemExit(
                f"self-test FAILED: {label} accepted web release proof"
            )

    unguarded_member = mutate_recipe_dependencies(
        justfile,
        "list-member-add",
        ("_list-member-add-inputs", "_operator-apply-confirm"),
        "reviewed-main removal from member add",
    )
    expect_attended_contract_rejection(
        unguarded_member,
        "reviewed-main removal from member add",
        "attended-recipe-dependencies-mismatch",
    )

    unconfirmed_altcha = mutate_recipe_dependencies(
        justfile,
        "form-altcha-secret-apply",
        ("_mail-kubeconfig-inputs", "_reviewed-clean-main"),
        "apply confirmation removal from ALTCHA rotation",
    )
    expect_attended_contract_rejection(
        unconfirmed_altcha,
        "apply confirmation removal from ALTCHA rotation",
        "attended-recipe-dependencies-mismatch",
    )

    attended_body_mutations = (
        (
            "_mail-kubeconfig-inputs",
            "    if stat.S_IMODE(metadata.st_mode) != 0o600:",
            "    if stat.S_IMODE(metadata.st_mode) != 0o644:",
            "mail kubeconfig mode weakening",
        ),
        (
            "_list-member-add-inputs",
            '    test "${GFTB_LIST_MEMBER_CONSENT:-}" = "confirmed" ||',
            '    test -n "${GFTB_LIST_MEMBER_CONSENT:-}" ||',
            "member consent weakening",
        ),
        (
            "list-member-add",
            "        | if (.total_size == 0 and ($entries | length) == 0) then \"absent\"",
            "        | if (.total_size >= 0 and ($entries | length) == 0) then \"absent\"",
            "Mailman absence ambiguity",
        ),
        (
            "list-member-add",
            '    test "${status}" = "201" ||',
            '    test "${status}" != "500" ||',
            "Mailman POST status weakening",
        ),
        (
            "list-member-add",
            '    core_pod="$(jq -er \'[.items[] | select(.metadata.deletionTimestamp == null)] as $active | if (($active | length) == 1 and',
            '    core_pod="$(jq -er \'[.items[] | select(.metadata.deletionTimestamp == null)] as $active | if (($active | length) >= 1 and',
            "Mailman pod cardinality weakening",
        ),
        (
            "form-altcha-secret-apply",
            '      kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace "${namespace}" delete pod "${old_name}" --wait=true --timeout=120s',
            '      kubectl --kubeconfig "${GFTB_MAIL_KUBECONFIG}" --namespace "${namespace}" rollout restart deployment/form-handler',
            "ALTCHA purpose-bounded replacement weakening",
        ),
        (
            "form-altcha-secret-apply",
            '    jq -e --arg old_uid "${old_uid}" \'[.items[] | select(.metadata.deletionTimestamp == null)] as $active | ($active | length) == 1 and',
            '    jq -e --arg old_uid "${old_uid}" \'[.items[] | select(.metadata.deletionTimestamp == null)] as $active | ($active | length) >= 1 and',
            "ALTCHA replacement cardinality weakening",
        ),
        (
            "form-altcha-secret-apply",
            '    trap \'rm -f "${manifest}"\' EXIT',
            "    true",
            "ALTCHA temporary Secret cleanup removal",
        ),
    )
    for name, old, new, label in attended_body_mutations:
        mutated = mutate_recipe_body(justfile, name, old, new, label)
        expect_attended_contract_rejection(
            mutated, label, "attended-recipe-executable-receipt-mismatch"
        )

    attended_short_circuit = mutate_recipe_body(
        justfile,
        "list-member-add",
        "    #!/usr/bin/env bash\n",
        "    #!/usr/bin/env bash\n    exit 0\n",
        "member-add short circuit",
    )
    expect_attended_contract_rejection(
        attended_short_circuit,
        "member-add short circuit",
        "attended-recipe-executable-receipt-mismatch",
    )

    attended_wrapper = justfile + "\nattended-ci: list-member-add\n    true\n"
    expect_attended_contract_rejection(
        attended_wrapper,
        "unreceipted attended wrapper",
        "attended-unreceipted-operator-wrapper",
    )
    attended_forbidden, _ = all_operator_local_recipe_closure(attended_wrapper)
    attended_known = set(all_just_recipe_blocks(attended_wrapper)) | set(
        all_just_aliases(attended_wrapper)
    )
    attended_arities = just_recipe_arities(attended_wrapper)
    if not any(
        finding.rule == "workflow-arc-operator-recipe"
        for finding in scan_workflow_text(
            "steps:\n  - run: just attended-ci\n",
            Path(".github/workflows/fixture.yml"),
            attended_forbidden,
            attended_known,
            attended_arities,
        )
    ):
        raise SystemExit(
            "self-test FAILED: workflow attended wrapper was accepted"
        )
    if not any(
        finding.rule == "carrier-arc-operator-recipe"
        for finding in scan_operator_carrier_text(
            "#!/usr/bin/env bash\njust list-member-add\n",
            Path("scripts/attended-ci.sh"),
            attended_forbidden,
            attended_known,
            attended_arities,
            fail_on_unresolved=True,
        )
    ):
        raise SystemExit("self-test FAILED: script attended carrier was accepted")

    comment_only = mutate_recipe_body(
        justfile,
        "arc-plan",
        '    core="${GF_ARC_CORE_PATH:-{{ arc_core_default }}}"',
        '    # receipt-insensitive explanation\n    core="${GF_ARC_CORE_PATH:-{{ arc_core_default }}}"',
        "comment-only normalization",
    )
    if scan_arc_operator_contract_text(comment_only, Path("Justfile")):
        raise SystemExit("self-test FAILED: comment-only ARC edit changed the receipt")

    global_drift = justfile.replace(
        f'gf_core_sha := "{GF_CORE_SHA}"', 'gf_core_sha := "' + "0" * 40 + '"', 1
    )
    expect_arc_contract_rejection(
        global_drift, "implementation-core pin drift", "arc-global-contract-mismatch"
    )

    reordered = mutate_recipe_dependencies(
        justfile,
        "arc-apply",
        tuple(reversed(ARC_RECIPE_DEPENDENCIES["arc-apply"])),
        "dependency reorder",
    )
    expect_arc_contract_rejection(
        reordered, "dependency reorder", "arc-recipe-dependencies-mismatch"
    )

    no_exclusive = mutate_recipe_dependencies(
        justfile,
        "arc-plan",
        tuple(
            dependency
            for dependency in ARC_RECIPE_DEPENDENCIES["arc-plan"]
            if dependency != "_arc-exclusive-confirm"
        ),
        "exclusive-confirm removal",
    )
    expect_arc_contract_rejection(
        no_exclusive,
        "exclusive-confirm removal",
        "arc-recipe-dependencies-mismatch",
    )

    body_mutations = (
        (
            "_reviewed-clean-main",
            '    git verify-commit "${head_sha}" >/dev/null',
            '    true # git verify-commit "${head_sha}" >/dev/null',
            "comment-spoofed commit verification",
        ),
        (
            "_reviewed-arc-core",
            '    [[ "$(git -C "${core}" rev-parse HEAD)" == "{{ arc_core_sha }}" ]] ||',
            '    [[ "$(git -C "${core}" rev-parse HEAD)" != "{{ arc_core_sha }}" ]] ||',
            "inverted ARC core equality",
        ),
        (
            "_arc-runtime-contract",
            '    [[ "${target_uid}" == "{{ arc_target_uid }}" ]] ||',
            '    [[ -n "${target_uid}" ]] ||',
            "target UID removal",
        ),
        (
            "_arc-kubeconfig-contract",
            "    if stat.S_IMODE(metadata.st_mode) != 0o600:",
            "    if stat.S_IMODE(metadata.st_mode) != 0o644:",
            "kubeconfig mode weakening",
        ),
        (
            "arc-init",
            '    data_dir="$(pwd)/.tofu-plans/arc-runners.tfdata"',
            '    data_dir="$(pwd)/.tofu-plans/arc-runners.otherdata"',
            "ARC data-directory drift",
        ),
        (
            "arc-apply",
            '    test "${plan_digest}" = "$(tr -d \'\\n\' < .tofu-plans/arc-runners.plan-sha256)" ||',
            '    true ||',
            "plan digest bypass",
        ),
        (
            "arc-apply",
            '    test "${plan_digest}" = "$(tr -d \'\\n\' < .tofu-plans/arc-runners.scope-sha256)" ||',
            '    true ||',
            "scope digest bypass",
        ),
        (
            "arc-apply",
            "    printf '%s\\n' \"${plan_digest}\" > .tofu-plans/arc-runners.apply-attempted",
            "    true",
            "apply tombstone removal",
        ),
        (
            "arc-plan-scope-check",
            '        raise SystemExit("ERROR: ARC plan JSON must be an object")',
            '            raise SystemExit("ERROR: ARC plan JSON must be an object")',
            "embedded Python indentation drift",
        ),
        (
            "arc-plan-scope-check",
            '        [[ "${GFTB_ARC_READBACK_MODE:-}" == "reconcile" && -n "${GFTB_ARC_RECONCILE_PLAN_PATH:-}" && -n "${GFTB_ARC_RECONCILE_DATA_DIR:-}" ]] ||',
            "        true ||",
            "reconcile-mode gate bypass",
        ),
        (
            "arc-capacity-readback",
            '        [[ "${plan_status}" == "0" ]] ||',
            "        true ||",
            "promoted readback no-change bypass",
        ),
        (
            "arc-capacity-readback",
            '        GFTB_ARC_READBACK_MODE=reconcile GFTB_ARC_RECONCILE_PLAN_PATH="${nochange_plan}" GFTB_ARC_RECONCILE_DATA_DIR="${data_dir}" just arc-plan-scope-check',
            "        true",
            "reconcile scope proof removal",
        ),
        (
            "arc-plan",
            "    #!/usr/bin/env bash\n",
            "",
            "recipe shebang removal",
        ),
    )
    for name, old, new, label in body_mutations:
        mutated = mutate_recipe_body(justfile, name, old, new, label)
        expect_arc_contract_rejection(
            mutated, label, "arc-recipe-executable-receipt-mismatch"
        )

    short_circuit = mutate_recipe_body(
        justfile,
        "arc-apply",
        "    #!/usr/bin/env bash\n",
        "    #!/usr/bin/env bash\n    exit 0\n",
        "apply short circuit",
    )
    expect_arc_contract_rejection(
        short_circuit, "apply short circuit", "arc-recipe-executable-receipt-mismatch"
    )

    wrapper_bodies = (
        "arc-ci: arc-apply\n    true\n",
        "arc-ci:\n    just -f Justfile arc-apply\n",
        "arc-ci:\n    just --justfile Justfile arc-apply\n",
        "arc-ci:\n    just -- arc-apply\n",
        "arc-ci:\n    just \\\n        arc-apply\n",
        "arc-ci:\n    just NAME=value arc-apply\n",
        "arc-ci:\n    just workflow-lint arc-apply\n",
        'arc-ci:\n    target=arc-apply\n    just "$target"\n',
        'arc-ci:\n    target=arc-apply\n    just workflow-lint "$target"\n',
    )
    for index, wrapper in enumerate(wrapper_bodies):
        mutated_wrapper = justfile + "\n" + wrapper
        expect_arc_contract_rejection(
            mutated_wrapper,
            f"unreceipted transitive ARC wrapper argv case {index}",
            "arc-unreceipted-operator-wrapper",
        )

    alias_wrapper = justfile + "\nalias arc-ci := arc-apply\n"
    expect_arc_contract_rejection(
        alias_wrapper,
        "unreceipted ARC alias",
        "arc-unreceipted-operator-wrapper",
    )
    alias_recipes, _ = arc_operator_recipe_closure(alias_wrapper)
    alias_known = set(all_just_recipe_blocks(alias_wrapper)) | set(
        all_just_aliases(alias_wrapper)
    )
    if not any(
        finding.rule == "workflow-arc-operator-recipe"
        for finding in scan_workflow_text(
            "steps:\n  - run: just arc-ci\n",
            Path(".github/workflows/fixture.yml"),
            alias_recipes,
            alias_known,
        )
    ):
        raise SystemExit("self-test FAILED: workflow ARC alias was accepted")

    # TIN-3899: the retired CD plane. A workflow that re-declares a
    # repository_dispatch trigger is exactly how the public site repo used to
    # reach `just web-stack-apply` unattended, so the trigger itself is refused,
    # and neither web-stack-apply nor its CD-only helpers remain approved for
    # any hosted workflow.
    if not any(
        finding.rule == "workflow-repository-dispatch-retired"
        for finding in scan_workflow_text(
            "on:\n  repository_dispatch:\n    types: [web-image-published]\n",
            Path(".github/workflows/fixture.yml"),
            alias_recipes,
            alias_known,
        )
    ):
        raise SystemExit(
            "self-test FAILED: a retired repository_dispatch trigger was accepted"
        )
    if any(
        finding.rule == "workflow-repository-dispatch-retired"
        for finding in scan_workflow_text(
            "on:\n  workflow_dispatch: {}\n",
            Path(".github/workflows/fixture.yml"),
            alias_recipes,
            alias_known,
        )
    ):
        raise SystemExit(
            "self-test FAILED: workflow_dispatch was mistaken for the retired "
            "repository_dispatch CD trigger"
        )
    for retired_cd_recipe in (
        "web-stack-apply",
        "web-stack-server-dry-run",
        "web-stack-health",
    ):
        if retired_cd_recipe in HOSTED_WORKFLOW_JUST_ALLOWLIST:
            raise SystemExit(
                "self-test FAILED: the retired legacy web CD recipe "
                f"{retired_cd_recipe!r} is still approved for hosted workflows"
            )
    if (REPO / RETIRED_WEB_CD_WORKFLOW).exists():
        raise SystemExit(
            "self-test FAILED: the retired legacy web CD workflow is still present"
        )

    transitive_wrapper = justfile + "\n" + wrapper_bodies[0]
    transitive_recipes, _ = arc_operator_recipe_closure(transitive_wrapper)
    transitive_known = set(all_just_recipe_blocks(transitive_wrapper)) | set(
        all_just_aliases(transitive_wrapper)
    )
    if not any(
        finding.rule == "workflow-arc-operator-recipe"
        for finding in scan_workflow_text(
            "steps:\n  - run: just arc-ci\n",
            Path(".github/workflows/fixture.yml"),
            transitive_recipes,
            transitive_known,
        )
    ):
        raise SystemExit("self-test FAILED: workflow transitive ARC wrapper was accepted")
    for forbidden in ("arc-validate", "check", "arc-apply"):
        if not any(
            finding.rule == "workflow-arc-operator-recipe"
            for finding in scan_workflow_text(
                f"steps:\n  - run: just {forbidden}\n",
                Path(".github/workflows/fixture.yml"),
                transitive_recipes,
                transitive_known,
            )
        ):
            raise SystemExit(
                f"self-test FAILED: workflow operator recipe {forbidden} was accepted"
            )
    if any(
        finding.rule == "workflow-arc-operator-recipe"
        for finding in scan_workflow_text(
            "steps:\n  - run: just check-hosted\n",
            Path(".github/workflows/fixture.yml"),
            transitive_recipes,
            transitive_known,
        )
    ):
        raise SystemExit("self-test FAILED: hosted-only check was classified as private ARC")
    if not any(
        finding.rule == "workflow-retired-arc-kubeconfig-secret"
        for finding in scan_workflow_text(
            "# secrets.ARC_RUNNERS_KUBECONFIG_B64\n",
            Path(".github/workflows/fixture.yml"),
            transitive_recipes,
            transitive_known,
        )
    ):
        raise SystemExit("self-test FAILED: retired ARC workflow secret was accepted")

    workflow_argv_cases = (
        "just -f Justfile arc-apply",
        "just --justfile Justfile arc-apply",
        "just -- arc-apply",
        "just \\\n  arc-apply",
        "just NAME=value arc-apply",
        "just workflow-lint arc-apply",
    )
    for command in workflow_argv_cases:
        if not any(
            finding.rule == "workflow-arc-operator-recipe"
            for finding in scan_workflow_text(
                f"steps:\n  - run: |\n      {command}\n",
                Path(".github/workflows/fixture.yml"),
                transitive_recipes,
                transitive_known,
            )
        ):
            raise SystemExit(
                f"self-test FAILED: workflow ARC argv bypass was accepted: {command!r}"
            )

    if not any(
        finding.rule == "workflow-unresolved-just-invocation"
        for finding in scan_workflow_text(
            'steps:\n  - run: just "$RECIPE"\n',
            Path(".github/workflows/fixture.yml"),
            transitive_recipes,
            transitive_known,
        )
    ):
        raise SystemExit("self-test FAILED: dynamic workflow Just argv was accepted")

    if not any(
        finding.rule == "workflow-unresolved-just-invocation"
        for finding in scan_workflow_text(
            'steps:\n  - run: just workflow-lint "$RECIPE"\n',
            Path(".github/workflows/fixture.yml"),
            transitive_recipes,
            transitive_known,
        )
    ):
        raise SystemExit(
            "self-test FAILED: dynamic second workflow Just recipe was accepted"
        )

    if not any(
        finding.rule == "workflow-multiple-just-recipes"
        for finding in scan_workflow_text(
            "steps:\n  - run: just check-hosted workflow-lint\n",
            Path(".github/workflows/fixture.yml"),
            transitive_recipes,
            transitive_known,
        )
    ):
        raise SystemExit("self-test FAILED: multi-recipe workflow Just argv was accepted")

    carrier_cases = (
        (
            "shell ARC carrier",
            "#!/usr/bin/env bash\njust arc-apply\n",
            Path("scripts/arc-ci.sh"),
            "carrier-arc-operator-recipe",
        ),
        (
            "dynamic shell carrier",
            '#!/usr/bin/env bash\ntarget=arc-apply\njust "$target"\n',
            Path("scripts/arc-ci.sh"),
            "carrier-unresolved-just-invocation",
        ),
        (
            "composite ARC carrier",
            "runs:\n  using: composite\n  steps:\n    - shell: bash\n      run: just arc-apply\n",
            Path(".github/actions/arc-ci/action.yml"),
            "carrier-arc-operator-recipe",
        ),
        (
            "carrier retired kubeconfig",
            "# ARC_RUNNERS_KUBECONFIG_B64\n",
            Path("scripts/arc-ci.sh"),
            "carrier-retired-arc-kubeconfig-secret",
        ),
    )
    for label, carrier_text, carrier_path, expected_rule in carrier_cases:
        if not any(
            finding.rule == expected_rule
            for finding in scan_operator_carrier_text(
                carrier_text,
                carrier_path,
                transitive_recipes,
                transitive_known,
                fail_on_unresolved=True,
            )
        ):
            raise SystemExit(f"self-test FAILED: {label} was accepted")

    retired_json = justfile + "\n_arc-plan-json:\n    true\n"
    if not any(
        finding.rule == "arc-sensitive-json-carrier-retained"
        for finding in scan_arc_operator_contract_text(retired_json, Path("Justfile"))
    ):
        raise SystemExit("self-test FAILED: persistent ARC plan JSON was accepted")

    retired_secret = justfile + "\narc-app-secret-dry-run:\n    true\n"
    if not any(
        finding.rule == "arc-secret-print-carrier-retained"
        for finding in scan_arc_operator_contract_text(
            retired_secret, Path("Justfile")
        )
    ):
        raise SystemExit("self-test FAILED: ARC Secret printing recipe was accepted")

    destroy_bypass = justfile + "\n# ALLOW_ARC_DESTROY\n"
    if not any(
        finding.rule == "arc-destroy-bypass-retained"
        for finding in scan_arc_operator_contract_text(
            destroy_bypass, Path("Justfile")
        )
    ):
        raise SystemExit("self-test FAILED: ARC destroy bypass was accepted")

    scope_source = extract_arc_scope_checker(justfile)
    valid = valid_arc_scope_plan()
    valid_result = run_arc_scope_checker(scope_source, valid)
    if valid_result.returncode != 0:
        raise SystemExit(
            "self-test FAILED: exact valid ARC scope was rejected: "
            + (valid_result.stdout + valid_result.stderr).strip()
        )
    resource_change = valid["resource_changes"][0]["change"]  # type: ignore[index]
    if resource_change["before_sensitive"] == resource_change["after_sensitive"]:  # type: ignore[index]
        raise SystemExit(
            "self-test FAILED: asymmetric resource sensitivity scaffolding fixture collapsed"
        )

    positive_output_plans: list[tuple[str, dict[str, object]]] = []
    plan = copy.deepcopy(valid)
    plan["output_changes"] = {}
    positive_output_plans.append(("empty output_changes", plan))
    plan = copy.deepcopy(valid)
    plan["output_changes"]["fixture_output"]["before"] = {  # type: ignore[index]
        "alpha": 1,
        "nested": {"first": True, "second": [None, "fixture"]},
    }
    plan["output_changes"]["fixture_output"]["after"] = {  # type: ignore[index]
        "nested": {"second": [None, "fixture"], "first": True},
        "alpha": 1,
    }
    positive_output_plans.append(("reordered structured no-op output", plan))
    plan = copy.deepcopy(valid)
    plan["output_changes"]["fixture_output"]["before_sensitive"] = True  # type: ignore[index]
    plan["output_changes"]["fixture_output"]["after_sensitive"] = True  # type: ignore[index]
    positive_output_plans.append(("sensitive no-op output", plan))
    for label, plan in positive_output_plans:
        result = run_arc_scope_checker(scope_source, plan)
        if result.returncode != 0:
            raise SystemExit(
                f"self-test FAILED: valid {label} was rejected: "
                + (result.stdout + result.stderr).strip()
            )

    for field, diagnostic in (
        ("format_version", "format_version must be exactly 1.2"),
        ("terraform_version", "terraform_version must be exactly 1.11.6"),
        ("errored", "errored must be exactly false"),
    ):
        plan = copy.deepcopy(valid)
        plan.pop(field)
        expect_scope_rejection(scope_source, f"missing {field}", plan, diagnostic)
    for field, value, diagnostic in (
        ("format_version", "1.1", "format_version must be exactly 1.2"),
        ("format_version", 1.2, "format_version must be exactly 1.2"),
        ("terraform_version", "1.11.5", "terraform_version must be exactly 1.11.6"),
        ("terraform_version", 1.116, "terraform_version must be exactly 1.11.6"),
        ("errored", True, "errored must be exactly false"),
        ("errored", 0, "errored must be exactly false"),
    ):
        plan = copy.deepcopy(valid)
        plan[field] = value
        expect_scope_rejection(scope_source, f"wrong {field}", plan, diagnostic)
    for field in ("complete", "applyable"):
        plan = copy.deepcopy(valid)
        plan[field] = True
        expect_scope_rejection(
            scope_source,
            f"unexpected {field}",
            plan,
            "fields outside the pinned OpenTofu schema",
        )

    plan = copy.deepcopy(valid)
    plan["foreign_schema_field"] = False
    expect_scope_rejection(
        scope_source,
        "foreign top-level field",
        plan,
        "fields outside the pinned OpenTofu schema",
    )

    for field, value in (("mode", "data"), ("type", "other"), ("name", "other")):
        plan = copy.deepcopy(valid)
        plan["resource_changes"][0][field] = value  # type: ignore[index]
        expect_scope_rejection(scope_source, f"wrong resource {field}", plan, "observed")

    drift_cases = (
        ("non-list resource drift", {}, "resource_drift must be a list"),
        ("malformed resource drift", ["bad"], "entry must be an object"),
        (
            "resource drift",
            [{"address": "module.drift", "change": {"actions": ["update"]}}],
            "contains resource drift",
        ),
    )
    for label, value, diagnostic in drift_cases:
        plan = copy.deepcopy(valid)
        plan["resource_drift"] = value
        expect_scope_rejection(scope_source, label, plan, diagnostic)

    output_cases = (
        ("non-object outputs", [], "output_changes must be an object"),
        ("malformed output", {"x": "bad"}, "value must be an object"),
    )
    for label, value, diagnostic in output_cases:
        plan = copy.deepcopy(valid)
        plan["output_changes"] = value
        expect_scope_rejection(scope_source, label, plan, diagnostic)

    for actions in (["create"], ["update"], ["delete"], ["delete", "create"]):
        plan = copy.deepcopy(valid)
        plan["output_changes"]["fixture_output"]["actions"] = actions  # type: ignore[index]
        expect_scope_rejection(
            scope_source, f"output actions {actions!r}", plan, "exactly no-op actions"
        )

    plan = copy.deepcopy(valid)
    plan["output_changes"]["fixture_output"]["after"] = "changed-fixture-value"  # type: ignore[index]
    expect_scope_rejection(scope_source, "changed output value", plan, "modifies the value")

    plan = copy.deepcopy(valid)
    plan["output_changes"]["fixture_output"]["before"] = True  # type: ignore[index]
    plan["output_changes"]["fixture_output"]["after"] = 1  # type: ignore[index]
    expect_scope_rejection(
        scope_source, "type-drifted output value", plan, "modifies the value"
    )

    plan = copy.deepcopy(valid)
    plan["output_changes"][""] = plan["output_changes"].pop("fixture_output")  # type: ignore[union-attr]
    expect_scope_rejection(scope_source, "empty output name", plan, "nonempty string")

    for unknown_mask in (True, {}, [], {"opaque": False}, "false"):
        plan = copy.deepcopy(valid)
        plan["output_changes"]["fixture_output"]["after_unknown"] = unknown_mask  # type: ignore[index]
        expect_scope_rejection(
            scope_source, "output unknown after-value", plan, "unknown after-values"
        )

    plan = copy.deepcopy(valid)
    plan["output_changes"]["fixture_output"]["after_sensitive"] = True  # type: ignore[index]
    expect_scope_rejection(
        scope_source, "output sensitive-shape drift", plan, "sensitive-field shape"
    )

    plan = copy.deepcopy(valid)
    plan["output_changes"]["fixture_output"]["before_sensitive"] = "false"  # type: ignore[index]
    plan["output_changes"]["fixture_output"]["after_sensitive"] = "false"  # type: ignore[index]
    expect_scope_rejection(
        scope_source, "invalid output sensitive mask", plan, "invalid sensitive-field shape"
    )

    for field, value in (
        ("replace_paths", []),
        ("importing", {}),
        ("generated_config", "fixture"),
        ("before_identity", {}),
        ("after_identity", {}),
        ("unknown", False),
    ):
        plan = copy.deepcopy(valid)
        plan["output_changes"]["fixture_output"][field] = value  # type: ignore[index]
        expect_scope_rejection(
            scope_source, f"output {field} metadata", plan, "unexpected="
        )

    plan = copy.deepcopy(valid)
    del plan["output_changes"]["fixture_output"]["after_unknown"]  # type: ignore[index]
    expect_scope_rejection(scope_source, "incomplete output Change", plan, "missing=")

    for deferred in ([], [{"reason": "fixture"}]):
        plan = copy.deepcopy(valid)
        plan["deferred_changes"] = deferred
        expect_scope_rejection(
            scope_source,
            "unsupported deferred_changes field",
            plan,
            "fields outside the pinned OpenTofu schema",
        )

    for owner, key, value in (
        ("resource", "previous_address", "module.old.helm_release.arc_runner"),
        ("resource", "deposed", "deadbeef"),
        ("resource", "generated_config", "generated"),
        ("change", "importing", {"id": "runner"}),
        ("change", "generated_config", "generated"),
    ):
        plan = copy.deepcopy(valid)
        extra = {
            "address": "module.old.helm_release.old",
            "mode": "managed",
            "type": "helm_release",
            "name": "old",
            "change": {"actions": ["no-op"]},
        }
        if owner == "resource":
            extra[key] = value
        else:
            extra["change"][key] = value  # type: ignore[index]
        plan["resource_changes"].append(extra)  # type: ignore[union-attr]
        expect_scope_rejection(
            scope_source, f"no-op {key} metadata", plan, "move/import/deposed/generated"
        )

    plan = copy.deepcopy(valid)
    plan["resource_changes"][0]["change"]["replace_paths"] = [["values"]]  # type: ignore[index]
    expect_scope_rejection(scope_source, "replacement path", plan, "replacement paths")

    plan = copy.deepcopy(valid)
    plan["resource_changes"][0]["change"]["after_unknown"] = {"values": True}  # type: ignore[index]
    expect_scope_rejection(scope_source, "unexpected unknown", plan, "unexpected unknown")

    sensitive_mask_cases = (
        ("missing true path", {"repository_password": False}, "mark exactly"),
        (
            "extra true path",
            {"repository_password": True, "unexpected": True},
            "mark exactly",
        ),
        (
            "moved true path",
            {"nested": {"repository_password": True}},
            "mark exactly",
        ),
        ("non-Boolean true mask", {"repository_password": 1}, "non-Boolean"),
        (
            "non-Boolean false scaffolding",
            {"metadata": [None], "repository_password": True},
            "non-Boolean",
        ),
    )
    for mask_name in ("before_sensitive", "after_sensitive"):
        for label, mask, diagnostic in sensitive_mask_cases:
            plan = copy.deepcopy(valid)
            plan["resource_changes"][0]["change"][mask_name] = mask  # type: ignore[index]
            expect_scope_rejection(
                scope_source,
                f"resource {mask_name} {label}",
                plan,
                diagnostic,
            )

    plan = copy.deepcopy(valid)
    plan["resource_changes"][0]["change"]["before"]["timeout"] = 1  # type: ignore[index]
    plan["resource_changes"][0]["change"]["after"]["timeout"] = 2  # type: ignore[index]
    expect_scope_rejection(scope_source, "known field drift", plan, "outside values")

    def swap_storage(document: str, low: str, high: str) -> str:
        """Reverse the runner request/limit storage pair inside one values doc."""
        swapped = document.replace(
            f'"limits":\n          "cpu": "4"\n          "ephemeral-storage": "{high}"',
            f'"limits":\n          "cpu": "4"\n          "ephemeral-storage": "{low}"',
            1,
        )
        return swapped.replace(
            f'"requests":\n          "cpu": "500m"\n          "ephemeral-storage": "{low}"',
            f'"requests":\n          "cpu": "500m"\n          "ephemeral-storage": "{high}"',
            1,
        )

    def duplicate_resources(document: str, low: str, high: str) -> str:
        """Add a second runner-container resources block with storage fields."""
        anchor = f'          "ephemeral-storage": "{low}"\n          "memory": "1Gi"\n'
        if document.count(anchor) != 1:
            raise SystemExit(
                "self-test FAILED: could not construct duplicate resources fixture"
            )
        return document.replace(
            anchor,
            anchor
            + '      "resources":\n'
            + f'        "limits":\n          "ephemeral-storage": "{high}"\n'
            + f'        "requests":\n          "ephemeral-storage": "{low}"\n',
            1,
        )

    trailing_container = (
        '    - "command": []\n'
        '      "name": "observer"\n'
        '      "resources":\n'
        '        "requests":\n'
        '          "ephemeral-storage": "1Gi"\n'
    )
    yaml_cases = (
        (
            "reversed request and limit",
            swap_storage(ARC_BEFORE_VALUES, "4Gi", "8Gi"),
            swap_storage(ARC_AFTER_VALUES, "8Gi", "16Gi"),
            "expected runner resources.requests",
        ),
        (
            "wrong ancestry",
            ARC_BEFORE_VALUES.replace('"template":\n', '"malicious":\n', 1),
            ARC_AFTER_VALUES.replace('"template":\n', '"malicious":\n', 1),
            "not under template.spec.containers",
        ),
        (
            "storage outside runner",
            ARC_BEFORE_VALUES + '"outside":\n  "ephemeral-storage": "1Gi"\n',
            ARC_AFTER_VALUES + '"outside":\n  "ephemeral-storage": "1Gi"\n',
            "outside the runner container",
        ),
        (
            "storage after runner",
            ARC_BEFORE_VALUES + trailing_container,
            ARC_AFTER_VALUES + trailing_container,
            "outside the runner container",
        ),
        (
            "nested resources",
            ARC_BEFORE_VALUES.replace(
                '      "resources":\n', '      "wrapper":\n        "resources":\n', 1
            ),
            ARC_AFTER_VALUES.replace(
                '      "resources":\n', '      "wrapper":\n        "resources":\n', 1
            ),
            "outside resources requests/limits",
        ),
        (
            "duplicate resources",
            duplicate_resources(ARC_BEFORE_VALUES, "4Gi", "8Gi"),
            duplicate_resources(ARC_AFTER_VALUES, "8Gi", "16Gi"),
            "duplicate runner ephemeral-storage field",
        ),
    )
    for label, before_yaml, after_yaml, diagnostic in yaml_cases:
        plan = copy.deepcopy(valid)
        plan["resource_changes"][0]["change"]["before"]["values"] = [before_yaml]  # type: ignore[index]
        plan["resource_changes"][0]["change"]["after"]["values"] = [after_yaml]  # type: ignore[index]
        expect_scope_rejection(scope_source, label, plan, diagnostic)

    # ---------------------------------------------------------------------
    # TIN-3902 runner-group cutover and its rollback.
    #
    # The guard admits exactly three enumerated plan shapes. Each move shape
    # carries exactly two admitted storage transitions: the original combined
    # one and, since TIN-2299's capacity bump applied on 2026-08-17 as
    # helm_release revision 6 (decomposing the cutover), the post-capacity
    # zero-delta one. `valid` above proves the pre-existing capacity plan is
    # still admitted unchanged. Everything after these is refused.
    # ---------------------------------------------------------------------
    cutover = valid_arc_cutover_plan()
    rollback = valid_arc_rollback_plan()
    post_capacity_cutover = valid_arc_post_capacity_cutover_plan()
    post_capacity_rollback = valid_arc_post_capacity_rollback_plan()
    for label, plan in (
        ("runner-group cutover", cutover),
        ("runner-group rollback", rollback),
        ("post-capacity runner-group cutover", post_capacity_cutover),
        ("post-capacity runner-group rollback", post_capacity_rollback),
    ):
        result = run_arc_scope_checker(scope_source, plan)
        if result.returncode != 0:
            raise SystemExit(
                f"self-test FAILED: reviewed {label} plan was rejected: "
                + (result.stdout + result.stderr).strip()
            )

    for pair_label, forward, reverse in (
        ("cutover", cutover, rollback),
        ("post-capacity cutover", post_capacity_cutover, post_capacity_rollback),
    ):
        if forward["resource_changes"][1]["change"]["before"]["values"] != (  # type: ignore[index]
            reverse["resource_changes"][1]["change"]["after"]["values"]  # type: ignore[index]
        ) or forward["resource_changes"][1]["change"]["after"]["values"] != (  # type: ignore[index]
            reverse["resource_changes"][1]["change"]["before"]["values"]  # type: ignore[index]
        ):
            raise SystemExit(
                "self-test FAILED: rollback fixture is not the byte-exact reverse "
                f"of the {pair_label}"
            )

    extra_resource = {
        "address": "kubernetes_priority_class_v1.arc_runner[0]",
        "mode": "managed",
        "type": "kubernetes_priority_class_v1",
        "name": "arc_runner",
        "change": {"actions": ["create"], "before": None, "after": {"value": -50}},
    }
    for label, base in (("cutover", cutover), ("rollback", rollback), ("capacity", valid)):
        plan = copy.deepcopy(base)
        plan["resource_changes"].append(copy.deepcopy(extra_resource))  # type: ignore[union-attr]
        expect_scope_rejection(
            scope_source, f"{label} plus an extra resource create", plan, "observed"
        )

    for label, actions, replace_paths in (
        ("helm delete", ["delete"], None),
        ("helm replace", ["delete", "create"], [["name"]]),
        ("helm create-then-delete replace", ["create", "delete"], [["name"]]),
    ):
        plan = copy.deepcopy(cutover)
        helm_change = plan["resource_changes"][1]["change"]  # type: ignore[index]
        helm_change["actions"] = actions
        if replace_paths is not None:
            helm_change["replace_paths"] = replace_paths
        expect_scope_rejection(scope_source, f"cutover with a {label}", plan, "observed")

    plan = copy.deepcopy(cutover)
    plan["resource_changes"][1]["change"]["replace_paths"] = [["name"]]  # type: ignore[index]
    expect_scope_rejection(
        scope_source, "cutover with a helm replacement path", plan, "replacement paths"
    )

    # A resource claiming no-op is dropped from the reviewed set, so it must
    # actually be unchanged. An honest no-op rides along; a lying one is refused.
    honest_noop = {
        "address": "module.gh_nix.helm_release.bystander",
        "mode": "managed",
        "type": "helm_release",
        "name": "bystander",
        "change": {
            "actions": ["no-op"],
            "before": {"values": ["unchanged"]},
            "after": {"values": ["unchanged"]},
        },
    }
    for label, base in (("cutover", cutover), ("rollback", rollback), ("capacity", valid)):
        plan = copy.deepcopy(base)
        plan["resource_changes"].append(copy.deepcopy(honest_noop))  # type: ignore[union-attr]
        result = run_arc_scope_checker(scope_source, plan)
        if result.returncode != 0:
            raise SystemExit(
                f"self-test FAILED: {label} plus an honest no-op was rejected: "
                + (result.stdout + result.stderr).strip()
            )
        plan = copy.deepcopy(base)
        lying_noop = copy.deepcopy(honest_noop)
        lying_noop["change"]["after"] = {"values": ["smuggled"]}  # type: ignore[index]
        plan["resource_changes"].append(lying_noop)  # type: ignore[union-attr]
        expect_scope_rejection(
            scope_source,
            f"{label} plus a no-op resource that actually changes",
            plan,
            "no-op resource change that modifies",
        )

    for label, actions in (("update", ["update"]), ("replacement", ["delete", "create"])):
        plan = copy.deepcopy(cutover)
        plan["resource_changes"][0]["change"]["actions"] = actions  # type: ignore[index]
        expect_scope_rejection(
            scope_source, f"cutover with a policy {label}", plan, "observed"
        )

    for label, entry_name, replacement in (
        ("maxRunners 4 -> 8", "maxRunners", "8"),
        ("githubConfigUrl", "githubConfigUrl", "https://github.com/Great-Falls-Tool-Bus-Evil"),
        ("scaleSetLabels[0]", "scaleSetLabels[0]", "great-falls-tool-bus-infra"),
        ("runnerScaleSetName", "runnerScaleSetName", "great-falls-tool-bus-nix-v2"),
    ):
        for shape_label, base, side in (
            ("cutover", cutover, "after"),
            ("rollback", rollback, "after"),
        ):
            plan = copy.deepcopy(base)
            entries = plan["resource_changes"][1]["change"][side]["set"]  # type: ignore[index]
            matched = [entry for entry in entries if entry["name"] == entry_name]
            if len(matched) != 1:
                raise SystemExit(
                    f"self-test FAILED: could not construct {entry_name} fixture"
                )
            matched[0]["value"] = replacement
            expect_scope_rejection(
                scope_source,
                f"{shape_label} with a {label} set change",
                plan,
                "exactly runnerGroup",
            )

    plan = copy.deepcopy(valid)
    [entry] = [  # type: ignore[misc]
        entry
        for entry in plan["resource_changes"][0]["change"]["after"]["set"]  # type: ignore[index]
        if entry["name"] == "runnerGroup"
    ]
    entry["value"] = "great-falls-tool-bus-infra"
    expect_scope_rejection(
        scope_source,
        "capacity plan smuggling a runnerGroup move",
        plan,
        "outside values",
    )

    for label, group in (
        ("unreviewed group", "tinyland-shared"),
        ("no move at all", "default"),
    ):
        plan = copy.deepcopy(cutover)
        entries = plan["resource_changes"][1]["change"]["after"]["set"]  # type: ignore[index]
        [entry] = [entry for entry in entries if entry["name"] == "runnerGroup"]
        entry["value"] = group
        expect_scope_rejection(
            scope_source, f"cutover into an {label}", plan, "exactly runnerGroup"
        )

    values_cases = (
        (
            "unreviewed runner image digest",
            lambda document: document.replace(
                "1ccce66d92dadecb648ea5c509a4806bf319b73e9730828e234c19670325397b",
                "0" * 64,
                1,
            ),
            "advanced ARC role-pin digest",
        ),
        (
            "missing arc-runner priorityClassName",
            lambda document: document.replace(
                '    "priorityClassName": "arc-runner"\n', "", 1
            ),
            "one arc-runner priorityClassName",
        ),
        (
            "relocated priorityClassName",
            lambda document: document.replace(
                '    "priorityClassName": "arc-runner"\n', "", 1
            ).replace(
                '  "spec":\n    "containers":\n    - "name": "listener"\n',
                '  "spec":\n    "priorityClassName": "arc-runner"\n'
                '    "containers":\n    - "name": "listener"\n',
                1,
            ),
            "not a direct template.spec field",
        ),
        (
            "missing GF_FLYWHEEL_PROFILE_STATE",
            lambda document: document.replace(
                '      - "name": "GF_FLYWHEEL_PROFILE_STATE"\n'
                '        "value": "shared-cache-backed"\n',
                "",
                1,
            ),
            "one GF_FLYWHEEL_PROFILE_STATE env entry",
        ),
        (
            "retargeted GF_FLYWHEEL_PROFILE_STATE value",
            lambda document: document.replace(
                '      - "name": "GF_FLYWHEEL_PROFILE_STATE"\n'
                '        "value": "shared-cache-backed"\n',
                '      - "name": "GF_FLYWHEEL_PROFILE_STATE"\n'
                '        "value": "executor-backed"\n',
                1,
            ),
            "shared-cache-backed pair",
        ),
        (
            "extra runner memory change",
            lambda document: document.replace(
                '          "memory": "8Gi"\n', '          "memory": "16Gi"\n', 1
            ),
            "beyond the reviewed runner-group",
        ),
        (
            "extra runner env var",
            lambda document: document.replace(
                '      - "name": "RUNNER_ALLOW_RUNASROOT"\n',
                '      - "name": "GF_UNREVIEWED"\n        "value": "1"\n'
                '      - "name": "RUNNER_ALLOW_RUNASROOT"\n',
                1,
            ),
            "beyond the reviewed runner-group",
        ),
        (
            "listener node move",
            lambda document: document.replace('"bumble"', '"sting"', 1),
            "beyond the reviewed runner-group",
        ),
    )
    for label, mutate, diagnostic in values_cases:
        for shape_label, base, side_name in (
            ("cutover", cutover, "after"),
            ("rollback", rollback, "before"),
            ("post-capacity cutover", post_capacity_cutover, "after"),
            ("post-capacity rollback", post_capacity_rollback, "before"),
        ):
            plan = copy.deepcopy(base)
            side = plan["resource_changes"][1]["change"][side_name]  # type: ignore[index]
            mutated = mutate(side["values"][0])
            if mutated == side["values"][0]:
                raise SystemExit(f"self-test FAILED: could not construct {label} fixture")
            side["values"] = [mutated]
            expect_scope_rejection(
                scope_source, f"{shape_label} with an {label}", plan, diagnostic
            )

    # The zero-storage-delta admission is exactly HIGH -> HIGH on the two move
    # shapes and nothing wider: an extra delta on the untouched (pre-cutover)
    # side, a rollback claiming the never-live LOW -> HIGH transition, a mixed
    # 8Gi/8Gi state on either side, and a capacity plan without its bump are
    # all still refused.
    def demote_storage_lines(document: str) -> str:
        """Rewrite one values doc's runner storage from 8/16Gi down to 4/8Gi."""
        demoted = document.replace(
            '          "ephemeral-storage": "8Gi"\n',
            '          "ephemeral-storage": "4Gi"\n',
            1,
        ).replace(
            '          "ephemeral-storage": "16Gi"\n',
            '          "ephemeral-storage": "8Gi"\n',
            1,
        )
        if demoted == document:
            raise SystemExit(
                "self-test FAILED: could not construct demoted storage fixture"
            )
        return demoted

    def mixed_storage_lines(document: str) -> str:
        """Rewrite one values doc's runner storage limit to the mixed 8Gi/8Gi state."""
        mixed = document.replace(
            '          "ephemeral-storage": "16Gi"\n',
            '          "ephemeral-storage": "8Gi"\n',
            1,
        )
        if mixed == document:
            raise SystemExit(
                "self-test FAILED: could not construct mixed storage fixture"
            )
        return mixed

    plan = copy.deepcopy(post_capacity_cutover)
    before_side = plan["resource_changes"][1]["change"]["before"]  # type: ignore[index]
    before_side["values"] = [
        before_side["values"][0].replace(
            '      - "name": "RUNNER_ALLOW_RUNASROOT"\n',
            '      - "name": "GF_UNREVIEWED"\n        "value": "1"\n'
            '      - "name": "RUNNER_ALLOW_RUNASROOT"\n',
            1,
        )
    ]
    expect_scope_rejection(
        scope_source,
        "post-capacity cutover with an extra pre-cutover-side env var",
        plan,
        "beyond the reviewed runner-group",
    )

    plan = copy.deepcopy(post_capacity_rollback)
    after_side = plan["resource_changes"][1]["change"]["after"]  # type: ignore[index]
    after_side["values"] = [
        after_side["values"][0].replace(
            '          "memory": "8Gi"\n', '          "memory": "16Gi"\n', 1
        )
    ]
    expect_scope_rejection(
        scope_source,
        "post-capacity rollback with an extra post-rollback-side memory change",
        plan,
        "beyond the reviewed runner-group",
    )

    plan = copy.deepcopy(post_capacity_rollback)
    helm_change = plan["resource_changes"][1]["change"]  # type: ignore[index]
    helm_change["before"]["values"] = [
        demote_storage_lines(helm_change["before"]["values"][0])
    ]
    expect_scope_rejection(
        scope_source,
        "rollback moving storage LOW -> HIGH",
        plan,
        "to move as one of",
    )

    for side_label, side_name in (("before", "before"), ("after", "after")):
        plan = copy.deepcopy(post_capacity_cutover)
        side = plan["resource_changes"][1]["change"][side_name]  # type: ignore[index]
        side["values"] = [mixed_storage_lines(side["values"][0])]
        expect_scope_rejection(
            scope_source,
            f"cutover with a mixed 8Gi/8Gi {side_label} storage state",
            plan,
            "to move as one of",
        )

    plan = copy.deepcopy(valid)
    helm_change = plan["resource_changes"][0]["change"]  # type: ignore[index]
    helm_change["before"]["values"] = [ARC_AFTER_VALUES]
    helm_change["after"]["values"] = [ARC_AFTER_VALUES]
    expect_scope_rejection(
        scope_source,
        "capacity plan with zero storage delta",
        plan,
        "to move as one of",
    )

    policy_cases = (
        ("policy", "legacy-default"),
        ("scale_sets", [{"group": "default", "name": "great-falls-tool-bus-nix"}]),
        (
            "scale_sets",
            [
                {"group": "great-falls-tool-bus-infra", "name": "great-falls-tool-bus-nix"},
                {"group": "great-falls-tool-bus-infra", "name": "great-falls-tool-bus-docker"},
            ],
        ),
        ("legacy_reason", "TIN-3209 core nine"),
    )
    for field, replacement in policy_cases:
        plan = copy.deepcopy(cutover)
        plan["resource_changes"][0]["change"]["after"]["input"][field] = replacement  # type: ignore[index]
        expect_scope_rejection(
            scope_source,
            f"cutover policy receipt with an unreviewed {field}",
            plan,
            "reviewed",
        )
        plan = copy.deepcopy(rollback)
        plan["resource_changes"][0]["change"]["before"]["input"][field] = replacement  # type: ignore[index]
        expect_scope_rejection(
            scope_source,
            f"rollback policy receipt with an unreviewed {field}",
            plan,
            "reviewed",
        )

    plan = copy.deepcopy(cutover)
    plan["resource_changes"][0]["change"]["after_unknown"]["input"]["policy"] = True  # type: ignore[index]
    expect_scope_rejection(
        scope_source, "cutover policy receipt with an unknown policy", plan, "unknown mask"
    )

    plan = copy.deepcopy(rollback)
    plan["resource_changes"][0]["action_reason"] = "delete_because_count_index"  # type: ignore[index]
    expect_scope_rejection(
        scope_source,
        "rollback policy destroy for an unreviewed reason",
        plan,
        "delete_because_no_resource_config",
    )

    plan = copy.deepcopy(rollback)
    del plan["resource_changes"][0]["action_reason"]  # type: ignore[index]
    expect_scope_rejection(
        scope_source,
        "rollback policy destroy with no reason",
        plan,
        "delete_because_no_resource_config",
    )

    output_cases: list[tuple[str, dict[str, object], str]] = []
    plan = copy.deepcopy(cutover)
    plan["output_changes"]["nix_runner_group"]["after"] = "default"  # type: ignore[index]
    output_cases.append(("cutover output into the Default group", plan, "reviewed value"))
    plan = copy.deepcopy(cutover)
    del plan["output_changes"]["nix_runner_group"]  # type: ignore[union-attr]
    output_cases.append(("cutover missing a reviewed output", plan, "missing="))
    plan = copy.deepcopy(cutover)
    plan["output_changes"]["unreviewed_output"] = {  # type: ignore[index]
        "actions": ["create"],
        "before": None,
        "after": "surprise",
        "after_unknown": False,
        "before_sensitive": False,
        "after_sensitive": False,
    }
    output_cases.append(("cutover with an unreviewed output create", plan, "no-op actions"))
    plan = copy.deepcopy(cutover)
    plan["output_changes"]["nix_runner_group"]["actions"] = ["delete"]  # type: ignore[index]
    output_cases.append(("cutover with an inverted output action", plan, "no-op actions"))
    plan = copy.deepcopy(rollback)
    plan["output_changes"]["nix_runner_group"]["actions"] = ["create"]  # type: ignore[index]
    output_cases.append(("rollback with an inverted output action", plan, "no-op actions"))
    plan = copy.deepcopy(valid)
    plan["output_changes"]["nix_runner_group"] = {  # type: ignore[index]
        "actions": ["create"],
        "before": None,
        "after": "great-falls-tool-bus-infra",
        "after_unknown": False,
        "before_sensitive": False,
        "after_sensitive": False,
    }
    output_cases.append(("capacity plan with a runner-group output", plan, "no-op actions"))
    for label, plan, diagnostic in output_cases:
        expect_scope_rejection(scope_source, label, plan, diagnostic)

    bridge_text = (REPO / WEB_GENERATION40_BRIDGE_WORKFLOW).read_text(encoding="utf-8")
    deployment_text = (REPO / WEB_GENERATION40_DEPLOYMENT).read_text(encoding="utf-8")
    if scan_web_generation40_bridge_contract(bridge_text, deployment_text):
        raise SystemExit("self-test FAILED: committed generation-40 bridge contract drifted")
    mutated_bridge = bridge_text.replace(WEB_GENERATION40_TARGET_SOURCE, "0" * 40, 1)
    if not any(
        finding.rule == "web-generation40-bridge-bytes"
        for finding in scan_web_generation40_bridge_contract(mutated_bridge, deployment_text)
    ):
        raise SystemExit("self-test FAILED: generation-40 bridge mutation was accepted")
    mutated_deployment = deployment_text.replace(WEB_GENERATION40_TARGET_IMAGE, "ghcr.io/great-falls-tool-bus/gftb-site@sha256:" + "0" * 64, 1)
    if not any(
        finding.rule == "web-generation40-desired-state-freeze"
        for finding in scan_web_generation40_bridge_contract(bridge_text, mutated_deployment)
    ):
        raise SystemExit("self-test FAILED: generation-40 desired-state drift was accepted")

    run_web_release_semantic_fixtures()
    run_web_release_mutation_fixtures()
    check_critical_recipe_shell_syntax()
    print("public-operator-surface self-test passed")


def main() -> int:
    if "--self-test" in sys.argv:
        self_test()
        return 0

    findings = (
        scan_docs()
        + scan_workflows()
        + scan_edge_workflow_contract()
        + scan_scripts()
        + scan_composite_actions()
        + scan_arc_operator_contract_text(
            (REPO / "Justfile").read_text(encoding="utf-8"), Path("Justfile")
        )
        + scan_attended_operator_contract_text(
            (REPO / "Justfile").read_text(encoding="utf-8"), Path("Justfile")
        )
        + scan_web_release_operator_contract_text(
            (REPO / "Justfile").read_text(encoding="utf-8"), Path("Justfile")
        )
        + scan_imperative_pin_text(
            (REPO / "Justfile").read_text(encoding="utf-8"), Path("Justfile")
        )
        + scan_web_stack_promotion_interlock_text(
            (REPO / "Justfile").read_text(encoding="utf-8"), Path("Justfile")
        )
        + scan_web_release_validation_script_bytes(
            (REPO / WEB_RELEASE_VALIDATION_SCRIPT).read_bytes()
        )
        + scan_web_release_toolchain_text(
            (REPO / "flake.nix").read_text(encoding="utf-8"),
            (REPO / "flake.lock").read_bytes(),
        )
    )
    if findings:
        print("public operator surface validation FAILED:", file=sys.stderr)
        for finding in findings:
            print(
                f"  [{finding.rule}] {finding.path}:{finding.line}: {finding.text}",
                file=sys.stderr,
            )
        return 1

    scanned = (
        len(git_files(PUBLIC_DOC_GLOBS))
        + len(git_files(WORKFLOW_GLOBS))
        + len(git_files(SCRIPT_GLOBS))
        + len(git_files(COMPOSITE_ACTION_GLOBS))
    )
    print(
        f"public operator surface validation passed ({scanned} tracked surface files)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())