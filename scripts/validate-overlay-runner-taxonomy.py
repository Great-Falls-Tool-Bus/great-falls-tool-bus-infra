#!/usr/bin/env python3
"""Validate implementation-overlay ARC runner taxonomy."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse


SHARED_CAPABILITY_LABELS = {
    "tinyland-docker",
    "tinyland-dind",
    "tinyland-nix",
    "tinyland-nix-gpu",
    "tinyland-nix-heavy",
    "tinyland-nix-kvm",
}

ALLOWED_TINYLAND_SUFFIXES = {
    "aarch64",
    "arm64",
    "browser",
    "dawn",
    "darwin",
    "gpu",
    "heavy",
    "kvm",
    "linux",
    "macos",
    "privileged",
    "riscv",
    "vm",
    "webgpu",
    "x86_64",
}

PROJECT_IDENTITY_TOKENS = {
    "7810",
    "acuity",
    "betterkvm",
    "cmux",
    "dell",
    "jess",
    "jesssullivan",
    "jesssullivan-infra",
    "massage",
    "massageithaca",
    "rockies",
    "scheduling",
    "tummycrypt",
    "xoxdwm",
    # Great-Falls-Tool-Bus org identity tokens (labels are hyphen-tokenized;
    # the org name never belongs in a workflow-facing capability label).
    "gftb",
    "great",
    "falls",
    "greatfalls",
    "toolbus",
}

EXPECTED_ATTIC_PUBLIC_KEY = "main:eaUydxuDu7xBoy5cCo3MdknYAkVyTIASQ7DGuwxa+XA="
RETIRED_ATTIC_PUBLIC_KEYS = {
    "main:l/gpjG5GLg1Gczmn5K97n5iSIRcsaWerICzdXqiBYT8=",
}

# Extra-runner-set anchors that are deliberately cache-less (non-Bazel / RBE-less
# lanes). A nix/docker/dind anchor that omits bazel_cache_endpoint injects NO
# bazel cache (arc-runner module locals.tf: bazel_env_enabled requires it), which
# is the "under-wired RBE anchor" failure. Default-deny: every such anchor MUST
# carry cache wiring UNLESS its map key is named here. The keys below are
# retained verbatim from the template so scripts/test-overlay-runner-taxonomy.sh
# passes unchanged; the GFTB tfvars keeps extra_runner_sets empty, so none of
# them can match real config in this overlay.
BARE_EXEMPT = frozenset(
    {
        "personal-docker",      # template fixture: blog docker runner, no Bazel
        "massageithaca-dind",   # template fixture: quarantine anchor, no RBE
        "massageithaca-browser",  # template fixture: browser e2e lane, no Bazel
    }
)


@dataclass
class RunnerSet:
    key: str
    start_line: int
    runner_label: str | None = None
    github_config_url: str | None = None
    runner_type: str | None = None
    attic_server: str | None = None
    bazel_cache_endpoint: str | None = None
    bazel_executor_endpoint: str | None = None


def strip_comment(line: str) -> str:
    in_string = False
    escaped = False
    for idx, ch in enumerate(line):
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
            continue
        if ch == "#":
            return line[:idx]
        if ch == "/" and idx + 1 < len(line) and line[idx + 1] == "/":
            return line[:idx]
    return line


def strip_strings(line: str) -> str:
    out: list[str] = []
    in_string = False
    escaped = False
    for ch in line:
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
                out.append('""')
            continue
        if ch == '"':
            in_string = True
            continue
        out.append(ch)
    return "".join(out)


def brace_delta(line: str) -> int:
    body = strip_strings(strip_comment(line))
    return body.count("{") - body.count("}")


def parse_literal_assignments(path: Path, name: str) -> list[tuple[int, str]]:
    values: list[tuple[int, str]] = []
    pattern = re.compile(rf'^\s*{re.escape(name)}\s*=\s*"([^"]+)"\s*$')
    lines = path.read_text(encoding="utf-8").splitlines()
    for line_number, raw_line in enumerate(lines, start=1):
        match = pattern.match(strip_comment(raw_line))
        if match:
            values.append((line_number, match.group(1)))
    return values


def parse_extra_runner_sets(path: Path) -> list[RunnerSet]:
    runners: list[RunnerSet] = []
    in_extra = False
    depth = 0
    current: RunnerSet | None = None
    current_depth = 0

    lines = path.read_text(encoding="utf-8").splitlines()
    for line_number, raw_line in enumerate(lines, start=1):
        line = strip_comment(raw_line)

        if not in_extra and re.match(r"^\s*extra_runner_sets\s*=\s*{\s*$", line):
            in_extra = True
            depth = 1
            continue

        if not in_extra:
            continue

        if current is None:
            match = re.match(r"^\s*([A-Za-z0-9_-]+)\s*=\s*{\s*$", line)
            if match and depth == 1:
                current = RunnerSet(key=match.group(1), start_line=line_number)
                current_depth = depth + 1
                depth += brace_delta(line)
                continue
        else:
            label_match = re.match(r'^\s*runner_label\s*=\s*"([^"]+)"\s*$', line)
            if label_match:
                current.runner_label = label_match.group(1)

            url_match = re.match(r'^\s*github_config_url\s*=\s*"([^"]+)"\s*$', line)
            if url_match:
                current.github_config_url = url_match.group(1)

            # RBE wiring fields. An explicit empty assignment (= "") does not
            # match [^"]+ and leaves the field None, which validate_rbe_wiring
            # treats identically to an omitted field (both mean "absent").
            type_match = re.match(r'^\s*runner_type\s*=\s*"([^"]+)"\s*$', line)
            if type_match:
                current.runner_type = type_match.group(1)

            attic_match = re.match(r'^\s*attic_server\s*=\s*"([^"]+)"\s*$', line)
            if attic_match:
                current.attic_server = attic_match.group(1)

            cache_match = re.match(r'^\s*bazel_cache_endpoint\s*=\s*"([^"]+)"\s*$', line)
            if cache_match:
                current.bazel_cache_endpoint = cache_match.group(1)

            executor_match = re.match(r'^\s*bazel_executor_endpoint\s*=\s*"([^"]+)"\s*$', line)
            if executor_match:
                current.bazel_executor_endpoint = executor_match.group(1)

        depth += brace_delta(line)

        if current is not None and depth < current_depth:
            runners.append(current)
            current = None
            current_depth = 0

        if depth == 0:
            in_extra = False

    if current is not None:
        runners.append(current)

    return runners


def github_url_scope(url: str) -> str:
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.netloc.lower() != "github.com":
        return "invalid"

    parts = [part for part in parsed.path.split("/") if part]
    if len(parts) == 1:
        return "owner"
    if len(parts) == 2:
        return "repo"
    return "invalid"


def label_errors(label: str) -> list[str]:
    errors: list[str] = []
    lowered = label.lower()
    tokens = lowered.split("-")

    if label in SHARED_CAPABILITY_LABELS:
        return errors

    if len(tokens) < 2 or tokens[0] != "tinyland":
        errors.append("label must use the shared tinyland-* capability namespace")
        return errors

    if tokens[1] not in {"docker", "dind", "nix"}:
        errors.append("label must start with tinyland-docker, tinyland-dind, or tinyland-nix")

    suffixes = tokens[2:]
    unknown_suffixes = [suffix for suffix in suffixes if suffix not in ALLOWED_TINYLAND_SUFFIXES]
    if unknown_suffixes:
        errors.append("unknown capability suffixes: " + ", ".join(unknown_suffixes))

    project_tokens = sorted(PROJECT_IDENTITY_TOKENS.intersection(tokens))
    if project_tokens:
        errors.append("label contains project identity tokens: " + ", ".join(project_tokens))

    return errors


def validate_github_url(url: str, allow_repo_registration_anchor: bool) -> list[str]:
    scope = github_url_scope(url)
    if scope == "invalid":
        return [f"github_config_url {url!r} must be a GitHub URL"]
    if scope == "repo" and not allow_repo_registration_anchor:
        return [f"github_config_url {url!r} is repo scoped; overlays must opt in to repo anchors"]
    return []


def validate_attic_contract(path: Path) -> list[str]:
    errors: list[str] = []
    attic_servers = parse_literal_assignments(path, "attic_server")
    attic_keys = parse_literal_assignments(path, "attic_public_key")

    if attic_servers and not attic_keys:
        first_server_line = attic_servers[0][0]
        return [f"{path}:{first_server_line}: attic_server is set but attic_public_key is missing"]

    for line_number, key in attic_keys:
        if key in RETIRED_ATTIC_PUBLIC_KEYS:
            errors.append(f"{path}:{line_number}: attic_public_key uses retired cache key {key!r}")
        elif key != EXPECTED_ATTIC_PUBLIC_KEY:
            errors.append(
                f"{path}:{line_number}: attic_public_key must match current shared cache key "
                f"{EXPECTED_ATTIC_PUBLIC_KEY!r}"
            )

    return errors


def validate_rbe_wiring(runner: RunnerSet) -> list[str]:
    """Reject under-wired RBE anchors.

    A nix/docker/dind extra_runner_sets anchor that omits bazel_cache_endpoint
    injects no bazel cache (arc-runner module locals.tf: bazel_env_enabled
    requires it), and a nix anchor without attic_server gets no Nix substituter
    — silent under-wiring that tofu plan does not catch. Default-deny: such an
    anchor MUST carry cache (and attic, for nix) unless its key is in
    BARE_EXEMPT. Independently, executor-backed mode requires a cache, so
    bazel_executor_endpoint implies bazel_cache_endpoint (checked unconditionally).
    """
    errors: list[str] = []
    cache = runner.bazel_cache_endpoint or ""
    executor = runner.bazel_executor_endpoint or ""
    attic = runner.attic_server or ""

    # executor-implies-cache: applies to every anchor, exempt or not.
    if executor and not cache:
        errors.append(
            "bazel_executor_endpoint is set but bazel_cache_endpoint is empty — "
            "executor-backed mode requires a remote cache"
        )

    if runner.runner_type in {"nix", "docker", "dind"} and runner.key not in BARE_EXEMPT:
        if not cache:
            errors.append(
                f"runner_type {runner.runner_type!r} requires bazel_cache_endpoint "
                f"(RBE cache wiring); an under-wired anchor injects no bazel cache — "
                f"add the endpoint or add {runner.key!r} to BARE_EXEMPT"
            )
        if runner.runner_type == "nix" and not attic:
            errors.append(
                'runner_type "nix" requires attic_server (Nix substituter wiring)'
            )

    return errors


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate overlay runner labels stay capability-shaped.",
    )
    parser.add_argument(
        "--allow-repo-registration-anchor",
        action="store_true",
        help="Permit repo-scoped GitHub URLs as private ARC registration anchors.",
    )
    parser.add_argument("paths", nargs="+", type=Path, help="tfvars files to inspect")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    all_errors: list[str] = []

    for path in args.paths:
        for line_number, label in parse_literal_assignments(path, "runner_label"):
            for error in label_errors(label):
                all_errors.append(f"{path}:{line_number}: runner_label {label!r}: {error}")

        for line_number, url in parse_literal_assignments(path, "github_config_url"):
            for error in validate_github_url(url, args.allow_repo_registration_anchor):
                all_errors.append(f"{path}:{line_number}: {error}")

        all_errors.extend(validate_attic_contract(path))

        for runner in parse_extra_runner_sets(path):
            if runner.runner_label is None:
                all_errors.append(f"{path}:{runner.start_line}: {runner.key}: missing runner_label")
            # The map key is an internal Helm release/state key. It may be
            # owner-distinct when multiple overlays attach to one cluster; the
            # workflow-facing runner_label is the taxonomy contract.
            if runner.github_config_url is None:
                all_errors.append(f"{path}:{runner.start_line}: {runner.key}: missing github_config_url")
            for error in validate_rbe_wiring(runner):
                all_errors.append(f"{path}:{runner.start_line}: {runner.key}: {error}")

    if all_errors:
        print("Overlay runner taxonomy validation failed:", file=sys.stderr)
        for error in all_errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    checked = ", ".join(str(path) for path in args.paths)
    print(f"Overlay runner taxonomy validation passed: {checked}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
