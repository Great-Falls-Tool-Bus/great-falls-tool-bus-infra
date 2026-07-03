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

variable "mail_dns_enabled" {
  description = <<-EOT
    Master gate for the latoolb.us mail DNS records staged below (MX,
    SPF, DMARC, and — separately — DKIM once var.mail_dkim_txt is set).
    Enabled 2026-07-03: the preconditions in README.md "mail DNS enable
    sequence" are met — TIN-2379 mail-crs APPLIED (MailDomain latoolb-us
    + MailAccount keyholders created via run 28683888543), D11 answered
    (self-hosted mail confirmed by the operator; the Google-Workspace
    notion was ambient DreamHost account noise, closed as moot), the
    DKIM key generated + materialized (dkim-keys/latoolb.us.mail.key;
    custody ciphertext blahaj PR #865), and the latoolb.us NS repointed
    to Cloudflare (propagating; CF accepts records on a pending zone,
    they serve on activation).
  EOT
  type        = bool
  default     = true
}

variable "mail_mx_target" {
  description = <<-EOT
    MX content for latoolb.us (priority 10), gated by
    var.mail_dns_enabled. Default is the blahaj mail substrate's public
    MX ingress hostname per ADR 010
    (great-falls-tool-bus-infra/blahaj-infra-boundary docs/architecture/
    decisions/010-tenant-list-engine-smtp-interface.md +
    docs/mail/MAIL_ROUTING_ARCHITECTURE.md: "Internet -> relay.tinyland.dev
    -> BuyVM relay -> honey Postfix"), i.e. relay.tinyland.dev.

    D11 CLOSED 2026-07-03: the operator confirmed self-hosted mail —
    "we do not use google workspace, we are self hosting mail." The MX
    target is the blahaj relay above, as decided in row (e)/ADR 010.
  EOT
  type        = string
  default     = "relay.tinyland.dev"
}

variable "mail_dkim_txt" {
  description = <<-EOT
    DKIM TXT record value for selector "mail" on latoolb.us
    (mail._domainkey.latoolb.us), e.g. "v=DKIM1; k=rsa; p=<pubkey>".
    "" means no DKIM record is created (count = 0) regardless of
    var.mail_dns_enabled. Set 2026-07-03 to the public half of the
    keypair generated per multidomain-mail proposal §4 (selector "mail",
    2048-bit; private key = dkim-keys/latoolb.us.mail.key in-cluster +
    sops custody in blahaj tenants/great-falls-tool-bus/secrets/).
    Selector "mail" must match the MailDomain CR's dkimSelector
    (k8s/mail/latoolb-us-production/maildomain-latoolb-us.yaml).
  EOT
  type        = string
  default     = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAysrM9OU25XpwMPRfJoXLEnYSO64eJM36hzAhTOkk/GtgGI1yf7Xz/DIEtuYP73xe0pR4j9gS/e5feUvauqUnXaFVhQEGpac0ewL31mHDlfDepudLwYXC7vNrX1nkTYBmEhbHh9JKXMRbDOt57USQUAlHFtdZg/paRKGn2m85xQUUUMQ1PoIqgBIjKcue/HsqaPUSbIxEIFl5JkhczWF64gtqP3Il0JyPmSGGlGsXCTRkyNx0DHEah4pOkghoNgv0Gsve6mg/dI4jN/sqPAfq8/1Y2KeJMTl/IGPhC23JdZRo3rAq8PGeuY8rjcyZV3h8hV/GU5ROvX/AoUz6HREg3QIDAQAB"
}

variable "alias_redirect_target" {
  description = <<-EOT
    301 target for latoolb.us + www.latoolb.us. Defaults to the raw
    GitHub Pages project URL; flips to https://greatfallstoolbus.org/
    when the Access gate on the apex opens — a one-line tfvars change,
    no resource churn. Status 2026-07-03 (later): D1=A executed — the
    latoolb.us NS was repointed to Cloudflare in the DreamHost panel
    (registry propagation pending; the zone auto-activates and this
    ruleset starts serving then). The target flip to the apex still
    waits on the Access gate opening (TIN-2421 criteria).
  EOT
  type        = string
  default     = "https://great-falls-tool-bus.github.io/greatfallstoolbus.org/"
}
