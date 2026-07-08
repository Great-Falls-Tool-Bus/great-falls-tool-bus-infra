# TIN-2385 posture: zones are added to the house Cloudflare account
# CONSOLE-SIDE (docs/runbooks/edge-token-and-zones.md step 1) and the
# token is zone-scoped, so this stack holds NO cloudflare_zone resources
# and NO account id input — zones are DATA lookups by name, and the
# account id the Access policy needs is read off the zone lookup.
#
# Record surface (site repo tofu/dns-intent reconciled to TIN-2378):
#   greatfallstoolbus.org  apex CNAME (CF-flattened) + www -> var.pages_host,
#                          proxied (the honey-ingress tunnel / on-cluster web
#                          Deployment since the ADR 0010 cutover, 2026-07-06;
#                          CF Pages 2026-07-03..06 — see variables.tf)
#   latoolb.us             root+www 301 redirect ruleset (variable target)
# Mail DNS (MX/SPF/DMARC/DKIM) is managed below, gated behind
# var.mail_dns_enabled (default true after D11 closed self-hosted and TIN-2379
# mail CRs applied).

locals {
  web_domain           = "greatfallstoolbus.org"
  alias_domain         = "latoolb.us"
  mail_dkim_txt_chunks = var.mail_dkim_txt == "" ? [] : regexall(".{1,255}", var.mail_dkim_txt)
  mail_dkim_content    = join(" ", [for chunk in local.mail_dkim_txt_chunks : "\"${chunk}\""])
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
# supplied from protected operator custody, not committed.

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

# --- Google Workspace SSO identity provider (additive, inert by default) -----
# Adds a Google Workspace ("google-apps") IdP to the CF Access account so the
# operator can sign in with the allowlisted Workspace account instead of the
# fragile 10-minute email One-Time-PIN. This is PURELY ADDITIVE
# and INERT BY DEFAULT:
#
#   * count = var.enable_google_sso ? 1 : 0, and var.enable_google_sso defaults
#     FALSE, so merging this changes NOTHING (no-op plan) until the operator
#     opts in. Flip sequence: tofu/stacks/edge/README.md "Google Workspace SSO
#     enable sequence" and docs/runbooks/cf-access-google-sso.md.
#   * The existing account IdP set already has One-Time-PIN (onetimepin). The
#     three self_hosted apps above (web_apex, web_www, pages_dev) leave
#     allowed_idps unset (= [], meaning ALL IdPs allowed), so once this IdP
#     exists BOTH Google and the OTP path keep working. The OTP path is never
#     removed by this change.
#   * client_id / client_secret come from operator-supplied edge-environment
#     secrets fed as TF_VAR_google_sso_client_id / TF_VAR_google_sso_client_secret.
#     They are declared as sensitive variables with default "" and are NEVER
#     committed. With the flag false they are unused.
#
# Account-level to match the OTP IdP and the shared allow policy above: the
# account id is read off the zone lookup, never committed.
resource "cloudflare_zero_trust_access_identity_provider" "google_sso" {
  count = var.enable_google_sso ? 1 : 0

  account_id = data.cloudflare_zone.web.account.id
  name       = "GFTB Google Workspace SSO"
  type       = "google-apps"

  config = {
    client_id     = var.google_sso_client_id
    client_secret = var.google_sso_client_secret
    apps_domain   = var.google_sso_apps_domain
  }
}

# OPTIONAL Google-only pinning (leave commented for the additive default).
# By default allowed_idps is unset on web_apex / web_www / pages_dev, so both
# Google and OTP work. If the operator later wants Google-ONLY (drop the OTP
# fallback), set allowed_idps on each app to the Google IdP id, for example:
#
#   resource "cloudflare_zero_trust_access_application" "web_apex" {
#     ...
#     allowed_idps = var.enable_google_sso
#       ? [cloudflare_zero_trust_access_identity_provider.google_sso[0].id]
#       : []
#   }
#
# Do this only as a deliberate follow-up once Google sign-in is verified
# working, since pinning to a not-yet-created IdP would lock the operator out.

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

# --- latoolb.us mail DNS (TIN-2379) — staged; enabled after D11 closed -------
# Mirrors the fail-closed shape already codified in the sibling
# tofu/stacks/edge-dns/ stack (alias_mx/alias_spf/alias_dmarc/alias_dkim),
# realized here against the console-created zone this stack looks up.
# MX/SPF/DMARC records remain gated on var.mail_dns_enabled; D11 closed
# self-hosted on 2026-07-03, so this branch flips the default true with
# MX -> relay.tinyland.dev per ADR 010. See README.md "mail DNS enable
# sequence".

resource "cloudflare_dns_record" "alias_mx" {
  count = var.mail_dns_enabled ? 1 : 0

  zone_id  = data.cloudflare_zone.alias.zone_id
  name     = local.alias_domain
  type     = "MX"
  content  = var.mail_mx_target # default: blahaj relay ingress, ADR 010
  priority = 10
  proxied  = false
  ttl      = 1
}

# SPF ambiguity RESOLVED by live evidence (2026-07-04 port25 round-trip,
# session 1f91b703): outbound egresses directly from honey (Source IP
# 71.168.64.84, HELO mail.tinyland.dev), NOT via the BuyVM relay — so
# "v=spf1 mx ~all" softfailed (mx only covers relay.tinyland.dev =
# 45.61.188.177). The working reference is tinyland.dev's own SPF, which
# authorizes BOTH the relay and honey's egress:
#   "v=spf1 ip4:45.61.188.177 ip4:71.168.64.84 mx ~all"
# Mirrored verbatim here. DKIM already passes (selector mail).
resource "cloudflare_dns_record" "alias_spf" {
  count = var.mail_dns_enabled ? 1 : 0

  zone_id = data.cloudflare_zone.alias.zone_id
  name    = local.alias_domain
  type    = "TXT"
  content = "\"v=spf1 ip4:45.61.188.177 ip4:71.168.64.84 mx ~all\"" # tighten ~all only after quiet DMARC
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
# Record only materializes once var.mail_dkim_txt is set to the public
# half of the operator-materialized DKIM key. DKIM is independent of
# var.mail_dns_enabled so a DKIM-only rollout remains possible.
resource "cloudflare_dns_record" "alias_dkim" {
  count = var.mail_dkim_txt != "" ? 1 : 0

  zone_id = data.cloudflare_zone.alias.zone_id
  name    = "mail._domainkey.${local.alias_domain}"
  type    = "TXT"
  content = local.mail_dkim_content
  ttl     = 1
}

# --- forms.latoolb.us — contact-form ingress tunnel CNAME (TIN-2420) ---------
# Path B go-live: the site contact form POSTs to the intake handler, which
# is fronted by Anubis and served out of the cluster over the SHARED
# honey-ingress Cloudflare Tunnel. This record points the form origin
# hostname at that tunnel's cname target so the proxied edge answers and
# the tunnel carries the request to the in-cluster handler.
#
# Tunnel cname target da3ffda2-68ee-46d1-aa55-ec8dae2bd471.cfargotunnel.com
# is the shared honey-ingress tunnel per the blahaj recon in
# Great-Falls-Tool-Bus/blahaj-infra-boundary PR #908 (honey-ingress tunnel
# id da3ffda2-68ee-46d1-aa55-ec8dae2bd471). Proxied so the tunnel route and
# Anubis gate front the handler and TLS terminates at the edge.
#
# Gated behind var.forms_dns_enabled. The default is true only after the
# 2026-07-05 route + live smoke proof; set false for operator-reviewed rollback.
# The tunnel route is Cloudflare-dashboard/token-managed and is NOT represented
# in this stack.
resource "cloudflare_dns_record" "alias_forms" {
  count = var.forms_dns_enabled ? 1 : 0

  zone_id = data.cloudflare_zone.alias.zone_id
  name    = "forms.${local.alias_domain}"
  type    = "CNAME"
  content = "da3ffda2-68ee-46d1-aa55-ec8dae2bd471.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

# --- lists.latoolb.us — public discuss@ archive ingress tunnel CNAME --------
# (TIN-2528, declare-only design packet). Mirrors the forms.latoolb.us record
# above EXACTLY: a PROXIED CNAME to the SAME shared honey-ingress Cloudflare
# Tunnel cname target, so the proxied edge answers and the tunnel carries the
# request to the in-cluster anubis-archive PoW gate, which fronts the
# HyperKitty web tier (k8s/archive/latoolb-us-production/).
#
# Hostname choice = lists.latoolb.us (NOT archives.latoolb.us): the HyperKitty
# archive URL shape is ALREADY documented as
# https://lists.latoolb.us/archives/list/<list>@latoolb.us/ (TIN-2380,
# docs/runbooks/list-bringup.md "HyperKitty private archive URL shape"), and
# ONE HyperKitty instance serves every list path-based off that one host — so
# the host name reflects the whole lists engine, not a single archive. See
# docs/discuss-archive-packet.md for the full rationale.
#
# FAIL-CLOSED: gated behind var.archives_dns_enabled, which DEFAULTS FALSE.
# Merging this record changes NOTHING (no-op plan) until the flag is flipped
# in a deliberate follow-up. Activation stays an operator-reviewable plan/apply
# (dispatch-apply doctrine, D6), never a merge side effect — and, uniquely for
# this route, it must NOT be flipped until the PRIVACY PRE-FLIGHT passes
# (keyholders@ archive_policy=private|never AND HyperKitty enforces it for
# anonymous users). Flip sequence: README.md "archives DNS enable sequence".
resource "cloudflare_dns_record" "alias_archives" {
  count = var.archives_dns_enabled ? 1 : 0

  zone_id = data.cloudflare_zone.alias.zone_id
  name    = "lists.${local.alias_domain}"
  type    = "CNAME"
  content = "da3ffda2-68ee-46d1-aa55-ec8dae2bd471.cfargotunnel.com"
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
