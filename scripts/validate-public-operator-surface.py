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

    findings = scan_docs() + scan_workflows() + scan_scripts()
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
    print(f"public operator surface validation passed ({scanned} tracked surface files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
