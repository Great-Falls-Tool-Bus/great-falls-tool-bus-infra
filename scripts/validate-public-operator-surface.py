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
    "mail-cr-apply",
    "mail-cr-drift-check",
    "mail-cr-server-dry-run",
    "mail-cr-validate",
    "web-cd-ci-green-gate",
    "web-stack-apply",
    "web-stack-drift-check",
    "web-stack-health",
    "web-stack-server-dry-run",
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
ARC_CORE_SHA = "df510574d17b85e7f15470caf3574fcabc4768f1"
ARC_GLOBAL_ASSIGNMENTS = {
    "gf_core": 'env_var_or_default("GF_CORE_PATH", "../GloriousFlywheel")',
    "gf_core_ci": (
        'env_var_or_default("GF_CORE_CI_PATH", '
        f'"github:tinyland-inc/GloriousFlywheel/{GF_CORE_SHA}#ci")'
    ),
    "gf_core_sha": f'"{GF_CORE_SHA}"',
    "arc_core_default": '"../GloriousFlywheel-arc-df510"',
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
        raise ValueError("invalid ARC executable receipt")
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
        "e68966736986a4ee", "8df1bb890018175a", "13c48e6c55ab5c31", "e395368aca18a8d3"
    ),
    "arc-apply": _receipt(
        "fe8c324732148b38", "c967bad1c1ccab8e", "fd3840cedf78db82", "9b5a73294ec96ef6"
    ),
    "arc-capacity-readback": _receipt(
        "af3ff1d577a41125", "6a843d789b1ff281", "83b9766729c0e9c1", "d07696a89e52ed38"
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
    return calls, unresolved, multiple


def executable_just_calls(
    body: str, known_recipes: set[str], recipe_arities: dict[str, int]
) -> tuple[set[str], bool]:
    calls, unresolved, _ = parse_just_calls(body, known_recipes, recipe_arities)
    return calls, unresolved


def arc_operator_recipe_closure(text: str) -> tuple[set[str], dict[str, set[str]]]:
    """Return recipes that directly or transitively reach operator-local ARC."""
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

    tainted = set(ARC_OPERATOR_LOCAL_ROOTS) | unresolved_recipes
    changed = True
    while changed:
        changed = False
        for name, targets in edges.items():
            if name not in tainted and targets & tainted:
                tainted.add(name)
                changed = True
    return tainted, edges


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
    receipted = set(ARC_RECIPE_DEPENDENCIES) | ARC_EXPLICIT_OPERATOR_LOCAL_WRAPPERS
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
                "readback, GitHub App Secret, or transitive operator recipes; "
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


def scan_workflows() -> list[Finding]:
    findings: list[Finding] = []
    observed_calls: set[str] = set()
    justfile = (REPO / "Justfile").read_text(encoding="utf-8")
    forbidden_recipes, _ = arc_operator_recipe_closure(justfile)
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
        findings.extend(
            scan_workflow_text(
                workflow_text,
                rel,
                forbidden_recipes,
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
                f"recipes or wrappers; observed {arc_calls!r}.",
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
    forbidden_recipes, _ = arc_operator_recipe_closure(justfile)
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
    forbidden_recipes, _ = arc_operator_recipe_closure(justfile)
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


ARC_BEFORE_VALUES = """\
template:
  spec:
    containers:
      - command: []
        name: runner
        resources:
          limits:
            ephemeral-storage: 8Gi
          requests:
            ephemeral-storage: 4Gi
"""

ARC_AFTER_VALUES = """\
template:
  spec:
    containers:
      - command: []
        name: runner
        resources:
          limits:
            ephemeral-storage: 16Gi
          requests:
            ephemeral-storage: 8Gi
"""


def valid_arc_scope_plan() -> dict[str, object]:
    return {
        "format_version": "1.2",
        "terraform_version": "1.11.6",
        "errored": False,
        "resource_drift": [],
        "output_changes": {
            "fixture_output": {
                "actions": ["no-op"],
                "before": "opaque-fixture-value",
                "after": "opaque-fixture-value",
                "after_unknown": False,
                "before_sensitive": False,
                "after_sensitive": False,
            }
        },
        "resource_changes": [
            {
                "address": "module.gh_nix.helm_release.arc_runner",
                "module_address": "module.gh_nix",
                "mode": "managed",
                "type": "helm_release",
                "name": "arc_runner",
                "change": {
                    "actions": ["update"],
                    "before": {"values": [ARC_BEFORE_VALUES]},
                    "after": {"values": [ARC_AFTER_VALUES]},
                    "after_unknown": {},
                    "before_sensitive": {
                        "metadata": [{}],
                        "repository_password": True,
                        "values": [False],
                    },
                    "after_sensitive": {
                        "metadata": [],
                        "repository_password": True,
                        "values": [False],
                    },
                    "replace_paths": [],
                },
            }
        ],
    }


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


def check_critical_recipe_shell_syntax() -> None:
    """Ask Just to expand dependency chains, then parse the exact shell output."""
    for name in ARC_RECIPE_DEPENDENCIES:
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

    yaml_cases = (
        (
            "reversed request and limit",
            ARC_BEFORE_VALUES.replace("limits:\n            ephemeral-storage: 8Gi\n          requests:\n            ephemeral-storage: 4Gi", "limits:\n            ephemeral-storage: 4Gi\n          requests:\n            ephemeral-storage: 8Gi"),
            ARC_AFTER_VALUES.replace("limits:\n            ephemeral-storage: 16Gi\n          requests:\n            ephemeral-storage: 8Gi", "limits:\n            ephemeral-storage: 8Gi\n          requests:\n            ephemeral-storage: 16Gi"),
            "expected runner resources.requests",
        ),
        (
            "wrong ancestry",
            ARC_BEFORE_VALUES.replace("template:\n", "malicious:\n", 1),
            ARC_AFTER_VALUES.replace("template:\n", "malicious:\n", 1),
            "not under template.spec.containers",
        ),
        (
            "storage outside runner",
            ARC_BEFORE_VALUES + "outside:\n  ephemeral-storage: 1Gi\n",
            ARC_AFTER_VALUES + "outside:\n  ephemeral-storage: 1Gi\n",
            "outside the runner container",
        ),
        (
            "storage after runner",
            ARC_BEFORE_VALUES
            + "      - command: []\n        name: observer\n        resources:\n          requests:\n            ephemeral-storage: 1Gi\n",
            ARC_AFTER_VALUES
            + "      - command: []\n        name: observer\n        resources:\n          requests:\n            ephemeral-storage: 1Gi\n",
            "outside the runner container",
        ),
        (
            "nested resources",
            ARC_BEFORE_VALUES.replace("        resources:\n", "        wrapper:\n          resources:\n", 1),
            ARC_AFTER_VALUES.replace("        resources:\n", "        wrapper:\n          resources:\n", 1),
            "outside resources requests/limits",
        ),
        (
            "duplicate resources",
            ARC_BEFORE_VALUES
            + "        resources:\n          limits:\n            ephemeral-storage: 8Gi\n          requests:\n            ephemeral-storage: 4Gi\n",
            ARC_AFTER_VALUES
            + "        resources:\n          limits:\n            ephemeral-storage: 16Gi\n          requests:\n            ephemeral-storage: 8Gi\n",
            "duplicate runner ephemeral-storage field",
        ),
    )
    for label, before_yaml, after_yaml, diagnostic in yaml_cases:
        plan = copy.deepcopy(valid)
        plan["resource_changes"][0]["change"]["before"]["values"] = [before_yaml]  # type: ignore[index]
        plan["resource_changes"][0]["change"]["after"]["values"] = [after_yaml]  # type: ignore[index]
        expect_scope_rejection(scope_source, label, plan, diagnostic)

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
