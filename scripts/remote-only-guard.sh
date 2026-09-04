#!/usr/bin/env bash
# scripts/remote-only-guard.sh — fail-closed remote-only execution guard.
# Operator ruling 2026-09-01: heavy toolchain execution must be impossible to
# land locally. GF v4 is fail-closed with no local-execution fallback; the
# REAPI action, not the runner, is the unit of compute (R243).
# Usage: bash scripts/remote-only-guard.sh <recipe-name>
set -euo pipefail
recipe="${1:?usage: remote-only-guard.sh <recipe-name>}"

# Operator-ratified attended-local lanes, as "<lane>:<recipe>" pairs.
# greatfallstoolbus.org: ratified_pairs=("preview-tailnet:_house-hydrate")
# gftb-site / great-falls-tool-bus-infra: ratified_pairs=()
ratified_pairs=()

refuse() { echo "${recipe}: REFUSE — $1" >&2; exit 3; }

if [[ "${RUNNER_ENVIRONMENT:-}" == "github-hosted" ]]; then
  refuse "GitHub-hosted runner (RUNNER_ENVIRONMENT=github-hosted); this estate schedules heavy work only on the GF admission shell (tinyland-nix) and the REAPI fabric."
fi
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  exit 0  # sanctioned hosted runner: Actions agent sets this on every job; ARC pods report RUNNER_ENVIRONMENT=self-hosted
fi
lane="${TINYLAND_RATIFIED_LOCAL_LANE:-}"
if [[ -n "$lane" && "${#ratified_pairs[@]}" -gt 0 ]]; then
  for pair in "${ratified_pairs[@]}"; do
    [[ "$pair" == "${lane}:${recipe}" ]] && { echo "[remote-only-guard] ratified lane '${lane}' -> '${recipe}'" >&2; exit 0; }
  done
fi
refuse "heavy execution is remote-only on this estate (GF v4 is fail-closed: no local-execution fallback; the action, not the runner, is the unit of compute — R243). Push the branch and read CI: gh pr checks / gh run view / gh run watch."
