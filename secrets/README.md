# `secrets/` — GFTB tenant sops lane (names-only inventory)

Ciphertext for the GFTB tenant lands here as `*.enc.yaml` / `*.enc.json`,
encrypted per the repo-root `.sops.yaml` to the distinct GFTB tenant age
recipient (TIN-2360 row d; private half = operator keys.txt custody). This
lane supersedes the prepared-but-unused blahaj
`tenants/great-falls-tool-bus/secrets/` lane for overlay-consumed secrets.
Transport-consumed DKIM private keys are the explicit carve-out: they live in
the Blahaj substrate custody lane and are recorded here only by public Secret
name/key.

The public site repo's `secrets.contract.yaml` remains the names-only
public contract; this file is the private-side inventory of what actually
lives (or will live) here. No values, hostnames, or key material in this
README — ever.

| Name | Purpose | Consumed by |
| --- | --- | --- |
| `cloudflare-api-token-gftb-zones` | Account-owned CF API token for the edge stack: zone-scoped to exactly greatfallstoolbus.org + latoolb.us for Zone: DNS Edit, Dynamic Redirect Edit, and Access: Apps and Policies Edit, plus narrow house-account scope for Access: Organizations, Identity Providers, and Groups Edit (needed for Google Workspace SSO IdP creation; TIN-2385 narrowed the pre-TIN-2385 `Account: Zone Create` shape — zones are console-created now; mint/rotation: `docs/runbooks/edge-token-and-zones.md`). Current display token: `gftb-zones-edge-2026-07-08-account`; the prior broad user token `gftb-zones-edge` was revoked after replacement. Same value as the protected `edge` environment secret `CLOUDFLARE_API_TOKEN_GFTB_ZONES` | `just edge-zones-plan` / `just edge-zones-apply` (`TF_VAR_cloudflare_api_token`) |
| `cloudflare-api-token-gftb-pages` | CF API token, ACCOUNT-scoped to the house account with EXACTLY one permission: Account: Cloudflare Pages Edit (ADR 0003 doctrine extension, approved 2026-07-03; mint/rotation: `docs/runbooks/edge-token-and-zones.md` step 2b). NO zone permissions — DNS/redirect/Access stay behind `cloudflare-api-token-gftb-zones`. Same value as the site repo secret `CLOUDFLARE_API_TOKEN_GFTB_PAGES` | CF Pages project create / custom-domain attach / wrangler deploys (site repo `Great-Falls-Tool-Bus/greatfallstoolbus.org`) |
| `cf-account-id` | House Cloudflare account id | `TF_VAR_cloudflare_account_id`; site repo secret `CLOUDFLARE_ACCOUNT_ID` (wrangler) |
| `dreamhost-api-key` | Registrar/DNS capture (`domain-list_domains`, `dns-list_records`); optionally `dns-add_record`/`dns-remove_record` for DreamHost-authority records if a future operator decision uses the API path — the API has no registration-NS mutation | `docs/runbooks/edge-token-and-zones.md` registrar capture / panel checks |
| `latoolbus-dkim-private-key` | DKIM signing key for latoolb.us. **Carve-out:** custody is Blahaj substrate-side; this overlay records only `dkim-keys` / `latoolb.us.mail.key` and publishes the public TXT half through the edge stack. | mail substrate + GFTB edge DNS (TIN-2379); not stored in this repo |
| `mail-substrate-ca` | **Public cert material, not a secret value** — the substrate mail CA `ca.crt` (the self-signed "Blahaj Mail CA" root, key `ca.crt`) that signs the postfix :587 STARTTLS cert. Namespace `latoolb-us-production` Secret, referenced by name only; created by the operator from the substrate `mail-tinyland-dev-tls` Secret's `ca.crt`. Trust anchor that lets mailman-core + mailman-web verify the postfix endpoint (#74). No private key here. | `deployment-mailman-core.yaml` (both containers, mounted at `/etc/ssl/mail-substrate-ca`, `SSL_CERT_FILE`) |
| `form-altcha-hmac` | HMAC-SHA256 key that signs and verifies the ALTCHA proof-of-work on the `/api/contact` form-handler (TIN-2420 Path B). Namespace `latoolb-us-production` Secret, key `hmac-key`, referenced BY NAME ONLY (`valueFrom.secretKeyRef`, `optional: true`); minted in-cluster by the operator (`docs/runbooks/form-intake.md`), never committed. Not shared with any other consumer; rotate freely (in-flight challenges within the expiry window become invalid, which is benign). | `deployment-form-handler.yaml` (`ALTCHA_HMAC_KEY`) |
| `google-sso-client-id` | OAuth 2.0 client id of the Google Cloud "Web application" credential backing the Google Workspace CF Access IdP (`cf-access-google-sso` runbook). Same value as the protected `edge` environment secret `GOOGLE_SSO_CLIENT_ID`. Not sensitive on its own but paired with the secret below; kept out of git. Unused until `var.enable_google_sso` / the `ENABLE_GOOGLE_SSO` environment variable is `true`. | `just edge-zones-plan` / `just edge-zones-apply` (`TF_VAR_google_sso_client_id`) |
| `google-sso-client-secret` | OAuth 2.0 client secret paired with `google-sso-client-id`. Same value as the protected `edge` environment secret `GOOGLE_SSO_CLIENT_SECRET`. Never committed. Unused until Google SSO is enabled. Rotate/mint per `docs/runbooks/cf-access-google-sso.md`. | `just edge-zones-plan` / `just edge-zones-apply` (`TF_VAR_google_sso_client_secret`) |
| `github-sso-client-id` | OAuth client id of the GitHub OAuth app backing the GitHub CF Access IdP that fronts the DECOUPLED dev + preview gate (`cf-access-dev-preview-and-github-sso` runbook, TIN-2535). Same value as the protected `edge` environment secret `GH_SSO_CLIENT_ID` (the `GH_` prefix, not `GITHUB_`, because GitHub reserves the `GITHUB_` secret/variable prefix). Kept out of git. Unused until `var.enable_github_sso` / the `ENABLE_GITHUB_SSO` environment variable is `true`. | `just edge-zones-plan` / `just edge-zones-apply` (`TF_VAR_github_sso_client_id`) |
| `github-sso-client-secret` | OAuth client secret paired with `github-sso-client-id`. Same value as the protected `edge` environment secret `GH_SSO_CLIENT_SECRET`. Never committed. Unused until GitHub SSO is enabled. Rotate/mint per `docs/runbooks/cf-access-dev-preview-and-github-sso.md`. | `just edge-zones-plan` / `just edge-zones-apply` (`TF_VAR_github_sso_client_secret`) |

Usage shape (operator machine, key in age custody):

```bash
sops exec-env secrets/edge-dns.enc.yaml 'just edge-zones-plan'
```

No file in this directory is created by CI; encryption and decryption are
operator actions.
