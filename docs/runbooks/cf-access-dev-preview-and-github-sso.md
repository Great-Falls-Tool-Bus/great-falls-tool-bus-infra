# GFTB edge: dev + preview Access DECOUPLE and GitHub SSO (operator runbook)

**Declare-only companion to [`tofu/stacks/edge/`](../../tofu/stacks/edge/README.md)
("dev + preview DECOUPLE and GitHub SSO enable sequence").** This is the
**safety keystone** (TIN-2535) that makes opening the prod apex gate (TIN-2421)
safe: it moves the dev + preview gate onto its OWN allowlist and its OWN
identity providers so that retiring the apex gate can NEVER un-gate dev or
preview. It also adds a GitHub sign-in option for the dev team, mirroring the
Google Workspace SSO change. The tofu is merged INERT: nothing applies live in
this PR and, even after a later gated apply, nothing that is currently served
changes (dev/preview have no origins yet). Creating the GitHub OAuth app and
storing secrets are **operator actions**. Secret **names only** in git, no
values, ever.

## The DECOUPLE safety property (why this exists)

Before this change, three self_hosted Access apps shared ONE allow policy:

- `web_apex` (greatfallstoolbus.org) -> `web_apex_allow`
- `web_www` (www.greatfallstoolbus.org) -> `web_apex_allow`
- the orphaned pages.dev app -> `web_apex_allow`

TIN-2421 opens the prod apex to the public by **dropping** `web_apex`,
`web_www`, and `web_apex_allow`. If the dev/preview surface stayed coupled to
`web_apex_allow`, that retirement would risk un-gating dev and preview as a side
effect. This change breaks that coupling:

- The (formerly pages.dev) app is RETARGETED into the **dev + preview gate** and
  points at its OWN policy `dev_preview_allow` -> the `GFTB dev team` group.
- `web_apex` / `web_www` stay on `web_apex_allow`.

After this, retiring the apex gate touches only `web_apex`, `web_www`, and
`web_apex_allow`. The dev/preview app, `dev_preview_allow`, and `gftb_dev_team`
are untouched. **The apex retirement can no longer ungate dev/preview.**

## What is already true (verified live)

- The CF Access account (`fdcb4fb750ab79be0800e885f09ddbdc`, team domain
  `sulliwood.cloudflareaccess.com`) has One-Time-PIN (`onetimepin`) and,
  optionally, the inert Google Workspace IdP from
  [`cf-access-google-sso.md`](cf-access-google-sso.md).
- The pages.dev Access application is orphaned: its CF Pages origin
  (`greatfallstoolbus-org.pages.dev` + `*.preview`) was deleted with the Pages
  project (ADR 0010 Amendment 2, TIN-2560). This change RETARGETS that same
  application in place rather than deleting it (the CF app AUD and state are
  preserved).

## What this change added (merged, inert)

- Retargeted `cloudflare_zero_trust_access_application.pages_dev` (Terraform
  label kept for state continuity) to
  `name = "GFTB dev + preview gate"`,
  `self_hosted_domains = ["dev.greatfallstoolbus.org", "*.preview.greatfallstoolbus.org"]`,
  pointing at the new `dev_preview_allow` policy (NOT `web_apex_allow`), with
  `allowed_idps` pinned to GitHub SSO + One-Time-PIN when GitHub SSO is enabled.
  One wildcard app gates unlimited PR preview hosts (Access matches by hostname,
  orthogonal to DNS/tunnel).
- `cloudflare_zero_trust_access_group.gftb_dev_team` — dev-team email
  membership from `var.dev_preview_allowed_emails`.
- `cloudflare_zero_trust_access_policy.dev_preview_allow` (decision `allow`) —
  includes the `gftb_dev_team` group.
- `cloudflare_zero_trust_access_identity_provider.github_sso` (type `github`),
  gated `count = var.enable_github_sso ? 1 : 0`.
- Variables `dev_preview_allowed_emails` (list, default `[]`),
  `enable_github_sso` (bool, default `false`), `onetimepin_idp_id` (string,
  default `""`), and the sensitive `github_sso_client_id` /
  `github_sso_client_secret` (default `""`, never committed).
- Workflow passthrough in `.github/workflows/edge-plan.yml`:
  `TF_VAR_dev_preview_allowed_emails` from the `edge` environment secret
  `DEV_PREVIEW_ALLOWED_EMAILS_JSON` (defaults `[]` when unset),
  `TF_VAR_enable_github_sso` from the `edge` environment variable
  `ENABLE_GITHUB_SSO` (defaults `false`), `TF_VAR_onetimepin_idp_id` from the
  `edge` variable `ONETIMEPIN_IDP_ID`, and `TF_VAR_github_sso_client_id` /
  `TF_VAR_github_sso_client_secret` from the `edge` environment secrets
  `GH_SSO_CLIENT_ID` / `GH_SSO_CLIENT_SECRET`.

With `enable_github_sso` false (the default) the plan is a strict no-op on the
IdP, exactly like Google SSO. (The retarget of the app + the new group/policy
DO show in the plan — they are the decouple; they just do not apply on merge and
do not affect live traffic.)

> **Secret naming:** the GitHub credentials use the `GH_` prefix
> (`GH_SSO_CLIENT_ID` / `GH_SSO_CLIENT_SECRET`), NOT `GITHUB_`. GitHub Actions
> reserves the `GITHUB_` prefix for both secret and variable names and rejects
> names that start with it. The tofu variable names (`github_sso_client_id`,
> `github_sso_client_secret`) are unaffected.

## Enable procedure

### Step 1 - create the GitHub OAuth app (operator, GitHub)

Under the GitHub account/org that owns the dev team
(Settings -> Developer settings -> OAuth Apps -> New OAuth App), or an
org-level OAuth app:

1. **Application name**: something like `cloudflare-access-gftb-dev`.
2. **Homepage URL**: `https://dev.greatfallstoolbus.org` (any valid URL; not
   load-bearing).
3. Under **Authorization callback URL**, add EXACTLY:

   ```text
   https://sulliwood.cloudflareaccess.com/cdn-cgi/access/callback
   ```

   This is the CF Access team-domain callback for team domain
   `sulliwood.cloudflareaccess.com`. If Cloudflare ever reports the expected
   callback under Zero Trust -> Settings -> Authentication -> Login methods, it
   will match this value; use whatever Cloudflare shows if it differs.
4. Register the app, then copy the **Client ID** and generate + copy a
   **Client secret**.

### Step 2 - store the secrets (operator custody, never committed)

Put the two values in the protected `edge` GitHub environment on
`Great-Falls-Tool-Bus/great-falls-tool-bus-infra`:

- Secret `GH_SSO_CLIENT_ID` = the client id from step 1.
- Secret `GH_SSO_CLIENT_SECRET` = the client secret from step 1.

On the operator machine (sops lane), the same values are the credentials
`github-sso-client-id` / `github-sso-client-secret` (names-only inventory:
[`secrets/README.md`](../../secrets/README.md)). For a local plan/apply, feed
them as `TF_VAR_github_sso_client_id` / `TF_VAR_github_sso_client_secret`.

### Step 3 - set the dev-team allowlist and the OTP IdP id

- Set the `edge` environment secret `DEV_PREVIEW_ALLOWED_EMAILS_JSON` to the
  dev-team allowlist JSON, for example `["dev@example.org","other@example.org"]`.
  This is a SEPARATE list from `ACCESS_ALLOWED_EMAILS_JSON` (which gates the
  prod apex) — that is the whole point of the decouple. Unset leaves the group
  empty and the gate admits nobody.
- Set the `edge` environment VARIABLE (not secret) `ONETIMEPIN_IDP_ID` to the
  account's One-Time-PIN IdP id, so OTP stays offered alongside GitHub. Read it
  from the Zero Trust dashboard (Settings -> Authentication -> Login methods ->
  One-time PIN) or the CF API (`GET
  /accounts/{account_id}/access/identity_providers`, the entry with
  `"type": "onetimepin"`). This is an id, not a secret. If you leave it unset
  while enabling GitHub SSO, the gate pins to GitHub ONLY — a lockout risk if
  GitHub sign-in misbehaves — so set it.

### Step 4 - flip the enable flag

Set the `edge` environment VARIABLE (not secret) `ENABLE_GITHUB_SSO` to `true`.
Unset or any non-`true` value keeps the IdP off. (For a local run,
`export TF_VAR_enable_github_sso=true`.)

### Step 5 - plan and apply through CI (dispatch-apply doctrine, D6)

1. The `edge-plan.yml` PR/push plan will now show the `github_sso` IdP create
   plus the dev/preview app pinning its `allowed_idps` to
   `[github_sso, onetimepin]`. Confirm the IdP is a single `create` and nothing
   is destroyed.
2. Apply via `workflow_dispatch` with `action=apply` (never a direct apply,
   never a merge side effect). See
   [`tofu/stacks/edge/README.md`](../../tofu/stacks/edge/README.md)
   "Operating it".

### Step 6 - verify sign-in (OTP still works)

1. Once `dev.greatfallstoolbus.org` (or a `*.preview.` host) has an origin and
   DNS, open it. The Access login screen offers **GitHub** and **one-time PIN**;
   it does NOT offer Google (Google is reserved for `@sulliwood.org`
   operators on the apex).
2. Sign in with a dev-team GitHub account whose email is on the
   `DEV_PREVIEW_ALLOWED_EMAILS_JSON` list. Access admits you.
3. Confirm the **one-time PIN** option is STILL present and STILL works (sign in
   via OTP in a private window). GitHub is additive, not a replacement.

## Rollback

Set `ENABLE_GITHUB_SSO` back to `false` (or unset it) and apply. The IdP is
destroyed and `allowed_idps` returns to `[]` (OTP-only). The dev/preview app,
`dev_preview_allow`, and `gftb_dev_team` remain — they are the decouple, not the
SSO — so rolling back GitHub SSO does NOT re-couple dev/preview to the apex.

## Diff-proof before the TIN-2421 apex flip (REQUIRED)

Before the TIN-2421 change that drops `web_apex` / `web_www` / `web_apex_allow`
opens the prod apex to the public, run its plan and confirm it shows **ZERO
changes** to all three decouple resources:

- `cloudflare_zero_trust_access_application.pages_dev` (the dev + preview gate)
- `cloudflare_zero_trust_access_policy.dev_preview_allow`
- `cloudflare_zero_trust_access_group.gftb_dev_team`

If any of those three appear in the apex-retirement plan (create / update /
delete), the decouple has regressed — **stop and reconcile before apply**. A
clean apex retirement touches only the apex/www app + `web_apex_allow`; the
dev/preview lane must be inert in that plan. This is the invariant the whole
keystone exists to guarantee.

## Guardrails

- Never commit the client id or secret, or the dev-team allowlist. They live
  only in the `edge` environment secrets and operator sops custody.
- Token permission: identity providers, access groups, and access policies are
  account-scoped Access objects. The zone-scoped Cloudflare API token
  (`cloudflare-api-token-gftb-zones`) already carries `Access: Organizations,
  Identity Providers, and Groups: Edit` (added for Google SSO) plus `Access:
  Apps and Policies: Edit`, which covers the group, policy, IdP, and app here.
  If an apply returns a 403 on `github_sso`, `dev_preview_allow`, or
  `gftb_dev_team`, re-check those scopes and mint/rotate per
  [`docs/runbooks/edge-token-and-zones.md`](edge-token-and-zones.md).
- This runbook changes WHO may enter dev/preview (the dev-team allowlist) and
  HOW they prove it (GitHub + OTP). It never touches the prod apex allowlist
  (`access_allowed_emails`) or the apex identity providers — that separation is
  the decouple.
- Google is deliberately NOT offered on the dev/preview gate: it authenticates
  `@sulliwood.org` operators only, which is the apex audience, not the dev team.
