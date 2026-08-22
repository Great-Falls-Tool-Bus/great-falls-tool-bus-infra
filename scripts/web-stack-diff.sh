#!/usr/bin/env bash
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
# fail_on_drift=true gate permanently red regardless of whether anything is
# actually wrong -- exactly as useless as the report-only gate it replaces.
#
# This wrapper strips ONLY that one known-synthesized annotation line from
# both sides before diffing, so the gate is green at rest and still red on
# any real divergence (image digest, replicas, securityContext, container
# shape, Service, or any NetworkPolicy that is present in BOTH the rendered
# manifest set and live state). It does not strip anything else.
#
# NOT HANDLED HERE, AND NOT HANDLEABLE HERE: `kubectl diff -k` compares the
# rendered LOCAL manifest set against LIVE state and has no prune awareness
# -- it is blind to any object that exists ONLY on the cluster. The
# web-release-* ceremony also synthesizes a `default-deny-egress`
# NetworkPolicy at render time that the checked-in base does not declare;
# that object will NEVER surface as a diff via this gate, for any input, by
# construction of `kubectl diff -k` itself (there is nothing on the LOCAL
# side to diff it against). Do not read a clean run of this gate as proof
# that NetworkPolicy is absent or correct -- it is simply invisible to this
# specific check. See k8s/web/greatfallstoolbus-org-production/
# networkpolicy.yaml and k8s/web/README.md for that residual.
#
# kubectl invokes this as `$KUBECTL_EXTERNAL_DIFF LOCAL LIVE` and expects
# ordinary diff(1) exit codes: 0 = no diff, 1 = diff, >1 = error.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: web-stack-diff.sh LOCAL LIVE (invoked by kubectl diff -k via KUBECTL_EXTERNAL_DIFF)" >&2
  exit 2
fi

strip_known_synthesized_fields() {
  # Only ever drops the one ceremony-synthesized annotation line; every
  # other byte of the input passes through unchanged.
  grep -v 'app\.tinyland\.dev/source-sha:' "$1"
}

diff -u -N <(strip_known_synthesized_fields "$1") <(strip_known_synthesized_fields "$2")
