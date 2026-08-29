# GFTB platform mail transport (TIN-4062 m1 — names/declarations only)

DECLARE-ONLY. Nothing here is applied and nothing here can be: the target
namespace, `members-greatfallstoolbus-org-production`, is created by infra
PR #121 (`feat/tin-3815-staging-platform-serving`, TIN-3815/TIN-3817), which
is unmerged as of 2026-08-29. Delivery stays OFF regardless of merge order —
see `../../docs/runbooks/platform-mail-transport.md` for the full chain and
the spec §7 policy fence.

## Files

| File | Role |
| --- | --- |
| `secrets.contract.yaml` | Names-only contract for `GFTB_MAIL_SMTP_URL`, `GFTB_MAIL_FROM_ADDRESS`, and the underlying SASL submission identity the DSN embeds. No values, ever. |
| `networkpolicy.yaml` | One additive egress `NetworkPolicy` (`allow-egress-mail-relay`) admitting the platform worker pod to the existing substrate postfix relay on `:587`. |

**Apply order matters:** `networkpolicy.yaml` must apply *after* infra PR
#121's stack (`feat/tin-3815-staging-platform-serving`), never before or
standalone. In a namespace that does not yet have #121's
`default-deny-egress` in place, this object alone would actively *restrict*
the worker to relay:587 and cut its database egress — the safe-direction
foot-gun, but still a foot-gun. See
`../../docs/runbooks/platform-mail-transport.md` step 5, which already
orders #121's stack first.

## Why a separate directory instead of `k8s/platform/`

#121 already declares `k8s/platform/secrets.contract.yaml` and
`k8s/platform/members-greatfallstoolbus-org-production/networkpolicy.yaml`.
This repo is main-based (per this build's instructions) and #121 is still an
open PR, so writing directly into those paths would either duplicate #121's
unmerged content or silently depend on a branch that might still change.
Staying in this sibling directory keeps both PRs mergeable independently.

**Follow-up once #121 merges:** fold `secrets.contract.yaml`'s `spec.secrets`
entry (`gftb-platform-mail-smtp`) into `k8s/platform/secrets.contract.yaml`'s
own `spec.secrets` list, fold its `spec.related` entries (the MailAccount
identity and the non-Secret From-address name — see below) into whatever
sibling list #121's contract adopts for names that are not k8s Secrets, and
fold `networkpolicy.yaml`'s one object into
`k8s/platform/members-greatfallstoolbus-org-production/networkpolicy.yaml`
alongside its `default-deny-egress` / `allow-egress-dns` /
`allow-egress-member-db` family, then delete this directory. All three
entries already match that target file's label idiom
(`app.kubernetes.io/part-of: gftb-platform`, `component: worker`); the
`spec.secrets` entry matches its `SecretContract` schema exactly (a real
`type:`/`keys:` pair), so only that one row is a pure cut-and-paste — the
two `spec.related` rows carry no k8s Secret shape by design (see
`secrets.contract.yaml`'s header) and need a matching sibling list on the
#121 side before they fold in verbatim.

## Validation

No validator in this repo's `just check-hosted` covers this path yet (each
stack — mail, list, form, archive, web — has its own `validate-*-stack.sh`;
`k8s/platform/**` will get one when #121 lands). Locally checked instead:
YAML parses (`yq .`), the `NetworkPolicy` passes a client-side dry-run via
the stack validator idiom (no cluster mutation, nothing applied), and
`gitleaks dir` finds nothing. Wiring this path into
`scripts/validate-platform-stack.sh` is part of the fold-in follow-up
above, not this PR.
