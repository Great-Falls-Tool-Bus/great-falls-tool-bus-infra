#!/usr/bin/env bash
set -euo pipefail

# Offline shape guard for the checked-in GFTB Grafana dashboards (TIN-3896).
#
# These dashboards are a declaration, not an apply: nothing here contacts
# Grafana, and importing them is an operator action (see the README beside the
# JSON). This guard asserts the invariants that make the JSON safe to import
# unattended -- so a regression that would import a broken, mis-tagged, or
# wrong-datasource dashboard fails CI before anyone touches the live instance.
#
# Axes:
#   1. every file parses as JSON
#   2. uid is present, non-empty, and equals the filename stem (stable import
#      identity: re-importing updates in place instead of forking a copy)
#   3. title is present and non-empty
#   4. tags contain "gftb" (the estate filter every GFTB dashboard must answer)
#   5. every datasource uid referenced exists in the discovered allowlist below
#   6. no panel references a datasource by name or by a bare template string
#   7. panel ids are unique and every panel carries a title
#   8. every $var used in a query is declared in templating
#
# The datasource allowlist is the set discovered from the live Grafana with
# read-only MCP calls on 2026-08-18. Adding a uid here without confirming it
# exists on the target instance defeats the point of the check.

dir="${1:?usage: validate-grafana-dashboards.sh <dashboard-dir>}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}
assert_eq() { [ "$1" = "$2" ] || fail "$3: got '$1', want '$2'"; }

command -v jq >/dev/null 2>&1 || fail "jq is required"

test -d "${dir}" || fail "missing dashboard directory ${dir}"

# Datasource uids that actually exist on the target Grafana, plus the built-in
# Grafana datasource used by the default annotation query.
ALLOWED_DS='["loki","mimir","PBFA97CFB590B2093","prometheus-mail","pyroscope","tempo","-- Grafana --"]'

# Every dashboard must claim this tag so the estate can filter on it.
REQUIRED_TAG="gftb"

shopt -s nullglob
files=("${dir}"/*.json)
shopt -u nullglob

[ "${#files[@]}" -gt 0 ] || fail "no dashboard JSON found under ${dir}"

checked=0
for f in "${files[@]}"; do
  name="$(basename "${f}")"
  stem="${name%.json}"

  # --- axis 1: parses as JSON ------------------------------------------------
  jq empty "${f}" >/dev/null 2>&1 || fail "${name}: not valid JSON"

  # --- axis 2: uid present, non-empty, equal to the filename stem ------------
  uid="$(jq -r '.uid // ""' "${f}")"
  [ -n "${uid}" ] || fail "${name}: missing .uid"
  assert_eq "${uid}" "${stem}" "${name}: .uid must match the filename stem"

  # --- axis 3: title present and non-empty ----------------------------------
  title="$(jq -r '.title // ""' "${f}")"
  [ -n "${title}" ] || fail "${name}: missing .title"

  # --- axis 4: tags include the required estate tag -------------------------
  if ! jq -e --arg t "${REQUIRED_TAG}" '(.tags // []) | index($t)' "${f}" >/dev/null; then
    got="$(jq -c '.tags // []' "${f}")"
    fail "${name}: .tags must contain \"${REQUIRED_TAG}\"; got ${got}"
  fi

  # --- axis 5: every referenced datasource uid is in the allowlist -----------
  bad_ds="$(jq -r --argjson allowed "${ALLOWED_DS}" '
    [ .. | objects | select(has("datasource")) | .datasource
      | select(type == "object") | .uid // empty ]
    | unique
    | map(select(. as $u | ($allowed | index($u)) | not))
    | join(", ")
  ' "${f}")"
  [ -z "${bad_ds}" ] || fail "${name}: undiscovered datasource uid(s): ${bad_ds}"

  # --- axis 6: no datasource pinned by name or left as a bare template ------
  # A string datasource ("Prometheus", "${DS}") is the legacy/templated form and
  # breaks on import when the target names differ. Require the {type,uid} object.
  str_ds="$(jq -r '
    [ .. | objects | select(has("datasource")) | .datasource
      | select(type == "string") ] | length
  ' "${f}")"
  assert_eq "${str_ds}" "0" "${name}: datasource must be a {type,uid} object, not a string"

  # Every panel that renders data must name its datasource explicitly.
  missing_ds="$(jq -r '
    [ .panels[]? | select(.type != "row") | select(.datasource == null) | .title ] | join(", ")
  ' "${f}")"
  [ -z "${missing_ds}" ] || fail "${name}: panel(s) without a datasource: ${missing_ds}"

  # --- axis 7: unique panel ids, every panel titled -------------------------
  total_ids="$(jq -r '[.panels[]?.id] | length' "${f}")"
  uniq_ids="$(jq -r '[.panels[]?.id] | unique | length' "${f}")"
  assert_eq "${uniq_ids}" "${total_ids}" "${name}: panel ids must be unique"

  untitled="$(jq -r '[.panels[]? | select((.title // "") == "")] | length' "${f}")"
  assert_eq "${untitled}" "0" "${name}: every panel must carry a title"

  # --- axis 8: every $var used in a query is declared in templating ---------
  undeclared="$(jq -r '
    ([ .templating.list[]?.name ] // []) as $declared
    | [ .. | objects | .expr? | strings ]
    | join(" ")
    | [ scan("\\$([A-Za-z_][A-Za-z0-9_]*)") ]
    | flatten
    | unique
    | map(select(. as $v | ($declared | index($v)) | not))
    | join(", ")
  ' "${f}")"
  [ -z "${undeclared}" ] || fail "${name}: query uses undeclared template var(s): ${undeclared}"

  panels="$(jq -r '[.panels[]? | select(.type != "row")] | length' "${f}")"
  queries="$(jq -r '[.. | objects | .expr? | strings] | length' "${f}")"
  echo "  ok  ${name}  uid=${uid}  panels=${panels}  queries=${queries}  title=\"${title}\""
  checked=$((checked + 1))
done

echo "grafana dashboard validation passed: ${checked} dashboard(s) under ${dir} parse, carry a filename-matching uid, a title, the \"${REQUIRED_TAG}\" tag, object-form datasources drawn only from the discovered allowlist, unique titled panels, and no undeclared template vars"
