# mailman-listsync — keyholders ⊆ discuss add-only reconciler (TIN-3813 lane)

A suspended, dry-run-default CronJob that enforces one roster invariant going
forward: every member of `keyholders@latoolb.us` is also a member of
`discuss@latoolb.us` (the ratified private/public list pairing, meta
`decisions/0014` ruling 5). Add-only by construction — its HTTP method
allowlist is GET/POST, the list pair is pinned, and it holds no cluster
identity and no engine Secret.

DECLARE-ONLY IN GIT: merging changes nothing. Offline validation is
`just listsync-stack-validate` (wired into `just check-hosted`); live rollout
is the attended `just listsync-stack-server-dry-run` / `just
listsync-stack-apply` recipes plus the three-step activation sequence —
operator-minted `mailman-listsync-rest` Secret, then unsuspend, then dry-run
off, each relaxation recorded as a dated ruling in `operator-activation.yaml`.

The Mailman-core credential-scoping gap (single global REST identity; the
TIN-3813 restricted proxy does not exist yet) is declared in
`cronjob-listsync.yaml` and in `docs/runbooks/list-operations.md` section 8,
which is the operating reference for this stack.
