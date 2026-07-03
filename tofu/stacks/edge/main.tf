# TIN-2385 posture: zones are added to the house Cloudflare account
# CONSOLE-SIDE (docs/runbooks/edge-token-and-zones.md step 1) and the
# token is zone-scoped, so this stack holds NO cloudflare_zone resources
# and NO account id input — zones are DATA lookups by name, and the
# account id the Access policy needs is read off the zone lookup.
#
# Record surface (site repo tofu/dns-intent reconciled to TIN-2378):
#   greatfallstoolbus.org  apex CNAME (CF-flattened) + www -> var.pages_host,
#                          proxied (GH Pages today; CF Pages after the
#                          ADR 0003 cutover flip — see variables.tf)
#   latoolb.us             root+www 301 redirect ruleset (variable target)
# NO mail DNS records here — TIN-2379 owns those (MX/SPF/DKIM/DMARC).

locals {
  web_domain   = "greatfallstoolbus.org"
  alias_domain = "latoolb.us"
}

data "cloudflare_zone" "web" {
  filter = {
    name = local.web_domain
  }
}

data "cloudflare_zone" "alias" {
  filter = {
    name = local.alias_domain
  }
}

# --- greatfallstoolbus.org — canonical site domain ---------------------------

# Apex CNAME: Cloudflare flattens apex CNAMEs automatically (RFC 1034
# apex constraint is satisfied by CF's CNAME flattening), so the apex can
# track the Pages host instead of pinning the 185.199.108-111.153 A set.
# Proxied from day one: the Access gate (below) requires the apex orange-
# clouded, and the proxy terminates TLS while the Pages custom-domain
# certificate issues.
resource "cloudflare_dns_record" "web_apex" {
  zone_id = data.cloudflare_zone.web.zone_id
  name    = local.web_domain
  type    = "CNAME"
  content = var.pages_host
  proxied = true
  ttl     = 1
}

resource "cloudflare_dns_record" "web_www" {
  zone_id = data.cloudflare_zone.web.zone_id
  name    = "www.${local.web_domain}"
  type    = "CNAME"
  content = var.pages_host
  proxied = true
  ttl     = 1
}

# --- Access gate for the apex (packet row g REV-2) ---------------------------
# The live apex serves GATED behind Cloudflare Access until public
# un-gating is deliberately flipped. Allowlist: var.access_allowed_emails
# (jess@sulliwood.org today; Alex/Kate/Joe are a one-line expansion).

resource "cloudflare_zero_trust_access_application" "web_apex" {
  zone_id          = data.cloudflare_zone.web.zone_id
  name             = "greatfallstoolbus.org apex gate (REV-2)"
  domain           = local.web_domain
  type             = "self_hosted"
  session_duration = "24h"

  policies = [{
    id         = cloudflare_zero_trust_access_policy.web_apex_allow.id
    precedence = 1
  }]
}

# www gets its own Access application sharing the apex allowlist policy.
# CF Pages serves www.greatfallstoolbus.org as its own custom domain (no
# implicit www->apex redirect like GitHub Pages did), so without this the
# www hostname would be an ungated public surface during the REV-2 gated
# phase. Additive: leaves the apex application untouched.
resource "cloudflare_zero_trust_access_application" "web_www" {
  zone_id          = data.cloudflare_zone.web.zone_id
  name             = "greatfallstoolbus.org www gate (REV-2)"
  domain           = "www.${local.web_domain}"
  type             = "self_hosted"
  session_duration = "24h"

  policies = [{
    id         = cloudflare_zero_trust_access_policy.web_apex_allow.id
    precedence = 1
  }]
}

# CF Pages serves greatfallstoolbus-org.pages.dev (production + *.preview) on
# Cloudflare's own zone, so it cannot be gated by a zone-bound Access app; this
# is an ACCOUNT-level self_hosted app covering the pages.dev origin, sharing the
# apex allowlist policy. Gates the last public surface during the REV-2 phase.
# The `import` block adopts the app created out-of-band on 2026-07-03 so CI
# manages it with no ungated window (remove the import block after first apply).
resource "cloudflare_zero_trust_access_application" "pages_dev" {
  account_id          = data.cloudflare_zone.web.account.id
  name                = "GFTB pages.dev gate (REV-2)"
  type                = "self_hosted"
  self_hosted_domains = ["greatfallstoolbus-org.pages.dev", "*.greatfallstoolbus-org.pages.dev"]
  session_duration    = "24h"

  policies = [{
    id         = cloudflare_zero_trust_access_policy.web_apex_allow.id
    precedence = 1
  }]
}

import {
  to = cloudflare_zero_trust_access_application.pages_dev
  id = "${data.cloudflare_zone.web.account.id}/a792bcb9-d0d0-4d1f-a797-69ffdc035d8c"
}

# Reusable Access policies are account-level API objects; the account id
# is read from the zone lookup, never committed. The token's Access
# permission is granted on the account resource but the policy gates only
# the apex application above — see the token-mint caveat in
# docs/runbooks/edge-token-and-zones.md step 2.
resource "cloudflare_zero_trust_access_policy" "web_apex_allow" {
  account_id = data.cloudflare_zone.web.account.id
  name       = "GFTB apex allowlist"
  decision   = "allow"

  include = [
    for email in var.access_allowed_emails : {
      email = {
        email = email
      }
    }
  ]
}

# --- latoolb.us — redirect alias (role: redirect only in THIS stack) ---------
# Proxied records exist solely so the redirect ruleset has something to
# answer on; 192.0.2.1 is RFC 5737 documentation space — the proxy
# answers before origin resolution. Mail records (MX/SPF/DKIM/DMARC) are
# deliberately absent: TIN-2379 owns them.

resource "cloudflare_dns_record" "alias_apex" {
  zone_id = data.cloudflare_zone.alias.zone_id
  name    = local.alias_domain
  type    = "A"
  content = "192.0.2.1"
  proxied = true
  ttl     = 1
}

resource "cloudflare_dns_record" "alias_www" {
  zone_id = data.cloudflare_zone.alias.zone_id
  name    = "www.${local.alias_domain}"
  type    = "CNAME"
  content = local.alias_domain
  proxied = true
  ttl     = 1
}

resource "cloudflare_ruleset" "alias_redirect" {
  zone_id = data.cloudflare_zone.alias.zone_id
  name    = "GFTB alias redirect"
  kind    = "zone"
  phase   = "http_request_dynamic_redirect"

  rules = [{
    expression  = "(http.host eq \"${local.alias_domain}\") or (http.host eq \"www.${local.alias_domain}\")"
    description = "latoolb.us alias -> ${var.alias_redirect_target} (TIN-2378; flips to the apex when the Access gate opens)"
    action      = "redirect"
    enabled     = true
    action_parameters = {
      from_value = {
        status_code = 301
        target_url = {
          value = var.alias_redirect_target
        }
        preserve_query_string = false
      }
    }
  }]
}
