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
