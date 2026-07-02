output "web_zone_name_servers" {
  description = "Cloudflare-assigned NS hosts for greatfallstoolbus.org (REV-2 path A only) — the DreamHost panel NS-flip inputs (edge-apply-runbook step 3). Null while the zone is unmanaged."
  value       = var.manage_web_zone ? cloudflare_zone.web[0].name_servers : null
}

output "alias_zone_name_servers" {
  description = "Cloudflare-assigned NS hosts for latoolb.us — null unless the deferred whole-zone migration is ever taken (manage_alias_zone)."
  value       = var.manage_alias_zone ? cloudflare_zone.alias[0].name_servers : null
}
