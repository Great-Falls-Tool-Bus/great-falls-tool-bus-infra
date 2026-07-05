# Apply-plane realization of the declare-only intent in
# Great-Falls-Tool-Bus/greatfallstoolbus.org:
#   tofu/dns-intent/intent.yaml  (zones, records, redirect rule)
#   tofu/mail-intent/intent.yaml (mail-domain posture; MX target only here)
#
# The site repo declares; THIS overlay applies. But the packet is newer
# than the site repo's intent files: docs/mvp-decision-packet.md row (g)
# REVISED + REV-2 (operator-attested 2026-07-02) says DreamHost STAYS DNS
# authority for both domains; only the GATED apex phase moves
# greatfallstoolbus.org to a CF zone (Cloudflare Access requires the apex
# proxied on a CF zone); latoolb.us stays DreamHost either way. So every
# resource here is toggle-gated and the default plan is EMPTY — fail
# closed until the operator picks the REV-2 path (runbook step 1).

locals {
  web_domain   = "greatfallstoolbus.org"
  alias_domain = "latoolb.us"

  # GitHub Pages apex A set (grey-cloud until the Pages custom-domain
  # certificate issues).
  github_pages_apex_a = [
    "185.199.108.153",
    "185.199.109.153",
    "185.199.110.153",
    "185.199.111.153",
  ]
}

resource "cloudflare_zone" "web" {
  count = var.manage_web_zone ? 1 : 0

  name = local.web_domain
  type = "full"
  account = {
    id = var.cloudflare_account_id
  }
}

# Row (g) REVISED: latoolb.us stays on DreamHost NS either way; this zone
# exists ONLY for the explicitly deferred whole-zone migration decision.
resource "cloudflare_zone" "alias" {
  count = var.manage_alias_zone ? 1 : 0

  name = local.alias_domain
  type = "full"
  account = {
    id = var.cloudflare_account_id
  }
}

# --- greatfallstoolbus.org — canonical site domain (role: web) -------------
# NO mail records on the web domain in the MVP window (row a).

resource "cloudflare_dns_record" "web_apex_a" {
  for_each = var.manage_web_zone ? toset(local.github_pages_apex_a) : toset([])

  zone_id = cloudflare_zone.web[0].id
  name    = local.web_domain
  type    = "A"
  content = each.value
  proxied = var.web_records_proxied
  ttl     = 1
}

resource "cloudflare_dns_record" "web_www" {
  count = var.manage_web_zone ? 1 : 0

  zone_id = cloudflare_zone.web[0].id
  name    = "www.${local.web_domain}"
  type    = "CNAME"
  content = "great-falls-tool-bus.github.io"
  proxied = var.web_records_proxied
  ttl     = 1
}

# GitHub org custom-domain verification TXT — value issued by GitHub at
# execution time (runbook step 4); gated until then.
resource "cloudflare_dns_record" "web_pages_verification" {
  count = (var.manage_web_zone && var.github_pages_verification_txt != null) ? 1 : 0

  zone_id = cloudflare_zone.web[0].id
  name    = "_github-pages-challenge-great-falls-tool-bus.${local.web_domain}"
  type    = "TXT"
  content = "\"${var.github_pages_verification_txt}\""
  ttl     = 1
}

# REV-2 note: the Cloudflare Access application + policy that gate the
# apex are added to THIS stack when
# the operator picks REV-2 path A (runbook step 1) — they are not
# pre-authored here because path B (gated CF preview host on an existing
# house zone) needs no resources in this stack at all.

# --- latoolb.us — mail + redirect alias (role: mail-and-redirect-alias) ----
# DORMANT by default (row g REVISED: stays DreamHost). Kept as the
# codified target shape for the deferred whole-zone migration only.
# Never a second site repo (row a).

resource "cloudflare_dns_record" "alias_apex_a" {
  count = var.manage_alias_zone ? 1 : 0

  zone_id = cloudflare_zone.alias[0].id
  name    = local.alias_domain
  type    = "A"
  content = "192.0.2.1" # RFC 5737 documentation space; the proxy answers first
  proxied = true
  ttl     = 1
}

resource "cloudflare_dns_record" "alias_www" {
  count = var.manage_alias_zone ? 1 : 0

  zone_id = cloudflare_zone.alias[0].id
  name    = "www.${local.alias_domain}"
  type    = "CNAME"
  content = local.alias_domain
  proxied = true
  ttl     = 1
}

resource "cloudflare_dns_record" "alias_mx" {
  count = var.manage_alias_zone ? 1 : 0

  zone_id  = cloudflare_zone.alias[0].id
  name     = local.alias_domain
  type     = "MX"
  content  = "relay.tinyland.dev" # house public MX target; never proxied
  priority = 10
  proxied  = false
  ttl      = 1
}

resource "cloudflare_dns_record" "alias_spf" {
  count = var.manage_alias_zone ? 1 : 0

  zone_id = cloudflare_zone.alias[0].id
  name    = local.alias_domain
  type    = "TXT"
  content = "\"v=spf1 mx ~all\"" # starting SPF; tighten only after quiet DMARC
  ttl     = 1
}

# DKIM public half — selector + key pair minted on the mail plane
# (TIN-2379); the private key lives ONLY in this overlay's tenant sops
# lane, named latoolbus-dkim-private-key. Gated until minted.
resource "cloudflare_dns_record" "alias_dkim" {
  count = (var.manage_alias_zone && var.dkim_selector != null && var.dkim_public_key != null) ? 1 : 0

  zone_id = cloudflare_zone.alias[0].id
  name    = "${var.dkim_selector}._domainkey.${local.alias_domain}"
  type    = "TXT"
  content = "\"v=DKIM1; k=rsa; p=${var.dkim_public_key}\""
  ttl     = 1
}

# DMARC monitor-only to start; tighten after clean reports. Gated on a
# real, operator-chosen rua mailbox.
resource "cloudflare_dns_record" "alias_dmarc" {
  count = (var.manage_alias_zone && var.dmarc_rua_mailbox != null) ? 1 : 0

  zone_id = cloudflare_zone.alias[0].id
  name    = "_dmarc.${local.alias_domain}"
  type    = "TXT"
  content = "\"v=DMARC1; p=none; rua=mailto:${var.dmarc_rua_mailbox}\""
  ttl     = 1
}

# MTA-STS: deferred (site intent: mta_sts: deferred) — do not add here
# until the mail plane ships it.

resource "cloudflare_ruleset" "alias_redirect" {
  count = var.manage_alias_zone ? 1 : 0

  zone_id = cloudflare_zone.alias[0].id
  name    = "GFTB alias redirect"
  kind    = "zone"
  phase   = "http_request_dynamic_redirect"

  rules = [{
    expression  = "(http.host eq \"latoolb.us\") or (http.host eq \"www.latoolb.us\")"
    description = "latoolb.us alias -> canonical site (TIN-2360 row a)"
    action      = "redirect"
    enabled     = true
    action_parameters = {
      from_value = {
        status_code = 301
        target_url = {
          value = "https://greatfallstoolbus.org/"
        }
        preserve_query_string = false
      }
    }
  }]
}
