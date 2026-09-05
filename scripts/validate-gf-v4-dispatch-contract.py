#!/usr/bin/env python3
"""Validate the GFTB GF v4 dispatch-edge overlay contract (TIN-2611, RULING 3).

Operator ruling 2026-09-05: the `gf-v4-dispatch` GitHub dispatch edge for the
Great-Falls-Tool-Bus organization lives in this -infra overlay as the
consumer's installation fact. GloriousFlywheel core keeps the reusable root
module (`tofu/stacks/arc-owner-overlay-release`); this overlay carries the
tfvars, the state coordinates, the pinned core role, the hosted plan/apply
lane, and the attended App Secret ceremony.

Six files declare one edge and nothing else holds them together:

- `tofu/stacks/gf-v4-dispatch/great-falls-tool-bus.tfvars` -- the eight
  module inputs, and nothing provider-shaped;
- `tofu/stacks/gf-v4-dispatch/tests/great-falls-tool-bus.tftest.hcl` -- the
  mock-provider proof of the derived identities, pinned to the same digest;
- `tofu/backend/honey-gf-v4-dispatch.s3.hcl` -- the state key under the
  consumer prefix;
- `config/organization.yaml` -- the owner identity the tfvars must join and
  the `dispatch_edge` record;
- `Justfile` -- the v4 dispatch role pin and stack globals; and
- `.github/workflows/gf-v4-dispatch.yml` -- the same pin, the protected
  environment, and the main-only apply gate.

This check is offline, deterministic, and toolchain-free: it parses text and
never launches OpenTofu, Nix, or a cluster client. Value regexes are copied
verbatim from the module's `variables.tf` at the pinned commit so a drifted
input fails here, on every pull request, before any plan runs. Changing the
runner image digest, the core pin, the runner group, or the state key is a
reviewed edit to this file, exactly as advancing a core pin is a reviewed edit
to `validate-core-checkout.py`.
"""

from __future__ import annotations

import os
import re
import sys
import tempfile
from pathlib import Path


def _repository_root() -> Path:
    script_dir = Path(sys.argv[0]).resolve().parent
    if os.environ.get("TEST_SRCDIR") and os.environ.get("TEST_WORKSPACE"):
        candidate = Path(os.environ["TEST_SRCDIR"]) / os.environ["TEST_WORKSPACE"]
        if candidate.is_dir():
            return candidate
    return script_dir.parent


ROOT = _repository_root()
TFVARS = Path("tofu/stacks/gf-v4-dispatch/great-falls-tool-bus.tfvars")
TFTEST = Path("tofu/stacks/gf-v4-dispatch/tests/great-falls-tool-bus.tftest.hcl")
BACKEND = Path("tofu/backend/honey-gf-v4-dispatch.s3.hcl")
ORGANIZATION = Path("config/organization.yaml")
JUSTFILE = Path("Justfile")
WORKFLOW = Path(".github/workflows/gf-v4-dispatch.yml")
CONTRACT_FILES = (TFVARS, TFTEST, BACKEND, ORGANIZATION, JUSTFILE, WORKFLOW)

# v4 dispatch role pin: GloriousFlywheel main merge of #1751 (2026-09-05), the
# first main commit carrying tofu/stacks/arc-owner-overlay-release together
# with #1766. Distinct from the implementation and ARC role pins in
# validate-core-checkout.py; advancing it is a reviewed edit to this constant,
# the Justfile globals, the workflow GF_CORE_REF, and config/organization.yaml.
GF_V4_DISPATCH_CORE_PIN = "82c96f5ce290bc768062782e911ed66a3527b941"

# Honey fleet runner image (tinyland-infra honey.tfvars nix_runner_image,
# read-only 2026-09-05). RE-PIN to the GloriousFlywheel #1766 publisher-baked
# digest in one reviewed PR (tfvars + this constant + the tftest digest) once
# deploy/gf-rbe/published-digests.log carries its receipt.
RUNNER_IMAGE_REPOSITORY = "ghcr.io/tinyland-inc/actions-runner-nix"
RUNNER_IMAGE_DIGEST = (
    "7bf301a6275bbe7d8e7b5d063335c9673ce284073606356ffc0900e560026be7"
)
RUNNER_IMAGE_PIN = f"{RUNNER_IMAGE_REPOSITORY}@sha256:{RUNNER_IMAGE_DIGEST}"

EXPECTED_CAPABILITY = "gf-v4-dispatch"
EXPECTED_OWNER_SLUG = "great-falls-tool-bus"
EXPECTED_GITHUB_CONFIG_URL = "https://github.com/Great-Falls-Tool-Bus"
# TO-RATIFY (TIN-2611 ceremony 0d step 1): reuse of the admitted tenancy group.
# The operator's fork is a dedicated great-falls-tool-bus-infra-gf-v4-dispatch
# group; changing it is a reviewed edit here, in the tfvars, in the tftest,
# and in config/organization.yaml together.
EXPECTED_RUNNER_GROUP = "great-falls-tool-bus-infra"
EXPECTED_CLUSTER_CONTEXT = "honey"
EXPECTED_POD_SECURITY_VERSION = "v1.33"
EXPECTED_MIN_RUNNERS = 0
EXPECTED_MAX_RUNNERS = 4
EXPECTED_STATE_BUCKET = "tofu-state"
EXPECTED_STATE_KEY = "great-falls-tool-bus-infra/gf-v4-dispatch/terraform.tfstate"
EXPECTED_STATE_ENDPOINT = "http://tofu-state-rustfs.nix-cache.svc:9000"
EXPECTED_ENVIRONMENT = "gf-v4-dispatch"
EXPECTED_APP_SECRET_NAME = (
    f"github-app-secret-{EXPECTED_OWNER_SLUG}-{EXPECTED_CAPABILITY}"
)
EXPECTED_RUNNER_NAMESPACE = f"arc-runners-{EXPECTED_OWNER_SLUG}"
EXPECTED_SCALE_SET_NAME = f"{EXPECTED_OWNER_SLUG}-{EXPECTED_CAPABILITY}"
EXPECTED_JOB_GATE = (
    "    if: github.event_name == 'push' || github.event_name == 'workflow_dispatch'"
)
EXPECTED_MAIN_ONLY_APPLY_FRAGMENT = (
    '[ "${{ github.ref }}" != "refs/heads/main" ]'
)
RETIRED_GITHUB_FLAKE_PREFIX = "github:tinyland-inc/GloriousFlywheel/"

REQUIRED_TFVARS_KEYS = frozenset(
    {
        "cluster_context",
        "owner_slug",
        "github_config_url",
        "runner_group",
        "runner_image",
        "pod_security_version",
        "min_runners",
        "max_runners",
    }
)
# Provider supply, placement, and roster never enter the consumer overlay. The
# module derives the namespace and label; the transaction kubeconfig is never
# committed.
FORBIDDEN_TFVARS_KEY = re.compile(
    r"k8s_config_path|node_selector|tolerations|affinity|storage_class|"
    r"namespace|endpoint|attic|bazel_|runner_label|extra_runner_sets|"
    r"priority_class|cache|executor|image_pull",
    re.IGNORECASE,
)

# Copied verbatim from tofu/stacks/arc-owner-overlay-release/variables.tf at
# GF_V4_DISPATCH_CORE_PIN.
OWNER_SLUG_PATTERN = re.compile(r"^[a-z][a-z0-9-]{1,38}[a-z0-9]$")
GITHUB_CONFIG_URL_PATTERN = re.compile(
    r"^https://github\.com/[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/?$"
)
RUNNER_GROUP_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_. -]{0,99}$")
RUNNER_IMAGE_PATTERN = re.compile(
    r"^ghcr\.io/tinyland-inc/actions-runner-nix@sha256:[0-9a-f]{64}$"
)
POD_SECURITY_VERSION_PATTERN = re.compile(r"^v[0-9]+\.[0-9]+$")
EXACT_SHA = re.compile(r"^[0-9a-f]{40}$")

JUSTFILE_GLOBALS = {
    "gf_v4_dispatch_core_sha": f'"{GF_V4_DISPATCH_CORE_PIN}"',
    "gf_v4_dispatch_core_default": '"../GloriousFlywheel-gf-v4-82c96f5c"',
    "gf_v4_dispatch_core_ci_default": (
        f'"{RETIRED_GITHUB_FLAKE_PREFIX}{GF_V4_DISPATCH_CORE_PIN}#ci"'
    ),
    "gf_v4_dispatch_core_stack": '"tofu/stacks/arc-owner-overlay-release"',
    "gf_v4_dispatch_stack": '"tofu/stacks/gf-v4-dispatch"',
    "gf_v4_dispatch_tfvars": f'"{TFVARS.as_posix()}"',
    "gf_v4_dispatch_backend": (
        'env_var_or_default("GF_V4_DISPATCH_BACKEND", '
        f'"{BACKEND.as_posix()}")'
    ),
}

DISPATCH_EDGE_BLOCK = {
    "capability": EXPECTED_CAPABILITY,
    "owner_slug": EXPECTED_OWNER_SLUG,
    "runner_group": EXPECTED_RUNNER_GROUP,
    "core_pin": GF_V4_DISPATCH_CORE_PIN,
    "state_key": EXPECTED_STATE_KEY,
    "environment": EXPECTED_ENVIRONMENT,
    "app_secret_name": EXPECTED_APP_SECRET_NAME,
    "runner_namespace": EXPECTED_RUNNER_NAMESPACE,
}

TFTEST_REQUIRED_FRAGMENTS = {
    'mock_provider "helm" {}': "mock the helm provider",
    'mock_provider "kubernetes" {}': "mock the kubernetes provider",
    f'output.dispatch_edge.owner == "{EXPECTED_OWNER_SLUG}"': "assert the owner",
    f'output.dispatch_edge.capability == "{EXPECTED_CAPABILITY}"': "assert the capability",
    f'output.dispatch_edge.runner_namespace == "{EXPECTED_RUNNER_NAMESPACE}"': (
        "assert the module-derived namespace"
    ),
    f'output.dispatch_edge.runner_scale_set_name == "{EXPECTED_SCALE_SET_NAME}"': (
        "assert the module-derived scale set name"
    ),
    f'output.dispatch_edge.github_config_url == "{EXPECTED_GITHUB_CONFIG_URL}"': (
        "assert the organization registration URL"
    ),
    f'output.dispatch_edge.runner_group == "{EXPECTED_RUNNER_GROUP}"': (
        "assert the admitted runner group"
    ),
    f'output.dispatch_edge.github_config_secret_name == "{EXPECTED_APP_SECRET_NAME}"': (
        "assert the module-derived App Secret name"
    ),
    f'output.dispatch_edge.runner_image_digest == "{RUNNER_IMAGE_DIGEST}"': (
        "assert the pinned runner image digest"
    ),
    'output.dispatch_edge.remote_action_scheduler == "reapi"': (
        "assert the remote-only scheduler"
    ),
    "!output.dispatch_edge.local_build_or_endpoint_fallback": (
        "assert no local or endpoint fallback"
    ),
    "!output.dispatch_edge.consumer_supplies_provider_endpoint": (
        "assert the consumer supplies no provider endpoint"
    ),
    "!output.dispatch_edge.runner_pod_is_compute_scheduling_unit": (
        "assert the runner pod is not the compute unit"
    ),
    "!output.standing_mutation_authorized": "assert no standing mutation authority",
}


class ContractError(RuntimeError):
    """A checked surface violates the dispatch-edge contract."""


def _read(root: Path, relative: Path) -> str:
    path = root / relative
    try:
        if not path.is_file():
            raise OSError("not a regular file")
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ContractError(f"{relative}: unreadable ({exc})") from exc


def parse_tfvars(source: str) -> dict[str, str | int]:
    """Parse scalar `key = value` assignments; anything else fails closed."""
    values: dict[str, str | int] = {}
    for lineno, raw in enumerate(source.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)\s*", line)
        if match is None:
            raise ContractError(
                f"{TFVARS}:{lineno}: only scalar `key = value` assignments are "
                f"admitted in the dispatch-edge tfvars"
            )
        key, literal = match.group(1), match.group(2)
        if key in values:
            raise ContractError(f"{TFVARS}:{lineno}: duplicate assignment of {key}")
        string = re.fullmatch(r'"([^"\\]*)"', literal)
        integer = re.fullmatch(r"-?[0-9]+", literal)
        if string is not None:
            values[key] = string.group(1)
        elif integer is not None:
            values[key] = int(literal)
        else:
            raise ContractError(
                f"{TFVARS}:{lineno}: {key} must be a plain string or integer literal"
            )
    return values


def top_level_block(source: str, header: str, label: Path) -> list[str]:
    lines = source.splitlines()
    headers = [
        index
        for index, line in enumerate(lines)
        if re.fullmatch(rf"{re.escape(header)}:\s*(?:#.*)?", line)
    ]
    if len(headers) != 1:
        raise ContractError(
            f"{label}: expected exactly one top-level `{header}:` block, "
            f"found {len(headers)}"
        )
    block: list[str] = []
    for line in lines[headers[0] + 1 :]:
        if line and not line[0].isspace():
            break
        block.append(line)
    return block


def block_scalar(block: list[str], key: str, indent: int, label: str) -> str:
    matches = [
        match.group(1)
        for match in (
            re.fullmatch(rf" {{{indent}}}{re.escape(key)}:\s*([^\s#]+)\s*(?:#.*)?", line)
            for line in block
        )
        if match
    ]
    if len(matches) != 1:
        raise ContractError(
            f"{ORGANIZATION}: {label}.{key} must be declared exactly once, "
            f"found {len(matches)}"
        )
    return matches[0]


def nested_block(block: list[str], header: str, indent: int, label: str) -> list[str]:
    headers = [
        index
        for index, line in enumerate(block)
        if re.fullmatch(rf" {{{indent}}}{re.escape(header)}:\s*(?:#.*)?", line)
    ]
    if len(headers) != 1:
        raise ContractError(
            f"{ORGANIZATION}: {label}.{header} must appear exactly once, "
            f"found {len(headers)}"
        )
    nested: list[str] = []
    for line in block[headers[0] + 1 :]:
        if not line.strip():
            nested.append(line)
            continue
        if len(line) - len(line.lstrip(" ")) <= indent:
            break
        nested.append(line)
    return nested


def organization_identity(source: str) -> tuple[str, str, str, dict[str, str]]:
    owner = top_level_block(source, "owner", ORGANIZATION)
    slug = block_scalar(owner, "slug", 2, "owner")
    url = block_scalar(owner, "github_config_url", 2, "owner")
    runner_contract = top_level_block(source, "runner_contract", ORGANIZATION)
    runner_group = nested_block(runner_contract, "runner_group", 2, "runner_contract")
    group_name = block_scalar(runner_group, "name", 4, "runner_contract.runner_group")
    dispatch = top_level_block(source, "dispatch_edge", ORGANIZATION)
    declared: dict[str, str] = {}
    for line in dispatch:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.fullmatch(r"  ([a-z0-9_]+):\s*([^\s#]+)\s*(?:#.*)?", line)
        if match is None:
            raise ContractError(
                f"{ORGANIZATION}: dispatch_edge admits only flat scalar keys; "
                f"observed {line.strip()!r}"
            )
        if match.group(1) in declared:
            raise ContractError(
                f"{ORGANIZATION}: dispatch_edge.{match.group(1)} declared twice"
            )
        declared[match.group(1)] = match.group(2)
    return slug, url, group_name, declared


def backend_values(source: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for key, pattern in (
        ("bucket", r'(?m)^bucket\s*=\s*"([^"]+)"\s*$'),
        ("key", r'(?m)^key\s*=\s*"([^"]+)"\s*$'),
        ("s3", r'(?m)^\s*s3\s*=\s*"([^"]+)"\s*$'),
    ):
        matches = re.findall(pattern, source)
        if len(matches) != 1:
            raise ContractError(f"{BACKEND}: {key} must be assigned exactly once")
        values[key] = matches[0]
    return values


def justfile_findings(source: str) -> list[str]:
    findings: list[str] = []
    for name, expected in JUSTFILE_GLOBALS.items():
        observed = re.findall(rf"(?m)^{re.escape(name)}\s*:=\s*(.*?)\s*$", source)
        if observed != [expected]:
            findings.append(
                f"{JUSTFILE}: {name} must be declared exactly once as {expected}; "
                f"observed {observed!r}"
            )
    return findings


def workflow_findings(source: str) -> list[str]:
    findings: list[str] = []
    refs = re.findall(r"(?m)^  GF_CORE_REF[ \t]*:[ \t]*([^\s#]+)[ \t]*(?:#.*)?$", source)
    if refs != [GF_V4_DISPATCH_CORE_PIN]:
        findings.append(
            f"{WORKFLOW}: GF_CORE_REF must be exactly the v4 dispatch role pin "
            f"{GF_V4_DISPATCH_CORE_PIN}; observed {refs!r}"
        )
    if len(re.findall(rf"(?m)^    environment: {EXPECTED_ENVIRONMENT}\s*$", source)) != 1:
        findings.append(
            f"{WORKFLOW}: the plan/apply job must bind the protected "
            f"`{EXPECTED_ENVIRONMENT}` environment exactly once"
        )
    if source.count(EXPECTED_JOB_GATE) != 1:
        findings.append(
            f"{WORKFLOW}: the credentialed job must carry the push/workflow_dispatch "
            "event gate exactly once (no pull_request-reachable credential)"
        )
    if EXPECTED_MAIN_ONLY_APPLY_FRAGMENT not in source:
        findings.append(
            f"{WORKFLOW}: action=apply must refuse every ref except refs/heads/main"
        )
    apply_steps = re.findall(
        r"(?ms)^      - name: Apply dispatch edge\n        if: >-\n(.*?)\n        uses:",
        source,
    )
    if len(apply_steps) != 1 or "github.event.inputs.action == 'apply'" not in apply_steps[0]:
        findings.append(
            f"{WORKFLOW}: the apply step must exist once and be conditioned on "
            "workflow_dispatch action=apply"
        )
    if re.search(r"(?m)^\s*pull_request_target\s*:", source):
        findings.append(f"{WORKFLOW}: pull_request_target is forbidden")
    if RETIRED_GITHUB_FLAKE_PREFIX in source:
        findings.append(
            f"{WORKFLOW}: must bind the checked-out core devshell, never the "
            "github: flake source (the core repository is private)"
        )
    if "GF_V4_DISPATCH_KUBECONFIG_B64" not in source:
        findings.append(
            f"{WORKFLOW}: the transaction kubeconfig must be the environment secret "
            "GF_V4_DISPATCH_KUBECONFIG_B64"
        )
    return findings


def tftest_findings(source: str, tfvars_digest: str | None) -> list[str]:
    findings: list[str] = []
    for fragment, purpose in TFTEST_REQUIRED_FRAGMENTS.items():
        if fragment not in source:
            findings.append(f"{TFTEST}: must {purpose} ({fragment!r})")
    variables = re.findall(r"(?ms)^variables \{\n(.*?)^\}", source)
    if len(variables) != 1:
        findings.append(f"{TFTEST}: exactly one top-level variables block is required")
    else:
        assigned = re.findall(r"(?m)^[ \t]*([a-z0-9_]+)[ \t]*=", variables[0])
        if assigned != ["k8s_config_path"]:
            findings.append(
                f"{TFTEST}: the top-level variables block may set only "
                f"k8s_config_path so the committed tfvars stay the proven input; "
                f"observed {assigned!r}"
            )
    digests = re.findall(
        r'output\.dispatch_edge\.runner_image_digest == "([0-9a-f]{64})"', source
    )
    if tfvars_digest is not None and digests != [tfvars_digest]:
        findings.append(
            f"{TFTEST}: the asserted runner image digest must equal the tfvars "
            f"digest {tfvars_digest}; observed {digests!r}"
        )
    return findings


def validate(root: Path) -> list[str]:
    findings: list[str] = []
    sources: dict[Path, str] = {}
    for relative in CONTRACT_FILES:
        try:
            sources[relative] = _read(root, relative)
        except ContractError as exc:
            findings.append(str(exc))
    if findings:
        return findings

    tfvars_digest: str | None = None
    try:
        values = parse_tfvars(sources[TFVARS])
    except ContractError as exc:
        findings.append(str(exc))
        values = {}

    if values:
        observed_keys = set(values)
        missing = sorted(REQUIRED_TFVARS_KEYS - observed_keys)
        extra = sorted(observed_keys - REQUIRED_TFVARS_KEYS)
        if missing:
            findings.append(f"{TFVARS}: missing required input(s) {missing!r}")
        if extra:
            findings.append(
                f"{TFVARS}: unadmitted input(s) {extra!r}; the consumer overlay "
                "declares exactly the module's eight inputs"
            )
        for key in sorted(observed_keys):
            if FORBIDDEN_TFVARS_KEY.search(key):
                findings.append(
                    f"{TFVARS}: {key} is provider supply, placement, roster, or a "
                    "transaction credential and never belongs in the overlay"
                )

        def string(key: str) -> str | None:
            value = values.get(key)
            if isinstance(value, str):
                return value
            if key in REQUIRED_TFVARS_KEYS and key in values:
                findings.append(f"{TFVARS}: {key} must be a string literal")
            return None

        def integer(key: str) -> int | None:
            value = values.get(key)
            if isinstance(value, int):
                return value
            if key in values:
                findings.append(f"{TFVARS}: {key} must be an integer literal")
            return None

        cluster_context = string("cluster_context")
        if cluster_context is not None and cluster_context != EXPECTED_CLUSTER_CONTEXT:
            findings.append(
                f"{TFVARS}: cluster_context must be {EXPECTED_CLUSTER_CONTEXT!r} "
                "(API context only, never placement); observed "
                f"{cluster_context!r}"
            )
        owner_slug = string("owner_slug")
        if owner_slug is not None:
            if OWNER_SLUG_PATTERN.fullmatch(owner_slug) is None:
                findings.append(f"{TFVARS}: owner_slug must be a lowercase DNS label")
            if owner_slug != EXPECTED_OWNER_SLUG:
                findings.append(
                    f"{TFVARS}: owner_slug must be {EXPECTED_OWNER_SLUG!r}; "
                    f"observed {owner_slug!r}"
                )
        github_config_url = string("github_config_url")
        if github_config_url is not None:
            if GITHUB_CONFIG_URL_PATTERN.fullmatch(github_config_url) is None:
                findings.append(
                    f"{TFVARS}: github_config_url must be an exact GitHub organization "
                    "URL with no repository path"
                )
            if github_config_url != EXPECTED_GITHUB_CONFIG_URL:
                findings.append(
                    f"{TFVARS}: github_config_url must be "
                    f"{EXPECTED_GITHUB_CONFIG_URL!r}; observed {github_config_url!r}"
                )
        runner_group = string("runner_group")
        if runner_group is not None:
            if (
                runner_group != runner_group.strip()
                or RUNNER_GROUP_PATTERN.fullmatch(runner_group) is None
                or runner_group.strip().lower() == "default"
            ):
                findings.append(
                    f"{TFVARS}: runner_group must name an explicit admitted "
                    "non-Default GitHub runner group"
                )
            if runner_group != EXPECTED_RUNNER_GROUP:
                findings.append(
                    f"{TFVARS}: runner_group must be {EXPECTED_RUNNER_GROUP!r} "
                    "(TO-RATIFY reuse of the admitted tenancy group); observed "
                    f"{runner_group!r}"
                )
        runner_image = string("runner_image")
        if runner_image is not None:
            if RUNNER_IMAGE_PATTERN.fullmatch(runner_image) is None:
                findings.append(
                    f"{TFVARS}: runner_image must be the immutable provider-published "
                    f"{RUNNER_IMAGE_REPOSITORY}@sha256 reference"
                )
            if runner_image != RUNNER_IMAGE_PIN:
                findings.append(
                    f"{TFVARS}: runner_image must be the reviewed pin "
                    f"{RUNNER_IMAGE_PIN}; a re-pin is a reviewed edit to this "
                    "validator, the tfvars, and the tftest digest together"
                )
            else:
                tfvars_digest = runner_image.rsplit("@sha256:", 1)[1]
        pod_security_version = string("pod_security_version")
        if pod_security_version is not None:
            if POD_SECURITY_VERSION_PATTERN.fullmatch(pod_security_version) is None:
                findings.append(
                    f"{TFVARS}: pod_security_version must be explicit, for example v1.33"
                )
            if pod_security_version != EXPECTED_POD_SECURITY_VERSION:
                findings.append(
                    f"{TFVARS}: pod_security_version must be "
                    f"{EXPECTED_POD_SECURITY_VERSION!r}; observed "
                    f"{pod_security_version!r}"
                )
        min_runners = integer("min_runners")
        max_runners = integer("max_runners")
        if min_runners is not None and min_runners != EXPECTED_MIN_RUNNERS:
            findings.append(
                f"{TFVARS}: min_runners must be {EXPECTED_MIN_RUNNERS}; observed "
                f"{min_runners}"
            )
        if max_runners is not None and (max_runners < 1 or max_runners != EXPECTED_MAX_RUNNERS):
            findings.append(
                f"{TFVARS}: max_runners must be {EXPECTED_MAX_RUNNERS} (a positive "
                f"integer so the released edge is schedulable); observed {max_runners}"
            )
        if (
            min_runners is not None
            and max_runners is not None
            and not 0 <= min_runners <= max_runners
        ):
            findings.append(
                f"{TFVARS}: runner capacity must satisfy 0 <= min_runners <= max_runners"
            )

        try:
            slug, url, group_name, declared = organization_identity(sources[ORGANIZATION])
        except ContractError as exc:
            findings.append(str(exc))
        else:
            if owner_slug is not None and slug.lower() != owner_slug:
                findings.append(
                    f"{ORGANIZATION}: owner.slug {slug!r} does not join tfvars "
                    f"owner_slug {owner_slug!r}"
                )
            if github_config_url is not None and url != github_config_url:
                findings.append(
                    f"{ORGANIZATION}: owner.github_config_url {url!r} does not join "
                    f"tfvars github_config_url {github_config_url!r}"
                )
            if runner_group is not None and group_name != runner_group:
                findings.append(
                    f"{ORGANIZATION}: runner_contract.runner_group.name {group_name!r} "
                    f"does not join tfvars runner_group {runner_group!r}"
                )
            if declared != DISPATCH_EDGE_BLOCK:
                findings.append(
                    f"{ORGANIZATION}: dispatch_edge must be exactly "
                    f"{DISPATCH_EDGE_BLOCK!r}; observed {declared!r}"
                )

    try:
        backend = backend_values(sources[BACKEND])
    except ContractError as exc:
        findings.append(str(exc))
    else:
        if backend["bucket"] != EXPECTED_STATE_BUCKET:
            findings.append(
                f"{BACKEND}: bucket must be {EXPECTED_STATE_BUCKET!r}; observed "
                f"{backend['bucket']!r}"
            )
        if backend["key"] != EXPECTED_STATE_KEY:
            findings.append(
                f"{BACKEND}: key must be {EXPECTED_STATE_KEY!r} (state lives under "
                f"the consumer prefix); observed {backend['key']!r}"
            )
        if backend["s3"] != EXPECTED_STATE_ENDPOINT:
            findings.append(
                f"{BACKEND}: endpoints.s3 must be {EXPECTED_STATE_ENDPOINT!r}; "
                f"observed {backend['s3']!r}"
            )

    findings.extend(justfile_findings(sources[JUSTFILE]))
    findings.extend(workflow_findings(sources[WORKFLOW]))
    findings.extend(tftest_findings(sources[TFTEST], tfvars_digest))
    return findings


def _write_fixture(destination: Path, source_root: Path) -> None:
    for relative in CONTRACT_FILES:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(_read(source_root, relative), encoding="utf-8")


def self_test(root: Path) -> None:
    other_digest = "0" * 64
    mutations: dict[str, tuple[Path, str, str]] = {
        "mutable runner image tag": (
            TFVARS,
            f'runner_image = "{RUNNER_IMAGE_PIN}"',
            f'runner_image = "{RUNNER_IMAGE_REPOSITORY}:main"',
        ),
        "foreign runner image": (
            TFVARS,
            f'runner_image = "{RUNNER_IMAGE_PIN}"',
            f'runner_image = "ghcr.io/example-owner/runner@sha256:{RUNNER_IMAGE_DIGEST}"',
        ),
        "unreviewed runner image digest": (
            TFVARS,
            f'runner_image = "{RUNNER_IMAGE_PIN}"',
            f'runner_image = "{RUNNER_IMAGE_REPOSITORY}@sha256:{other_digest}"',
        ),
        "Default runner group": (
            TFVARS,
            f'runner_group = "{EXPECTED_RUNNER_GROUP}"',
            'runner_group = "Default"',
        ),
        "repository registration anchor": (
            TFVARS,
            f'github_config_url = "{EXPECTED_GITHUB_CONFIG_URL}"',
            f'github_config_url = "{EXPECTED_GITHUB_CONFIG_URL}/gftb-site"',
        ),
        "placement literal": (
            TFVARS,
            "max_runners = 4\n",
            'max_runners = 4\nnode_selector = "sting"\n',
        ),
        "committed transaction kubeconfig": (
            TFVARS,
            "max_runners = 4\n",
            'max_runners = 4\nk8s_config_path = "/tmp/kubeconfig"\n',
        ),
        "zero dispatch capacity": (
            TFVARS,
            "max_runners = 4\n",
            "max_runners = 0\n",
        ),
        "Justfile pin drift": (
            JUSTFILE,
            f'gf_v4_dispatch_core_sha := "{GF_V4_DISPATCH_CORE_PIN}"',
            f'gf_v4_dispatch_core_sha := "{"a" * 40}"',
        ),
        "workflow pin drift": (
            WORKFLOW,
            f"GF_CORE_REF: {GF_V4_DISPATCH_CORE_PIN}",
            "GF_CORE_REF: main",
        ),
        "workflow apply gate removed": (
            WORKFLOW,
            EXPECTED_JOB_GATE + "\n",
            "",
        ),
        "wrong backend key": (
            BACKEND,
            f'"{EXPECTED_STATE_KEY}"',
            '"owner-overlay/example/plane/release.tfstate"',
        ),
        "tftest digest drift": (
            TFTEST,
            f'runner_image_digest == "{RUNNER_IMAGE_DIGEST}"',
            f'runner_image_digest == "{other_digest}"',
        ),
        "organization dispatch_edge drift": (
            ORGANIZATION,
            f"  runner_group: {EXPECTED_RUNNER_GROUP}\n  core_pin:",
            f"  runner_group: {EXPECTED_RUNNER_GROUP}-other\n  core_pin:",
        ),
    }
    for label, (relative, old, new) in mutations.items():
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary)
            _write_fixture(fixture, root)
            path = fixture / relative
            source = path.read_text(encoding="utf-8")
            if source.count(old) != 1:
                raise RuntimeError(
                    f"self-test fixture for {label} needs exactly one occurrence of "
                    f"{old!r}"
                )
            path.write_text(source.replace(old, new, 1), encoding="utf-8")
            if not validate(fixture):
                raise RuntimeError(f"self-test accepted {label}")


def main() -> int:
    findings = validate(ROOT)
    if findings:
        print(
            f"gf-v4-dispatch contract FAILED ({len(findings)} finding(s)):",
            file=sys.stderr,
        )
        for finding in findings:
            print(f"- {finding}", file=sys.stderr)
        return 1

    if "--self-test" in sys.argv:
        try:
            self_test(ROOT)
        except RuntimeError as exc:
            print(f"gf-v4-dispatch contract self-test FAILED: {exc}", file=sys.stderr)
            return 1
        print("gf-v4-dispatch contract self-test passed")
        return 0

    print(
        "gf-v4-dispatch contract passed: owner "
        f"{EXPECTED_OWNER_SLUG} at {EXPECTED_GITHUB_CONFIG_URL}, runner group "
        f"{EXPECTED_RUNNER_GROUP} (TO-RATIFY), runner image digest "
        f"{RUNNER_IMAGE_DIGEST[:12]}..., v4 dispatch role pin "
        f"{GF_V4_DISPATCH_CORE_PIN}, state key {EXPECTED_STATE_KEY}, "
        f"environment {EXPECTED_ENVIRONMENT}; no provider endpoint, placement, "
        "roster, or transaction credential in the overlay"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
