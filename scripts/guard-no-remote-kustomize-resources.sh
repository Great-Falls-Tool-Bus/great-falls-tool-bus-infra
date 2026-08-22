#!/usr/bin/env bash
set -euo pipefail

# Remote-resource guard, ALLOWLIST design (round 4, adversarial review PR #127
# comments 5380010266 + 5380172269): kustomize resolves reference-carrying
# fields by FETCHING them when the entry is not a real local file -- no flag
# required, and every one of these fetches is a real outbound network call
# driven purely by committed (or PR-controlled) YAML.
#
# The round-3 version of this script was a DENYLIST (reject entries matching
# a handful of URL-scheme prefixes) and adversarial review proved it leaky
# three separate ways against the real binary: (a) scheme-less host shorthand
# (`github.com/org/repo//path?ref=x`, and the same for `gitlab.com`/
# `bitbucket.org`) resolves to a real `git fetch` and matched none of the
# denylist's prefixes; (b) the `transformers`, `configurations`, and `crds`
# fields are not in a denylist's field list at all, and all three load
# through the identical remote-capable loader `resources` uses. A denylist
# has to enumerate every remote form kustomize's loader will ever accept, and
# this round alone found three independent ways off that list.
#
# INVERTED HERE: this is now an ALLOWLIST. An entry is accepted ONLY if it
# resolves, via a symlink-safe `realpath`, to a path that EXISTS and is
# CONTAINED within the kustomization file's own directory. Everything else --
# every URL scheme, every host-shorthand form, every `../` escape, every
# dangling symlink, every path that simply doesn't exist -- is rejected. The
# committed web stack tree carries nothing but plain local filenames in
# `resources:`, so this is closed-by-default and does not need to keep pace
# with kustomize's loader syntax the way a denylist does.
#
# FIELDS COVERED (every reference-carrying field kustomize's loader resolves
# through the same remote-capable path, per kustomize's own kustomization.yaml
# reference and api/types): `resources`, `bases` (deprecated alias),
# `components`, `generators`, `transformers`, `configurations`, `crds`,
# `openapi.path`, `patches[].path`, `patchesJson6902[].path`,
# `configMapGenerator[].files`/`.envs`, `secretGenerator[].files`/`.envs`
# (the `key=path` form is unwrapped before checking). Deliberately NOT
# covered: `patches[].patch` / `patchesJson6902[].patch` / string entries of
# `patchesStrategicMerge` -- these can be either a file path OR a literal
# inline YAML document, and a multi-line inline document is not itself a
# network-capable reference (there is nothing to fetch; it IS the content),
# so subjecting it to a "must resolve as a local path" check would produce
# false rejections with no security benefit. `patches[].patch` /
# `patchesJson6902[].patch` are excluded outright (never path references).
#
# This script is silent on success (no stdout) so callers that capture
# `kubectl kustomize` output as a pure render are never contaminated by it --
# it is a standalone script, not a Just recipe dependency, for exactly that
# reason (see the Justfile `web-stack-render` comment).
#
# Tripwire only: the committed web stack tree carries nothing but plain local
# resources.yaml/service.yaml/networkpolicy.yaml filenames today, so this
# never fires against it -- it exists so a future PR that adds a remote
# reference, in ANY of the fields above, in ANY syntax kustomize accepts,
# fails loud here, before any `kubectl kustomize` call, instead of silently
# reaching the network.

JQ_FILTER='
def pairs(fname; arr): (arr // [])[]? | [fname, (. // "")] ;
(
  pairs("resources"; .resources),
  pairs("bases"; .bases),
  pairs("components"; .components),
  pairs("generators"; .generators),
  pairs("transformers"; .transformers),
  pairs("configurations"; .configurations),
  pairs("crds"; .crds),
  (if ((.openapi.path // "") != "") then ["openapi.path", .openapi.path] else empty end),
  ((.patches // [])[]? | select((.path // "") != "") | ["patches[].path", .path]),
  ((.patchesJson6902 // [])[]? | select((.path // "") != "") | ["patchesJson6902[].path", .path]),
  ((.configMapGenerator // [])[]? | (.files // [])[]? | ["configMapGenerator[].files", .]),
  ((.configMapGenerator // [])[]? | (.envs // [])[]? | ["configMapGenerator[].envs", .]),
  ((.secretGenerator // [])[]? | (.files // [])[]? | ["secretGenerator[].files", .]),
  ((.secretGenerator // [])[]? | (.envs // [])[]? | ["secretGenerator[].envs", .])
) | @tsv
'

# is_safe_local_path <kustomization-dir> <candidate-entry>
# Strips an optional `key=` generator-file prefix, resolves the candidate
# with a symlink-safe realpath, and requires it to both EXIST and be
# CONTAINED within the kustomization directory's own realpath. Exit 0 =
# safe/allowed, exit 1 = rejected (includes: doesn't exist, is a symlink or
# path that escapes the directory, or is any non-local-path form -- a URL, a
# host-shorthand git reference, etc., none of which resolve to a real local
# file).
is_safe_local_path() {
  local kdir="$1" entry="$2"
  python3 -I - "${kdir}" "${entry}" <<'PY'
import os
import sys

kdir, candidate = sys.argv[1], sys.argv[2]

# Unwrap generator `key=path` syntax (configMapGenerator/secretGenerator
# files/envs). Only strip when the left side looks like a bare identifier,
# so a genuine filename that happens to contain "=" isn't mangled.
if "=" in candidate:
    key, _, rest = candidate.partition("=")
    if key and all(c.isalnum() or c in "_.-" for c in key) and rest:
        candidate = rest

try:
    kdir_real = os.path.realpath(kdir)
    candidate_path = candidate if os.path.isabs(candidate) else os.path.join(kdir, candidate)
    candidate_real = os.path.realpath(candidate_path)
except (OSError, ValueError):
    sys.exit(1)

if not os.path.exists(candidate_real):
    sys.exit(1)
if candidate_real != kdir_real and not candidate_real.startswith(kdir_real + os.sep):
    sys.exit(1)
sys.exit(0)
PY
}

# check_kustomization_dir <dir>
# Walks every kustomization.yaml/kustomization.yml under <dir>, extracts
# every reference-carrying field entry, and requires each to pass
# is_safe_local_path relative to THAT FILE's own directory (not <dir> itself
# -- a nested kustomization's references are relative to where it lives).
# Prints one ERROR line and returns 1 on the first violation.
check_kustomization_dir() {
  local root="$1"
  local kfile kdir field value
  while IFS= read -r -d '' kfile; do
    kdir="$(dirname "${kfile}")"
    while IFS=$'\t' read -r field value; do
      [ -n "${field}" ] || continue
      if ! is_safe_local_path "${kdir}" "${value}"; then
        echo "ERROR: ${kfile}: '${field}' entry '${value}' does not resolve to an existing local path under ${kdir} -- refusing before render (kubectl kustomize would otherwise attempt to fetch or read it)" >&2
        return 1
      fi
    done < <(yq -r "${JQ_FILTER}" "${kfile}" 2>/dev/null)
  done < <(find "${root}" \( -iname 'kustomization.yaml' -o -iname 'kustomization.yml' \) -print0)
  return 0
}

self_test() {
  local failures=0
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN

  run_case() {
    local name="$1" dir="$2" expect="$3"
    local got
    if check_kustomization_dir "${dir}" >/tmp/guard-selftest-out 2>&1; then
      got=0
    else
      got=1
    fi
    if [ "${got}" != "${expect}" ]; then
      echo "SELF-TEST FAILED: ${name}: expected exit ${expect}, got ${got}" >&2
      cat /tmp/guard-selftest-out >&2
      failures=$((failures + 1))
    else
      echo "self-test ok: ${name} (exit ${got} as expected)"
    fi
    rm -f /tmp/guard-selftest-out
  }

  # RED 1: scheme-less host shorthand on `resources` -- the round-3 bypass.
  mkdir -p "${tmp}/red-resources-shorthand"
  cat > "${tmp}/red-resources-shorthand/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - github.com/attacker-controlled/evil//manifests?ref=main
YAML
  run_case "resources: github.com/... host shorthand" "${tmp}/red-resources-shorthand" 1

  mkdir -p "${tmp}/red-resources-shorthand-gitlab"
  cat > "${tmp}/red-resources-shorthand-gitlab/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - gitlab.com/attacker-controlled/evil
YAML
  run_case "resources: gitlab.com/... host shorthand" "${tmp}/red-resources-shorthand-gitlab" 1

  # RED 2: `transformers` field -- absent from the round-3 denylist entirely.
  mkdir -p "${tmp}/red-transformers"
  cat > "${tmp}/red-transformers/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
transformers:
  - https://evil.example/t.yaml
YAML
  echo "kind: Deployment" > "${tmp}/red-transformers/deployment.yaml"
  run_case "transformers: https:// entry" "${tmp}/red-transformers" 1

  # RED 3: `configurations` field -- also absent from the round-3 denylist.
  mkdir -p "${tmp}/red-configurations"
  cat > "${tmp}/red-configurations/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
configurations:
  - https://evil.example/c.yaml
YAML
  echo "kind: Deployment" > "${tmp}/red-configurations/deployment.yaml"
  run_case "configurations: https:// entry" "${tmp}/red-configurations" 1

  # RED 4: `crds` field -- also absent from the round-3 denylist.
  mkdir -p "${tmp}/red-crds"
  cat > "${tmp}/red-crds/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
crds:
  - https://evil.example/crd.yaml
YAML
  echo "kind: Deployment" > "${tmp}/red-crds/deployment.yaml"
  run_case "crds: https:// entry" "${tmp}/red-crds" 1

  # RED 5: path-traversal escape -- proves containment, not just existence.
  mkdir -p "${tmp}/red-escape/inner"
  echo "outside" > "${tmp}/red-escape/outside.yaml"
  cat > "${tmp}/red-escape/inner/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../outside.yaml
YAML
  run_case "resources: ../ escape to a real file outside the dir" "${tmp}/red-escape" 1

  # GREEN: plain local filenames, exactly the committed tree's shape.
  mkdir -p "${tmp}/green-local"
  cat > "${tmp}/green-local/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
components:
  - subdir
YAML
  echo "kind: Deployment" > "${tmp}/green-local/deployment.yaml"
  echo "kind: Service" > "${tmp}/green-local/service.yaml"
  mkdir -p "${tmp}/green-local/subdir"
  run_case "resources+components: plain local entries" "${tmp}/green-local" 0

  # GREEN: the real committed tree.
  run_case "the real committed web stack tree" "k8s/web/greatfallstoolbus-org-production" 0

  if [ "${failures}" -eq 0 ]; then
    echo "guard-no-remote-kustomize-resources self-test passed (8 cases)"
    return 0
  fi
  echo "guard-no-remote-kustomize-resources self-test FAILED (${failures} case(s))" >&2
  return 1
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi

dir="${1:?usage: guard-no-remote-kustomize-resources.sh <kustomization-directory> | --self-test}"
test -d "${dir}" || { echo "ERROR: not a directory: ${dir}" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "ERROR: yq is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 1; }

check_kustomization_dir "${dir}"
