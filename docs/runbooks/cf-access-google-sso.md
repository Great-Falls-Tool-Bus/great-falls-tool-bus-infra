# GFTB edge: Google Workspace SSO for Cloudflare Access (operator runbook)

**Declare-only companion to [`tofu/stacks/edge/`](../../tofu/stacks/edge/README.md)
("Google Workspace SSO enable sequence").** Adds a Google Workspace sign-in
option to the Cloudflare Access edge stack so the operator
(`jess@sulliwood.org`, which IS Google Workspace) can authenticate with Google
instead of the fragile 10-minute email One-Time-PIN (OTP). The tofu is merged
INERT: it does nothing until the operator supplies the Google OAuth client
id/secret and flips the enable flag. This is ADDITIVE: the OTP path stays
available and working the entire time. Creating the Google Cloud OAuth client
and storing secrets are **operator actions**. Secret **names only** in git, no
values, ever.

## What is already true (verified live)

- The CF Access account (`fdcb4fb750ab79be0800e885f09ddbdc`, team domain
  `sulliwood.cloudflareaccess.com`) has exactly ONE identity provider today:
  One-Time-PIN (`onetimepin`).
- The three `self_hosted` Access apps in the edge stack (`web_apex`, `web_www`,
  `pages_dev`) leave `allowed_idps` unset (`= []`), which means ALL account
  IdPs are allowed. So the moment a Google IdP exists, Google sign-in works AND
  the OTP option is still offered.
- The shared allow policy `cloudflare_zero_trust_access_policy.web_apex_allow`
  allows four emails including `jess@sulliwood.org`. Adding an IdP does NOT
  change the allowlist: Google sign-in still only admits allowlisted emails.

## What this change added (already merged, inert)

- `cloudflare_zero_trust_access_identity_provider.google_sso` in
  `tofu/stacks/edge/main.tf` (type `google-apps`, `apps_domain` =
  `var.google_sso_apps_domain`, default `sulliwood.org`), gated
  `count = var.enable_google_sso ? 1 : 0`.
- Variables `enable_google_sso` (bool, default `false`),
  `google_sso_apps_domain` (default `sulliwood.org`), and the sensitive
  `google_sso_client_id` / `google_sso_client_secret` (default `""`, never
  committed).
- Workflow passthrough in `.github/workflows/edge-plan.yml`:
  `TF_VAR_enable_google_sso` from the `edge` environment variable
  `ENABLE_GOOGLE_SSO` (defaults `false` when unset), and
  `TF_VAR_google_sso_client_id` / `TF_VAR_google_sso_client_secret` from the
  `edge` environment secrets `GOOGLE_SSO_CLIENT_ID` / `GOOGLE_SSO_CLIENT_SECRET`.

With `enable_google_sso` false (the default) the plan is a no-op.

## Enable procedure

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

### Step 3 - flip the enable flag

Set the `edge` environment VARIABLE (not secret) `ENABLE_GOOGLE_SSO` to
`true`. Unset or any non-`true` value keeps the IdP off. (For a local run,
`export TF_VAR_enable_google_sso=true`.)

The `apps_domain` defaults to `sulliwood.org`; override with the
`edge`-scoped `TF_VAR_google_sso_apps_domain` only if the OAuth client belongs
to a different Workspace primary domain.

### Step 4 - plan and apply through CI (dispatch-apply doctrine, D6)

1. The `edge-plan.yml` PR/push plan will now show ONE resource to create:
   `cloudflare_zero_trust_access_identity_provider.google_sso[0]`. Confirm it
   is a single `create` and nothing is destroyed.
2. Apply via `workflow_dispatch` with `action=apply` (never a direct apply,
   never a merge side effect). See
   [`tofu/stacks/edge/README.md`](../../tofu/stacks/edge/README.md)
   "Operating it".

### Step 5 - verify sign-in (OTP still works)

1. Open `https://sulliwood.cloudflareaccess.com` (or any gated app such as
   `https://greatfallstoolbus.org`). The Access login screen now offers
   **Google** in addition to the one-time PIN.
2. Sign in with `jess@sulliwood.org` via Google. Because the email is on the
   allowlist, Access admits you.
3. Confirm the **one-time PIN** option is STILL present and STILL works
   (sign in via OTP in a private window). Google is additive, not a
   replacement.

## Rollback

Set `ENABLE_GOOGLE_SSO` back to `false` (or unset it) and apply. The IdP is
destroyed and the account returns to OTP-only. No app or policy change is
needed because the apps never pinned `allowed_idps` to Google.

## Optional: Google-only (drop the OTP fallback)

Only after Google sign-in is verified working, and only as a deliberate
follow-up, the operator can pin the apps to the Google IdP so OTP is no longer
offered. The inline example is in `tofu/stacks/edge/main.tf` next to the IdP
resource (set `allowed_idps` on `web_apex` / `web_www` / `pages_dev` to
`[cloudflare_zero_trust_access_identity_provider.google_sso[0].id]`). Do NOT do
this before the IdP exists and is proven, or the operator can be locked out.

## Guardrails

- Never commit the client id or secret. They live only in the `edge`
  environment secrets and operator sops custody.
- Token permission: the zone-scoped Cloudflare API token
  (`cloudflare-api-token-gftb-zones`) carries `Access: Apps and Policies
  Edit`, which manages the Access apps and policies today. Identity providers
  are a SEPARATE Cloudflare permission group. If the apply returns a 403 /
  authentication error on the `google_sso` resource, add `Access:
  Organizations, Identity Providers, and Groups: Edit` to the token (mint /
  rotate per [`docs/runbooks/edge-token-and-zones.md`](edge-token-and-zones.md))
  and re-run. This is the only token change the IdP might need; DNS,
  redirects, and Access apps stay on the existing scopes.
- This runbook changes authentication only. The allowlist
  (`access_allowed_emails`) still governs WHO may enter; Google just adds
  HOW they prove who they are.
