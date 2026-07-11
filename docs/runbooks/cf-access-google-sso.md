# GFTB edge: Google Workspace SSO for Cloudflare Access (operator runbook)

**Steady-state companion to [`tofu/stacks/edge/`](../../tofu/stacks/edge/README.md)
("Google Workspace SSO steady-state contract").** Google Workspace SSO is
already live and managed by this stack. It is ADDITIVE: the apex and `www`
applications continue to allow the account One-Time-PIN (OTP) provider
alongside Google. Creating or rotating the Google Cloud OAuth client and
storing its credentials are **operator actions**. Secret **names only** in git,
no values, ever.

## Current managed posture

- The CF Access account (`fdcb4fb750ab79be0800e885f09ddbdc`, team domain
  `sulliwood.cloudflareaccess.com`) has Google Workspace SSO and One-Time-PIN
  (`onetimepin`).
- The apex and `www` Access apps leave `allowed_idps` unset (`= []`), which
  allows both account IdPs. The separate dev/preview app can pin its own
  GitHub + OTP provider set; that does not change the apex Google + OTP
  posture.
- The shared allow policy `cloudflare_zero_trust_access_policy.web_apex_allow`
  allows the operator's Workspace mailbox plus the other approved addresses.
  Google sign-in still only admits allowlisted emails.
- The protected `edge` environment keeps `ENABLE_GOOGLE_SSO=true`; setting it
  false or leaving it unset makes OpenTofu plan destruction of the managed
  Google IdP.

## Workflow contract

- `cloudflare_zero_trust_access_identity_provider.google_sso` in
  `tofu/stacks/edge/main.tf` (type `google-apps`, `apps_domain` =
  `var.google_sso_apps_domain`, default `sulliwood.org`), gated
  `count = var.enable_google_sso ? 1 : 0`.
- Both `.github/workflows/edge-plan.yml` and the scheduled
  `.github/workflows/edge-drift.yml` pass the same live inputs:
  `TF_VAR_enable_google_sso` from the `edge` environment variable
  `ENABLE_GOOGLE_SSO`, `TF_VAR_google_sso_apps_domain` from the optional
  `TF_VAR_GOOGLE_SSO_APPS_DOMAIN` variable (default `sulliwood.org`), and
  `TF_VAR_google_sso_client_id` / `TF_VAR_google_sso_client_secret` from the
  `edge` environment secrets `GOOGLE_SSO_CLIENT_ID` / `GOOGLE_SSO_CLIENT_SECRET`.
- When `ENABLE_GOOGLE_SSO=true`, both workflows check only whether both
  credential secrets exist and fail before checkout/planning if either is
  absent. The preflight never dereferences or prints either value; later
  OpenTofu steps consume them as masked secret environment inputs.

The Terraform variable still defaults to `false` for inert bootstrap/local
use. That default is NOT the live workflow posture and is NOT safe for a
steady-state plan unless the live IdP is being deliberately decommissioned.

## Bootstrap or credential-rotation procedure

### Step 1 - create the Google Cloud OAuth 2.0 Web client (operator, Google console)

In the Google Cloud project you administer for the `sulliwood.org` Workspace:

1. APIs & Services -> Credentials -> Create credentials -> OAuth client ID.
2. Application type: **Web application**. Name it something like
   `cloudflare-access-gftb`.
3. Under **Authorized redirect URIs**, add EXACTLY:

   ```text
   https://sulliwood.cloudflareaccess.com/cdn-cgi/access/callback
   ```

   This is the CF Access team-domain callback for team domain
   `sulliwood.cloudflareaccess.com`. If Cloudflare ever reports the expected
   callback under Zero Trust -> Settings -> Authentication -> Login methods,
   it will match this value; use whatever Cloudflare shows if it differs.
4. Create, then copy the **Client ID** and **Client secret**.

If prompted to configure the OAuth consent screen, set it to **Internal**
(restricts to your Workspace) and the app domain to `sulliwood.org`.

### Step 2 - store the secrets (operator custody, never committed)

Put the two values in the protected `edge` GitHub environment on
`Great-Falls-Tool-Bus/great-falls-tool-bus-infra`:

- Secret `GOOGLE_SSO_CLIENT_ID` = the client id from step 1.
- Secret `GOOGLE_SSO_CLIENT_SECRET` = the client secret from step 1.

On the operator machine (sops lane), the same values are the credentials
`google-sso-client-id` / `google-sso-client-secret` (names-only inventory:
[`secrets/README.md`](../../secrets/README.md)). For a local plan/apply, feed
them as `TF_VAR_google_sso_client_id` / `TF_VAR_google_sso_client_secret`.

### Step 3 - preserve the live workflow variables

Keep the `edge` environment VARIABLE (not secret) `ENABLE_GOOGLE_SSO` set to
`true`. For a local operator plan, export `TF_VAR_enable_google_sso=true` and
both credential variables from operator custody.

The `apps_domain` defaults to `sulliwood.org`; override with the
`edge` environment variable `TF_VAR_GOOGLE_SSO_APPS_DOMAIN` only if the OAuth
client belongs to a different Workspace primary domain. GitHub configuration
variable names are case-insensitive; the workflows map it to the
case-sensitive runner variable `TF_VAR_google_sso_apps_domain` for plan,
apply, and scheduled drift. Local operator runs set the latter directly.

### Step 4 - plan and apply through CI (dispatch-apply doctrine, D6)

1. A steady-state `edge-plan.yml` or `edge-drift.yml` run must report no
   changes for
   `cloudflare_zero_trust_access_identity_provider.google_sso[0]`. Any proposed
   delete is a stop condition: restore the enable flag and required inputs
   before proceeding.
2. During a credential or apps-domain rotation, confirm the plan updates only
   the intended IdP fields and destroys nothing.
3. Apply an intentional update via `workflow_dispatch` with `action=apply`
   (never a direct apply, never a merge side effect). See
   [`tofu/stacks/edge/README.md`](../../tofu/stacks/edge/README.md)
   "Operating it".

### Step 5 - verify sign-in (OTP still works)

1. Open `https://sulliwood.cloudflareaccess.com` (or any gated app such as
   `https://greatfallstoolbus.org`). The Access login screen now offers
   **Google** in addition to the one-time PIN.
2. Sign in with the operator Workspace account via Google. Because that mailbox
   is on the allowlist, Access admits you.
3. Confirm the **one-time PIN** option is STILL present and STILL works
   (sign in via OTP in a private window). Google is additive, not a
   replacement.

## Recovery and decommissioning

For an OAuth or Google sign-in problem, use the retained OTP path, restore the
last-known-good credentials/domain from operator custody, and re-plan. Do NOT
set `ENABLE_GOOGLE_SSO=false` merely to make drift green: that requests
destruction of the managed IdP.

Removing Google SSO is a destructive decommission, not routine rollback. It
requires an explicit operator decision, a reviewed plan whose intended delete
is limited to `google_sso[0]`, and a manual dispatch with `allow_destroy=true`.
OTP must be verified first and remains the fallback throughout. Pinning the
apex/`www` apps to Google-only is outside this contract; keep OTP alongside
Google.

## Guardrails

- Never commit the client id or secret. They live only in the `edge`
  environment secrets and operator sops custody.
- Keep `ENABLE_GOOGLE_SSO=true` and both credential secrets present for every
  live plan, apply, and scheduled drift run. The presence preflight is
  deliberately fail-closed.
- Token permission: the zone-scoped Cloudflare API token
  (`cloudflare-api-token-gftb-zones`) carries both `Access: Apps and Policies
  Edit` and the separate account-scoped `Access: Organizations, Identity
  Providers, and Groups: Edit` grant. If the apply returns a 403 /
  authentication error on `google_sso`, verify that exact documented shape
  and rotate the token per
  [`docs/runbooks/edge-token-and-zones.md`](edge-token-and-zones.md); do not
  broaden it beyond the named account/zones and permissions.
- This runbook changes authentication only. The allowlist
  (`access_allowed_emails`) still governs WHO may enter; Google just adds
  HOW they prove who they are.
- Keep the apex and `www` applications unpinned so OTP remains available
  alongside Google.
