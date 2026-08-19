#!/usr/bin/env python3
"""Validate the TIN-3902 GitHub runner-group admission contract.

Two files declare one boundary and nothing used to hold them together:

- `config/organization.yaml` `runner_contract.runner_group` declares the
  GitHub-side admission facts (group name, visibility, public-repository
  posture, selected-repository roster).
- `tofu/stacks/arc-runners/great-falls-tool-bus.tfvars` binds the ARC scale
  sets to that group (`runner_group`, `runner_group_policy`).

The GloriousFlywheel `arc-runners` module never reads the roster -- it owns no
`github_actions_runner_group` resource and only stamps the group NAME onto the
Helm release -- and `validate-overlay-runner-taxonomy.py` parses only runner
labels, registration URLs, Attic keys, and `extra_runner_sets`. So before this
check, the roster could be emptied, the group renamed on one side only, or the
operator-ruled public-admission value flipped back, and every gate stayed
green while the live cutover silently changed meaning.

The roster and the ruled public-admission value are encoded here on purpose.
Changing either is a reviewed edit to this file, exactly as advancing a core
pin is a reviewed edit to `validate-core-checkout.py`.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path


def _repository_root() -> Path:
    script_dir = Path(sys.argv[0]).resolve().parent
    if os.environ.get("TEST_SRCDIR") and os.environ.get("TEST_WORKSPACE"):
        candidate = Path(os.environ["TEST_SRCDIR"]) / os.environ["TEST_WORKSPACE"]
        if candidate.is_dir():
            return candidate
    return script_dir.parent


ROOT = _repository_root()
ORGANIZATION_CONFIG = Path("config/organization.yaml")
ARC_TFVARS = Path("tofu/stacks/arc-runners/great-falls-tool-bus.tfvars")

EXPECTED_GROUP_NAME = "great-falls-tool-bus-infra"
EXPECTED_POLICY = "organization-restricted"
EXPECTED_VISIBILITY = "selected"

# Operator ruling 2026-08-18 (TIN-3902): the roster must be EFFECTIVE, so the
# public `greatfallstoolbus.org` entry requires public-repository admission.
# This is a ruled value, not a default -- flipping it back is a reviewed
# decision that must edit this constant and cite the superseding ruling.
RULED_ALLOWS_PUBLIC_REPOSITORIES = True
RULING_CITATIONS = ("TIN-3902", "2026-08-18")

# Great-Falls-Tool-Bus/gftb-site (private) and
# Great-Falls-Tool-Bus/greatfallstoolbus.org (public, admitted under the
# ruling). Add the TIN-3815 successor spoke's id here when that repository
# exists; that is a reviewed roster change, not a drive-by edit.
EXPECTED_SELECTED_REPOSITORY_IDS = frozenset({1336591141, 1287399122})

# Great-Falls-Tool-Bus/great-falls-tool-bus-infra -- this public repository.
# With `allows_public_repositories: true` the roster is the ONLY control
# keeping it out, so admitting it must be explicit and self-documenting.
INFRA_REPOSITORY_ID = 1286829099
INFRA_ADMISSION_RULING_FIELD = "infra_repo_admission_ruling"

YAML_BOOLEANS = {"true": True, "false": False}


class ContractError(RuntimeError):
    """A checked surface violates the runner-group admission contract."""


def _read(root: Path, relative: Path) -> str:
    path = root / relative
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ContractError(f"{relative}: unreadable ({exc})") from exc


def runner_group_block(source: str) -> list[str]:
    """Return the `runner_contract.runner_group` block lines, comments included."""
    lines = source.splitlines()
    headers = [
        index
        for index, line in enumerate(lines)
        if re.fullmatch(r"  runner_group:\s*(?:#.*)?", line)
    ]
    if len(headers) != 1:
        raise ContractError(
            f"{ORGANIZATION_CONFIG}: expected exactly one "
            f"`runner_contract.runner_group:` block, found {len(headers)}"
        )
    block: list[str] = []
    for line in lines[headers[0] + 1 :]:
        if not line.strip():
            block.append(line)
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent < 4:
            break
        block.append(line)
    if not block:
        raise ContractError(f"{ORGANIZATION_CONFIG}: runner_group block is empty")
    return block


def scalar(block: list[str], key: str) -> str:
    matches = [
        match.group(1)
        for match in (
            re.fullmatch(rf"    {re.escape(key)}:\s*([^\s#]+)\s*(?:#.*)?", line)
            for line in block
        )
        if match
    ]
    if len(matches) != 1:
        raise ContractError(
            f"{ORGANIZATION_CONFIG}: runner_group.{key} must be declared exactly "
            f"once, found {len(matches)}"
        )
    return matches[0]


def boolean(block: list[str], key: str) -> bool:
    raw = scalar(block, key)
    if raw not in YAML_BOOLEANS:
        raise ContractError(
            f"{ORGANIZATION_CONFIG}: runner_group.{key} must be the YAML boolean "
            f"`true` or `false`, observed {raw!r}"
        )
    return YAML_BOOLEANS[raw]


def selected_repository_ids(block: list[str]) -> list[int]:
    headers = [
        index
        for index, line in enumerate(block)
        if re.fullmatch(r"    selected_repository_ids:\s*(?:#.*)?", line)
    ]
    if len(headers) != 1:
        raise ContractError(
            f"{ORGANIZATION_CONFIG}: runner_group.selected_repository_ids must be "
            f"declared exactly once, found {len(headers)}"
        )
    ids: list[int] = []
    for line in block[headers[0] + 1 :]:
        if not line.strip() or re.fullmatch(r"\s*#.*", line):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent <= 4:
            break
        item = re.fullmatch(r"      - ([^\s#]+)\s*(?:#.*)?", line)
        if not item:
            raise ContractError(
                f"{ORGANIZATION_CONFIG}: unparsable selected_repository_ids entry: "
                f"{line.strip()!r}"
            )
        value = item.group(1)
        if not re.fullmatch(r"[0-9]+", value):
            raise ContractError(
                f"{ORGANIZATION_CONFIG}: selected_repository_ids entries must be "
                f"bare numeric GitHub repository ids, observed {value!r}"
            )
        ids.append(int(value))
    return ids


def tfvars_string(source: str, key: str) -> str:
    matches = re.findall(
        rf'(?m)^{re.escape(key)}\s*=\s*"([^"]*)"\s*$',
        source,
    )
    if len(matches) != 1:
        raise ContractError(
            f"{ARC_TFVARS}: {key} must be assigned exactly once as a string "
            f"literal, found {len(matches)}"
        )
    return matches[0]


def validate(org_source: str, tfvars_source: str) -> list[str]:
    findings: list[str] = []

    try:
        block = runner_group_block(org_source)
    except ContractError as exc:
        return [str(exc)]
    block_text = "\n".join(block)

    try:
        declared_name = scalar(block, "name")
    except ContractError as exc:
        declared_name = None
        findings.append(str(exc))

    try:
        bound_name = tfvars_string(tfvars_source, "runner_group")
    except ContractError as exc:
        bound_name = None
        findings.append(str(exc))

    if declared_name is not None and declared_name != EXPECTED_GROUP_NAME:
        findings.append(
            f"{ORGANIZATION_CONFIG}: runner_group.name must be "
            f"{EXPECTED_GROUP_NAME!r}, observed {declared_name!r}"
        )
    if bound_name is not None and bound_name.strip().lower() == "default":
        findings.append(
            f"{ARC_TFVARS}: runner_group may never be GitHub's shared Default group"
        )
    if declared_name is not None and bound_name is not None and declared_name != bound_name:
        findings.append(
            f"declared runner_group.name {declared_name!r} "
            f"({ORGANIZATION_CONFIG}) and bound runner_group {bound_name!r} "
            f"({ARC_TFVARS}) must be the same group"
        )

    try:
        policy = tfvars_string(tfvars_source, "runner_group_policy")
        if policy != EXPECTED_POLICY:
            findings.append(
                f"{ARC_TFVARS}: runner_group_policy must be {EXPECTED_POLICY!r}, "
                f"observed {policy!r}; the legacy-default roster is nine "
                f"tinyland-inc scale sets, has never included "
                f"great-falls-tool-bus-nix, and expired 2026-08-15"
            )
    except ContractError as exc:
        findings.append(str(exc))

    try:
        visibility = scalar(block, "visibility")
        if visibility != EXPECTED_VISIBILITY:
            findings.append(
                f"{ORGANIZATION_CONFIG}: runner_group.visibility must be "
                f"{EXPECTED_VISIBILITY!r}, observed {visibility!r}; the roster is "
                f"the admission boundary and only `selected` enforces it"
            )
    except ContractError as exc:
        findings.append(str(exc))

    try:
        allows_public = boolean(block, "allows_public_repositories")
        if allows_public != RULED_ALLOWS_PUBLIC_REPOSITORIES:
            findings.append(
                f"{ORGANIZATION_CONFIG}: runner_group.allows_public_repositories "
                f"must be {str(RULED_ALLOWS_PUBLIC_REPOSITORIES).lower()} per "
                f"operator ruling 2026-08-18 (TIN-3902), observed "
                f"{str(allows_public).lower()}; the public greatfallstoolbus.org "
                f"roster entry is inert without it"
            )
    except ContractError as exc:
        findings.append(str(exc))

    missing_citations = [
        citation for citation in RULING_CITATIONS if citation not in block_text
    ]
    if missing_citations:
        findings.append(
            f"{ORGANIZATION_CONFIG}: the runner_group block must carry the "
            f"operator-ruling citation "
            f"({', '.join(RULING_CITATIONS)}) so the public-admission value is "
            f"never read as a default; missing {missing_citations!r}"
        )

    try:
        restricted = boolean(block, "restricted_to_workflows")
        if restricted:
            findings.append(
                f"{ORGANIZATION_CONFIG}: runner_group.restricted_to_workflows must "
                f"be false; workflow-ref filtering is a different control and is "
                f"not a substitute for the selected-repository roster"
            )
    except ContractError as exc:
        findings.append(str(exc))

    infra_ruling_present = any(
        re.fullmatch(rf"    {INFRA_ADMISSION_RULING_FIELD}:\s*[^\s#]+\s*(?:#.*)?", line)
        for line in block
    )

    try:
        observed_ids = selected_repository_ids(block)
    except ContractError as exc:
        return findings + [str(exc)]

    if not observed_ids:
        findings.append(
            f"{ORGANIZATION_CONFIG}: selected_repository_ids must not be empty; an "
            f"empty roster formalizes a runner group that admits nobody"
        )

    duplicates = sorted({value for value in observed_ids if observed_ids.count(value) > 1})
    if duplicates:
        findings.append(
            f"{ORGANIZATION_CONFIG}: duplicate selected_repository_ids entries: "
            f"{duplicates!r}"
        )

    if INFRA_REPOSITORY_ID in observed_ids and not infra_ruling_present:
        findings.append(
            f"{ORGANIZATION_CONFIG}: repository id {INFRA_REPOSITORY_ID} is this "
            f"public infrastructure repository. With allows_public_repositories "
            f"true the roster is the only control excluding it, so admitting it "
            f"requires an explicit `{INFRA_ADMISSION_RULING_FIELD}:` field "
            f"recording the operator decision"
        )

    allowed_ids = set(EXPECTED_SELECTED_REPOSITORY_IDS)
    if infra_ruling_present:
        allowed_ids.add(INFRA_REPOSITORY_ID)
    unexpected = sorted(set(observed_ids) - allowed_ids)
    missing = sorted(allowed_ids - set(observed_ids) - {INFRA_REPOSITORY_ID})
    if unexpected or missing:
        findings.append(
            f"{ORGANIZATION_CONFIG}: selected_repository_ids must be exactly the "
            f"reviewed roster {sorted(EXPECTED_SELECTED_REPOSITORY_IDS)!r}; "
            f"unexpected={unexpected!r}, missing={missing!r}. A roster change is a "
            f"reviewed edit to this file and to "
            f"scripts/validate-runner-group-contract.py"
        )

    return findings


NEGATIVE_FIXTURES: tuple[tuple[str, str, str, str], ...] = (
    (
        "public admission flipped back against the ruling",
        "organization",
        "\n    allows_public_repositories: true\n",
        "\n    allows_public_repositories: false\n",
    ),
    (
        "roster reduced below the reviewed set",
        "organization",
        "      - 1336591141",
        "",
    ),
    (
        "roster emptied entirely",
        "organization",
        "re:(?m)^      - [0-9]+\n",
        "",
    ),
    (
        "group renamed on the tfvars side only",
        "tfvars",
        'runner_group        = "great-falls-tool-bus-infra"',
        'runner_group        = "great-falls-tool-bus-other"',
    ),
    (
        "policy relaxed to the expired legacy-default escape",
        "tfvars",
        'runner_group_policy = "organization-restricted"',
        'runner_group_policy = "legacy-default"',
    ),
    (
        "visibility widened past the roster",
        "organization",
        "    visibility: selected",
        "    visibility: all",
    ),
    (
        "public infra repository admitted without a recorded ruling",
        "organization",
        "      - 1287399122",
        "      - 1287399122\n      - 1286829099",
    ),
    (
        "non-boolean public-admission value",
        "organization",
        "\n    allows_public_repositories: true\n",
        '\n    allows_public_repositories: "yes"\n',
    ),
)


def self_test(org_source: str, tfvars_source: str) -> None:
    baseline = validate(org_source, tfvars_source)
    if baseline:
        raise SystemExit(
            "runner-group contract self-test needs a clean baseline; observed: "
            + repr(baseline)
        )

    for name, target, old, new in NEGATIVE_FIXTURES:
        if target == "organization":
            source, other = org_source, tfvars_source
        else:
            source, other = tfvars_source, org_source
        if old.startswith("re:"):
            pattern = old[3:]
            if not re.search(pattern, source):
                raise SystemExit(
                    f"runner-group contract self-test fixture {name!r} matched no "
                    f"line with {pattern!r}"
                )
            mutated = re.sub(pattern, new, source)
        else:
            if source.count(old) != 1:
                raise SystemExit(
                    f"runner-group contract self-test fixture {name!r} needs exactly "
                    f"one occurrence of {old!r}"
                )
            mutated = source.replace(old, new)
        findings = (
            validate(mutated, other)
            if target == "organization"
            else validate(other, mutated)
        )
        if not findings:
            raise SystemExit(
                f"runner-group contract self-test failed: mutation {name!r} was not "
                "rejected"
            )

    print(
        f"runner-group contract self-test passed "
        f"({len(NEGATIVE_FIXTURES)} adversarial mutations rejected)"
    )


def main() -> int:
    try:
        org_source = _read(ROOT, ORGANIZATION_CONFIG)
        tfvars_source = _read(ROOT, ARC_TFVARS)
    except ContractError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    if "--self-test" in sys.argv[1:]:
        self_test(org_source, tfvars_source)
        return 0

    findings = validate(org_source, tfvars_source)
    if findings:
        print("runner-group admission contract validation FAILED:", file=sys.stderr)
        for finding in findings:
            print(f"  - {finding}", file=sys.stderr)
        return 1

    print(
        "runner-group admission contract passed: group "
        f"{EXPECTED_GROUP_NAME} bound at policy {EXPECTED_POLICY}, visibility "
        f"{EXPECTED_VISIBILITY}, public admission "
        f"{str(RULED_ALLOWS_PUBLIC_REPOSITORIES).lower()} per operator ruling "
        "2026-08-18 (TIN-3902), roster "
        f"{sorted(EXPECTED_SELECTED_REPOSITORY_IDS)}, "
        f"infra repository {INFRA_REPOSITORY_ID} excluded"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
