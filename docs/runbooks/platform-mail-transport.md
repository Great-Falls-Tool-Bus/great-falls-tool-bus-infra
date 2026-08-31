# GFTB platform mail transport — activation runbook

Tracking: TIN-4062. Names/declarations only — this runbook does not send
mail, and nothing in `k8s/platform-mail-transport/` (this repo) or the
`feat/member-v0-mail-leg` mail leg (app repo PR #208) turns delivery on by
itself. `GFTB_MAIL_DELIVERY` defaults OFF (`DisabledDelivery`,
`src/lib/server/mail/delivery.ts`) in every environment this repo's or the
app repo's own tests and CI ever run. Agents never flip this chain; every
step below is operator-attended.

## What this activates

The app repo's outbox worker (`src/lib/server/worker.ts`) dispatches three
mail handlers — application receipt, application decision, application
withdrawn-ack (`src/lib/server/outbox/handlers/*-email.ts`, PR #208) — through
`src/lib/server/mail/delivery.ts`. Today every send resolves to
`DisabledDelivery` and is journaled as a recorded no-op
(`src/lib/server/mail/journal.ts`). This runbook is the chain that, step by
step, makes a real `SmtpDelivery` reachable — and stops it dead the moment
any one link is missing.

## Policy fence: spec §7 automation go-live gate

`spec/launch-member-v0-system-2026-08-16.md` §7 "Automation go-live gate"
(quoted in full — this is the fence, not a summary):

> Automated projection is disabled until all are true:
>
> - stale `initial-password-*` Secrets are removed and custody is audited;
> - initial-password expiry is enforced, not merely annotated;
> - declared `MailAlias` resources match live state;
> - the namespace-local account projection reaches the central
>   Dovecot/Postfix authority without a manual hidden merge;
> - the `latoolb.us` capacity rule is enforced or raised deliberately;
> - an allowlisted, idempotent desired-state interface exists with observed-
>   state readback;
> - external-email recovery, disable, retry, dead-letter, and offboarding
>   pass; and
> - the application receives no cluster-admin or broad Mailman credential.
>
> Before that gate, mail stays unprovisioned as a delayed entitlement, not an
> optional one (decision 0024, 2026-08-31, §1.6: "a delayed mailbox is an
> unmet projection, not an optional benefit"). Operators must not make it look
> automated by performing undocumented manual steps.

The quoted block above tracks the amended spec §7 text. Decision 0024
(2026-08-31) also supplies the carrier values behind the `latoolb.us` capacity
row: account ceiling 64, alert at 48, from the TIN-3813 acceptance gate
(Amendment 1). Nothing in that decision opens this gate or authorizes a send:
it rules the member entitlement and its periods, not this automation's
readiness.

Per the estate gap matrix (2026-08-23), all eight rows are open as of
2026-08-29. **This gate governs the automated *account/mailbox projection*
system (`MailAccount`/`MailAlias` reconciliation) — a different mechanism
from the mail leg's transactional application-notification sends this
runbook activates.** They are not the same gate, but decisions/0019 P5
("everything mailbox-shaped stays a recorded no-op until the §7 gate
passes") is written broadly enough to cover both in spirit, and this
runbook treats §7 as the load-bearing policy fence for BOTH: nothing here
authorizes an agent-initiated send, and no step below claims §7 has passed.
Flipping `GFTB_MAIL_DELIVERY=enabled` (step 6) is a human decision made
after reading this section, not a mechanical consequence of the earlier
steps completing.

## Activation chain (operator-attended, in order)

Each step names the artifact it depends on. Skipping ahead fails closed: the
app's own config guard (`src/lib/server/mail/config.ts` `readMailConfig`)
throws `MailConfigError` rather than degrading if `GFTB_MAIL_DELIVERY=enabled`
is set with either name below it missing, and `resolveDelivery` refuses to
construct a transport at all for a template whose `approved` flag is not
`true` (`src/lib/server/mail/templates.ts`), independent of the DSN.

1. **Merge #208** (`feat/member-v0-mail-leg`, app repo). Ships the handlers,
   the config/delivery/journal code, and the `approved: false` template
   placeholders. Nothing downstream is possible before this lands — the env
   names this runbook provisions do not exist in the running app image
   otherwise.

2. **Approve template copy.** Every shipped template
   (`application.receipt_email`, `application.decision_email`,
   `application.withdrawn_ack`) carries `approved: false` and a `TODO_MARKER`
   subject/body — "operator-approved wording is not yet ratified" (templates
   header, citing this same spec §7). Flipping one template's `approved` to
   `true` with ratified wording is an ordinary code change (no schema, no
   migration) but is also the *only* door `resolveDelivery` opens toward
   `SmtpDelivery`, and it is the operator's alone. Do this per-template, not
   as one blanket flip — a template can go live independently of the others.

3. **Mint the SMTP Secret.** Two names must both resolve before this step
   completes (`k8s/platform-mail-transport/secrets.contract.yaml`, this
   repo):
   - Mint a dedicated `mail.tinyland.dev/v1alpha1` `MailAccount` under
     `latoolb.us` (a NEW CR this repo does not yet declare — follow
     `docs/mail-cr-apply-runbook.md` and
     `k8s/list/latoolb-us-production/mailaccount-lists-bounces.yaml`'s
     pattern: no `passwordSecretRef` committed, the account controller
     generates the credential on first reconcile). Do not reuse
     `keyholders@latoolb.us` or `lists-bounces@latoolb.us` — see the
     contract file for why.
   - Project that generated credential into a `gftb-platform-mail-smtp`
     Secret (key `url`) in `members-greatfallstoolbus-org-production`,
     shaped `smtps://<user>:<pass>@postfix.tinyland-dev-production.svc.cluster.local:587`
     (or `smtp://` if relying on opportunistic STARTTLS — `SmtpDelivery`
     supports both; the existing relay is STARTTLS+SASL on :587, the same
     one `lists-bounces@latoolb.us` already authenticates to).
   - Set `GFTB_MAIL_FROM_ADDRESS` (plain env or ConfigMap, not secret) to a
     `latoolb.us` address the minted identity is authorized to send as.

4. **BLOCKER — confirm the substrate relay's TLS trust posture before step 6
   depends on it working. Tracked as
   [TIN-4216](https://linear.app/tinyland/issue/TIN-4216).** This is not
   resolved by this runbook or by this PR; it is flagged here so it is
   closed before activation, not discovered during it.
   `docs/runbooks/list-bringup.md` records a `mail-substrate-ca` Secret
   (`ca.crt`, the self-signed "Blahaj Mail CA" root) that both mailman
   containers mount and trust via `SSL_CERT_FILE` for verified STARTTLS
   against this same relay. `SmtpDelivery`
   (`src/lib/server/mail/delivery.ts`, app repo PR #208) calls plain
   `tls.connect`/STARTTLS against the system CA store with no custom-CA
   option today. If the relay presents that same self-signed root on the
   platform worker's leg, `SmtpDelivery` will fail TLS verification with
   every other step here otherwise correct — either the app needs a
   `NODE_EXTRA_CA_CERTS`-style trust knob referencing `mail-substrate-ca` by
   name, or the relay needs to present a publicly-trusted cert on this leg.
   TIN-4216 tracks confirming which is true and, if needed, shipping the
   fix — do not proceed to step 6 until it is closed.

5. **Apply the egress admission.** `k8s/platform-mail-transport/networkpolicy.yaml`
   (this repo) admits the worker pod's egress to
   `192.168.70.10/32:587`. It cannot be applied before infra PR #121
   (`feat/tin-3815-staging-platform-serving`) creates the
   `members-greatfallstoolbus-org-production` namespace and its
   `gftb-platform` pod labels — apply #121's stack first, then this file (or
   its folded-in successor once #121 has merged; see the header comments in
   both new files for the fold-in plan).

6. **Set `GFTB_MAIL_DELIVERY=enabled`** on the worker Deployment. This is the
   one flip that turns steps 1–5 from "wired" into "live," and per §7's
   framing above, is the point at which an operator is asserting the policy
   fence has been deliberately cleared for the templates approved in step 2
   — not merely that the plumbing compiles.

7. **Verify DNS (SPF/DKIM/DMARC)**, not publish — the records are already
   live. `latoolb.us` is Cloudflare-authoritative for DNS as of 2026-07-03
   (`dig +short NS latoolb.us` → `austin.ns.cloudflare.com.` /
   `oaklyn.ns.cloudflare.com.`; DreamHost is registrar-only), via the
   **`edge`** stack (`var.mail_dns_enabled` default `true`,
   `tofu/stacks/edge/variables.tf:60-76`) — the superseded `edge-dns` tfvars
   this step used to cite are not the authority; TIN-2379 that gated the
   mint is `Done` (2026-07-04). Re-verified this session, all live and
   matching `tofu/stacks/edge/main.tf:321-343` /
   `tofu/stacks/edge/variables.tf:109`:
   - `dig +short TXT mail._domainkey.latoolb.us` returns the committed DKIM
     public key byte-for-byte.
   - SPF: `"v=spf1 ip4:45.61.188.177 mx ~all"`.
   - DMARC: `"v=DMARC1; p=none; rua=mailto:postmaster@latoolb.us"`.

   The genuine residual is DMARC's `p=none` (monitor-only, no enforcement) —
   not an unpublished record. This step is listed last because the original
   draft had it as a pending publish; now that the records are already live,
   run the three `dig` checks above as a regression check the first time
   this chain is exercised (confirming they were still true going into
   step 6), and again after, not as a one-time publish step — a mismatch
   means the `edge` stack has drifted, not that DNS needs minting.

## Rollback

Unset `GFTB_MAIL_DELIVERY` (or set it to anything other than the exact
string `enabled`) on the worker Deployment. `readMailConfig` treats every
other value identically to unset — disabled, no warning, no partial state —
so this is a single-field revert with no secondary cleanup required. The
Secret, MailAccount, NetworkPolicy, and DNS records may stay in place; none
of them alone causes a send.

## Citations

| Claim | Source |
| --- | --- |
| Three env names, fail-closed together, SASL embedded in the DSN | app repo PR #208 `src/lib/server/mail/config.ts` |
| Exactly two shipped delivery adapters; template-approval gate lives in `resolveDelivery` | app repo PR #208 `src/lib/server/mail/delivery.ts` |
| Templates ship `approved: false`; no body copy ratified anywhere in meta | app repo PR #208 `src/lib/server/mail/templates.ts` |
| §7 automation go-live gate, 8 rows | meta `spec/launch-member-v0-system-2026-08-16.md` §7 |
| §7 all 8 rows open as of the estate gap matrix | operator memory, gftb-estate-gap-matrix-20260823 |
| P5 "everything mailbox-shaped stays a recorded no-op until §7 passes" | meta `decisions/0019-member-account-provisioning-2026-08-21.md` |
| Substrate relay host/port/auth posture; `lists-bounces` MailAccount pattern | `docs/runbooks/list-bringup.md`; `k8s/list/latoolb-us-production/mailaccount-lists-bounces.yaml` |
| `mail-substrate-ca` self-signed CA trust requirement; open TLS-trust question tracked as [TIN-4216](https://linear.app/tinyland/issue/TIN-4216) | `docs/runbooks/list-bringup.md` §"Operator-owned Secrets" |
| DNS is Cloudflare-authoritative (DreamHost registrar-only since 2026-07-03); SPF/DKIM/DMARC live and matching `tofu/stacks/edge/`; TIN-2379 Done | `dig` against `latoolb.us` (re-verified 2026-08-29); `tofu/stacks/edge/main.tf`, `tofu/stacks/edge/variables.tf` |
| Platform namespace name, pod labels, default-deny-both-directions posture | infra PR #121 `k8s/platform/members-greatfallstoolbus-org-production/networkpolicy.yaml` (unmerged, feat/tin-3815-staging-platform-serving) |
| Substrate postfix host IP `192.168.70.10/32:587` (host-networked, not SNAT'd on egress) | `k8s/list/latoolb-us-production/networkpolicy.yaml` (this repo, existing) |
