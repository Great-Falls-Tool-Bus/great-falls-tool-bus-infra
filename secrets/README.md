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
| `cloudflare-api-token-gftb-zones` | CF API token, ZONE-scoped to exactly greatfallstoolbus.org + latoolb.us: Zone: DNS Edit + Dynamic Redirect Edit + Access: Apps and Policies Edit (TIN-2385 narrowed the pre-TIN-2385 `Account: Zone Create` shape — zones are console-created now; mint/rotation: `docs/runbooks/edge-token-and-zones.md`). Same value as the protected `edge` environment secret `CLOUDFLARE_API_TOKEN_GFTB_ZONES` | `just edge-zones-plan` / `just edge-zones-apply` (`TF_VAR_cloudflare_api_token`) |
| `cloudflare-api-token-gftb-pages` | CF API token, ACCOUNT-scoped to the house account with EXACTLY one permission: Account: Cloudflare Pages Edit (ADR 0003 doctrine extension, approved 2026-07-03; mint/rotation: `docs/runbooks/edge-token-and-zones.md` step 2b). NO zone permissions — DNS/redirect/Access stay behind `cloudflare-api-token-gftb-zones`. Same value as the site repo secret `CLOUDFLARE_API_TOKEN_GFTB_PAGES` | CF Pages project create / custom-domain attach / wrangler deploys (site repo `Great-Falls-Tool-Bus/greatfallstoolbus.org`) |
| `cf-account-id` | House Cloudflare account id | `TF_VAR_cloudflare_account_id`; site repo secret `CLOUDFLARE_ACCOUNT_ID` (wrangler) |
| `dreamhost-api-key` | Registrar/DNS capture (`domain-list_domains`, `dns-list_records`); optionally `dns-add_record`/`dns-remove_record` for DreamHost-authority records if a future operator decision uses the API path — the API has no registration-NS mutation | `docs/runbooks/edge-token-and-zones.md` registrar capture / panel checks |
| `latoolbus-dkim-private-key` | DKIM signing key for latoolb.us. **Carve-out:** custody is Blahaj substrate-side; this overlay records only `dkim-keys` / `latoolb.us.mail.key` and publishes the public TXT half through the edge stack. | mail substrate + GFTB edge DNS (TIN-2379); not stored in this repo |

Usage shape (operator machine, key in age custody):

```bash
sops exec-env secrets/edge-dns.enc.yaml 'just edge-zones-plan'
```

No file in this directory is created by CI; encryption and decryption are
operator actions.
