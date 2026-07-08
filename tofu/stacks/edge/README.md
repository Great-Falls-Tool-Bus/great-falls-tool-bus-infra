# `tofu/stacks/edge/` — GFTB zone stack (TIN-2378 prep + TIN-2385)

The records / Access-gate / redirect surface for the two GFTB zones once
they exist as **console-created zones on the house Cloudflare account**
(same-account + zone-scoped token per TIN-2385). This stack:

- **looks zones up by name** (`data "cloudflare_zone"`) — it never
  creates them; zone add is an operator console step
  ([`docs/runbooks/edge-token-and-zones.md`](../../docs/runbooks/edge-token-and-zones.md)
  step 1)
- manages `greatfallstoolbus.org` apex CNAME (CF-flattened) + `www`
  CNAME → `var.pages_host`, proxied — default is now the on-cluster
  honey-ingress tunnel cname (site ADR 0010, executed 2026-07-06; see
  `variables.tf`'s `pages_host` description). The variable's original
  default, `greatfallstoolbus-org.pages.dev` (the ADR 0003 CF Pages
  cutover, executed 2026-07-03, PR #15 — see "`pages_host` cutover"
  below), is **historical**: that Pages project is deleted (ADR 0010
  Amendment 2, TIN-2560), so the hostname no longer resolves.
- gates the apex behind a Cloudflare Access application + allow policy
  (`access_allowed_emails` supplied from the protected edge environment; no
  personal allowlist addresses are committed) — packet row (g) REV-2
- serves the `latoolb.us` root+`www` 301 redirect ruleset; the target is
  `var.alias_redirect_target`, defaulting to the raw Pages project URL
  (`https://great-falls-tool-bus.github.io/greatfallstoolbus.org/`) and
  flipping to the apex when the Access gate opens. Status 2026-07-03
  later: the `latoolb.us` NS change was saved at DreamHost and is
  propagating; the ruleset starts serving once the Cloudflare zone
  activates
- stages `latoolb.us` mail DNS (MX/SPF/DMARC/DKIM) ALL gated behind
  `var.mail_dns_enabled` (default `true` after D11 closed self-hosted)
  — see "mail DNS enable
  sequence" below
- manages the live `forms.latoolb.us` contact-form ingress CNAME → the shared
  honey-ingress Cloudflare Tunnel (proxied), gated behind
  `var.forms_dns_enabled` (default `true` after the 2026-07-05 route + smoke
  proof) — TIN-2420 Path B; see "`forms.latoolb.us` DNS enable sequence" below
- stages the `lists.latoolb.us` public-archive ingress CNAME → the SAME
  shared honey-ingress Cloudflare Tunnel (proxied), gated behind
  `var.archives_dns_enabled` (default `false`, fail-closed) — TIN-2528;
  see "`lists.latoolb.us` archives DNS enable sequence" below
- stages a Google Workspace SSO identity provider on the CF Access account
  (`cloudflare_zero_trust_access_identity_provider` type `google-apps`),
  gated behind `var.enable_google_sso` (default `false`, inert). Additive:
  the apps keep `allowed_idps` empty, so once enabled BOTH Google and the
  existing One-Time-PIN work - see "Google Workspace SSO enable sequence"
  below and [`docs/runbooks/cf-access-google-sso.md`](../../docs/runbooks/cf-access-google-sso.md)

Auth is exclusively `TF_VAR_cloudflare_api_token`: a token scoped to
EXACTLY these two zones, held as the protected-environment secret
`CLOUDFLARE_API_TOKEN_GFTB_ZONES` in CI and as the sops-lane credential
`cloudflare-api-token-gftb-zones` on the operator machine
([`secrets/README.md`](../../secrets/README.md)). No account id input:
the account id the Access policy needs is read off the zone lookup.

## `pages_host` cutover (ADR 0003 — EXECUTED 2026-07-03; HISTORICAL, see below)

> **Superseded 2026-07-06 by ADR 0010** (`docs/runbooks/oncluster-web-cutover.md`
> P6): `var.pages_host`'s default moved from `greatfallstoolbus-org.pages.dev`
> to the on-cluster honey-ingress tunnel cname. **Superseded again 2026-07-07
> by ADR 0010 Amendment 2** (TIN-2560): the CF Pages project named below is
> **deleted**, so the "rollback is a one-line flip" language two paragraphs
> down no longer has a CF Pages target to flip to (a GH Pages rollback, if
> ever needed, would first require re-standing up that publisher — it was
> never deleted, only demoted, but has not been verified serving since this
> section was written). The current rollback path is on-cluster: re-dispatch
> `web-stack.yml` with a prior image digest (`docs/runbooks/oncluster-web-
> cutover.md` P7).

The apex + `www` targets are `var.pages_host`. The GH Pages → CF Pages
flip was executed 2026-07-03: the CF Pages project exists with the
`greatfallstoolbus.org` custom domain attached, and the cutover value
`greatfallstoolbus-org.pages.dev` is committed as the variable default
(PR #15) — apex + `www` serve from CF Pages behind the REV-2 Access
gate. Full sequencing, token doctrine (account-scoped Pages:Edit token
vs. the zone-scoped token), and the verify matrix:
[`docs/runbooks/edge-token-and-zones.md`](../../docs/runbooks/edge-token-and-zones.md)
step 5. Rollback is a one-line flip back to the GH Pages host
(`great-falls-tool-bus.github.io`) via tfvars or `TF_VAR_pages_host` at
apply time.

## `latoolb.us` mail DNS enable sequence (TIN-2379, D11 closed self-hosted)

MX/SPF/DMARC/DKIM records for `latoolb.us` are staged in `main.tf`,
gated behind `var.mail_dns_enabled` (default `true` after D11 closed
self-hosted) and `var.mail_dkim_txt` (set to the public DKIM TXT value;
DKIM only materializes once set). The enable sequence is:

1. `latoolb.us` NS cutover to Cloudflare completes and the zone goes
   live (D1=A: DreamHost panel change saved 2026-07-03, registry
   propagation pending; CF zone auto-activates on delegation).
2. **D11 is answered** — the operator confirmed self-hosted mail, not
   Google Workspace. The mail target is the blahaj relay per [ADR
   010](https://github.com/tinyland-inc/blahaj/blob/main/docs/architecture/decisions/010-tenant-list-engine-smtp-interface.md)
   (`var.mail_mx_target` default `relay.tinyland.dev`).
3. Mail is applied on the substrate side (TIN-2379 `mail-crs.yml`
   server-dry-run -> apply) so the `MailDomain`/`MailAccount` CRs
   (`k8s/mail/latoolb-us-production/`) are live and a DKIM key exists
   for selector `mail`.
4. `var.mail_dkim_txt` is set to the extracted DKIM public-key TXT
   value.
5. `var.mail_dns_enabled` flips to `true` (current branch default).
6. PR-plan (this repo's normal `edge-plan.yml` PR flow) then
   `workflow_dispatch action=apply` (dispatch-apply doctrine, D6) — no
   direct apply.

## `forms.latoolb.us` DNS enable sequence (TIN-2420 Path B)

The site contact form POSTs to the in-cluster intake handler (honeypot +
5/min rate limit + CORS locked to `https://greatfallstoolbus.org` +
validation, all smoke-proven; handler POST 200 → mailman ACCEPT → Gmail
250). The handler is fronted by Anubis (v1.13.0, digest-pinned) and
reached from the internet over the **shared honey-ingress Cloudflare
Tunnel**. `forms.latoolb.us` is the form-origin hostname: a **proxied**
CNAME to that tunnel's cname target
`da3ffda2-68ee-46d1-aa55-ec8dae2bd471.cfargotunnel.com` (tunnel id per
`Great-Falls-Tool-Bus/blahaj-infra-boundary` PR #908 recon).

Staged in `main.tf` gated behind `var.forms_dns_enabled`. This gate is now
**active by default** because the route, handler, LMTP fan-out, and live smoke
were proven before the default flipped. Enable or rollback sequence:

1. `latoolb.us` NS cutover to Cloudflare completes and the zone is live
   (shared with the mail enable sequence, step 1 above).
2. The honey-ingress tunnel has an ingress route for `forms.latoolb.us`
   fronting the Anubis-gated intake handler (substrate side).
3. `var.forms_dns_enabled` is set to `true` for activation, or `false` for
   rollback.
4. PR-plan (this repo's normal `edge-plan.yml` PR flow) then
   `workflow_dispatch action=apply` (dispatch-apply doctrine, D6) — no
   direct apply.

## `lists.latoolb.us` archives DNS enable sequence (TIN-2528 — declare-only)

The PUBLIC `discuss@latoolb.us` HyperKitty archive rides the shared
honey-ingress Cloudflare Tunnel, fronted by a second Anubis PoW gate
(`k8s/archive/latoolb-us-production/`, `anubis-archive`). `lists.latoolb.us`
is the archive-origin hostname: a **proxied** CNAME to the same tunnel cname
target as `forms.latoolb.us`. Hostname is `lists.` (not `archives.`) because
the HyperKitty archive URL shape is already `https://lists.latoolb.us/
hyperkitty/list/<list>@latoolb.us/` (TIN-2380) and one HyperKitty instance
serves every list off that one host — see `docs/discuss-archive-packet.md`.

Staged in `main.tf` gated behind `var.archives_dns_enabled` (default
`false`, fail-closed — merging changes nothing until flipped).

**This route has an extra HARD gate the forms route does not.** The same web
tier also serves the PRIVATE `keyholders@` archive, so flipping this on
without the privacy pre-flight would risk exposing private list content.
Enable sequence:

1. `latoolb.us` NS cutover to Cloudflare completes and the zone is live
   (shared with the mail/forms enable sequences).
2. The `k8s/archive/...` stack is applied and the honey-ingress tunnel has an
   ingress route for `lists.latoolb.us` fronting `anubis-archive:8081`
   (substrate/dashboard side).
3. **PRIVACY PRE-FLIGHT PASSES** (operator-gated, read-only): `keyholders@`
   `archive_policy=private|never`, HyperKitty is **>= 1.3.8** (the RSS-feed
   private-leak fix), and an anonymous probe confirms the private archive
   (HTML, RSS/Atom, permalinks, `/export/`, search) 403s while `discuss@`
   renders. Full procedure + command: `docs/discuss-archive-packet.md`.
4. `var.archives_dns_enabled` flips to `true` in a follow-up change.
5. PR-plan (`edge-plan.yml`) then `workflow_dispatch action=apply`
   (dispatch-apply doctrine, D6) — no direct apply.

Rollback: flip `var.archives_dns_enabled` back to `false` (plan/apply) and
remove the `lists.latoolb.us` tunnel public-hostname route dashboard-side.

## Google Workspace SSO enable sequence (declare-only; inert by default)

The CF Access account today has exactly one IdP: One-Time-PIN
(`onetimepin`), so operator sign-in relies on the fragile 10-minute email
OTP. `main.tf` stages a Google Workspace IdP
(`cloudflare_zero_trust_access_identity_provider.google_sso`, type
`google-apps`, `apps_domain` = `var.google_sso_apps_domain`, default
`sulliwood.org`) so the operator's Workspace account can sign in with Google
instead.

This is PURELY ADDITIVE and INERT BY DEFAULT: it is gated behind
`var.enable_google_sso` (default `false`, `count = 0`), so merging this
changes nothing (no-op plan). The three self_hosted apps leave
`allowed_idps` empty (all IdPs allowed), so enabling the IdP adds Google
WITHOUT removing the OTP path - the OTP fallback keeps working throughout.

Full operator procedure (Google Cloud OAuth client, redirect URI, secrets,
verify): [`docs/runbooks/cf-access-google-sso.md`](../../docs/runbooks/cf-access-google-sso.md).
Enable sequence:

1. Operator creates a Google Cloud **OAuth 2.0 Client ID** of type **Web
   application** with the authorized redirect URI
   `https://sulliwood.cloudflareaccess.com/cdn-cgi/access/callback` (the CF
   Access team-domain callback), and records the client id + secret.
2. Operator stores those in the protected `edge` environment as the secrets
   `GOOGLE_SSO_CLIENT_ID` / `GOOGLE_SSO_CLIENT_SECRET` (and, on the operator
   machine, the sops-lane credentials `google-sso-client-id` /
   `google-sso-client-secret`). Never committed.
3. Operator sets the `edge` environment variable `ENABLE_GOOGLE_SSO` to
   `true` (this feeds `TF_VAR_enable_google_sso`; unset stays `false`).
4. PR-plan (`edge-plan.yml`) shows the single IdP create, then
   `workflow_dispatch action=apply` (dispatch-apply doctrine, D6) - no
   direct apply.
5. Operator verifies Google sign-in at
   `https://sulliwood.cloudflareaccess.com` (or any gated app); the OTP
   option is still offered and still works.

Rollback: set `ENABLE_GOOGLE_SSO` back to `false` (or unset it) and
apply - the IdP is destroyed and only OTP remains. Google-ONLY pinning
(dropping the OTP fallback) is a separate, deliberate follow-up documented
inline in `main.tf` (`allowed_idps`), not part of this change.

## Relationship to `tofu/stacks/edge-dns/` (read before touching either)

`edge-dns/` predates TIN-2385 and codifies packet row (g) REVISED +
REV-2 as **zone-creating, fail-closed** (both `manage_*` toggles false;
empty default plan; DreamHost stays DNS authority unless the operator
picks REV-2 path A). THIS stack is the TIN-2385 realization of REV-2
path A with the zone-create step moved console-side and the token
narrowed from `Account: Zone Create` to zone-scoped only — and it
extends path A to `latoolb.us` for the redirect ruleset (records only;
`latoolb.us` mail posture is untouched until TIN-2379). The two stacks
overlap on the web-zone record surface, so they must never both apply:
`edge-dns` `manage_*` toggles stay `false` when this stack is live. If
the operator instead rejects the latoolb.us-on-CF extension, the
redirect half of this stack is dropped and `latoolb.us` redirects stay
DreamHost-side per the edge-dns runbook — that reconciliation is an
explicit operator decision recorded on the PR, not a default.

State: `tofu/backend/honey-edge.s3.hcl` — same bucket/endpoint shape as
the other stacks, key `great-falls-tool-bus-infra/edge/terraform.tfstate`.

## Operating it

```bash
just edge-zones-fmt-check   # formatting
just edge-zones-validate    # init -backend=false + validate (no state, no creds)
just edge-zones-init        # backend: tofu/backend/honey-edge.s3.hcl
just edge-zones-plan        # needs TF_VAR_cloudflare_api_token + backend keys
just edge-zones-plan-show
just edge-zones-apply       # destroy-checked, ALLOW_EDGE_ZONES_DESTROY-gated
```

CI: [`.github/workflows/edge-plan.yml`](../../.github/workflows/edge-plan.yml)
plans on PR/push against the protected `edge` environment and applies
only via `workflow_dispatch` `action=apply`; it skips green with a
notice while `CLOUDFLARE_API_TOKEN_GFTB_ZONES` is unset (the token does
not exist until the runbook's mint step).

Precondition: both zones exist on the house account (console step) —
until then `plan` fails on the zone lookups by design; there is nothing
fail-open to guess.
