#!/usr/bin/env bash
set -euo pipefail

# Live smoke test for the GFTB contact-intake stack (TIN-2420 Path B).
# Contacts the real public edge; run it manually, post-deploy, from an
# operator shell. Never run in CI (no cluster/network reach there) and never
# wired to flip ALTCHA_REQUIRED -- that flag flip is TIN-2583's own gated
# decision and this script does not touch it.
#
# Promotes the two inline curl checks that lived only as copy/paste in
# docs/runbooks/form-intake.md "Through Anubis" section into one reusable,
# git-tracked script so drift between the documented expectation and live
# behavior (observed 2026-08-17: GET / returned the handler's bare JSON 404
# instead of the Anubis PoW interstitial -- the ALLOW/CHALLENGE split not
# actually enforced at the edge) is a scripted, rerunnable check rather than
# a one-off manual paste.
#
# Root-cause note (2026-08-17 finding, unresolved by this script): the
# Cloudflare Tunnel *route* that maps forms.latoolb.us to the in-cluster
# anubis Service is dashboard/token-managed and is NOT represented in this
# repo (see tofu/stacks/edge/main.tf's alias_forms comment). If check 2
# below fails, the tunnel route itself is the first thing to check -- it may
# be pointing at form-handler's Service directly instead of anubis's,
# bypassing the PoW gate entirely. That is an operator dashboard fix, not a
# code change; nothing in this repo can apply it.

host="${GFTB_FORMS_HOST:-forms.latoolb.us}"
origin="${GFTB_FORMS_ORIGIN:-https://greatfallstoolbus.org}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo "== GFTB form-stack live smoke (${host}) =="

# --- Check 1: the ALLOWed API route reaches the handler ----------------------
# The site's cross-origin fetch() POST cannot solve a browser PoW, so Anubis
# must ALLOW this path outright (see form-intake.md "Bot policy"). A bare curl
# without a browser UA proves the ALLOW rule, not just that the handler works.
resp="$(curl -sS -X POST "https://${host}/api/contact" \
  -H 'Content-Type: application/json' -H "Origin: ${origin}" \
  -d '{"name":"Smoke Test","email":"smoke@example.com","message":"live smoke — ignore","website":""}')"
echo "check 1 (POST /api/contact): ${resp}"
echo "${resp}" | grep -q '"ok"[[:space:]]*:[[:space:]]*true' \
  || fail "POST /api/contact did not return {\"ok\": true} -- got: ${resp}"
echo "  PASS: /api/contact ALLOWed and accepted (confirm keyholders@latoolb.us received it manually)"

# --- Check 2: the browsing surface is still CHALLENGEd by Anubis ------------
# A browser-UA GET to root must get the Anubis PoW interstitial HTML, NOT the
# handler's bare JSON 404 -- the latter means traffic is bypassing Anubis
# entirely (see the tunnel-route root-cause note above).
root_body="$(curl -sS -A 'Mozilla/5.0' "https://${host}/")"
if echo "${root_body}" | grep -qi 'anubis\|challenge'; then
  echo "  PASS: browsing surface challenged (Anubis PoW gate is in front of the handler)"
else
  echo "${root_body}" | head -c 500
  echo
  fail "GET / did not return the Anubis challenge -- Anubis is likely being bypassed at the tunnel route (dashboard-managed, not in this repo; see script header)"
fi

echo "== all live smoke checks passed =="
