variable "cloudflare_api_token" {
  description = <<-EOT
    Cloudflare API token scoped to EXACTLY the two GFTB zones
    (greatfallstoolbus.org + latoolb.us): Zone:DNS:Edit, Zone:Dynamic
    Redirect (Config Rules/Ruleset) Edit, Access: Apps and Policies Edit.
    Never account-wide. Fed as TF_VAR_cloudflare_api_token; in CI it is
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
    CF-proxied; the apex is CF-flattened). Default is the CURRENT GitHub
    Pages project host, so merging this variable is inert — no plan
    diff. The CF Pages cutover value (ADR 0003, site repo
    docs/decisions/0003, operator-approved 2026-07-03) is
    greatfallstoolbus-org.pages.dev. Flip it by setting
    TF_VAR_pages_host at apply time or via a one-line tfvars change,
    ONLY AFTER the CF Pages project exists AND the greatfallstoolbus.org
    custom domain is attached to it — sequencing:
    docs/runbooks/edge-token-and-zones.md step 5.
  EOT
  type        = string
  default     = "great-falls-tool-bus.github.io"
}

variable "alias_redirect_target" {
  description = <<-EOT
    301 target for latoolb.us + www.latoolb.us. Defaults to the raw
    GitHub Pages project URL; flips to https://greatfallstoolbus.org/
    when the Access gate on the apex opens (TIN-2378 cutover) — a
    one-line tfvars change, no resource churn.
  EOT
  type        = string
  default     = "https://great-falls-tool-bus.github.io/greatfallstoolbus.org/"
}
