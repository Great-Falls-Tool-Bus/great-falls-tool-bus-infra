# TIN-2385 posture: zones are added to the house Cloudflare account
# CONSOLE-SIDE (docs/runbooks/edge-token-and-zones.md step 1) and the
# token is zone-scoped, so this stack holds NO cloudflare_zone resources
# and NO account id input — zones are DATA lookups by name, and the
# account id the Access policy needs is read off the zone lookup.
#
# Record surface (site repo tofu/dns-intent reconciled to TIN-2378):
#   greatfallstoolbus.org  apex CNAME (CF-flattened) + www -> var.pages_host,
#                          proxied (CF Pages since the ADR 0003 cutover,
#                          executed 2026-07-03 — see variables.tf)
#   latoolb.us             root+www 301 redirect ruleset (variable target)
# Mail DNS (MX/SPF/DMARC/DKIM) is staged below, ALL gated behind
# var.mail_dns_enabled (default false — no-op plan) pending TIN-2379
# mail-crs apply + D11 (mail target, blahaj relay ADR 010 vs. Google
# Workspace, OPEN 2026-07-03).

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
# The app was created out-of-band on 2026-07-03 and adopted into state via a
# one-time `import` block (run 28673911406); the import block has since been
# removed (PR #18) — CI now manages the resource normally.
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

# --- latoolb.us mail DNS (TIN-2379) — staged, gated OFF by default ----------
# Mirrors the fail-closed shape already codified in the sibling
# tofu/stacks/edge-dns/ stack (alias_mx/alias_spf/alias_dmarc/alias_dkim),
# realized here against the console-created zone this stack looks up.
# ALL records below are gated on var.mail_dns_enabled (default false) —
# plan is a no-op with defaults. D11 IS OPEN (2026-07-03): the blahaj
# relay (ADR 010) vs. Google Workspace MX choice is unconfirmed; do not
# flip var.mail_dns_enabled until D11 is answered. See README.md "mail
# DNS enable sequence".

resource "cloudflare_dns_record" "alias_mx" {
  count = var.mail_dns_enabled ? 1 : 0

  zone_id  = data.cloudflare_zone.alias.zone_id
  name     = local.alias_domain
  type     = "MX"
  content  = var.mail_mx_target # default: blahaj relay ingress, ADR 010 — D11 OPEN, may become Google Workspace
  priority = 10
  proxied  = false
  ttl      = 1
}

# SPF mirrors the sibling edge-dns stack's "v=spf1 mx ~all" (the mx
# mechanism resolves to var.mail_mx_target above, so it authorizes the
# same relay without pinning an IP literal here). The blahaj substrate's
# own per-tenant dhall fragment for latoolb.us
# (blahaj-infra-boundary dhall/fragments/latoolb-us-domain.dhall)
# instead pins the literal BuyVM relay IP: "v=spf1 ip4:45.61.188.177 mx
# ~all" (constants.dhall mailRelay.publicIp). The two are not identical;
# noting the ambiguity per task instruction rather than silently picking
# one — reconcile with the edge-dns stack and the mail-crs apply before
# this is ever enabled with mail_mx_target left at the blahaj relay.
resource "cloudflare_dns_record" "alias_spf" {
  count = var.mail_dns_enabled ? 1 : 0

  zone_id = data.cloudflare_zone.alias.zone_id
  name    = local.alias_domain
  type    = "TXT"
  content = "\"v=spf1 mx ~all\"" # starting SPF; tighten only after quiet DMARC
  ttl     = 1
}

# DMARC: start-observing posture (p=none) per operator instruction.
# rua mailbox is postmaster@latoolb.us here; note the blahaj dhall
# fragment's dmarcRua is dmarc-reports@latoolb.us — divergence is
# intentional (operator-specified), not an oversight.
resource "cloudflare_dns_record" "alias_dmarc" {
  count = var.mail_dns_enabled ? 1 : 0

  zone_id = data.cloudflare_zone.alias.zone_id
  name    = "_dmarc.${local.alias_domain}"
  type    = "TXT"
  content = "\"v=DMARC1; p=none; rua=mailto:postmaster@${local.alias_domain}\""
  ttl     = 1
}

# DKIM: selector "mail" matches k8s/mail/latoolb-us-production/
# maildomain-latoolb-us.yaml dkimSelector and the blahaj dhall fragment.
# Record only materializes once the key is extracted post mail-crs apply
# and var.mail_dkim_txt is set — independent of var.mail_dns_enabled so
# a DKIM-only rollout (key ready before D11 lands) is possible, though
# the enable sequence in README.md recommends flipping mail_dns_enabled
# and setting the DKIM value together.
resource "cloudflare_dns_record" "alias_dkim" {
  count = var.mail_dkim_txt != "" ? 1 : 0

  zone_id = data.cloudflare_zone.alias.zone_id
  name    = "mail._domainkey.${local.alias_domain}"
  type    = "TXT"
  content = "\"${var.mail_dkim_txt}\""
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
