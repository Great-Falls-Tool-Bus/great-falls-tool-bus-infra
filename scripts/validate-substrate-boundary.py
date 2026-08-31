#!/usr/bin/env python3
"""Substrate-boundary conformance (TIN-2423 / ledger item 30, consumer-side).

Asserts ADR-008 "logical replaceability" as a checked invariant instead of
prose: this repo's CODE surfaces may reach the blahaj substrate ONLY through
named interfaces recorded (with provenance) in
config/substrate-boundary-allowlist.json. Docs (*.md) are exempt — the
invariant is about code reach, not prose mentions.

Flagged reach classes (TIN-2423 item 1):
  repo-ref    a tinyland-inc/blahaj reference (module source, workflow
              dispatch target, checkout) in a code surface
  path-reach  a sibling/home-relative filesystem reach into a blahaj
              checkout (../blahaj, ~/git/blahaj, /git/blahaj)
  state-key   an OpenTofu backend key under the blahaj/ state prefix

Exit 0 = conformant (allowlisted hits are reported, not failed).
Exit 1 = un-allowlisted reach (the boundary bleed class of TIN-2398/2406).
"""
from __future__ import annotations

import copy
import json
import re
import subprocess
import sys
from datetime import date
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SELF = Path(__file__).resolve().relative_to(REPO)
ALLOWLIST = REPO / "config" / "substrate-boundary-allowlist.json"
ALLOWLIST_REL = ALLOWLIST.relative_to(REPO)

# Code surfaces (git-tracked). Markdown is exempt everywhere.
CODE_GLOBS = [
    "tofu/**", ".github/workflows/**", "scripts/**", "k8s/**", "config/**",
    "Justfile", "flake.nix", "MODULE.bazel", "**/*.bzl", "**/BUILD.bazel",
]

PATTERNS = {
    "repo-ref": re.compile(r"tinyland-inc/blahaj"),
    "path-reach": re.compile(r"(\.\./|~/git/|/git/)blahaj\b"),
    "state-key": re.compile(r"key\s*=\s*\"blahaj/"),
}


def should_scan_raw_reach(rel: Path) -> bool:
    """Exclude prose, this validator, and only the exact parsed allowlist."""
    return (
        not rel.as_posix().endswith(".md")
        and rel not in (SELF, ALLOWLIST_REL)
    )


def tracked_code_files() -> list[Path]:
    out = subprocess.run(
        ["git", "ls-files", "--"] + CODE_GLOBS,
        cwd=REPO, capture_output=True, text=True, check=True,
    ).stdout.splitlines()
    return [
        rel
        for rel in (Path(p) for p in sorted(set(out)))
        if should_scan_raw_reach(rel)
    ]


def parse_allowlist(data: object) -> list[dict]:
    """Strictly parse the sole authority for raw-reach exceptions."""
    top_level_keys = {"$comment", "schema_version", "allowed"}
    entry_keys = {"path_prefix", "kinds", "interface", "provenance"}
    provenance_keys = {"decision", "date"}

    if not isinstance(data, dict) or set(data) != top_level_keys:
        raise SystemExit(
            "allowlist must be an object with exactly $comment, schema_version, "
            "and allowed"
        )
    comment = data["$comment"]
    if not isinstance(comment, str) or not comment or comment != comment.strip():
        raise SystemExit("allowlist $comment must be a nonempty trimmed string")
    schema_version = data["schema_version"]
    if (
        not isinstance(schema_version, int)
        or isinstance(schema_version, bool)
        or schema_version != 1
    ):
        raise SystemExit("allowlist schema_version must be the integer 1")
    entries = data["allowed"]
    if not isinstance(entries, list):
        raise SystemExit("allowlist allowed must be a list")

    seen_prefixes: set[str] = set()
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict) or set(entry) != entry_keys:
            raise SystemExit(
                f"allowlist entry {index} must contain exactly {sorted(entry_keys)!r}"
            )

        prefix = entry["path_prefix"]
        if not isinstance(prefix, str) or not prefix:
            raise SystemExit(f"allowlist entry {index} path_prefix must be nonempty")
        normalized = Path(prefix).as_posix()
        if (
            prefix != prefix.strip()
            or any(character.isspace() for character in prefix)
            or "\\" in prefix
            or "\x00" in prefix
            or Path(prefix).is_absolute()
            or normalized != prefix
            or any(part in (".", "..") for part in Path(prefix).parts)
            or prefix == ALLOWLIST_REL.as_posix()
        ):
            raise SystemExit(
                f"allowlist entry {index} path_prefix must be a normalized safe "
                "relative path and may not name the allowlist itself"
            )
        if prefix in seen_prefixes:
            raise SystemExit(f"allowlist path_prefix is duplicated: {prefix}")
        seen_prefixes.add(prefix)

        kinds = entry["kinds"]
        if (
            not isinstance(kinds, list)
            or not kinds
            or not all(isinstance(kind, str) for kind in kinds)
            or len(kinds) != len(set(kinds))
            or any(kind not in PATTERNS for kind in kinds)
        ):
            raise SystemExit(
                f"allowlist entry {index} kinds must be unique known reach classes"
            )

        interface = entry["interface"]
        if (
            not isinstance(interface, str)
            or not interface
            or interface != interface.strip()
        ):
            raise SystemExit(
                f"allowlist entry {index} interface must be a nonempty trimmed string"
            )

        provenance = entry["provenance"]
        if not isinstance(provenance, dict) or set(provenance) != provenance_keys:
            raise SystemExit(
                f"allowlist entry {index} provenance must contain exactly "
                f"{sorted(provenance_keys)!r}"
            )
        decision = provenance["decision"]
        recorded_date = provenance["date"]
        if (
            not isinstance(decision, str)
            or not decision
            or decision != decision.strip()
        ):
            raise SystemExit(
                f"allowlist entry {index} provenance decision must be a nonempty "
                "trimmed string"
            )
        if (
            not isinstance(recorded_date, str)
            or not recorded_date
            or recorded_date != recorded_date.strip()
        ):
            raise SystemExit(
                f"allowlist entry {index} provenance date must be a nonempty "
                "trimmed string"
            )
        try:
            parsed_date = date.fromisoformat(recorded_date)
        except ValueError as exc:
            raise SystemExit(
                f"allowlist entry {index} provenance date must be ISO YYYY-MM-DD"
            ) from exc
        if parsed_date.isoformat() != recorded_date:
            raise SystemExit(
                f"allowlist entry {index} provenance date must be canonical ISO"
            )
    return entries


def load_allowlist() -> list[dict]:
    try:
        data = json.loads(ALLOWLIST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"could not parse strict substrate allowlist: {exc}") from exc
    return parse_allowlist(data)


def matching_allowlist_entry(
    rel: Path, kind: str, allowed: list[dict]
) -> dict | None:
    """Match one reach by exact path or a real descendant path segment."""
    rel_text = rel.as_posix()
    for entry in allowed:
        prefix = entry["path_prefix"]
        path_matches = rel_text == prefix or rel_text.startswith(prefix + "/")
        if path_matches and kind in entry["kinds"]:
            return entry
    return None


def scan_texts(
    texts: dict[Path, str], allowed: list[dict]
) -> tuple[list[tuple], list[tuple]]:
    """Scan supplied tracked-surface text through the production matcher."""
    violations, allowed_hits = [], []
    for rel in sorted(texts, key=lambda path: path.as_posix()):
        for lineno, line in enumerate(texts[rel].splitlines(), 1):
            for kind, rx in PATTERNS.items():
                if not rx.search(line):
                    continue
                entry = matching_allowlist_entry(rel, kind, allowed)
                record = (rel.as_posix(), lineno, kind, line.strip()[:120])
                (allowed_hits if entry else violations).append(record)
    return violations, allowed_hits


def scan(files: list[Path], allowed: list[dict]):
    texts: dict[Path, str] = {}
    for rel in files:
        path = REPO / rel
        try:
            texts[rel] = path.read_text(encoding="utf-8", errors="replace")
        except (OSError, IsADirectoryError):
            continue
    return scan_texts(texts, allowed)


def self_test() -> None:
    cases = {
        "repo-ref": 'uses: tinyland-inc/blahaj/.github/workflows/x.yml@main',
        "repo-ref-dispatch": 'gh api repos/tinyland-inc/blahaj/dispatches -f event_type=x',
        "path-reach": 'source = "../blahaj/tofu/modules/thing"',
        "path-reach-home": 'cd ~/git/blahaj && just apply',
        "state-key": 'key = "blahaj/mail/terraform.tfstate"',
    }
    for name, sample in cases.items():
        if not any(rx.search(sample) for rx in PATTERNS.values()):
            raise SystemExit(f"self-test FAILED: {name!r} not detected")
    clean = 'key = "tinyland-infra/attic/terraform.tfstate"  # fine'
    if any(rx.search(clean) for rx in PATTERNS.values()):
        raise SystemExit("self-test FAILED: false positive on clean line")

    valid_document = {
        "$comment": "self-test",
        "schema_version": 1,
        "allowed": [{
            "path_prefix": "config/arc-storage-source-contract.json",
            "kinds": ["repo-ref"],
            "interface": "signed source provenance",
            "provenance": {"decision": "TIN-4072", "date": "2026-08-30"},
        }],
    }
    parse_allowlist(copy.deepcopy(valid_document))
    allowed = load_allowlist()
    exact = Path("config/arc-storage-source-contract.json")
    source_entries = [
        entry for entry in allowed if entry["path_prefix"] == exact.as_posix()
    ]
    if len(source_entries) != 1 or source_entries[0]["kinds"] != ["repo-ref"]:
        raise SystemExit(
            "self-test FAILED: loaded source contract exception must be exactly "
            "one repo-ref entry"
        )

    suffix_paths = (
        Path("config/arc-storage-source-contract.json.evil"),
        Path("config/arc-storage-source-contract.json.backup"),
        Path("config/arc-storage-source-contract.jsonx"),
    )
    candidate_paths = (ALLOWLIST_REL, *suffix_paths)
    scanned_candidates = tuple(
        path for path in candidate_paths if should_scan_raw_reach(path)
    )
    if scanned_candidates != suffix_paths:
        raise SystemExit(
            "self-test FAILED: raw scan must exclude only the exact allowlist "
            f"and retain suffix siblings; observed {scanned_candidates!r}"
        )

    exact_violations, exact_allowed = scan_texts(
        {
            exact: (
                "repository = tinyland-inc/blahaj\n"
                'source = "../blahaj/tofu/modules/thing"\n'
                'key = "blahaj/test/terraform.tfstate"\n'
            )
        },
        allowed,
    )
    if [record[2] for record in exact_allowed] != ["repo-ref"]:
        raise SystemExit(
            "self-test FAILED: exact source file must exempt repo-ref only"
        )
    if sorted(record[2] for record in exact_violations) != [
        "path-reach",
        "state-key",
    ]:
        raise SystemExit(
            "self-test FAILED: non-repo reaches in the exact source file must "
            "remain violations"
        )

    suffix_violations, suffix_allowed = scan_texts(
        {path: "repository = tinyland-inc/blahaj\n" for path in scanned_candidates},
        allowed,
    )
    if (
        suffix_allowed
        or len(suffix_violations) != len(suffix_paths)
        or {record[0] for record in suffix_violations}
        != {path.as_posix() for path in suffix_paths}
    ):
        raise SystemExit(
            "self-test FAILED: filename-suffix siblings must remain scanned "
            "repo-ref violations"
        )

    malformed_cases: list[tuple[str, object]] = []

    bad = copy.deepcopy(valid_document)
    bad["schema_version"] = 2
    malformed_cases.append(("wrong schema version", bad))

    bad = copy.deepcopy(valid_document)
    bad["schema_version"] = True
    malformed_cases.append(("boolean schema version", bad))

    bad = copy.deepcopy(valid_document)
    del bad["allowed"]
    malformed_cases.append(("missing top-level key", bad))

    bad = copy.deepcopy(valid_document)
    bad["extra"] = True
    malformed_cases.append(("extra top-level key", bad))

    bad = copy.deepcopy(valid_document)
    bad["allowed"] = {}
    malformed_cases.append(("non-list allowed", bad))

    bad = copy.deepcopy(valid_document)
    bad["allowed"][0] = "not-an-entry"
    malformed_cases.append(("non-object entry", bad))

    bad = copy.deepcopy(valid_document)
    del bad["allowed"][0]["interface"]
    malformed_cases.append(("missing entry key", bad))

    bad = copy.deepcopy(valid_document)
    bad["allowed"][0]["extra"] = True
    malformed_cases.append(("extra entry key", bad))

    bad = copy.deepcopy(valid_document)
    bad["allowed"][0]["interface"] = ""
    malformed_cases.append(("empty interface", bad))

    bad = copy.deepcopy(valid_document)
    bad["allowed"][0]["provenance"] = "not-provenance"
    malformed_cases.append(("non-object provenance", bad))

    bad = copy.deepcopy(valid_document)
    del bad["allowed"][0]["provenance"]["decision"]
    malformed_cases.append(("missing provenance key", bad))

    bad = copy.deepcopy(valid_document)
    bad["allowed"][0]["provenance"]["extra"] = True
    malformed_cases.append(("extra provenance key", bad))

    bad = copy.deepcopy(valid_document)
    bad["allowed"][0]["provenance"]["decision"] = ""
    malformed_cases.append(("empty provenance decision", bad))

    bad = copy.deepcopy(valid_document)
    bad["allowed"][0]["provenance"]["date"] = 20260830
    malformed_cases.append(("non-string date", bad))

    bad = copy.deepcopy(valid_document)
    bad["allowed"][0]["provenance"]["date"] = "2026-8-30"
    malformed_cases.append(("noncanonical date", bad))

    bad = copy.deepcopy(valid_document)
    bad["allowed"].append(copy.deepcopy(bad["allowed"][0]))
    malformed_cases.append(("duplicate path", bad))

    bad = copy.deepcopy(valid_document)
    bad["allowed"][0]["kinds"] = ["repo-ref", "repo-ref"]
    malformed_cases.append(("duplicate kind", bad))

    bad = copy.deepcopy(valid_document)
    bad["allowed"][0]["kinds"] = ["unknown"]
    malformed_cases.append(("unknown kind", bad))

    for unsafe_prefix in (
        "",
        "/config/source.json",
        "../config/source.json",
        "config//source.json",
        "config/source.json/",
        "config\\source.json",
        ALLOWLIST_REL.as_posix(),
    ):
        bad = copy.deepcopy(valid_document)
        bad["allowed"][0]["path_prefix"] = unsafe_prefix
        malformed_cases.append((f"unsafe prefix {unsafe_prefix!r}", bad))

    for label, malformed in malformed_cases:
        try:
            parse_allowlist(malformed)
        except SystemExit:
            continue
        raise SystemExit(
            f"self-test FAILED: malformed allowlist mutation accepted: {label}"
        )

    print("substrate-boundary self-test passed")


def main() -> int:
    if "--self-test" in sys.argv:
        self_test()
        return 0
    allowed = load_allowlist()
    violations, allowed_hits = scan(tracked_code_files(), allowed)
    for rel, lineno, kind, frag in allowed_hits:
        print(f"allowed [{kind}] {rel}:{lineno}: {frag}")
    if violations:
        print(f"\nsubstrate-boundary FAILED: {len(violations)} un-allowlisted "
              f"blahaj reach(es) — consume the substrate via a named interface "
              f"or add a provenance-carrying allowlist entry (TIN-2423):",
              file=sys.stderr)
        for rel, lineno, kind, frag in violations:
            print(f"  [{kind}] {rel}:{lineno}: {frag}", file=sys.stderr)
        return 1
    print(f"substrate-boundary validation passed "
          f"({len(allowed_hits)} allowlisted hit(s), 0 violations)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
