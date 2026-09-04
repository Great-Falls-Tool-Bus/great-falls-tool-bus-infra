#!/usr/bin/env bash
set -euo pipefail

# Attended live smoke for the GFTB contact-intake stack (TIN-2420 Path B).
# The sole supported entrypoint is `just form-stack-live-smoke`; this helper
# repeats its confirmation and CI refusals so direct execution cannot bypass
# the one-real-message consent gate.

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

confirm="${GFTB_FORM_SMOKE_CONFIRM:-}"
[[ "${GITHUB_ACTIONS:-}" != "true" ]] || fail "the live form smoke is attended-operator-only and must never run in CI"
[[ "${confirm}" == "send-keyholders-test-mail" ]] || {
  echo "This smoke sends one real message to keyholders@latoolb.us." >&2
  echo "Run only through: GFTB_FORM_SMOKE_CONFIRM=send-keyholders-test-mail just form-stack-live-smoke" >&2
  exit 2
}

for tool in curl jq python3; do
  command -v "${tool}" >/dev/null 2>&1 || fail "${tool} is required"
done

readonly host="forms.latoolb.us"
readonly origin="https://greatfallstoolbus.org"
readonly endpoint="https://${host}"

curl_response() {
  env -i PATH="${PATH}" curl --disable \
    --silent --show-error \
    --connect-timeout 10 \
    --max-time 30 \
    --max-filesize 1048576 \
    --max-redirs 0 \
    --proto '=https' \
    --write-out $'\n%{http_code}' \
    "$@"
}

response_status() {
  printf '%s' "${1##*$'\n'}"
}

response_body() {
  printf '%s' "${1%$'\n'*}"
}

echo "== GFTB attended form-stack live smoke (${host}) =="
echo "Confirmed side effect: one successful POST will fan out one test message to keyholders@latoolb.us."

# Check the non-API browsing surface before doing anything mail-shaped. A bare
# handler JSON 404 here means the dashboard-owned tunnel route bypasses Anubis.
root_response="$(curl_response --user-agent 'Mozilla/5.0' "${endpoint}/")" \
  || fail "GET / failed"
root_status="$(response_status "${root_response}")"
root_body="$(response_body "${root_response}")"
if [[ "${root_status}" != "200" ]] || ! grep -Eqi 'anubis|challenge' <<<"${root_body}"; then
  printf '%s\n' "${root_body:0:500}"
  fail "GET / returned HTTP ${root_status} without the Anubis challenge; verify the dashboard-owned tunnel route"
fi
echo "  PASS: browsing surface is challenged by Anubis"

# Observe the handler's actual ALTCHA phase rather than assuming that a bare
# contact POST is accepted. With a signing key, solve and submit a fresh proof;
# that is valid in either advisory or enforced mode and does not claim which of
# those two is live. The exact 503 JSON means challenge-disabled grace, where a
# proof cannot be minted and ALTCHA_REQUIRED must be false for the pod to serve.
challenge_response="$(curl_response \
  --header "Origin: ${origin}" \
  "${endpoint}/api/challenge")" || fail "GET /api/challenge failed"
challenge_status="$(response_status "${challenge_response}")"
challenge_body="$(response_body "${challenge_response}")"
altcha_proof=""
altcha_phase=""

case "${challenge_status}" in
  200)
    altcha_proof="$(python3 -I - "${challenge_body}" <<'PY'
import base64
import hashlib
import json
import re
import sys
from urllib.parse import parse_qs

try:
    challenge = json.loads(sys.argv[1])
except (IndexError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid ALTCHA challenge JSON: {error}")

required = ("algorithm", "challenge", "salt", "signature", "maxnumber")
if not isinstance(challenge, dict) or any(key not in challenge for key in required):
    raise SystemExit("ALTCHA challenge is missing required fields")
if challenge["algorithm"] != "SHA-256":
    raise SystemExit("ALTCHA challenge algorithm is not SHA-256")
salt = challenge["salt"]
if not isinstance(salt, str):
    raise SystemExit("ALTCHA salt is not a string")
salt_prefix, separator, salt_query = salt.partition("?")
if separator != "?" or not re.fullmatch(r"[0-9a-f]{24}", salt_prefix):
    raise SystemExit("ALTCHA salt prefix is malformed")
try:
    salt_params = parse_qs(salt_query, strict_parsing=True)
except ValueError as error:
    raise SystemExit(f"ALTCHA salt query is malformed: {error}") from error
if set(salt_params) != {"expires", "t"} or any(
    len(values) != 1 or not re.fullmatch(r"[0-9]+", values[0])
    for values in salt_params.values()
):
    raise SystemExit("ALTCHA salt must carry one integer t and expires value")
issued = int(salt_params["t"][0])
expires = int(salt_params["expires"][0])
if expires <= issued:
    raise SystemExit("ALTCHA salt expiry must follow its issue time")
if not isinstance(challenge["challenge"], str) or not re.fullmatch(r"[0-9a-f]{64}", challenge["challenge"]):
    raise SystemExit("ALTCHA challenge digest is malformed")
if not isinstance(challenge["signature"], str) or not re.fullmatch(r"[0-9a-f]{64}", challenge["signature"]):
    raise SystemExit("ALTCHA signature is malformed")
maximum = challenge["maxnumber"]
if isinstance(maximum, bool) or not isinstance(maximum, int) or not 0 <= maximum <= 1_000_000:
    raise SystemExit("ALTCHA maxnumber is outside the bounded solver range")

number = next(
    (
        candidate
        for candidate in range(maximum + 1)
        if hashlib.sha256(f"{salt}{candidate}".encode()).hexdigest()
        == challenge["challenge"]
    ),
    None,
)
if number is None:
    raise SystemExit("ALTCHA challenge had no solution in its declared range")

proof = {
    "algorithm": challenge["algorithm"],
    "challenge": challenge["challenge"],
    "number": number,
    "salt": salt,
    "signature": challenge["signature"],
}
print(base64.b64encode(json.dumps(proof, separators=(",", ":")).encode()).decode())
PY
    )" || fail "could not solve the live ALTCHA challenge"
    # The checked-in handler rejects implausibly fast solves below three
    # seconds. Wait from receipt so the proof crosses that declared time trap.
    sleep 4
    altcha_phase="challenge-enabled; proofed submission covers advisory or enforced mode without guessing which"
    ;;
  503)
    jq -e '. == {"ok": false, "error": "challenge unavailable"}' \
      <<<"${challenge_body}" >/dev/null \
      || fail "503 from /api/challenge was not the exact challenge-disabled grace response"
    altcha_phase="challenge-disabled grace; bare submission is expected because ALTCHA_REQUIRED cannot be true while this pod serves"
    ;;
  *)
    printf '%s\n' "${challenge_body:0:500}"
    fail "GET /api/challenge returned HTTP ${challenge_status}; expected 200 or the exact grace-mode 503"
    ;;
esac
echo "  PASS: observed ALTCHA phase: ${altcha_phase}"

if [[ -n "${altcha_proof}" ]]; then
  contact_payload="$(jq -cn --arg altcha "${altcha_proof}" '{
    name: "GFTB operator live smoke",
    email: "smoke@example.com",
    message: "Operator-confirmed TIN-2420 live form-stack smoke. No reply is needed.",
    website: "",
    altcha: $altcha
  }')"
else
  contact_payload="$(jq -cn '{
    name: "GFTB operator live smoke",
    email: "smoke@example.com",
    message: "Operator-confirmed TIN-2420 live form-stack smoke. No reply is needed.",
    website: ""
  }')"
fi

# Exactly one mail-shaped request. Do not add curl retries: a lost response must
# not duplicate a delivery whose server-side outcome is unknown.
contact_response="$(curl_response \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "Origin: ${origin}" \
  --data "${contact_payload}" \
  "${endpoint}/api/contact")" || fail "POST /api/contact failed; delivery outcome may be unknown, so do not retry automatically"
contact_status="$(response_status "${contact_response}")"
contact_body="$(response_body "${contact_response}")"
if [[ "${contact_status}" != "200" ]] || ! jq -e '.ok == true' <<<"${contact_body}" >/dev/null; then
  printf '%s\n' "${contact_body:0:500}"
  fail "POST /api/contact did not return HTTP 200 with {\"ok\":true}; delivery outcome may be unknown"
fi

echo "  PASS: one operator-confirmed contact submission was accepted"
echo "Manual receipt required: confirm the single test message reached keyholders@latoolb.us."
echo "== live smoke complete =="
