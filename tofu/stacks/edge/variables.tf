variable "cloudflare_api_token" {
  description = <<-EOT
    Cloudflare API token scoped to EXACTLY the two GFTB zones
    (greatfallstoolbus.org + latoolb.us): Zone:DNS:Edit, Zone:Dynamic
    Redirect (Config Rules/Ruleset) Edit, Access: Apps and Policies Edit.
    account-resource-scoped Access:Apps:Edit (never all-accounts). Fed as TF_VAR_cloudflare_api_token; in CI it is
    the protected-environment secret CLOUDFLARE_API_TOKEN_GFTB_ZONES
    (docs/runbooks/edge-token-and-zones.md), on the operator machine the
    sops-lane credential cloudflare-api-token-gftb-zones. Never committed.
  EOT
  type        = string
  sensitive   = true
}

variable "access_allowed_emails" {
  description = <<-EOT
    Email allowlist for the Cloudflare Access application gating the
    greatfallstoolbus.org apex (packet row g REV-2: gated until public
    un-gating is deliberately flipped). Expansion to Alex/Kate/Joe is a
    one-line append here — no new resources.
  EOT
  type        = list(string)
  default     = ["jess@sulliwood.org"]
}

variable "pages_host" {
  description = <<-EOT
    Host the greatfallstoolbus.org apex + www CNAMEs point at (both
    CF-proxied; the apex is CF-flattened). Default is the LIVE CF Pages
    project host: the ADR 0003 cutover (site repo docs/decisions/0003,
    operator-approved 2026-07-03) was EXECUTED 2026-07-03 — the default
    was flipped to greatfallstoolbus-org.pages.dev (this repo PR #15)
    and apex + www now serve from CF Pages behind the REV-2 Access
    gate. Rollback is a one-line change back to the GitHub Pages host
    (great-falls-tool-bus.github.io) or a TF_VAR_pages_host override at
    apply time — sequencing and verify matrix:
    docs/runbooks/edge-token-and-zones.md step 5.
  EOT
  type        = string
  default     = "greatfallstoolbus-org.pages.dev"
}

variable "alias_redirect_target" {
  description = <<-EOT
    301 target for latoolb.us + www.latoolb.us. Defaults to the raw
    GitHub Pages project URL; flips to https://greatfallstoolbus.org/
    when the Access gate on the apex opens — a one-line tfvars change,
    no resource churn. Status 2026-07-03: TIN-2378 closed Done (NS
    cutover executed for greatfallstoolbus.org), but the latoolb.us NS
    is still DreamHost — the CF zone is undelegated, so this redirect
    ruleset is DORMANT; the target flip waits on the Access gate
    opening, which is a separate pending decision.
  EOT
  type        = string
  default     = "https://great-falls-tool-bus.github.io/greatfallstoolbus.org/"
}
