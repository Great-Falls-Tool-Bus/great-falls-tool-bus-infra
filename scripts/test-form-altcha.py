#!/usr/bin/env python3
"""Offline round-trip + adversarial test for the form-handler's ALTCHA logic.

Loads the stdlib server.py out of the form-handler ConfigMap (the exact bytes
that ship in the pod), then exercises challenge issuance, a brute-force solve,
and verification end to end WITHOUT any network, cluster, or live endpoint. It
never opens a socket and never contacts LMTP; it only imports the module and
calls its pure functions. Run via `just form-altcha-test` or directly:

    python3 scripts/test-form-altcha.py [path/to/server.py]

With no argument it extracts server.py from the ConfigMap with yq. The stdlib
verify mirrors the official altcha-lib byte layout (SHA-256 challenge +
HMAC-SHA256 signature + signed expiry), so a real stock widget solving the same
challenge produces a payload this handler accepts.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CONFIGMAP = REPO / "k8s" / "form" / "latoolb-us-production" / "configmap-form-handler.yaml"

# Deterministic, small maxnumber so the brute-force solve is instant offline.
# The key is an obvious throwaway; it is NOT a secret and NEVER ships anywhere.
os.environ.setdefault("ALTCHA_HMAC_KEY", "offline-test-key-not-a-real-secret")
os.environ.setdefault("ALTCHA_MAX_NUMBER", "5000")
os.environ.setdefault("ALTCHA_EXPIRES_SECONDS", "1800")
os.environ.setdefault("ALTCHA_MIN_SOLVE_SECONDS", "3.0")


def load_server(argv: list[str]):
    if len(argv) > 1:
        server_path = Path(argv[1])
    else:
        if not CONFIGMAP.is_file():
            raise SystemExit("configmap not found: %s" % CONFIGMAP)
        extracted = subprocess.run(
            ["yq", "-r", '.data["server.py"]', str(CONFIGMAP)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        tmp = tempfile.NamedTemporaryFile(
            "w", suffix=".py", prefix="gftb-form-server.", delete=False
        )
        tmp.write(extracted)
        tmp.close()
        server_path = Path(tmp.name)
    # Load by explicit source loader so a path without a .py suffix (e.g. an
    # mktemp temp file from the validate script) still imports.
    loader = importlib.machinery.SourceFileLoader("gftb_form_server", str(server_path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


server = load_server(sys.argv)

PASS = 0
FAIL = 0


def check(name: str, condition: bool, detail: str = "") -> None:
    global PASS, FAIL
    if condition:
        PASS += 1
        print("  PASS  %s" % name)
    else:
        FAIL += 1
        print("  FAIL  %s %s" % (name, detail))


def solve(challenge: dict) -> int:
    """The client's job: brute-force n so SHA-256(salt + n) == challenge."""
    salt = challenge["salt"]
    target = challenge["challenge"]
    for n in range(challenge["maxnumber"] + 1):
        if hashlib.sha256((salt + str(n)).encode("utf-8")).hexdigest() == target:
            return n
    raise RuntimeError("challenge was not solvable within maxnumber")


def payload_b64(challenge: dict, number: int) -> str:
    body = {
        "algorithm": "SHA-256",
        "challenge": challenge["challenge"],
        "number": number,
        "salt": challenge["salt"],
        "signature": challenge["signature"],
    }
    return base64.b64encode(json.dumps(body).encode("utf-8")).decode("ascii")


def forge(expires_offset: int, t_offset: int, number: int = 7) -> dict:
    """A correctly-SIGNED challenge with attacker-chosen timing, to prove the
    time-trap rejects it even though the HMAC signature is valid."""
    import secrets

    now = int(time.time())
    salt = "%s?expires=%d&t=%d" % (secrets.token_hex(12), now + expires_offset, now + t_offset)
    challenge = hashlib.sha256((salt + str(number)).encode("utf-8")).hexdigest()
    signature = hmac.new(
        server.ALTCHA_HMAC_KEY_BYTES, challenge.encode("utf-8"), hashlib.sha256
    ).hexdigest()
    return {
        "algorithm": "SHA-256",
        "challenge": challenge,
        "salt": salt,
        "signature": signature,
        "maxnumber": server.ALTCHA_MAX_NUMBER,
    }


def main() -> int:
    print("ALTCHA challenge/solve/verify offline round-trip")
    print("module: %s" % server.__file__)
    print(
        "config: maxnumber=%d expires=%ds min_solve=%.1fs enabled=%s"
        % (
            server.ALTCHA_MAX_NUMBER,
            server.ALTCHA_EXPIRES_SECONDS,
            server.ALTCHA_MIN_SOLVE_SECONDS,
            server.ALTCHA_ENABLED,
        )
    )
    print()

    # 1. Issuance shape + signature integrity.
    challenge = server.altcha_new_challenge()
    check("issuance has ALTCHA fields", set(challenge) >= {"algorithm", "challenge", "salt", "signature", "maxnumber"})
    check("issuance algorithm is SHA-256", challenge["algorithm"] == "SHA-256")
    expected_sig = hmac.new(
        server.ALTCHA_HMAC_KEY_BYTES, challenge["challenge"].encode("utf-8"), hashlib.sha256
    ).hexdigest()
    check("issuance signature is HMAC(key, challenge)", hmac.compare_digest(expected_sig, challenge["signature"]))

    # 2. Happy round-trip: solve, then verify. The instant solve would trip the
    #    3s time-trap, so drop the floor to 0 for the honest-client path only.
    number = solve(challenge)
    check("brute-force solve found n", isinstance(number, int) and 0 <= number <= challenge["maxnumber"])
    saved_min = server.ALTCHA_MIN_SOLVE_SECONDS
    server.ALTCHA_MIN_SOLVE_SECONDS = 0.0
    ok, reason = server.altcha_verify(payload_b64(challenge, number))
    check("valid solution verifies", ok, "reason=%r" % reason)

    # 3. Replay: the same (valid) payload must not verify twice.
    ok2, reason2 = server.altcha_verify(payload_b64(challenge, number))
    check("replayed solution rejected", (not ok2) and reason2 == "altcha replay", "reason=%r" % reason2)
    server.ALTCHA_MIN_SOLVE_SECONDS = saved_min

    # 4. Wrong number: hash mismatch.
    fresh = server.altcha_new_challenge()
    n2 = solve(fresh)
    server.ALTCHA_MIN_SOLVE_SECONDS = 0.0
    okw, rw = server.altcha_verify(payload_b64(fresh, (n2 + 1) % (fresh["maxnumber"] + 1)))
    check("wrong number rejected", (not okw) and rw == "altcha challenge", "reason=%r" % rw)

    # 5. Tampered signature (forged issuer): recompute passes, HMAC fails.
    fresh2 = server.altcha_new_challenge()
    n3 = solve(fresh2)
    bad = dict(fresh2)
    flipped = ("0" if fresh2["signature"][0] != "0" else "1") + fresh2["signature"][1:]
    bad["signature"] = flipped
    oks, rs = server.altcha_verify(payload_b64(bad, n3))
    check("tampered signature rejected", (not oks) and rs == "altcha signature", "reason=%r" % rs)

    # 6. Wrong algorithm.
    fresh3 = server.altcha_new_challenge()
    n4 = solve(fresh3)
    body = {
        "algorithm": "SHA-512",
        "challenge": fresh3["challenge"],
        "number": n4,
        "salt": fresh3["salt"],
        "signature": fresh3["signature"],
    }
    oka, ra = server.altcha_verify(base64.b64encode(json.dumps(body).encode()).decode())
    check("wrong algorithm rejected", (not oka) and ra == "altcha algorithm", "reason=%r" % ra)
    server.ALTCHA_MIN_SOLVE_SECONDS = saved_min

    # 7. Time-trap: a genuine, freshly-issued challenge solved instantly is too
    #    fast (age < min_solve). Uses the real default floor (3s).
    fast = server.altcha_new_challenge()
    nf = solve(fast)
    okf, rf = server.altcha_verify(payload_b64(fast, nf))
    check("instant solve tripped the time-trap", (not okf) and rf == "altcha too fast", "reason=%r" % rf)

    # 8. Expired: a correctly-signed challenge whose expiry is in the past.
    server.ALTCHA_MIN_SOLVE_SECONDS = 0.0
    expired = forge(expires_offset=-10, t_offset=-60)
    oke, re_ = server.altcha_verify(payload_b64(expired, 7))
    check("expired challenge rejected", (not oke) and re_ == "altcha expired", "reason=%r" % re_)
    server.ALTCHA_MIN_SOLVE_SECONDS = saved_min

    # 9. Missing / garbage payloads.
    okm, rm = server.altcha_verify("")
    check("empty payload rejected", (not okm) and rm == "altcha missing", "reason=%r" % rm)
    okd, rd = server.altcha_verify("not base64 @@@")
    check("garbage payload rejected", (not okd) and rd == "altcha decode", "reason=%r" % rd)

    print()
    print("%d passed, %d failed" % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
