output "web_zone_id" {
  description = "Cloudflare zone id for greatfallstoolbus.org (console-created; looked up by name)."
  value       = data.cloudflare_zone.web.zone_id
}

output "alias_zone_id" {
  description = "Cloudflare zone id for latoolb.us (console-created; looked up by name)."
  value       = data.cloudflare_zone.alias.zone_id
}

output "web_zone_name_servers" {
  description = "Cloudflare-assigned NS hosts for greatfallstoolbus.org — the DreamHost registrar NS-repoint inputs (edge-token-and-zones runbook step 4)."
  value       = data.cloudflare_zone.web.name_servers
}

output "alias_zone_name_servers" {
  description = "Cloudflare-assigned NS hosts for latoolb.us — the DreamHost registrar NS-repoint inputs (edge-token-and-zones runbook step 4)."
  value       = data.cloudflare_zone.alias.name_servers
}

output "access_application_aud" {
  description = "Access application AUD tag for the gated apex (verification input for the TIN-2378 curl matrix)."
  value       = cloudflare_zero_trust_access_application.web_apex.aud
}

output "google_sso_idp_id" {
  description = "Cloudflare Access IdP id for the Google Workspace provider, or null when var.enable_google_sso is false. Use it to pin allowed_idps for a Google-only follow-up (see main.tf)."
  value       = one(cloudflare_zero_trust_access_identity_provider.google_sso[*].id)
}
