#!/usr/bin/env bash
set -euo pipefail

# Remote-resource guard (adversarial review, PR #127 comment 5377613179):
# `kubectl kustomize` resolves `resources`/`bases`/`components`/`generators`
# entries that look like a URL by FETCHING them -- no flag required, and no
# distinction between "reviewed tree" and "PR-supplied YAML" once the render
# runs. Proven live: adding one such entry to a scratch copy of the committed
# web-stack kustomization produced a real outbound connection attempt.
#
# This script is silent on success (no stdout) so callers that capture
# `kubectl kustomize` output as a pure render are never contaminated by it --
# it is a standalone script, not a Just recipe dependency, for exactly that
# reason (see the Justfile `web-stack-render` comment). Walks every
# kustomization file under the target directory (not just the top-level one)
# so a future nested layout stays covered.
#
# Tripwire only: the committed web stack tree carries none of these entries
# today, so this never fires against it -- it exists so a future PR that adds
# one fails loud here, before any `kubectl kustomize` call, instead of
# silently reaching the network.

dir="${1:?usage: guard-no-remote-kustomize-resources.sh <kustomization-directory>}"
test -d "${dir}" || { echo "ERROR: not a directory: ${dir}" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "ERROR: yq is required" >&2; exit 1; }

remote_ref() {
  case "$1" in
    http://* | https://* | git::* | git@* | ssh://*) return 0 ;;
    *) return 1 ;;
  esac
}

while IFS= read -r -d '' kfile; do
  for field in resources bases components generators; do
    while IFS= read -r entry; do
      [ -n "${entry}" ] || continue
      if remote_ref "${entry}"; then
        echo "ERROR: ${kfile}: '${field}' entry '${entry}' is a remote resource reference; kubectl kustomize would fetch it over the network -- refusing before render" >&2
        exit 1
      fi
    done < <(yq -r ".${field}[]? // empty" "${kfile}" 2>/dev/null)
  done
done < <(find "${dir}" \( -iname 'kustomization.yaml' -o -iname 'kustomization.yml' \) -print0)
