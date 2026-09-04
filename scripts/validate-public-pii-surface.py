#!/usr/bin/env python3
"""Validate that public-ready surfaces do not contain personal PII.

This is deliberately narrower than a secrets scanner:

- allow role/list/project email addresses that are expected in public docs and
  manifests
- fail personal-looking or unexpected email domains/localparts
- fail local home-directory paths
- fail separator-form phone numbers

Findings print path/line/kind only, not the matched value.
"""

from __future__ import annotations

import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent
SELF = Path(__file__).resolve().relative_to(REPO)

EMAIL = re.compile(
    r"(?<![A-Za-z0-9._%+-])"
    r"([A-Za-z0-9._%+-]+)@([A-Za-z0-9.-]+\.[A-Za-z]{2,})"
    r"(?![A-Za-z0-9._%+-])"
)
PHONE = re.compile(
    r"(?<!\d)(?:\+?1[ .-])?(?:\(\d{3}\)|\d{3})[ .-]\d{3}[ .-]\d{4}(?!\d)"
)
# Matches a home-rooted path and every trailing segment. Consuming the whole
# path is what lets ALLOWLIST_HOME_PATHS below be a set of exact literals: a
# two-segment token would make exact-equality behave as a subtree prefix test,
# silently exempting anything under an allowlisted root.
HOME_PATH = re.compile(r"/(?:Users|home)/[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*")

PUBLIC_ROLE_EMAILS = {
    "abuse@latoolb.us",
    "discuss@latoolb.us",
    "dmarc-reports@latoolb.us",
    "form-intake@latoolb.us",
    "keyholders-join@latoolb.us",
    "keyholders@latoolb.us",
    "lists-bounces@latoolb.us",
    "postmaster@latoolb.us",
    "root@lists.latoolb.us",
}

EXAMPLE_DOMAINS = {"example.com", "example.org", "example.net"}
ALLOWLIST_EMAILS = {"git@github.com"}
# Whole-path literals that are never an operator's local path: fixed, publicly
# documented locations inside images this repo consumes, which therefore appear
# verbatim in the committed ARC plan fixtures. Matched by exact equality against
# the FULL path, not by root or prefix -- /home/runner/.ssh/id_rsa and
# /home/runner-evil/run.sh are both still flagged, as is a bare /home/runner.
# Add a literal here only for a path that is provably a container-image constant.
ALLOWLIST_HOME_PATHS = {"/home/runner/run.sh"}
BINARY_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".ico", ".pdf"}


@dataclass(frozen=True)
class Finding:
    kind: str
    path: Path
    line: int
    detail: str


def tracked_files() -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files"],
        cwd=REPO,
        check=True,
        capture_output=True,
        text=True,
    )
    return [Path(line) for line in result.stdout.splitlines() if line]


def allowed_email(local: str, domain: str) -> bool:
    address = f"{local}@{domain}".lower()
    return (
        address in PUBLIC_ROLE_EMAILS
        or address in ALLOWLIST_EMAILS
        or domain.lower() in EXAMPLE_DOMAINS
    )


def flagged_home_paths(line: str) -> list[str]:
    """Home-rooted paths on one line that are not exact-literal allowlisted."""
    return [
        match.group(0)
        for match in HOME_PATH.finditer(line)
        if match.group(0) not in ALLOWLIST_HOME_PATHS
    ]


def scan() -> list[Finding]:
    findings: list[Finding] = []
    for rel in tracked_files():
        if rel == SELF or rel.suffix.lower() in BINARY_SUFFIXES:
            continue
        path = REPO / rel
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except (OSError, IsADirectoryError):
            continue
        for lineno, line in enumerate(lines, start=1):
            for match in EMAIL.finditer(line):
                local, domain = match.group(1).lower(), match.group(2).lower()
                if not allowed_email(local, domain):
                    findings.append(
                        Finding(
                            "unexpected-email",
                            rel,
                            lineno,
                            "domain/localpart is not public-role allowlisted",
                        )
                    )
            if PHONE.search(line):
                findings.append(Finding("phone-number", rel, lineno, "phone-like literal"))
            if flagged_home_paths(line):
                findings.append(Finding("home-path", rel, lineno, "local user path"))
    return findings


def self_test() -> None:
    if not allowed_email("keyholders", "latoolb.us"):
        raise SystemExit("self-test FAILED: expected role address was not allowed")
    if not allowed_email("root", "lists.latoolb.us"):
        raise SystemExit("self-test FAILED: expected list root role address was not allowed")
    if not allowed_email("operator", "example.org"):
        raise SystemExit("self-test FAILED: expected example address was not allowed")
    if allowed_email("person", "private.invalid"):
        raise SystemExit("self-test FAILED: unexpected personal address was allowed")
    if not PHONE.search("call 555-111-2222"):
        raise SystemExit("self-test FAILED: phone literal not detected")
    if PHONE.search("run 28673911406"):
        raise SystemExit("self-test FAILED: GitHub run id was falsely detected as phone")
    # Exercise the predicate scan() actually calls, not the bare regex, and prove
    # the allowlist is exact rather than a subtree exemption.
    for allowed in ALLOWLIST_HOME_PATHS:
        if flagged_home_paths(f'      - "{allowed}"'):
            raise SystemExit(
                f"self-test FAILED: allowlisted container path {allowed!r} was flagged"
            )
    for personal in (
        "/Users/operator/project",
        "/home/operator/project",
        "/home/runner/.ssh/id_rsa",
        "/home/runner/secrets/id_ed25519",
        "/home/runner/work/_temp/creds.env",
        "/home/runner-evil/run.sh",
        "/home/runnerx/run.sh",
        "/home/runner",
    ):
        if flagged_home_paths(f'value: "{personal}"') != [personal]:
            raise SystemExit(
                f"self-test FAILED: {personal!r} was not flagged as a local user path"
            )
    if any(
        entry.count("/") < 3 or entry.rstrip("/") != entry
        for entry in ALLOWLIST_HOME_PATHS
    ):
        raise SystemExit(
            "self-test FAILED: an allowlist entry is a bare home root, not a whole-path literal"
        )
    print("public-pii-surface self-test passed")


def main() -> int:
    if "--self-test" in sys.argv:
        self_test()
        return 0

    findings = scan()
    if findings:
        print("public PII surface validation FAILED:", file=sys.stderr)
        for finding in findings:
            print(
                f"  [{finding.kind}] {finding.path}:{finding.line}: {finding.detail}",
                file=sys.stderr,
            )
        return 1

    print("public PII surface validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
