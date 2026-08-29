Warning: truncated output (original token count: 83756)
Total output lines: 8270

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
    "web-release-render": _receipt(
        "513bc0ad22178c9d", "b30a8177165af253", "68571a990e279382", "f5929829bd04e386"
    ),
    "_web-release-kubeconfig-inputs": _receipt(
        "a2601a6824409840", "45f4b6df270eb1db", "fe2386345de59807", "2e9d451a53f33f47"
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
WEB_RELEASE_VALIDATION_SCRIPT_SHA256 = _receipt(
    "72a7fbc8d123013e", "84ef7f8799c1cccc", "37130a09b73229f1", "959af85964ccbcec"
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
                    "defined exac…53756 tokens truncated…ck removed",
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
