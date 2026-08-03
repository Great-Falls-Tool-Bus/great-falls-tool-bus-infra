#!/usr/bin/env python3
"""Validate the finite private GF release and owner-runner attachment.

This check enforces the current hand-authored overlay boundary. Retire it when
the generated GF front-door/owner-overlay projection emits these workflow and
release bindings directly.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path


PIN = "f26b541d1d7600d56b2e78c87038415fa06b3622"
SIGNED_REF = "refs/tags/v0.3.0"
CORE_REPOSITORY = "tinyland-inc/GloriousFlywheel"
GROUP = "great-falls-tool-bus-infra"
LABEL = "tinyland-nix"
CHECKOUT_ACTION = "actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10"
NIX_SETUP_ACTION = (
    "tinyland-inc/ci-templates/.github/actions/nix-setup@"
    "e07ac8b2b316eedeb3bbffea47af1acf05624545"
)
CREDHELPER_ACTION = (
    "tinyland-inc/ci-templates/.github/actions/gf-credhelper-install@"
    "a76a637c8d1b2abe5fade554185892cb37a09c66"
)

EXPECTED_WORKFLOWS = {
    "archive-stack.yml",
    "deploy-arc-runners.yml",
    "edge-drift.yml",
    "edge-plan.yml",
    "flywheel-cache-proof.yml",
    "form-crs.yml",
    "k8s-stack-drift.yml",
    "list-crs.yml",
    "mail-crs.yml",
    "validate.yml",
    "web-crs.yml",
    "web-stack.yml",
}

CORE_CHECKOUTS = {
    "archive-stack.yml": 2,
    "deploy-arc-runners.yml": 1,
    "edge-drift.yml": 1,
    "edge-plan.yml": 1,
    "form-crs.yml": 2,
    "k8s-stack-drift.yml": 2,
    "list-crs.yml": 2,
    "mail-crs.yml": 2,
    "validate.yml": 1,
    "web-crs.yml": 1,
    "web-stack.yml": 1,
}

ACTION_CHECKOUTS = {
    "archive-stack.yml": 4,
    "deploy-arc-runners.yml": 2,
    "edge-drift.yml": 2,
    "edge-plan.yml": 2,
    "flywheel-cache-proof.yml": 1,
    "form-crs.yml": 4,
    "k8s-stack-drift.yml": 4,
    "list-crs.yml": 4,
    "mail-crs.yml": 4,
    "validate.yml": 2,
    "web-crs.yml": 2,
    "web-stack.yml": 2,
}

CORE_CI_PATH_EXPORTS = {
    "archive-stack.yml": 3,
    "deploy-arc-runners.yml": 4,
    "edge-drift.yml": 1,
    "edge-plan.yml": 3,
    "flywheel-cache-proof.yml": 0,
    "form-crs.yml": 3,
    "k8s-stack-drift.yml": 5,
    "list-crs.yml": 3,
    "mail-crs.yml": 3,
    "validate.yml": 1,
    "web-crs.yml": 1,
    "web-stack.yml": 3,
}


def repository_root() -> Path:
    if os.environ.get("TEST_SRCDIR") and os.environ.get("TEST_WORKSPACE"):
        candidate = Path(os.environ["TEST_SRCDIR"]) / os.environ["TEST_WORKSPACE"]
        if candidate.is_dir():
            return candidate
    return Path(__file__).resolve().parent.parent


ROOT = repository_root()


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def exact_field(text: str, field: str, expected: str, source: str) -> list[str]:
    values = re.findall(rf"(?m)^\s*{re.escape(field)}:\s*([^\s#]+)", text)
    if values == [expected]:
        return []
    return [f"{source}: expected exactly one {field}: {expected}, found {values}"]


def steps(text: str) -> list[tuple[str, str]]:
    lines = text.splitlines()
    starts = [index for index, line in enumerate(lines) if line.startswith("      - name: ")]
    result: list[tuple[str, str]] = []
    for position, start in enumerate(starts):
        end = starts[position + 1] if position + 1 < len(starts) else len(lines)
        result.append((lines[start].split(": ", 1)[1], "\n".join(lines[start:end])))
    return result


def condition(step: str) -> str:
    match = re.search(r"(?m)^        if:\s*(.+)$", step)
    return match.group(1).strip() if match else ""


def permissions(text: str) -> tuple[str, ...]:
    headers = list(re.finditer(r"(?m)^permissions:\s*$", text))
    if len(headers) != 1:
        return ()
    values: list[str] = []
    for line in text[headers[0].end() :].splitlines():
        if not line.strip():
            if values:
                break
            continue
        match = re.fullmatch(r"  ([a-z0-9-]+):\s*([^\s#]+)(?:\s+#.*)?", line)
        if not match:
            break
        values.append(f"{match.group(1)}: {match.group(2)}")
    return tuple(values)


def validate() -> list[str]:
    findings: list[str] = []
    organization = read("config/organization.yaml")

    findings += exact_field(organization, "pinned_commit", PIN, "config/organization.yaml")
    findings += exact_field(organization, "signed_ref", SIGNED_REF, "config/organization.yaml")
    findings += exact_field(organization, "repository_id", "1286829099", "config/organization.yaml")
    findings += exact_field(organization, "repository_visibility", "private", "config/organization.yaml")

    for required in (
        "name: great-falls-tool-bus-infra",
        "visibility: selected",
        "allows_public_repositories: false",
        "restricted_to_workflows: false",
    ):
        if organization.count(required) != 1:
            findings.append(f"config/organization.yaml: expected exactly one {required!r}")

    module = read("MODULE.bazel")
    if f'commit = "{PIN}"' not in module:
        findings.append("MODULE.bazel: GF module override does not match the signed release commit")
    if f'remote = "https://github.com/{CORE_REPOSITORY}.git"' not in module:
        findings.append("MODULE.bazel: GF module override must use the canonical repository")

    justfile = read("Justfile")
    if '"--override_module=attic-iac={{ gf_core }}"' not in justfile:
        findings.append("Justfile: the root Bazel contract test must use the verified local GF checkout")

    workflows = ROOT / ".github" / "workflows"
    observed = {path.name for path in workflows.glob("*.y*ml")}
    if observed != EXPECTED_WORKFLOWS:
        findings.append(
            "workflow census drift: "
            f"missing={sorted(EXPECTED_WORKFLOWS - observed)} "
            f"unexpected={sorted(observed - EXPECTED_WORKFLOWS)}"
        )

    selector = re.compile(
        rf"(?m)^\s*runs-on:\s*$\n\s*group:\s*{re.escape(GROUP)}\s*$"
        rf"\n\s*labels:\s*{re.escape(LABEL)}\s*$"
    )
    key = "ssh-key: ${{ secrets.GF_CORE_DEPLOY_KEY }}"

    for name in sorted(observed & EXPECTED_WORKFLOWS):
        text = (workflows / name).read_text(encoding="utf-8")
        parsed_steps = steps(text)
        runs_on = len(re.findall(r"(?m)^\s*runs-on:\s*(?:\S.*)?$", text))
        selected = len(selector.findall(text))
        if selected != runs_on:
            findings.append(
                f"{name}: every {runs_on} job selector must bind {GROUP!r} + {LABEL!r}; found {selected}"
            )
        if re.search(r"(?m)^\s*runs-on:\s*tinyland-nix\s*$", text):
            findings.append(f"{name}: label-only runner selection is forbidden")

        expected_permissions = (
            ("contents: read", "id-token: write")
            if name == "flywheel-cache-proof.yml"
            else ("contents: read",)
        )
        if permissions(text) != expected_permissions:
            findings.append(f"{name}: workflow permissions must be {expected_permissions}")

        checkout_steps = [step for _, step in parsed_steps if "uses: actions/checkout@" in step]
        if len(checkout_steps) != ACTION_CHECKOUTS[name]:
            findings.append(
                f"{name}: expected {ACTION_CHECKOUTS[name]} checkout steps, found {len(checkout_steps)}"
            )
        for checkout in checkout_steps:
            if f"uses: {CHECKOUT_ACTION}" not in checkout:
                findings.append(f"{name}: every checkout action must use the immutable approved commit")
            if checkout.count("persist-credentials: false") != 1:
                findings.append(f"{name}: every checkout must disable credential persistence")
            if re.search(r"(?m)^\s*token\s*:", checkout):
                findings.append(f"{name}: explicit checkout token is forbidden")

        expected = CORE_CHECKOUTS.get(name, 0)
        core_steps = [
            (index, step)
            for index, (_, step) in enumerate(parsed_steps)
            if f"repository: {CORE_REPOSITORY}" in step
        ]
        actual = len(core_steps)
        if actual != expected:
            findings.append(f"{name}: expected {expected} GF checkouts, found {actual}")
        if expected:
            if text.count("Checkout private GloriousFlywheel release") != expected:
                findings.append(f"{name}: private GF checkout step count drift")
            if text.count(key) != expected:
                findings.append(f"{name}: every private GF checkout requires the read-only deploy key")
            refs = re.findall(r"(?m)^\s*GF_CORE_REF:\s*([0-9a-f]+)\s*$", text)
            if refs != [PIN]:
                findings.append(f"{name}: GF_CORE_REF must be the signed release commit")
            expected_ci_paths = CORE_CI_PATH_EXPORTS[name]
            observed_ci_paths = text.count('GF_CORE_CI_PATH="path:../GloriousFlywheel#ci"')
            if observed_ci_paths != expected_ci_paths:
                findings.append(
                    f"{name}: expected {expected_ci_paths} verified local #ci paths, found {observed_ci_paths}"
                )

        for index, checkout in core_steps:
            for required in (
                "ref: ${{ env.GF_CORE_REF }}",
                "path: GloriousFlywheel",
                key,
                "persist-credentials: false",
            ):
                if checkout.count(required) != 1:
                    findings.append(f"{name}: private GF checkout requires exactly one {required!r}")
            if index + 1 >= len(parsed_steps):
                findings.append(f"{name}: private GF checkout has no following HEAD verification")
                continue
            verify_name, verify = parsed_steps[index + 1]
            if verify_name != "Verify GloriousFlywheel core checkout":
                findings.append(f"{name}: private GF checkout must be followed by HEAD verification")
                continue
            if condition(checkout) != condition(verify):
                findings.append(f"{name}: checkout and HEAD verification conditions differ")
            for required in (
                'actual="$(git -C GloriousFlywheel rev-parse --verify HEAD)"',
                'if [ "${actual}" != "${GF_CORE_REF}" ]; then',
                "exit 1",
            ):
                if required not in verify:
                    findings.append(f"{name}: HEAD verification is missing {required!r}")

        if f"github:tinyland-inc/GloriousFlywheel/" in text:
            findings.append(f"{name}: private GF devshell must use the verified local checkout")

        unexpected_ssh = [
            checkout
            for checkout in checkout_steps
            if "ssh-key:" in checkout and f"repository: {CORE_REPOSITORY}" not in checkout
        ]
        if unexpected_ssh:
            findings.append(f"{name}: only the private GF checkout may use an SSH key")

    proof = (workflows / "flywheel-cache-proof.yml").read_text(encoding="utf-8")
    if proof.count(f"uses: {NIX_SETUP_ACTION}") != 1:
        findings.append("flywheel-cache-proof.yml: nix-setup must use its immutable v2.12.1 commit")
    if proof.count(f"uses: {CREDHELPER_ACTION}") != 1:
        findings.append("flywheel-cache-proof.yml: credhelper install must use its immutable v2.11.0 commit")
    if "workflow_dispatch:" in proof:
        findings.append("flywheel-cache-proof.yml: manual cache-write dispatch is forbidden")

    public_claims = (
        "Checkout public GloriousFlywheel core",
        "public GloriousFlywheel core",
        "GloriousFlywheel source is public",
        "CI checks out the public `tinyland-inc/GloriousFlywheel`",
    )
    for relative in (
        "README.md",
        "Justfile",
        "docs/ci-credentials.md",
        "docs/implementation-overlay.md",
        "docs/onboarding-runbook.md",
        "docs/runbooks/oncluster-web-cutover.md",
        "bazel/flywheel-proof/MODULE.bazel",
    ):
        text = read(relative)
        for claim in public_claims:
            if claim in text:
                findings.append(f"{relative}: stale public-core claim {claim!r}")

    return findings


def main() -> int:
    findings = validate()
    if findings:
        for finding in findings:
            print(f"ERROR: {finding}", file=sys.stderr)
        return 1
    print("private GF release and owner-runner attachment contract: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
