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
HOME_PATH = re.compile(r"/Users/[A-Za-z0-9._-]+|/home/[A-Za-z0-9._-]+")

PUBLIC_ROLE_EMAILS = {
    "abuse@latoolb.us",
    "discuss@latoolb.us",
    "dmarc-reports@latoolb.us",
    "form-intake@latoolb.us",
    "keyholders-join@latoolb.us",
    "keyholders@latoolb.us",
    "lists-bounces@latoolb.us",
    "postmaster@latoolb.us",
}

EXAMPLE_DOMAINS = {"example.com", "example.org", "example.net"}
ALLOWLIST_EMAILS = {"git@github.com"}
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
            if HOME_PATH.search(line):
                findings.append(Finding("home-path", rel, lineno, "local user path"))
    return findings


def self_test() -> None:
    if not allowed_email("keyholders", "latoolb.us"):
        raise SystemExit("self-test FAILED: expected role address was not allowed")
    if not allowed_email("operator", "example.org"):
        raise SystemExit("self-test FAILED: expected example address was not allowed")
    if allowed_email("person", "private.invalid"):
        raise SystemExit("self-test FAILED: unexpected personal address was allowed")
    if not PHONE.search("call 555-111-2222"):
        raise SystemExit("self-test FAILED: phone literal not detected")
    if PHONE.search("run 28673911406"):
        raise SystemExit("self-test FAILED: GitHub run id was falsely detected as phone")
    if not HOME_PATH.search("/Users/operator/project"):
        raise SystemExit("self-test FAILED: local home path not detected")
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
