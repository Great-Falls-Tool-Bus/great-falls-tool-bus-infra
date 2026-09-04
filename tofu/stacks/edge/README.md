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
  honey-ingress tunnel CNAME. The variable keeps its old name only for state
  and input compatibility; a Pages or GitHub Pages hostname is not admitted
  as a deploy or rollback target.
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
- manages the live `lists.latoolb.us` public-archive ingress CNAME → the SAME
  shared honey-ingress Cloudflare Tunnel (proxied), gated behind
  `var.archives_dns_enabled` (default `true`) — TIN-2528;
  see "`lists.latoolb.us` archive ingress" below
- manages the live Google Workspace SSO identity provider on the CF Access account
  (`cloudflare_zero_trust_access_identity_provider` type `google-apps`),
  gated behind `var.enable_google_sso` (code default `false`, live `edge`
  environment value `true`). Additive: the apex/`www` apps keep
  `allowed_idps` empty, so BOTH Google and the existing One-Time-PIN work -
  see "Google Workspace SSO steady-state contract"
  below and [`docs/runbooks/cf-access-google-sso.md`](../../docs/runbooks/cf-access-google-sso.md)
- RETARGETS the orphaned pages.dev Access app into a **DECOUPLED dev + preview
  gate** covering `dev.greatfallstoolbus.org` + `*.preview.greatfallstoolbus.org`
  on its OWN allowlist (the `GFTB dev team` group + `GFTB dev/preview allowlist`
  policy, fed by `var.dev_preview_allowed_emails`), NOT the shared
  `web_apex_allow`, and stages a **GitHub SSO** identity provider
  (`cloudflare_zero_trust_access_identity_provider` type `github`) gated behind
  `var.enable_github_sso` (default `false`, inert) — TIN-2535;
  see "dev + preview DECOUPLE and GitHub SSO enable sequence" below and
  [`docs/runbooks/cf-access-dev-preview-and-github-sso.md`](../../docs/runbooks/cf-access-dev-preview-and-github-sso.md)

Auth is exclusively `TF_VAR_cloudflare_api_token`: a token scoped to
EXACTLY these two zones, held as the protected-environment secret
`CLOUDFLARE_API_TOKEN_GFTB_ZONES` in CI and as the sops-lane credential
`cloudflare-api-token-gftb-zones` on the operator machine
([`secrets/README.md`](../../secrets/README.md)). No account id input:
the account id the Access policy needs is read off the zone lookup.

## Web origin

The apex and `www` targets are the shared honey-ingress tunnel CNAME held by
`var.pages_host`. Cloudflare Access gates the hostnames and the tunnel routes
allowed requests to the in-cluster `gftb-site` Service. The route itself is
Cloudflare dashboard/API substrate state and is not declared by this stack.

Image promotion and rollback use the reviewed `web-release-*` saved-plan
transaction in
[`docs/runbooks/oncluster-web-cutover.md`](../../docs/runbooks/oncluster-web-cutover.md).
Changing `pages_host` to a `pages.dev` or `github.io` value is explicitly not a
rollback. Current edge-token custody and verification are documented in
[`docs/runbooks/edge-token-and-zones.md`](../../docs/runbooks/edge-token-and-zones.md).

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

## `lists.latoolb.us` archive ingress (TIN-2528 — live)

The PUBLIC `discuss@latoolb.us` HyperKitty archive rides the shared
honey-ingress Cloudflare Tunnel, fronted by a second Anubis PoW gate
(`k8s/archive/latoolb-us-production/`, `anubis-archive`). `lists.latoolb.us`
is the archive-origin hostname: a **proxied** CNAME to the same tunnel cname
target as `forms.latoolb.us`. Hostname is `lists.` (not `archives.`) because
the HyperKitty archive URL shape is already `https://lists.latoolb.us/
hyperkitty/list/<list>@latoolb.us/` (TIN-2380) and one HyperKitty instance
serves every list off that one host — see `docs/discuss-archive-packet.md`.

Declared in `main.tf` behind `var.archives_dns_enabled`, now default `true`.
The stack, public-hostname tunnel route, privacy pre-flight, and DNS apply are
complete; `.github/workflows/archive-stack.yml` records the same live posture.

**This route has an extra HARD gate the forms route does not.** The same web
tier also serves the PRIVATE `keyholders@` archive, so flipping this on
without the privacy pre-flight would risk exposing private list content.
Continuous invariants:

1. The `latoolb.us` Cloudflare zone and `lists.latoolb.us` proxied CNAME remain
   live.
2. The applied `k8s/archive/...` stack and honey-ingress public-hostname route
   continue to front `anubis-archive:8081`.
3. **PRIVACY PRE-FLIGHT REMAINS GREEN** (operator-gated, read-only): `keyholders@`
   `archive_policy=private|never`, HyperKitty is **>= 1.3.8** (the RSS-feed
   private-leak fix), and an anonymous probe confirms the private archive
   (HTML, RSS/Atom, permalinks, `/export/`, search) 403s while `discuss@`
   renders. Full procedure + command: `docs/discuss-archive-packet.md`.
4. `var.archives_dns_enabled` remains `true`; edge drift must not propose its
   deletion.

Recovery that disables the public archive is a separately reviewed change:
plan `archives_dns_enabled=false`, apply it through the edge transaction, and
remove the tunnel public-hostname route under its owning substrate authority.

## Google Workspace SSO steady-state contract (live; OTP retained)

The CF Access account has a managed Google Workspace IdP
(`cloudflare_zero_trust_access_identity_provider.google_sso`, type
`google-apps`, `apps_domain` = `var.google_sso_apps_domain`, default
`sulliwood.org`) plus One-Time-PIN (`onetimepin`). The apex and `www`
applications leave `allowed_idps` empty (all account IdPs), so Google and OTP
remain available together. The dev/preview app has its separate GitHub + OTP
pinning contract when GitHub SSO is enabled.

The Terraform variable defaults to `false` for inert bootstrap/local use, but
the live protected `edge` environment sets `ENABLE_GOOGLE_SSO=true`. Both
`edge-plan.yml` and `edge-drift.yml` pass that flag, the two credential
secrets, and the optional `TF_VAR_GOOGLE_SSO_APPS_DOMAIN` configuration
variable override into OpenTofu. If the live flag is false or omitted, the
plan requests destruction of the IdP; that is never a steady-state no-op.

Both workflows fail closed before planning when `ENABLE_GOOGLE_SSO=true` and
either `GOOGLE_SSO_CLIENT_ID` or `GOOGLE_SSO_CLIENT_SECRET` is absent. The
preflight uses only secret-presence booleans and never dereferences or prints
the values; later OpenTofu steps consume them as masked secret environment
inputs. Full bootstrap/rotation/recovery procedure:
[`docs/runbooks/cf-access-google-sso.md`](../../docs/runbooks/cf-access-google-sso.md).
Steady-state contract:

1. Keep `ENABLE_GOOGLE_SSO=true` and both Google credential secrets present in
   the protected `edge` environment.
2. Leave `TF_VAR_GOOGLE_SSO_APPS_DOMAIN` unset for `sulliwood.org`, or set it
   to the OAuth client's Workspace primary domain. The workflows map the
   case-insensitive GitHub variable to `TF_VAR_google_sso_apps_domain` in
   plan, apply, and drift.
3. Expect the normal plan and scheduled drift plan to report no change to
   `google_sso[0]`; a delete is a stop condition and indicates missing/skewed
   workflow inputs.
4. Verify Google sign-in and the retained OTP fallback after any intentional
   credential/domain update.

Recovery uses OTP while the operator restores the last-known-good Google
inputs; setting `ENABLE_GOOGLE_SSO=false` is not routine rollback. It is an
explicit destructive decommission requiring a reviewed IdP-only delete and a
manual `action=apply` dispatch with `allow_destroy=true`. Google-only pinning
is outside this contract: keep OTP alongside Google.

## dev + preview DECOUPLE and GitHub SSO enable sequence (TIN-2535; inert by default)

This is the **safety keystone** for opening the prod apex gate (TIN-2421).
Today `web_apex`, `web_www`, and the (formerly pages.dev) third app all shared
one allow policy, `web_apex_allow`. If they stayed coupled, the TIN-2421
retirement of `web_apex` / `web_www` / `web_apex_allow` would risk un-gating
dev and preview along with prod. This change **decouples** them:

- The orphaned pages.dev app (its CF Pages origin died with TIN-2560) is
  **RETARGETED in place** (Terraform label kept `pages_dev` for state
  continuity; CF app **not** deleted) into the **dev + preview gate**:
  `name = "GFTB dev + preview gate"`,
  `self_hosted_domains = ["dev.greatfallstoolbus.org", "*.preview.greatfallstoolbus.org"]`.
  One wildcard app gates every future PR preview host — Access matches by
  hostname, orthogonal to DNS/tunnel.
- That app references its **OWN** policy `dev_preview_allow` (decision `allow`),
  which includes the `GFTB dev team` group. The group's membership is
  `var.dev_preview_allowed_emails` (edge secret `DEV_PREVIEW_ALLOWED_EMAILS_JSON`,
  default `[]`). It does **NOT** reference `web_apex_allow`. `web_apex` /
  `web_www` stay on `web_apex_allow`; TIN-2421 retires those later without
  touching the dev/preview app, policy, or group.
- A **GitHub SSO** IdP (`cloudflare_zero_trust_access_identity_provider.github_sso`,
  type `github`) is staged, gated `count = var.enable_github_sso ? 1 : 0`,
  default `false`. It uses the same count-gated resource shape as Google, but
  Google is already live. Merging is a **strict no-op** on the GitHub IdP. The
  dev/preview app pins `allowed_idps` to **[GitHub SSO,
  One-Time-PIN]** when enabled (Google is deliberately absent — it authenticates
  `@sulliwood.org` operators only, not the dev team). While disabled,
  `allowed_idps` resolves to `[]` (all account IdPs, currently Google + OTP) so
  no lockout.

**INERT TO LIVE TRAFFIC:** `dev.` and `*.preview.` have no origins/DNS in this
stack yet, so gating them changes nothing currently served. Full operator
procedure (GitHub OAuth app, callback URI, secrets, verify, and the
diff-proof-before-flip note for TIN-2421):
[`docs/runbooks/cf-access-dev-preview-and-github-sso.md`](../../docs/runbooks/cf-access-dev-preview-and-github-sso.md).

Enable sequence:

1. Operator creates a **GitHub OAuth app** with the authorization callback URL
   `https://sulliwood.cloudflareaccess.com/cdn-cgi/access/callback` (the CF
   Access team-domain callback) and records the client id + secret.
2. Operator stores those in the protected `edge` environment as the secrets
   `GH_SSO_CLIENT_ID` / `GH_SSO_CLIENT_SECRET` (the `GH_` prefix is required —
   GitHub reserves the `GITHUB_` prefix for secret/variable names), and, on the
   operator machine, the sops-lane credentials `github-sso-client-id` /
   `github-sso-client-secret`. Never committed.
3. Operator populates the `edge` secret `DEV_PREVIEW_ALLOWED_EMAILS_JSON` with
   the dev-team allowlist JSON, and sets the `edge` variable `ONETIMEPIN_IDP_ID`
   to the account One-Time-PIN IdP id (so OTP stays offered alongside GitHub).
4. Operator sets the `edge` variable `ENABLE_GITHUB_SSO` to `true`.
5. PR-plan (`edge-plan.yml`) shows the IdP create + the dev/preview app pinning
   its `allowed_idps`, then `workflow_dispatch action=apply` (dispatch-apply
   doctrine, D6) — no direct apply.

Rollback: set `ENABLE_GITHUB_SSO` back to `false` (or unset it) and apply — the
IdP is destroyed and `allowed_idps` returns to `[]` (all account IdPs,
currently Google + OTP). The dev/preview app / policy / group remain (they are
the decouple, not the SSO).

**DIFF-PROOF BEFORE THE TIN-2421 FLIP:** before dropping the apex gate, a plan
must show **ZERO changes** to `pages_dev` (the dev/preview app),
`dev_preview_allow`, and `gftb_dev_team`. If any of those three show a diff when
you touch the apex, the decouple has regressed — stop and reconcile before
apply.

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
just edge-zones-lock        # refresh Linux CI + Apple Silicon provider hashes
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
