# `secrets/` — GFTB tenant sops lane (names-only inventory)

Ciphertext for the GFTB tenant lands here as `*.enc.yaml` / `*.enc.json`,
encrypted per the repo-root `.sops.yaml` to the distinct GFTB tenant age
recipient (TIN-2360 row d; private half = operator keys.txt custody). This
lane supersedes the prepared-but-unused blahaj
`tenants/great-falls-tool-bus/secrets/` lane — consumer overlays own their
secret plane.

The public site repo's `secrets.contract.yaml` remains the names-only
public contract; this file is the private-side inventory of what actually
lives (or will live) here. No values, hostnames, or key material in this
README — ever.

| Name | Purpose | Consumed by |
| --- | --- | --- |
| `cloudflare-api-token-gftb-zones` | CF API token, ZONE-scoped to exactly greatfallstoolbus.org + latoolb.us: Zone: DNS Edit + Dynamic Redirect Edit + Access: Apps and Policies Edit (TIN-2385 narrowed the pre-TIN-2385 `Account: Zone Create` shape — zones are console-created now; mint/rotation: `docs/runbooks/edge-token-and-zones.md`). Same value as the protected `edge` environment secret `CLOUDFLARE_API_TOKEN_GFTB_ZONES` | `just edge-zones-plan` / `just edge-zones-apply` (`TF_VAR_cloudflare_api_token`); legacy edge-dns stack (`CLOUDFLARE_API_TOKEN`) |
| `cf-account-id` | House Cloudflare account id | `TF_VAR_cloudflare_account_id` |
| `dreamhost-api-key` | Registrar/DNS capture (`domain-list_domains`, `dns-list_records`); optionally `dns-add_record`/`dns-remove_record` for the DreamHost-authority records (row g REVISED) — the API has no registration-NS mutation | `docs/edge-apply-runbook.md` steps 0/1/5 |
| `latoolbus-dkim-private-key` | DKIM signing key for latoolb.us (public half becomes a DreamHost TXT record per row g REVISED) | mail plane (TIN-2379); stored here, never in the public repo |

Usage shape (operator machine, key in age custody):

```bash
sops exec-env secrets/edge-dns.enc.yaml 'just edge-plan'
```

No file in this directory is created by CI; encryption and decryption are
operator actions.
