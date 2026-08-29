#!/usr/bin/env bash
# shellcheck disable=SC2094
# SC2094 is a false positive throughout: `$filelist` is always fully written
# by `find ... > "$filelist"` and closed before the later `done < "$filelist"`
# / `rm -f "$filelist"` read it -- sequential, not concurrent, in the same
# pipeline.
#
# KUBECTL_EXTERNAL_DIFF comparator for `kubectl diff -k` on the web stack
# ONLY (wired in by Justfile `web-stack-drift-check`; the true-zero-diff
# stacks -- mail/list/form/archive/listsync -- do not set
# KUBECTL_EXTERNAL_DIFF and are untouched by this script).
#
# WHY THIS EXISTS (adversarial review B2, 2026-08-21): `web-release-render`
# (Justfile) unconditionally stamps
# `app.tinyland.dev/source-sha: <the promoted commit sha>` onto the live
# Deployment's pod-template annotations at every release ceremony. The
# checked-in base (k8s/web/greatfallstoolbus-org-production/deployment.yaml)
# deliberately never carries a static value for that key -- the value
# changes on every release, so no committed value could ever be "correct".
# A raw `kubectl diff -k` therefore reports that one annotation as drift on
# EVERY run, forever, which would make `web-stack-drift-check`'s
# fail_on_drift gate permanently red regardless of whether anything is
# actually wrong -- exactly as useless as the report-only gate it replaces.
#
# CALLING CONVENTION (round 2 correction, B2-R2): `kubectl diff` invokes
# `$KUBECTL_EXTERNAL_DIFF LOCAL LIVE` with LOCAL and LIVE as TWO DIRECTORIES
# (one file per rendered object), never two files -- that is why kubectl's
# own default differ is `diff -u -N`, which compares directories natively.
# An earlier version of this script ran a line-oriented `grep` directly on
# the two arguments; against a directory `grep` prints "Is a directory" to
# stderr and nothing to stdout, both sides silently collapsed to empty
# streams, and `diff` reported zero-diff for EVERY input, including a
# replicas 2->50 change and a swapped image -- a false green, strictly worse
# than the report-only gate this PR replaces. This version walks both
# directories and normalizes file-by-file; it MUST be exercised with two
# directories in any test, never two bare files, or a regression here reads
# as passing again.
#
# NORMALIZATION IS YAML-AWARE, NOT A TEXT/SUBSTRING FILTER (round 2, E4): a
# line-grep on the literal string "app.tinyland.dev/source-sha" would also
# drop any OTHER line that happens to contain that text anywhere (comments,
# other keys with a matching substring) -- an unanchored filter. This
# version parses each file as YAML/JSON (via `yq`, which shells out to
# `jq`) and deletes the EXACT key `app.tinyland.dev/source-sha` from every
# object in the document, wherever it appears, using `has()`/`del()` -- an
# object-key match, never a substring match. When that deletion leaves an
# `annotations` map empty, the now-empty `annotations` key is deleted too,
# so a side that started with an `annotations: {app.tinyland.dev/source-sha:
# ...}` map (nothing else) normalizes to having NO `annotations` key at all
# -- the same shape as a side that never had an `annotations` key to begin
# with (round 2, B2-R2b: the committed base's actual pod-template metadata
# carries only `labels`, no `annotations` block, so this asymmetry is the
# real case at rest, not a hypothetical).
#
# FAILS CLOSED (round 2, E5): missing/unreadable input directories, a
# missing `yq`, or any parse/normalize failure exit >1 (kubectl treats an
# external-diff exit code >1 as a differ ERROR, distinct from "diff found");
# nothing here can silently degrade to exit 0 on an I/O or tool failure.
#
# NOT HANDLED HERE, AND NOT HANDLEABLE HERE: `kubectl diff -k` compares the
# rendered LOCAL manifest set against LIVE and has no prune awareness -- it
# is blind to any object that exists ONLY on the cluster. The web-release-*
# ceremony also synthesizes a `default-deny-egress` NetworkPolicy at render
# time that the checked-in base does not declare; that object will NEVER
# surface as a diff via this gate, for any input, by construction of
# `kubectl diff -k` itself. Do not read a clean run of this gate as proof
# that NetworkPolicy is absent or correct -- it is simply invisible to this
# specific check. See k8s/web/greatfallstoolbus-org-production/
# networkpolicy.yaml and k8s/web/README.md for that residual.
#
# kubectl invokes this as `$KUBECTL_EXTERNAL_DIFF LOCAL LIVE` and expects
# ordinary diff(1) exit codes: 0 = no diff, 1 = diff, >1 = error.
set -euo pipefail

fail() {
  echo "web-stack-diff.sh: $*" >&2
  exit 2
}

if [ "$#" -ne 2 ]; then
  fail "usage: web-stack-diff.sh LOCAL_DIR LIVE_DIR (invoked by kubectl diff -k via KUBECTL_EXTERNAL_DIFF; both arguments must be directories)"
fi

local_dir="$1"
live_dir="$2"

for d in "$local_dir" "$live_dir"; do
  [ -d "$d" ] || fail "not a directory: $d"
  [ -r "$d" ] || fail "not readable: $d"
done

command -v yq >/dev/null 2>&1 || fail "yq is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"

# NORMALIZE_FILTER deletes exactly the app.tinyland.dev/source-sha key from
# every object in the document (anchored key match via has()/del(), never a
# substring match), then deletes any `annotations` map that is left empty by
# that removal, so a source-sha-only annotations block and a wholly-absent
# annotations block normalize to the identical (absent) shape.
NORMALIZE_FILTER='
  walk(
    if type == "object" then
      (if has("app.tinyland.dev/source-sha") then del(."app.tinyland.dev/source-sha") else . end)
      | (if (has("annotations") and (.annotations | type) == "object" and (.annotations | length) == 0)
         then del(.annotations)
         else . end)
    else . end
  )
'

work="$(mktemp -d 2>/dev/null)" || fail "mktemp -d failed"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/local" "$work/live"

# Mirror + normalize one source directory tree into a destination directory
# tree, file by file. Fails closed (exit 3) on any listing or normalization
# error, and cross-checks the normalized file count against the source
# listing so a partial/interrupted walk cannot silently read as zero-diff.
normalize_tree() {
  src="$1"
  dst="$2"
  filelist="$(mktemp 2>/dev/null)" || fail "mktemp failed"
  if ! find "$src" -type f -print0 > "$filelist" 2>/dev/null; then
    rm -f "$filelist"
    echo "web-stack-diff.sh: failed to list files under $src" >&2
    exit 3
  fi
  count=0
  while IFS= read -r -d '' f; do
    count=$((count + 1))
    rel="${f#"$src"/}"
    mkdir -p "$(dirname "$dst/$rel")"
    # `yq -y FILTER file` is the python-yq (kislyuk) calling convention. The
    # `yq` that actually resolves on PATH here is mikefarah's yq-go (pinned by
    # GloriousFlywheel core's `ci` devshell, which is what `nix develop
    # "${GF_CORE_CI_PATH}"` puts in scope in CI -- this repo's OWN flake.nix
    # separately pins `pkgs.yq` (python-yq), but that shell is never entered
    # for this job, so it was never what ran here). yq-go has no `-y` flag and
    # no bare-filter-then-file positional form, so this always failed in CI
    # (2026-08-29 sweep g1: every k8s-stack-drift run since PR #126 introduced
    # this script errors here, before ever reaching the actual diff -- a
    # tooling defect, not evidence of real web-stack drift one way or the
    # other). Fix: use yq-go only for YAML<->JSON conversion, and run
    # NORMALIZE_FILTER (unchanged, it's plain jq syntax -- walk/has/del are
    # all real jq builtins) through actual `jq`, which is present in the same
    # GF-core ci closure.
    if ! yq eval -o=json '.' "$f" 2>"$work/yq.err" \
        | jq "${NORMALIZE_FILTER}" 2>>"$work/yq.err" \
        | yq eval -P '.' - > "$dst/$rel" 2>>"$work/yq.err"; then
      echo "web-stack-diff.sh: failed to normalize $f as YAML:" >&2
      cat "$work/yq.err" >&2 2>/dev/null || true
      rm -f "$filelist"
      exit 3
    fi
  done < "$filelist"
  rm -f "$filelist"
  dst_count="$(find "$dst" -type f | wc -l | tr -d '[:space:]')"
  if [ "$dst_count" != "$count" ]; then
    echo "web-stack-diff.sh: normalized ${dst_count:-0} files under $dst, expected $count from $src" >&2
    exit 3
  fi
}

normalize_tree "$local_dir" "$work/local"
normalize_tree "$live_dir" "$work/live"

diff -r -u -N "$work/local" "$work/live"
