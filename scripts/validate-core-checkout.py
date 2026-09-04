#!/usr/bin/env python3
"""Validate the finite GloriousFlywheel source-declaration contract."""

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
ARC_CORE_PIN = "11ace397282ff89aeb1dfeb4a32fcbed3200c2ff"
# Operand publisher role pin (TIN-2611). publish-operands.yml consumes the
# closed v4 operand wire (services/gf-reapi-cell/pkg/operand) and the
# gf-operand-publisher command from this exact GloriousFlywheel revision. It is
# advanced only together with operands/README.md when the publisher lands.
OPERAND_PUBLISHER_CORE_PIN = "8d428cb83015205ec8e26354e9f9baf479b9a81b"
EXACT_SHA = re.compile(r"^[0-9a-f]{40}$")

EXPECTED_WORKFLOWS = {
    "archive-stack.yml",
    "edge-drift.yml",
    "edge-plan.yml",
    "form-crs.yml",
    "k8s-stack-drift.yml",
    "list-crs.yml",
    "mail-crs.yml",
    "operand-references-pr.yml",
    "publish-operands.yml",
    "validate.yml",
}

# One entry per workflow that declares the reusable core checkout. Values are
# exact job-level checkout counts, not a loose minimum.
EXPECTED_CORE_CHECKOUTS = {
    "archive-stack.yml": 2,
    "edge-drift.yml": 1,
    "edge-plan.yml": 1,
    "form-crs.yml": 2,
    "k8s-stack-drift.yml": 2,
    "list-crs.yml": 2,
    "mail-crs.yml": 2,
    "publish-operands.yml": 1,
}

# Preserve the reviewed executable authority for each role. Checkout
# hardening must not silently import a newer core implementation into unrelated
# apply, drift, or mail lanes.
EXPECTED_CORE_PINS = {
    workflow: IMPLEMENTATION_CORE_PIN
    for workflow in EXPECTED_CORE_CHECKOUTS
}
EXPECTED_CORE_PINS["publish-operands.yml"] = OPERAND_PUBLISHER_CORE_PIN

# Every source checkout, including the overlay checkout, is immutable and does
# not persist the source repository's per-run GITHUB_TOKEN into Git config.
EXPECTED_ACTION_CHECKOUTS = {
    "archive-stack.yml": 4,
    "edge-drift.yml": 2,
    "edge-plan.yml": 2,
    "form-crs.yml": 4,
    "k8s-stack-drift.yml": 4,
    "list-crs.yml": 4,
    "mail-crs.yml": 4,
    "operand-references-pr.yml": 1,
    "publish-operands.yml": 2,
    "validate.yml": 1,
}

EXPECTED_CORE_CI_PATH_EXPORTS = {
    "archive-stack.yml": 3,
    "edge-drift.yml": 1,
    "edge-plan.yml": 3,
    "form-crs.yml": 3,
    "k8s-stack-drift.yml": 6,
    "list-crs.yml": 3,
    "mail-crs.yml": 3,
    "operand-references-pr.yml": 0,
    "publish-operands.yml": 2,
    "validate.yml": 0,
}

EXPECTED_PERMISSIONS = {
    workflow: ("contents: read",) for workflow in EXPECTED_WORKFLOWS
}
# TIN-2611 privilege split. The publisher (the O-2 signer identity) holds
# id-token for Sigstore keyless signing and packages for the GHCR push, and
# reads Git only. The commit-back holds Git/pull-request write on the
# repository token only, with no id-token, no packages, and no core checkout,
# so neither workflow can both sign an operand and write to Git.
EXPECTED_PERMISSIONS["publish-operands.yml"] = (
    "contents: read",
    "id-token: write",
    "packages: write",
)
EXPECTED_PERMISSIONS["operand-references-pr.yml"] = (
    "actions: read",
    "contents: write",
    "pull-requests: write",
)

CONDITIONAL_CHECKOUTS = {
    "edge-drift.yml": "if: steps.secrets.outputs.edge-deploy-secrets-present == 'true'",
    "edge-plan.yml": "if: steps.secrets.outputs.edge-deploy-secrets-present == 'true'",
    "k8s-stack-drift.yml": "if: steps.secrets.outputs.kubeconfig-present == 'true'",
}

# GF_CORE_READ_TOKEN stays retired: TIN-4015 reinstated the deploy-key half of
# the pre-91ed60ea credential ladder (see CORE_DEPLOY_KEY_EXPR below), not the
# token half. GF_CORE_DEPLOY_KEY itself is deliberately NOT in this list any
# more -- see the history note above CORE_DEPLOY_KEY_EXPR.
RETIRED_CORE_CREDENTIALS = ("GF_CORE_READ_TOKEN",)
AUTHORITY_DOCS = (
    Path("README.md"),
    Path("docs/ci-credentials.md"),
    Path("docs/runbooks/oncluster-web-cutover.md"),
)
# History: commit 91ed60ea (2026-07-20) retired GF_CORE_DEPLOY_KEY when
# GloriousFlywheel was public, added it to RETIRED_CORE_CREDENTIALS, and wrote
# "do not silently restore a deploy-key/PAT ladder ... and do not reuse the
# org-scoped ARC registration App" into docs/ci-credentials.md on the
# assumption a future private-repo transition would use a dedicated,
# per-overlay contents:read GitHub App installation token instead. TIN-4015
# (2026-08-22, operator-ruled in the Linear issue text: "credential properly
# (deploy key pattern)") supersedes that assumption: GloriousFlywheel went
# private again the same day roster admission gave every self-hosted workflow
# here an actual runner, and no dedicated, per-overlay contents:read App
# installation on tinyland-inc/GloriousFlywheel exists (a GFTB GitHub App does
# exist -- config/organization.yaml's github_app_secret_name,
# config/organization.yaml's App secret is the org-scoped ARC registration
# App, and 91ed60ea's prohibition on reusing it
# for this still holds; nothing here does). The `GF_CORE_DEPLOY_KEY`
# repository secret was never deleted (minted 2026-07-14, predates its own
# retirement), so TIN-4015 reuses it rather than standing up new credential
# infrastructure.
# Every core-repository checkout below must bind exactly this expression -- a
# read-only deploy key scoped to source checkout only, never an ARC/apply
# credential.
CORE_DEPLOY_KEY_EXPR = "${{ secrets.GF_CORE_DEPLOY_KEY }}"
VERIFY_SCRIPT = (
    "set -euo pipefail",
    'actual="$(git -C GloriousFlywheel rev-parse --verify HEAD)"',
    'if [ "${actual}" != "${GF_CORE_REF}" ]; then',
    '  echo "::error::GloriousFlywheel checkout mismatch: expected ${GF_CORE_REF}, got ${actual}"',
    "  exit 1",
    "fi",
)
HOSTED_SELFTEST_WORKFLOW = Path(".github/workflows/validate.yml")
CORE_SELFTEST_WORKFLOW = Path(".github/workflows/archive-stack.yml")
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
            "Justfile gf_core_ci default must be the canonical exact #ci flake reference"
        )
    return _exact_sha(match.group(1), "Justfile gf_core_ci commit")


def justfile_arc_pin(source: str) -> str:
    sha_definition = _one(
        re.findall(r'(?m)^arc_core_sha\s*:=\s*"([0-9a-f]{40})"\s*$', source),
        "Justfile arc_core_sha authority",
    )
    ci_definition = _one(
        re.findall(
            r'(?m)^arc_core_ci_default\s*:=\s*"'
            + re.escape(CORE_FLAKE_PREFIX)
            + r'([0-9a-f]{40})#ci"\s*$',
            source,
        ),
        "Justfile arc_core_ci_default authority",
    )
    sha = _exact_sha(sha_definition, "Justfile ARC core commit")
    ci_sha = _exact_sha(ci_definition, "Justfile ARC core #ci commit")
    if sha != ci_sha:
        raise ContractError("Justfile ARC checkout and #ci pins must match")
    return sha


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
            r'(?m)^[ \t]+export GF_CORE_CI_PATH="path:\$\{GF_CORE_PATH\}#ci"[ \t]*$',
            source,
        )
        if len(canonical_ci_path_lines) != expected_ci_paths:
            findings.append(
                f"{workflow}: every GF_CORE_CI_PATH must bind the local "
                'path:${GF_CORE_PATH}#ci devshell (TIN-4015: GloriousFlywheel is '
                "private; a github: flake ref 404s even after the checkout is "
                "credentialed)"
            )
        core_path_definitions = re.findall(
            r"(?m)^[ \t]+export GF_CORE_PATH=\.\./GloriousFlywheel[ \t]*$",
            source,
        )
        if len(core_path_definitions) != expected_ci_paths:
            findings.append(
                f"{workflow}: expected {expected_ci_paths} GF_CORE_PATH export(s), "
                "one immediately backing each GF_CORE_CI_PATH"
            )
        if CORE_FLAKE_PREFIX in source:
            findings.append(
                f"{workflow}: must not reference the retired github: GloriousFlywheel "
                "flake source (TIN-4015)"
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
            if _step_condition(step) != expected_condition:
                findings.append(f"{location}: checkout condition must preserve lane gating")

            repositories = _with_values(step, "repository")
            if repositories == [CORE_REPOSITORY]:
                # Core-repository checkouts carry a mandatory, exact ssh-key
                # credential bound to GF_CORE_DEPLOY_KEY (TIN-4015). An
                # off-census path must not escape the credential, pin, and
                # HEAD-assertion checks below.
                allowed = {"GloriousFlywheel"}
                if set(_with_values(step, "path")) != allowed:
                    findings.append(
                        f"{location}: core-repository checkout path must be "
                        f"{sorted(allowed)[0]} -- an off-census core checkout "
                        "escapes every credential, pin, and HEAD-assertion check"
                    )
                continue
            if re.search(
                r"(?mi)^\s+['\"]?(?:token|ssh-key)['\"]?\s*:", step.text
            ):
                findings.append(f"{location}: checkout has an explicit credential input")
            if repositories:
                findings.append(f"{location}: overlay checkout cannot select another repository")
            if step.name != "Checkout overlay":
                findings.append(f"{location}: non-core checkout must be the overlay checkout")
            if _with_values(step, "ref"):
                findings.append(f"{location}: overlay checkout must use the event revision")
            expected_overlay_path = ["overlay"]
            if _with_values(step, "path") != expected_overlay_path:
                rendered = "the workspace root" if not expected_overlay_path else "overlay"
                findings.append(f"{location}: overlay checkout path must be {rendered}")

        core_indexes = [
            index
            for index, step in enumerate(steps)
            if _with_values(step, "repository") == [CORE_REPOSITORY]
            and _with_values(step, "path") == ["GloriousFlywheel"]
        ]
        if core_indexes:
            observed_core_workflows.add(workflow)
        expected_core_count = EXPECTED_CORE_CHECKOUTS.get(workflow, 0)
        if len(core_indexes) != expected_core_count:
            findings.append(
                f"{workflow}: expected {expected_core_count} core checkout declaration(s), found {len(core_indexes)}"
            )

        for index in core_indexes:
            step = steps[index]
            location = f"{workflow}:{step.line}"
            if step.name != "Checkout pinned GloriousFlywheel core":
                findings.append(f"{location}: core checkout name must state pinned source")
            if _with_values(step, "repository") != [CORE_REPOSITORY]:
                findings.append(f"{location}: core repository must be {CORE_REPOSITORY}")
            if _with_values(step, "ref") != ["${{ env.GF_CORE_REF }}"]:
                findings.append(f"{location}: core ref must be env.GF_CORE_REF")
            if _with_values(step, "path") != ["GloriousFlywheel"]:
                findings.append(f"{location}: core checkout path must be GloriousFlywheel")
            if _with_values(step, "ssh-key") != [CORE_DEPLOY_KEY_EXPR]:
                findings.append(
                    f"{location}: core checkout must bind the GF_CORE_DEPLOY_KEY deploy key"
                )
            if _with_values(step, "token"):
                findings.append(f"{location}: core checkout must not use a token credential")
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

    try:
        observed_arc_pin = justfile_arc_pin(_read(root, Path("Justfile"), "Justfile"))
        if observed_arc_pin != ARC_CORE_PIN:
            findings.append(
                f"Justfile: ARC authority must preserve role pin {ARC_CORE_PIN}"
            )
    except ContractError as exc:
        findings.append(str(exc))

    for relative in AUTHORITY_DOCS:
        try:
            source = _read(root, relative, f"authority document {relative}")
        except ContractError as exc:
            findings.append(str(exc))
            continue
        for credential in RETIRED_CORE_CREDENTIALS:
            if credential in source:
                findings.append(f"{relative}: references retired {credential}")

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
            CORE_SELFTEST_WORKFLOW,
            f"GF_CORE_REF: {IMPLEMENTATION_CORE_PIN}",
            "GF_CORE_REF: main",
        ),
        "job-level core ref override": (
            CORE_SELFTEST_WORKFLOW,
            "    steps:\n",
            f"    env:\n      GF_CORE_REF: {'e' * 40}\n    steps:\n",
        ),
        "floating checkout action": (
            HOSTED_SELFTEST_WORKFLOW,
            CHECKOUT_ACTION,
            "actions/checkout@v6",
        ),
        "credential persistence": (
            HOSTED_SELFTEST_WORKFLOW,
            "persist-credentials: false",
            "persist-credentials: true",
        ),
        "wrong core path": (
            CORE_SELFTEST_WORKFLOW,
            "path: GloriousFlywheel",
            "path: core",
        ),
        "explicit checkout token": (
            CORE_SELFTEST_WORKFLOW,
            "          path: GloriousFlywheel\n",
            "          path: GloriousFlywheel\n          token: ${{ github.token }}\n",
        ),
        "wrong core checkout SSH key": (
            CORE_SELFTEST_WORKFLOW,
            "          ssh-key: ${{ secrets.GF_CORE_DEPLOY_KEY }}\n",
            "          ssh-key: ${{ secrets.SOME_KEY }}\n",
        ),
        "missing core checkout SSH key": (
            CORE_SELFTEST_WORKFLOW,
            "          ssh-key: ${{ secrets.GF_CORE_DEPLOY_KEY }}\n",
            "",
        ),
        "off-census core checkout": (
            # B1 (PR #130 review, comment 5382527702): repointing an ordinary
            # "Checkout overlay" step at the core repository with a path
            # outside the two known census paths used to `continue` past both
            # the overlay credential rule AND the (then path-scoped)
            # core_indexes census, escaping every credential/pin/HEAD-assertion
            # check with 0 findings. This mutation is that exact shape.
            CORE_SELFTEST_WORKFLOW,
            "          path: overlay\n          persist-credentials: false\n",
            "          repository: tinyland-inc/GloriousFlywheel\n"
            "          ref: main\n"
            "          path: pwn\n"
            "          token: ${{ secrets.SOME_OTHER_SECRET }}\n"
            "          persist-credentials: false\n",
        ),
        "overlay checkout token": (
            HOSTED_SELFTEST_WORKFLOW,
            "          path: overlay\n",
            "          path: overlay\n          token: ${{ secrets.SITE_CI_READ_TOKEN }}\n",
        ),
        "spaced checkout credential key": (
            CORE_SELFTEST_WORKFLOW,
            "          path: GloriousFlywheel\n",
            "          path: GloriousFlywheel\n          token : ${{ secrets.NEW_GF_PAT }}\n",
        ),
        "wrong overlay path": (
            HOSTED_SELFTEST_WORKFLOW,
            "          path: overlay\n",
            "          path: wrong-overlay\n",
        ),
        "duplicate core ref": (
            CORE_SELFTEST_WORKFLOW,
            "          ref: ${{ env.GF_CORE_REF }}\n",
            "          ref: ${{ env.GF_CORE_REF }}\n          ref: main\n",
        ),
        "quoted hidden checkout": (
            HOSTED_SELFTEST_WORKFLOW,
            "    steps:\n",
            "    steps:\n      - name: Hidden checkout\n        uses: 'actions/checkout@v6'\n",
        ),
        "shell core clone": (
            HOSTED_SELFTEST_WORKFLOW,
            "    steps:\n",
            "    steps:\n      - name: Clone core\n        run: git clone https://github.com/tinyland-inc/GloriousFlywheel\n",
        ),
        "remote core action": (
            HOSTED_SELFTEST_WORKFLOW,
            "    steps:\n",
            "    steps:\n      - name: Remote core action\n        uses: tinyland-inc/GloriousFlywheel/.github/actions/nix-job@main\n",
        ),
        "floating core devshell": (
            CORE_SELFTEST_WORKFLOW,
            'export GF_CORE_CI_PATH="path:${GF_CORE_PATH}#ci"',
            'export GF_CORE_CI_PATH="path:../GloriousFlywheel-other#ci"',
        ),
        "resurrected github flake source": (
            CORE_SELFTEST_WORKFLOW,
            'export GF_CORE_CI_PATH="path:${GF_CORE_PATH}#ci"',
            'export GF_CORE_CI_PATH="github:tinyland-inc/GloriousFlywheel/${GF_CORE_REF}#ci"',
        ),
        "write contents permission": (
            HOSTED_SELFTEST_WORKFLOW,
            "  contents: read",
            "  contents: write",
        ),
        "expanded workflow token permissions": (
            HOSTED_SELFTEST_WORKFLOW,
            "  contents: read\n",
            "  contents: read\n  actions: write\n",
        ),
        "legacy core credential": (
            CORE_SELFTEST_WORKFLOW,
            "env:\n",
            "env:\n  GF_CORE_READ_TOKEN: ${{ secrets.GF_CORE_READ_TOKEN }}\n",
        ),
        "missing HEAD assertion": (
            CORE_SELFTEST_WORKFLOW,
            "      - name: Verify GloriousFlywheel core checkout",
            "      - name: Do not verify GloriousFlywheel core checkout",
        ),
        "mutated HEAD assertion": (
            CORE_SELFTEST_WORKFLOW,
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
            CORE_SELFTEST_WORKFLOW,
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
            Path("Justfile"),
            f'arc_core_sha := "{ARC_CORE_PIN}"',
            f'arc_core_sha := "{"c" * 40}"',
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
        f"{sum(EXPECTED_CORE_CHECKOUTS.values())} exact-SHA checkout declarations, "
        f"{sum(EXPECTED_CORE_CI_PATH_EXPORTS.values())} pinned #ci devshell sources, "
        f"implementation pin {IMPLEMENTATION_CORE_PIN}, "
        f"ARC role pin {ARC_CORE_PIN}, "
        f"operand publisher pin {OPERAND_PUBLISHER_CORE_PIN}; "
        "every core-repository checkout binds the read-only GF_CORE_DEPLOY_KEY "
        "deploy key (TIN-4015)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
