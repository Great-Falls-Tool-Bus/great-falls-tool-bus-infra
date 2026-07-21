#!/usr/bin/env python3
"""Validate the finite public GloriousFlywheel source-checkout contract."""

from __future__ import annotations

import os
import re
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


def _repository_root() -> Path:
    test_srcdir = Path(sys.argv[0]).resolve().parent
    if os.environ.get("TEST_SRCDIR") and os.environ.get("TEST_WORKSPACE"):
        candidate = Path(os.environ["TEST_SRCDIR"]) / os.environ["TEST_WORKSPACE"]
        if candidate.is_dir():
            return candidate
    return test_srcdir.parent


ROOT = _repository_root()
WORKFLOW_DIR = Path(".github/workflows")
CORE_REPOSITORY = "tinyland-inc/GloriousFlywheel"
CORE_REMOTE = f"https://github.com/{CORE_REPOSITORY}.git"
CORE_MODULE = "attic-iac"
CORE_FLAKE_PREFIX = f"github:{CORE_REPOSITORY}/"
CHECKOUT_ACTION = "actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10"
IMPLEMENTATION_CORE_PIN = "2281b576bce0e8dd776a047b84e7464f5b508a62"
ARC_CORE_PIN = "df510574d17b85e7f15470caf3574fcabc4768f1"
OIDC_PROFILE_PIN = ARC_CORE_PIN
OIDC_PROFILE_SHA256 = "0aa1bb2b1814c28d6162fc91d5cb3201ecaa13775e94ab3571db776d5dcc3ba8"
EXACT_SHA = re.compile(r"^[0-9a-f]{40}$")

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

# One entry per workflow that checks out the public reusable core. Values are
# exact job-level checkout counts, not a loose minimum.
EXPECTED_CORE_CHECKOUTS = {
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

# Preserve the reviewed executable authority for each role. Public-checkout
# hardening must not silently import a newer core implementation into unrelated
# apply, drift, or mail lanes.
EXPECTED_CORE_PINS = {
    workflow: (
        ARC_CORE_PIN if workflow == "deploy-arc-runners.yml" else IMPLEMENTATION_CORE_PIN
    )
    for workflow in EXPECTED_CORE_CHECKOUTS
}

# Every source checkout, including the overlay checkout, is immutable and does
# not persist the source repository's per-run GITHUB_TOKEN into Git config.
EXPECTED_ACTION_CHECKOUTS = {
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

EXPECTED_CORE_CI_PATH_EXPORTS = {
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

EXPECTED_PERMISSIONS = {
    workflow: (
        ("contents: read", "id-token: write")
        if workflow == "flywheel-cache-proof.yml"
        else ("contents: read",)
    )
    for workflow in EXPECTED_WORKFLOWS
}

CONDITIONAL_CHECKOUTS = {
    "deploy-arc-runners.yml": "if: steps.secrets.outputs.arc-deploy-secrets-present == 'true'",
    "edge-drift.yml": "if: steps.secrets.outputs.edge-deploy-secrets-present == 'true'",
    "edge-plan.yml": "if: steps.secrets.outputs.edge-deploy-secrets-present == 'true'",
    "k8s-stack-drift.yml": "if: steps.secrets.outputs.kubeconfig-present == 'true'",
}

RETIRED_CORE_CREDENTIALS = ("GF_CORE_DEPLOY_KEY", "GF_CORE_READ_TOKEN")
AUTHORITY_DOCS = (
    Path("README.md"),
    Path("docs/ci-credentials.md"),
    Path("docs/implementation-overlay.md"),
    Path("docs/onboarding-runbook.md"),
    Path("docs/runbooks/oncluster-web-cutover.md"),
    Path("bazel/flywheel-proof/MODULE.bazel"),
)
VERIFY_SCRIPT = (
    "set -euo pipefail",
    'actual="$(git -C GloriousFlywheel rev-parse --verify HEAD)"',
    'if [ "${actual}" != "${GF_CORE_REF}" ]; then',
    '  echo "::error::GloriousFlywheel checkout mismatch: expected ${GF_CORE_REF}, got ${actual}"',
    "  exit 1",
    "fi",
)
OIDC_INSTALL_SCRIPT = (
    "set -euo pipefail",
    'tools_dir="${RUNNER_TEMP}/gf-tools"',
    'dest="${tools_dir}/flywheel-github-oidc-profile"',
    'url="https://raw.githubusercontent.com/tinyland-inc/GloriousFlywheel/'
    '${GF_OIDC_PROFILE_REF}/scripts/flywheel-github-oidc-profile.sh"',
    'mkdir -p "${tools_dir}"',
    'curl --fail --silent --show-error --location "${url}" --output "${dest}"',
    'actual="$(sha256sum "${dest}" | awk \'{ print $1 }\')"',
    'if [ "${actual}" != "${GF_OIDC_PROFILE_SHA256}" ]; then',
    '  echo "::error::flywheel-github-oidc-profile sha256 mismatch: expected '
    '${GF_OIDC_PROFILE_SHA256}, got ${actual}"',
    "  exit 1",
    "fi",
    'chmod +x "${dest}"',
    'echo "${tools_dir}" >> "${GITHUB_PATH}"',
    'echo "installed pinned flywheel-github-oidc-profile (sha256 ${actual})"',
)


class ContractError(RuntimeError):
    """A checked source surface violates the finite checkout contract."""


@dataclass(frozen=True)
class Step:
    name: str
    line: int
    lines: tuple[str, ...]

    @property
    def text(self) -> str:
        return "\n".join(self.lines)


def _read(root: Path, relative: Path, label: str) -> str:
    path = root / relative
    try:
        if not path.is_file():
            raise OSError("not a regular file")
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ContractError(f"{label} is unreadable: {relative}") from exc


def _one(values: list[str], label: str) -> str:
    if len(values) != 1:
        raise ContractError(f"{label} must appear exactly once")
    return values[0]


def _exact_sha(value: str, label: str) -> str:
    if not EXACT_SHA.fullmatch(value):
        raise ContractError(f"{label} must be an exact lowercase 40-hex commit")
    return value


def workflow_sources(root: Path) -> dict[str, str]:
    directory = root / WORKFLOW_DIR
    paths = sorted([*directory.glob("*.yml"), *directory.glob("*.yaml")])
    return {path.name: path.read_text(encoding="utf-8") for path in paths}


def workflow_steps(text: str) -> list[Step]:
    lines = text.splitlines()
    starts = [
        index for index, line in enumerate(lines) if line.startswith("      - name: ")
    ]
    steps: list[Step] = []
    for position, start in enumerate(starts):
        end = starts[position + 1] if position + 1 < len(starts) else len(lines)
        steps.append(
            Step(
                name=lines[start].split(": ", 1)[1],
                line=start + 1,
                lines=tuple(lines[start:end]),
            )
        )
    return steps


def workflow_permissions(text: str) -> tuple[str, ...]:
    lines = text.splitlines()
    headers = [index for index, line in enumerate(lines) if line == "permissions:"]
    if len(headers) != 1:
        raise ContractError("permissions must appear exactly once at workflow scope")
    permissions: list[str] = []
    for line in lines[headers[0] + 1 :]:
        if not line.strip():
            break
        match = re.fullmatch(
            r"  ([a-z0-9-]+)[ \t]*:[ \t]*([^\s#]+)[ \t]*(?:#.*)?", line
        )
        if match is None:
            raise ContractError("workflow permissions block must contain simple scalar grants")
        permissions.append(f"{match.group(1)}: {match.group(2)}")
    return tuple(permissions)


def _step_condition(step: Step) -> tuple[str, ...]:
    for index, line in enumerate(step.lines[1:], start=1):
        if not line.startswith("        if:"):
            continue
        condition = [line.strip()]
        for following in step.lines[index + 1 :]:
            if following.startswith("          "):
                condition.append(following.strip())
            else:
                break
        return tuple(condition)
    return ()


def _step_run_script(step: Step) -> tuple[str, ...]:
    try:
        start = step.lines.index("        run: |") + 1
    except ValueError:
        return ()
    script: list[str] = []
    for line in step.lines[start:]:
        if line.startswith("          "):
            script.append(line[10:])
        elif not line.strip():
            script.append("")
        else:
            break
    while script and not script[-1]:
        script.pop()
    return tuple(script)


def _checkout_use(step: Step) -> list[str]:
    return re.findall(r"(?m)^\s+uses:\s*([^\s#]+)(?:\s*#.*)?$", step.text)


def _with_values(step: Step, key: str) -> list[str]:
    return [
        value.strip()
        for value in re.findall(
            rf"(?m)^\s{{10}}{re.escape(key)}\s*:\s*([^#\n]+?)(?:\s+#.*)?$",
            step.text,
        )
    ]


def organization_pin(source: str) -> str:
    lines = source.splitlines()
    headers = [
        index for index, line in enumerate(lines) if re.fullmatch(r"core:\s*(?:#.*)?", line)
    ]
    if len(headers) != 1:
        raise ContractError("config/organization.yaml must contain one core block")
    block_lines: list[str] = []
    for line in lines[headers[0] + 1 :]:
        if line and not line[0].isspace():
            break
        block_lines.append(line)
    block = "\n".join(block_lines)
    repository = _one(
        re.findall(r"(?m)^  repository:\s*([^\s#]+)\s*(?:#.*)?$", block),
        "config core.repository",
    )
    module = _one(
        re.findall(r"(?m)^  module_name:\s*([^\s#]+)\s*(?:#.*)?$", block),
        "config core.module_name",
    )
    pin = _one(
        re.findall(r"(?m)^  pinned_commit:\s*([^\s#]+)\s*(?:#.*)?$", block),
        "config core.pinned_commit",
    )
    if repository != CORE_REPOSITORY:
        raise ContractError(f"config core.repository must be {CORE_REPOSITORY}")
    if module != CORE_MODULE:
        raise ContractError(f"config core.module_name must be {CORE_MODULE}")
    return _exact_sha(pin, "config core.pinned_commit")


def module_pin(source: str) -> str:
    blocks = re.findall(r"(?ms)^\s*git_override\s*\(\s*(.*?)^\s*\)\s*$", source)
    matches: list[tuple[str, str]] = []
    for block in blocks:
        modules = re.findall(r'(?m)^\s*module_name\s*=\s*"([^"]+)"\s*,?\s*$', block)
        if modules != [CORE_MODULE]:
            continue
        remote = _one(
            re.findall(r'(?m)^\s*remote\s*=\s*"([^"]+)"\s*,?\s*$', block),
            "MODULE.bazel core remote",
        )
        commit = _one(
            re.findall(r'(?m)^\s*commit\s*=\s*"([^"]+)"\s*,?\s*$', block),
            "MODULE.bazel core commit",
        )
        matches.append((remote, commit))
    if len(matches) != 1:
        raise ContractError("MODULE.bazel must contain one attic-iac git_override")
    remote, commit = matches[0]
    if remote != CORE_REMOTE:
        raise ContractError(f"MODULE.bazel core remote must be {CORE_REMOTE}")
    return _exact_sha(commit, "MODULE.bazel core commit")


def justfile_pin(source: str) -> str:
    definitions = re.findall(r"(?m)^gf_core_ci\s*:=.*$", source)
    definition = _one(definitions, "Justfile gf_core_ci authority")
    match = re.fullmatch(
        r'gf_core_ci := env_var_or_default\("GF_CORE_CI_PATH", "'
        + re.escape(CORE_FLAKE_PREFIX)
        + r'([0-9a-f]{40})#ci"\)',
        definition,
    )
    if match is None:
        raise ContractError(
            "Justfile gf_core_ci default must be the canonical exact public #ci flake"
        )
    return _exact_sha(match.group(1), "Justfile gf_core_ci commit")


def _workflow_census_findings(sources: dict[str, str]) -> list[str]:
    findings: list[str] = []
    actual = set(sources)
    missing = sorted(EXPECTED_WORKFLOWS - actual)
    extra = sorted(actual - EXPECTED_WORKFLOWS)
    if missing:
        findings.append(f"workflow census missing: {', '.join(missing)}")
    if extra:
        findings.append(f"workflow census has unowned file(s): {', '.join(extra)}")
    stems: dict[str, list[str]] = {}
    for name in actual:
        stems.setdefault(Path(name).stem, []).append(name)
    for stem, names in sorted(stems.items()):
        if len(names) > 1:
            findings.append(
                f"workflow census has duplicate basename {stem}: {', '.join(sorted(names))}"
            )
    return findings


def _checkout_findings(sources: dict[str, str]) -> list[str]:
    findings: list[str] = []
    observed_core_workflows: set[str] = set()

    for workflow, source in sorted(sources.items()):
        for credential in RETIRED_CORE_CREDENTIALS:
            if credential in source:
                findings.append(f"{workflow}: references retired {credential}")
        if re.search(
            r"(?mi)\b(?:git\s+clone|gh\s+repo\s+clone)\b[^\n]*GloriousFlywheel",
            source,
        ):
            findings.append(f"{workflow}: bypasses the bounded core checkout with a shell clone")
        if re.search(
            r"(?m)^\s+uses:\s*['\"]?tinyland-inc/GloriousFlywheel(?:/|@)",
            source,
        ):
            findings.append(
                f"{workflow}: consumes remote core workflow/action outside the bounded checkout"
            )

        permission_headers = re.findall(
            r"(?m)^([ \t]*)permissions[ \t]*:[ \t]*$", source
        )
        if permission_headers != [""]:
            findings.append(f"{workflow}: must declare permissions exactly once at workflow scope")
        try:
            observed_permissions = workflow_permissions(source)
            if observed_permissions != EXPECTED_PERMISSIONS[workflow]:
                findings.append(
                    f"{workflow}: workflow permissions must remain the finite least-privilege set"
                )
        except (ContractError, KeyError) as exc:
            findings.append(f"{workflow}: {exc}")

        expected_ci_paths = EXPECTED_CORE_CI_PATH_EXPORTS.get(workflow, 0)
        core_ci_definitions = re.findall(
            r"(?m)^[ \t]+(?:export[ \t]+)?GF_CORE_CI_PATH[ \t]*=", source
        )
        if len(core_ci_definitions) != expected_ci_paths:
            findings.append(
                f"{workflow}: expected {expected_ci_paths} GF_CORE_CI_PATH definition(s)"
            )
        canonical_ci_path_lines = re.findall(
            r'(?m)^[ \t]+export GF_CORE_CI_PATH="github:tinyland-inc/'
            r'GloriousFlywheel/\$\{GF_CORE_REF\}#ci"[ \t]*$',
            source,
        )
        if len(canonical_ci_path_lines) != expected_ci_paths:
            findings.append(
                f"{workflow}: every GF_CORE_CI_PATH must bind the exact workflow GF_CORE_REF"
            )
        if source.count(CORE_FLAKE_PREFIX) != expected_ci_paths:
            findings.append(
                f"{workflow}: has an unowned GloriousFlywheel flake source"
            )

        steps = workflow_steps(source)
        action_steps = [step for step in steps if CHECKOUT_ACTION.split("@", 1)[0] in step.text]
        raw_action_count = len(re.findall(r"(?m)^\s+uses:\s*actions/checkout@", source))
        checkout_mentions = source.count("actions/checkout")
        if checkout_mentions != raw_action_count:
            findings.append(
                f"{workflow}: every actions/checkout mention must be an unquoted uses field"
            )
        if len(action_steps) != raw_action_count:
            findings.append(f"{workflow}: every actions/checkout use must be a named step")
        expected_action_count = EXPECTED_ACTION_CHECKOUTS.get(workflow)
        if expected_action_count is not None and raw_action_count != expected_action_count:
            findings.append(
                f"{workflow}: expected {expected_action_count} checkout action(s), found {raw_action_count}"
            )
        expected_condition = (
            (CONDITIONAL_CHECKOUTS[workflow],)
            if workflow in CONDITIONAL_CHECKOUTS
            else ()
        )
        for step in action_steps:
            location = f"{workflow}:{step.line}"
            if _checkout_use(step) != [CHECKOUT_ACTION]:
                findings.append(f"{location}: checkout action must pin {CHECKOUT_ACTION}")
            if _with_values(step, "persist-credentials") != ["false"]:
                findings.append(
                    f"{location}: checkout must set persist-credentials: false exactly once"
                )
            if re.search(
                r"(?mi)^\s+['\"]?(?:token|ssh-key)['\"]?\s*:", step.text
            ):
                findings.append(f"{location}: checkout has an explicit credential input")
            if _step_condition(step) != expected_condition:
                findings.append(f"{location}: checkout condition must preserve lane gating")

            repositories = _with_values(step, "repository")
            if repositories == [CORE_REPOSITORY]:
                continue
            if repositories:
                findings.append(f"{location}: overlay checkout cannot select another repository")
            if step.name != "Checkout overlay":
                findings.append(f"{location}: non-core checkout must be the overlay checkout")
            if _with_values(step, "ref"):
                findings.append(f"{location}: overlay checkout must use the event revision")
            expected_overlay_path = [] if workflow == "flywheel-cache-proof.yml" else ["overlay"]
            if _with_values(step, "path") != expected_overlay_path:
                rendered = "the workspace root" if not expected_overlay_path else "overlay"
                findings.append(f"{location}: overlay checkout path must be {rendered}")

        core_indexes = [
            index
            for index, step in enumerate(steps)
            if _with_values(step, "repository") == [CORE_REPOSITORY]
        ]
        if core_indexes:
            observed_core_workflows.add(workflow)
        expected_core_count = EXPECTED_CORE_CHECKOUTS.get(workflow, 0)
        if len(core_indexes) != expected_core_count:
            findings.append(
                f"{workflow}: expected {expected_core_count} public core checkout(s), found {len(core_indexes)}"
            )

        for index in core_indexes:
            step = steps[index]
            location = f"{workflow}:{step.line}"
            if step.name != "Checkout public GloriousFlywheel core":
                findings.append(f"{location}: core checkout name must state public authority")
            if _with_values(step, "repository") != [CORE_REPOSITORY]:
                findings.append(f"{location}: core repository must be {CORE_REPOSITORY}")
            if _with_values(step, "ref") != ["${{ env.GF_CORE_REF }}"]:
                findings.append(f"{location}: core ref must be env.GF_CORE_REF")
            if _with_values(step, "path") != ["GloriousFlywheel"]:
                findings.append(f"{location}: core checkout path must be GloriousFlywheel")
            if _with_values(step, "persist-credentials") != ["false"]:
                findings.append(f"{location}: core checkout must not persist credentials")
            if index + 1 >= len(steps):
                findings.append(f"{location}: core checkout lacks a following HEAD assertion")
                continue
            assertion = steps[index + 1]
            assertion_location = f"{workflow}:{assertion.line}"
            if assertion.name != "Verify GloriousFlywheel core checkout":
                findings.append(
                    f"{location}: the immediately following step must verify core HEAD"
                )
                continue
            if _step_condition(assertion) != _step_condition(step):
                findings.append(
                    f"{assertion_location}: HEAD assertion condition must equal checkout condition"
                )
            if _step_run_script(assertion) != VERIFY_SCRIPT:
                findings.append(
                    f"{assertion_location}: HEAD assertion must use the closed canonical script"
                )
            if re.search(
                r"(?m)^\s+continue-on-error\s*:", assertion.text
            ):
                findings.append(f"{assertion_location}: HEAD assertion cannot fail soft")

        if expected_core_count:
            all_ref_definitions = re.findall(
                r"(?m)^[ \t]+GF_CORE_REF[ \t]*:[ \t]*[^\s#]+[ \t]*(?:#.*)?$",
                source,
            )
            if len(all_ref_definitions) != 1:
                findings.append(
                    f"{workflow}: GF_CORE_REF must have one workflow-level definition and no job/step override"
                )
            refs = re.findall(
                r"(?m)^  GF_CORE_REF[ \t]*:[ \t]*([^\s#]+)[ \t]*(?:#.*)?$",
                source,
            )
            if len(refs) != 1:
                findings.append(f"{workflow}: GF_CORE_REF must appear exactly once")
            else:
                try:
                    observed_pin = _exact_sha(refs[0], f"{workflow} GF_CORE_REF")
                    expected_pin = EXPECTED_CORE_PINS[workflow]
                    if observed_pin != expected_pin:
                        findings.append(
                            f"{workflow}: GF_CORE_REF must preserve role pin {expected_pin}"
                        )
                except ContractError as exc:
                    findings.append(str(exc))

    if observed_core_workflows != set(EXPECTED_CORE_CHECKOUTS):
        missing = sorted(set(EXPECTED_CORE_CHECKOUTS) - observed_core_workflows)
        extra = sorted(observed_core_workflows - set(EXPECTED_CORE_CHECKOUTS))
        if missing:
            findings.append(f"core checkout census missing: {', '.join(missing)}")
        if extra:
            findings.append(f"core checkout census has unowned workflow(s): {', '.join(extra)}")
    return findings


def validate(root: Path) -> list[str]:
    findings: list[str] = []
    sources = workflow_sources(root)
    findings.extend(_workflow_census_findings(sources))
    findings.extend(_checkout_findings(sources))

    for label, relative, parser in (
        ("organization config", Path("config/organization.yaml"), organization_pin),
        ("Bzlmod module", Path("MODULE.bazel"), module_pin),
        ("Justfile", Path("Justfile"), justfile_pin),
    ):
        try:
            observed_pin = parser(_read(root, relative, label))
            if observed_pin != IMPLEMENTATION_CORE_PIN:
                findings.append(
                    f"{relative}: core authority must preserve implementation pin "
                    f"{IMPLEMENTATION_CORE_PIN}"
                )
        except ContractError as exc:
            findings.append(str(exc))

    proof = sources.get("flywheel-cache-proof.yml", "")
    oidc_refs = re.findall(
        r"(?m)^[ \t]+GF_OIDC_PROFILE_REF[ \t]*:[ \t]*([^\s#]+)[ \t]*$",
        proof,
    )
    if len(oidc_refs) != 1:
        findings.append("flywheel-cache-proof.yml must contain one GF_OIDC_PROFILE_REF")
    else:
        try:
            observed_pin = _exact_sha(
                oidc_refs[0], "flywheel-cache-proof.yml GF_OIDC_PROFILE_REF"
            )
            if observed_pin != OIDC_PROFILE_PIN:
                findings.append(
                    "flywheel-cache-proof.yml: GF_OIDC_PROFILE_REF must preserve "
                    f"role pin {OIDC_PROFILE_PIN}"
                )
        except ContractError as exc:
            findings.append(str(exc))
    oidc_hashes = re.findall(
        r"(?m)^[ \t]+GF_OIDC_PROFILE_SHA256[ \t]*:[ \t]*([^\s#]+)[ \t]*$",
        proof,
    )
    if oidc_hashes != [OIDC_PROFILE_SHA256]:
        findings.append(
            "flywheel-cache-proof.yml must preserve the content hash for the pinned OIDC helper"
        )
    canonical_oidc_url = (
        'url="https://raw.githubusercontent.com/tinyland-inc/GloriousFlywheel/'
        '${GF_OIDC_PROFILE_REF}/scripts/flywheel-github-oidc-profile.sh"'
    )
    raw_oidc_urls = re.findall(
        r'(?m)^\s+url="https://raw\.githubusercontent\.com/tinyland-inc/'
        r'GloriousFlywheel/[^\n]+$',
        proof,
    )
    if len(raw_oidc_urls) != 1 or canonical_oidc_url not in raw_oidc_urls[0]:
        findings.append(
            "flywheel-cache-proof.yml must fetch the OIDC helper through its exact pinned ref"
        )
    oidc_install_steps = [
        step
        for step in workflow_steps(proof)
        if step.name == "Install fleet OIDC front door (pinned)"
    ]
    if len(oidc_install_steps) != 1:
        findings.append(
            "flywheel-cache-proof.yml must contain one pinned OIDC helper install step"
        )
    elif _step_run_script(oidc_install_steps[0]) != OIDC_INSTALL_SCRIPT:
        findings.append(
            "flywheel-cache-proof.yml must preserve the closed OIDC fetch-and-hash script"
        )

    for relative in AUTHORITY_DOCS:
        try:
            source = _read(root, relative, f"authority document {relative}")
        except ContractError as exc:
            findings.append(str(exc))
            continue
        for credential in RETIRED_CORE_CREDENTIALS:
            if credential in source:
                findings.append(f"{relative}: references retired {credential}")
        if re.search(r"private\s+(?:GloriousFlywheel|core repo)", source, re.IGNORECASE):
            findings.append(f"{relative}: claims the public core source is private")

    return findings


def _write_fixture(destination: Path, source_root: Path) -> None:
    required = [
        Path("config/organization.yaml"),
        Path("MODULE.bazel"),
        Path("Justfile"),
        *AUTHORITY_DOCS,
        *[WORKFLOW_DIR / name for name in EXPECTED_WORKFLOWS],
    ]
    for relative in dict.fromkeys(required):
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(_read(source_root, relative, f"self-test fixture {relative}"), encoding="utf-8")


def self_test(root: Path) -> None:
    mutations: dict[str, tuple[Path, str, str]] = {
        "floating workflow pin": (
            Path(".github/workflows/validate.yml"),
            f"GF_CORE_REF: {IMPLEMENTATION_CORE_PIN}",
            "GF_CORE_REF: main",
        ),
        "job-level core ref override": (
            Path(".github/workflows/validate.yml"),
            "    steps:\n",
            f"    env:\n      GF_CORE_REF: {'e' * 40}\n    steps:\n",
        ),
        "floating checkout action": (
            Path(".github/workflows/validate.yml"),
            CHECKOUT_ACTION,
            "actions/checkout@v6",
        ),
        "credential persistence": (
            Path(".github/workflows/validate.yml"),
            "persist-credentials: false",
            "persist-credentials: true",
        ),
        "wrong core path": (
            Path(".github/workflows/validate.yml"),
            "path: GloriousFlywheel",
            "path: core",
        ),
        "explicit checkout token": (
            Path(".github/workflows/validate.yml"),
            "          path: GloriousFlywheel\n",
            "          path: GloriousFlywheel\n          token: ${{ github.token }}\n",
        ),
        "explicit checkout SSH key": (
            Path(".github/workflows/validate.yml"),
            "          path: GloriousFlywheel\n",
            "          path: GloriousFlywheel\n          ssh-key: ${{ secrets.SOME_KEY }}\n",
        ),
        "overlay checkout token": (
            Path(".github/workflows/validate.yml"),
            "          path: overlay\n",
            "          path: overlay\n          token: ${{ secrets.SITE_CI_READ_TOKEN }}\n",
        ),
        "spaced checkout credential key": (
            Path(".github/workflows/validate.yml"),
            "          path: GloriousFlywheel\n",
            "          path: GloriousFlywheel\n          token : ${{ secrets.NEW_GF_PAT }}\n",
        ),
        "wrong overlay path": (
            Path(".github/workflows/validate.yml"),
            "          path: overlay\n",
            "          path: wrong-overlay\n",
        ),
        "duplicate core ref": (
            Path(".github/workflows/validate.yml"),
            "          ref: ${{ env.GF_CORE_REF }}\n",
            "          ref: ${{ env.GF_CORE_REF }}\n          ref: main\n",
        ),
        "quoted hidden checkout": (
            Path(".github/workflows/validate.yml"),
            "    steps:\n",
            "    steps:\n      - name: Hidden checkout\n        uses: 'actions/checkout@v6'\n",
        ),
        "shell core clone": (
            Path(".github/workflows/validate.yml"),
            "    steps:\n",
            "    steps:\n      - name: Clone core\n        run: git clone https://github.com/tinyland-inc/GloriousFlywheel\n",
        ),
        "remote core action": (
            Path(".github/workflows/validate.yml"),
            "    steps:\n",
            "    steps:\n      - name: Remote core action\n        uses: tinyland-inc/GloriousFlywheel/.github/actions/nix-job@main\n",
        ),
        "floating core devshell": (
            Path(".github/workflows/validate.yml"),
            'export GF_CORE_CI_PATH="github:tinyland-inc/GloriousFlywheel/${GF_CORE_REF}#ci"',
            'export GF_CORE_CI_PATH="github:tinyland-inc/GloriousFlywheel/main#ci"',
        ),
        "write contents permission": (
            Path(".github/workflows/validate.yml"),
            "  contents: read",
            "  contents: write",
        ),
        "expanded workflow token permissions": (
            Path(".github/workflows/validate.yml"),
            "  contents: read\n",
            "  contents: read\n  actions: write\n",
        ),
        "floating OIDC helper URL": (
            Path(".github/workflows/flywheel-cache-proof.yml"),
            "GloriousFlywheel/${GF_OIDC_PROFILE_REF}/scripts/flywheel-github-oidc-profile.sh",
            "GloriousFlywheel/main/scripts/flywheel-github-oidc-profile.sh",
        ),
        "mismatched OIDC helper hash": (
            Path(".github/workflows/flywheel-cache-proof.yml"),
            f"GF_OIDC_PROFILE_SHA256: {OIDC_PROFILE_SHA256}",
            f"GF_OIDC_PROFILE_SHA256: {'f' * 64}",
        ),
        "disabled OIDC hash comparison": (
            Path(".github/workflows/flywheel-cache-proof.yml"),
            'if [ "${actual}" != "${GF_OIDC_PROFILE_SHA256}" ]; then',
            "if false; then",
        ),
        "legacy core credential": (
            Path(".github/workflows/validate.yml"),
            "env:\n",
            "env:\n  GF_CORE_READ_TOKEN: ${{ secrets.GF_CORE_READ_TOKEN }}\n",
        ),
        "missing HEAD assertion": (
            Path(".github/workflows/validate.yml"),
            "      - name: Verify GloriousFlywheel core checkout",
            "      - name: Do not verify GloriousFlywheel core checkout",
        ),
        "mutated HEAD assertion": (
            Path(".github/workflows/validate.yml"),
            "rev-parse --verify HEAD",
            "rev-parse --verify HEAD || true",
        ),
        "HEAD assertion condition drift": (
            Path(".github/workflows/edge-drift.yml"),
            "      - name: Verify GloriousFlywheel core checkout\n        if: steps.secrets.outputs.edge-deploy-secrets-present == 'true'",
            "      - name: Verify GloriousFlywheel core checkout\n        if: always()",
        ),
        "checkout lane condition drift": (
            Path(".github/workflows/edge-drift.yml"),
            "      - name: Checkout overlay\n        if: steps.secrets.outputs.edge-deploy-secrets-present == 'true'",
            "      - name: Checkout overlay\n        if: always()",
        ),
        "fail-soft HEAD assertion": (
            Path(".github/workflows/validate.yml"),
            "      - name: Verify GloriousFlywheel core checkout\n        run: |",
            "      - name: Verify GloriousFlywheel core checkout\n        continue-on-error: true\n        run: |",
        ),
        "mismatched Justfile pin": (
            Path("Justfile"),
            f"{IMPLEMENTATION_CORE_PIN}#ci",
            f"{'a' * 40}#ci",
        ),
        "floating Bzlmod pin": (
            Path("MODULE.bazel"),
            f'commit = "{IMPLEMENTATION_CORE_PIN}"',
            'commit = "main"',
        ),
        "mismatched organization pin": (
            Path("config/organization.yaml"),
            f"pinned_commit: {IMPLEMENTATION_CORE_PIN}",
            f"pinned_commit: {'b' * 40}",
        ),
        "mismatched ARC role pin": (
            Path(".github/workflows/deploy-arc-runners.yml"),
            f"GF_CORE_REF: {ARC_CORE_PIN}",
            f"GF_CORE_REF: {'c' * 40}",
        ),
        "mismatched OIDC profile pin": (
            Path(".github/workflows/flywheel-cache-proof.yml"),
            f"GF_OIDC_PROFILE_REF: {OIDC_PROFILE_PIN}",
            f"GF_OIDC_PROFILE_REF: {'d' * 40}",
        ),
    }

    for label, (relative, old, new) in mutations.items():
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary)
            _write_fixture(fixture, root)
            path = fixture / relative
            source = path.read_text(encoding="utf-8")
            if old not in source:
                raise RuntimeError(f"self-test fixture for {label} did not match source")
            path.write_text(source.replace(old, new, 1), encoding="utf-8")
            findings = validate(fixture)
            if not findings:
                raise RuntimeError(f"self-test accepted {label}")

    with tempfile.TemporaryDirectory() as temporary:
        fixture = Path(temporary)
        _write_fixture(fixture, root)
        (fixture / WORKFLOW_DIR / "validate.yaml").write_text(
            _read(root, WORKFLOW_DIR / "validate.yml", "validate workflow"),
            encoding="utf-8",
        )
        findings = validate(fixture)
        if not any("duplicate basename validate" in finding for finding in findings):
            raise RuntimeError("self-test accepted a duplicate .yml/.yaml workflow")


def main() -> int:
    findings = validate(ROOT)
    if findings:
        print(f"core-checkout contract FAILED ({len(findings)} finding(s)):", file=sys.stderr)
        for finding in findings:
            print(f"- {finding}", file=sys.stderr)
        return 1

    if "--self-test" in sys.argv:
        try:
            self_test(ROOT)
        except RuntimeError as exc:
            print(f"core-checkout self-test FAILED: {exc}", file=sys.stderr)
            return 1
        print("core-checkout self-test passed")
        return 0

    print(
        "core-checkout contract passed: "
        f"{len(EXPECTED_CORE_CHECKOUTS)} workflow consumers, "
        f"{sum(EXPECTED_CORE_CHECKOUTS.values())} public exact-SHA checkouts, "
        f"{sum(EXPECTED_CORE_CI_PATH_EXPORTS.values())} pinned #ci devshell sources, "
        f"implementation pin {IMPLEMENTATION_CORE_PIN}, "
        f"ARC/OIDC role pin {ARC_CORE_PIN}; "
        "no dedicated cross-repo checkout credential"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
