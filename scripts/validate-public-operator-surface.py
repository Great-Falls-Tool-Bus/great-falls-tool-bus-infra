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

import re
import subprocess
import sys
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

RETIRED_EDGE_RECIPE = re.compile(
    r"\bjust\s+edge-(?:fmt(?:-check)?|validate|init|plan(?:-show|-destroy-check)?|apply)\b"
)
RAW_K8S_MUTATION = re.compile(
    r"(\bkubectl\b[^\n#`]*\b(?:apply|delete)\b|\bapply\s+-k\b|\bdelete\s+-k\b|"
    r"\bkustomize\s+build\b[^\n#`]*\bkubectl\b[^\n#`]*\b(?:apply|delete)\b)"
)
RAW_TOFU_WORKFLOW = re.compile(r"(?<![A-Za-z0-9_-])tofu(?:\s|-chdir\b)")
WORKFLOW_ENV_ENTRY = re.compile(r"^          (TF_VAR_[A-Za-z0-9_]+):[ \t]*(.+)$")

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


def scan_workflows() -> list[Finding]:
    findings: list[Finding] = []
    for rel, lineno, line in iter_lines(git_files(WORKFLOW_GLOBS)):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if RAW_TOFU_WORKFLOW.search(line) and " just " not in f" {line} ":
            findings.append(
                Finding(
                    "workflow-raw-tofu",
                    rel,
                    lineno,
                    "GitHub workflows must call Justfile recipes instead of raw tofu.",
                )
            )
        if RAW_K8S_MUTATION.search(line) and " just " not in f" {line} ":
            findings.append(
                Finding(
                    "workflow-raw-k8s-mutation",
                    rel,
                    lineno,
                    "GitHub workflows must call Justfile recipes instead of raw kubectl/kustomize mutation commands.",
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


def scan_scripts() -> list[Finding]:
    findings: list[Finding] = []
    for rel, lineno, line in iter_lines(git_files(SCRIPT_GLOBS)):
        if RAW_K8S_MUTATION.search(line):
            findings.append(
                Finding(
                    "script-raw-k8s-mutation",
                    rel,
                    lineno,
                    "Helper scripts may validate/render, but live Kubernetes mutation belongs in the Justfile recipe surface.",
                )
            )
    return findings


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
    print("public-operator-surface self-test passed")


def main() -> int:
    if "--self-test" in sys.argv:
        self_test()
        return 0

    findings = (
        scan_docs() + scan_workflows() + scan_edge_workflow_contract() + scan_scripts()
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
    )
    print(
        f"public operator surface validation passed ({scanned} tracked surface files)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
