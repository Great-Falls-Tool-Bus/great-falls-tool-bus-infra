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
    Default false: this stack's plan is a no-op for mail with defaults,
    matching this stack's carries-no-mail-DNS posture until TIN-2379
    (mail-crs) is applied and the operator has answered D11 (mail
    target: blahaj relay per ADR 010 vs. Google Workspace — OPEN as of
    2026-07-03, see recent DreamHost Google Workspace orders). Do not
    flip to true until D11 is answered AND a DKIM key exists (see
    README.md "mail DNS enable sequence").
  EOT
  type        = bool
  default     = false
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

    D11 IS OPEN (2026-07-03): the operator has recent DreamHost Google
    Workspace orders on file and MAY choose Google Workspace MX
    (aspmx.l.google.com etc.) for latoolb.us instead of the blahaj relay
    — that choice is UNCONFIRMED. Do not enable var.mail_dns_enabled
    (and do not publish MX records) until D11 is answered. If D11
    resolves to Google Workspace, override this variable rather than
    changing the default silently.
  EOT
  type        = string
  default     = "relay.tinyland.dev"
}

variable "mail_dkim_txt" {
  description = <<-EOT
    DKIM TXT record value for selector "mail" on latoolb.us
    (mail._domainkey.latoolb.us), e.g. "v=DKIM1; k=rsa; p=<pubkey>".
    Default "" means no DKIM record is created (count = 0) regardless
    of var.mail_dns_enabled — the key is extracted post mail-crs apply
    (TIN-2379; k8s/mail/latoolb-us-production/maildomain-latoolb-us.yaml
    dkimSelector: mail) and set here explicitly. Selector "mail" must
    match that CR's dkimSelector if it ever changes.
  EOT
  type        = string
  default     = ""
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
