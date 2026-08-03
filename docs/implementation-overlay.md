# Great-Falls-Tool-Bus implementation overlay

This repository is the Great-Falls-Tool-Bus (GFTB) installation overlay for
the shared GloriousFlywheel product. It owns GFTB-specific admission and
installation coordinates; it does not fork runner, cache, or REAPI product
logic from `tinyland-inc/GloriousFlywheel`.

## Authority boundary

This overlay owns:

- the GFTB GitHub App registration coordinates;
- desired non-Default runner-group admission;
- exact private repository identity;
- per-plane backend, namespace, credential, and release coordinates; and
- GFTB edge and DNS apply authority.

GloriousFlywheel owns reusable ARC roots, runner images, shared capability
labels, authenticated cache attachment, REAPI execution, and the generated
front-door contract.

## Three independent facts

GFTB Actions capacity is usable only when all three facts are proved:

1. **Admission:** runner group `great-falls-tool-bus-infra` admits exact private
   repository id `1286829099`.
2. **Registration and capacity:** an org-scoped ARC release for
   `https://github.com/Great-Falls-Tool-Bus` exposes shared label
   `tinyland-nix` with bounded nonzero capacity.
3. **Attachment:** the runner receives the authenticated GF cache/front-door
   profile and produces deposit/withdraw evidence.

A group, a label, a green job, or a live release proves only its own layer.
None is activation evidence by itself.

## Current observed state

The adopted compatibility release `great-falls-tool-bus-nix` is live in shared
namespace `arc-runners`, bound to GitHub's `Default` group, and configured at
`min=0/max=4`. It carries the current token-exchange and GF front-door
environment. Preserve it until an attended migration gives it an explicit
disposition. Its runner payload selects Sting; its request-less listener still
has a legacy Bumble hostname pin. That listener is not job compute, but it is
placement drift the dedicated owner root must not reproduce.

The overlay repository is currently public, and the target group could not be
read with the available token. Therefore this branch stages desired admission
and workflow selectors but is not merge or activation authority. There is no
Default, hosted-runner, or repo-shaped-label fallback.

## Target owner plane

The target uses:

- org-scoped ARC registration with no per-repo registration anchors;
- a selected, private-repository-only owner group;
- shared capability label `tinyland-nix`;
- a dedicated owner namespace, state key, plan identity, release credential,
  saved plan, and `TF_DATA_DIR`; and
- initial owner-release capacity `min=0/max=0`, raised only by a later reviewed
  readiness change.

The frozen primary `arc-runners` root is not owner authority. Do not rebind the
adopted release in place or use its legacy workflow to simulate owner
isolation.

Runner payload placement is compute-only. Bumble provides storage services; it
is not runner compute placement. Target Nix owner planes carry no physical
hostname or storage-node selector, and both payload and listener exclude the
installation's storage-only node label.

## Core release boundary

Source validation pins signed GF tag `v0.3.0`, exact commit
`f26b541d1d7600d56b2e78c87038415fa06b3622`. Every core-consuming workflow
checks out that private source with `GF_CORE_DEPLOY_KEY`, verifies `HEAD`, and
uses the local `#ci` devshell.

That release is validation authority only. It predates the storage-only
placement correction and its owner root cannot project the typed
token-exchange plus `:8980` authenticated-front-door tuple that the live GFTB
release already carries. The unauthenticated `:9092` compatibility cache is
not an acceptable new owner-plane default.

Activation is blocked until GF lands that typed attachment contract and cuts a
new signed release. The overlay must then repin and add dedicated bootstrap and
release roots from that release before any attended plan exists.

## Source checks

From this worktree, with the signed GF release checked out beside it:

```bash
export GF_CORE_PATH=../GloriousFlywheel
export GF_CORE_CI_PATH=path:../GloriousFlywheel#ci
just check
just enrollment-preflight
```

`just runner-group-test` is a backend-disabled mock-provider source test. It
does not contact GitHub. `just enrollment-preflight` is read-only. Missing
visibility, group, credential, registration, or attachment evidence is a
blocker, never permission to improvise a fallback.

## Legacy workflow

`.github/workflows/deploy-arc-runners.yml` retains maintenance behavior for the
adopted primary-root release. It is not the owner-plane activation path and
must not bind the target group or create the future owner release. Any later
retirement or migration of that workflow needs its own reviewed carrier.

The attended activation order, once all missing source exists, is maintained in
[onboarding-runbook.md](onboarding-runbook.md).
