#!/usr/bin/env bash
set -euo pipefail

# Executable negative controls for scripts/validate-member-db-stack.sh.
# The validator renders local files only; these fixtures never contact a
# cluster, registry, or other external service.
repo_root="$(git rev-parse --show-toplevel)"
source_root="${repo_root}/k8s/member-db"
validator="${repo_root}/scripts/validate-member-db-stack.sh"
test -d "${source_root}" || { echo "missing ${source_root}" >&2; exit 1; }
test -x "${validator}" || { echo "missing executable ${validator}" >&2; exit 1; }

temp_root="$(mktemp -d)"
fixtures="${temp_root}/fixtures"
mkdir -m 700 "${fixtures}"
cleanup() {
  case "${fixtures}" in
    "${temp_root}"/fixtures) rm -rf -- "${fixtures}" ;;
    *) echo "refusing unsafe self-test cleanup target: ${fixtures}" >&2; return 1 ;;
  esac
  rmdir "${temp_root}"
}
trap cleanup EXIT

mutate_once() {
  local path="$1"
  local old="$2"
  local new="$3"
  python3 -I - "${path}" "${old}" "${new}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
old = sys.argv[2]
new = sys.argv[3]
text = path.read_text()
count = text.count(old)
if count != 1:
    raise SystemExit(f"{path}: mutation anchor count {count}, want 1")
path.write_text(text.replace(old, new))
PY
}

expect_failure() {
  local name="$1"
  local relative_path="$2"
  local old="$3"
  local new="$4"
  local diagnostic="$5"
  local fixture="${fixtures}/${name}"
  local log="${fixture}.log"

  mkdir -m 700 "${fixture}"
  cp -R "${source_root}/." "${fixture}/"
  mutate_once "${fixture}/${relative_path}" "${old}" "${new}"

  if bash "${validator}" "${fixture}/members-greatfallstoolbus-org-db-production" >"${log}" 2>&1; then
    echo "negative control ${name} unexpectedly passed" >&2
    exit 1
  fi
  if ! grep -Fq -- "${diagnostic}" "${log}"; then
    echo "negative control ${name} failed without expected diagnostic: ${diagnostic}" >&2
    sed -n '1,120p' "${log}" >&2
    exit 1
  fi
  echo "negative control passed: ${name}"
}

job="members-greatfallstoolbus-org-production/job-migrator.template.yaml"
expect_failure image-tag "${job}" \
  'ghcr.io/great-falls-tool-bus/greatfallstoolbus.org@sha256:10f853938dc6823afe8c9bdc54943587f963d22117aafd17247350b2b5712b35' \
  'ghcr.io/great-falls-tool-bus/greatfallstoolbus.org:sha-af60fcd7539a4beff6f24e1a95eb11160df7c166' \
  'migration Job image must be the exact greatfallstoolbus.org publisher repository pinned by @sha256:<64 lowercase hex>'

expect_failure foreign-image "${job}" \
  'ghcr.io/great-falls-tool-bus/greatfallstoolbus.org@sha256:10f853938dc6823afe8c9bdc54943587f963d22117aafd17247350b2b5712b35' \
  'ghcr.io/not-great-falls-tool-bus/greatfallstoolbus.org@sha256:10f853938dc6823afe8c9bdc54943587f963d22117aafd17247350b2b5712b35' \
  'migration Job image must be the exact greatfallstoolbus.org publisher repository pinned by @sha256:<64 lowercase hex>'

expect_failure wrong-source "${job}" \
  $'  annotations:\n    app.tinyland.dev/source-sha: af60fcd7539a4beff6f24e1a95eb11160df7c166' \
  $'  annotations:\n    app.tinyland.dev/source-sha: 0000000000000000000000000000000000000000' \
  'migration Job source identity'

expect_failure command-override "${job}" \
  '          imagePullPolicy: IfNotPresent' \
  $'          imagePullPolicy: IfNotPresent\n          command: ["migrator"]' \
  'migration Job command (must be absent'

expect_failure wrong-args "${job}" \
  '          args: ["migrator"]' \
  '          args: ["worker"]' \
  'migration Job entrypoint'

expect_failure runtime-dsn "${job}" \
  '                  name: gftb-member-db-migrator-dsn' \
  '                  name: gftb-member-db-runtime' \
  'migration Job secret references (only the narrow migration credential)'

expect_failure invalid-yaml "${job}" \
  'apiVersion: batch/v1' \
  'apiVersion: [' \
  'YAML decode or jq query failed'

echo "member-db validator negative controls passed"
