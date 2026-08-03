# GFTB Flywheel onboarding

This runbook records the activation gates for the GFTB implementation overlay.
It does not authorize a live change. TIN-2299 is the carrier for the current
hold and evidence.

## Desired contract

- Overlay: `Great-Falls-Tool-Bus/great-falls-tool-bus-infra`, repository id
  `1286829099`, private before admission.
- Runner group: `great-falls-tool-bus-infra`, selected visibility, public
  repositories refused, exactly the overlay repository admitted.
- ARC registration: organization-scoped
  `https://github.com/Great-Falls-Tool-Bus`.
- Capability: shared `tinyland-nix`; no GFTB-shaped label.
- Owner release: dedicated namespace and state, initially `min=0/max=0`.
- Attachment: token exchange plus token-enforced GF cache front door `:8980`.

## Current hold

Do not merge the staged group-plus-label selectors or run an activation while
any item below remains unresolved:

1. The overlay repository is still public.
2. Existing target-group state has not been read with an administrator token.
3. The signed `v0.3.0` GF owner root lacks the typed authenticated-front-door
   projection and predates the storage-only placement correction.
4. No GFTB owner-plane bootstrap/release root, state, identity, credential, or
   saved-plan workflow exists in this overlay.
5. The live compatibility release remains in the frozen primary root and needs
   an explicit migration disposition.

No Default group, hosted runner, legacy `:9092` product default, repo-specific
label, or in-place primary-root rebind is an acceptable workaround.

## Read-only preparation

Use the signed GF checkout next to this overlay:

```bash
export GF_CORE_PATH=../GloriousFlywheel
export GF_CORE_CI_PATH=path:../GloriousFlywheel#ci
just check
just enrollment-preflight
just runner-group-test
```

`runner-group-test` uses a mock provider with the backend disabled. It proves
only desired admission source. It does not prove group existence, repository
visibility, ARC registration, capacity, or cache attachment.

## Required GF release

Before overlay activation, GF must publish a signed release whose dedicated
owner root:

- accepts a typed attached-profile input;
- projects the token-exchange and token-enforced `:8980` cache front door;
- rejects incomplete or split cache/executor authority;
- rejects storage-node and physical-host placement for Nix runners; and
- keeps credentials outside OpenTofu state.

The overlay then repins every core consumer to that exact signed commit and
adds one-plane bootstrap/release source with separate backend keys,
`TF_DATA_DIR` values, identities, credentials, and protected environments.

## Attended activation sequence

Once the missing source is merged and a fresh operator ruling names the exact
artifacts:

1. Prove the repository is private and census the target group. Adopt an
   existing unmanaged group explicitly; never create a duplicate.
2. Review the runner-group plan independently. It may change only exact GFTB
   admission.
3. Prove the target owner namespace, release, state key, and registration are
   absent. Existing state stops the create path.
4. Produce and accept a create-only owner bootstrap plan under attended
   administrator authority; install its plan credential outside OpenTofu.
5. Produce and accept the dedicated owner-release plan at zero capacity under
   separate attended authority. Bind the saved-plan digest and apply the exact
   file through the protected mutation workflow.
6. Produce zero-diff plans for admission, bootstrap, and release roots.
7. Merge the group-plus-label selectors and prove a natural default-branch job
   reports the exact owner group and ARC scale-set identity.
8. Prove authenticated cache attachment and a clean second-run withdrawal.
9. Raise capacity in a separate reviewed readiness change.
10. Retire or preserve the compatibility release only through its own reviewed
    migration artifact and rollback plan.

## Evidence boundary

Green CI is not cache or remote-execution evidence. Shared-cache-backed means
actions still execute on the ARC runner. Full remote offload requires the
executor-backed profile and TIN-2730's separate-worker, forced-remote,
no-fallback proof.

Public GFTB application repositories require a separately reviewed public
admission policy. Until one exists they remain unadmitted; they do not fall
back to Default or GitHub-hosted capacity.
