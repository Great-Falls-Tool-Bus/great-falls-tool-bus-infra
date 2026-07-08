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
    un-gating is deliberately flipped). Supply this at plan/apply time from
    protected operator custody, for example:
    TF_VAR_access_allowed_emails='["operator@example.org"]'. Do not commit
    personal allowlist addresses.
  EOT
  type        = list(string)
}

variable "pages_host" {
  description = <<-EOT
    Host the greatfallstoolbus.org apex + www CNAMEs point at (both
    CF-proxied; the apex is CF-flattened). Default is the ON-CLUSTER
    origin: the shared honey-ingress Cloudflare Tunnel cname target,
    routing to the adapter-node web Deployment in
    greatfallstoolbus-org-production (site ADR 0010 + Amendment 1;
    cutover 2026-07-06 — web-stack apply run 28767572897 put 2/2
    replicas Ready on /health, and the tunnel carries public hostnames
    for apex + www -> the web Service). The REV-2 Access gate is
    host-scoped and unaffected by this origin change. History: ADR 0003
    pointed this at CF Pages (greatfallstoolbus-org.pages.dev,
    2026-07-03, PR #15); ADR 0010 retired the Pages lane, and ADR 0010
    Amendment 2 (TIN-2560, 2026-07-07) closed the cutover-rollback
    window early -- the greatfallstoolbus-org Pages project itself is
    DELETED (workflow run 28801030150, 2026-07-06). Flipping this
    variable back to "greatfallstoolbus-org.pages.dev" is NOT a valid
    rollback anymore -- that hostname resolves to nothing; doing so
    would point the apex at a dead origin. The real rollback is
    on-cluster: re-dispatch this repo's web-stack.yml
    (workflow_dispatch, confirm=apply, image=<prior known-good
    digest>) to roll the Deployment back to a previously-served image
    -- sequencing: docs/runbooks/oncluster-web-cutover.md P7. (Variable
    name kept for continuity; renaming to web_origin_host is a
    follow-up.)
  EOT
  type        = string
  default     = "da3ffda2-68ee-46d1-aa55-ec8dae2bd471.cfargotunnel.com"
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

variable "forms_dns_enabled" {
  description = <<-EOT
    Master gate for the forms.latoolb.us contact-form ingress CNAME
    (TIN-2420 Path B). When true, forms.latoolb.us is a PROXIED CNAME to
    the shared honey-ingress Cloudflare Tunnel cname target
    da3ffda2-68ee-46d1-aa55-ec8dae2bd471.cfargotunnel.com (tunnel id per
    Great-Falls-Tool-Bus/blahaj-infra-boundary PR #908 recon), routing the
    site form POST through the tunnel to the in-cluster intake handler
    behind the Anubis gate.

    ACTIVE since 2026-07-05: the route, handler, LMTP fan-out, and live smoke
    passed before this default flipped. Keep this true only while those proofs
    remain current; rollback is an operator-reviewed plan/apply that sets this
    false and removes the CNAME. Activation/rollback sequence: README.md
    "forms.latoolb.us DNS enable sequence".
  EOT
  type        = bool
  default     = true
}

variable "archives_dns_enabled" {
  description = <<-EOT
    Master gate for the lists.latoolb.us public-archive ingress CNAME
    (TIN-2528). When true, lists.latoolb.us is a PROXIED CNAME to the
    SAME shared honey-ingress Cloudflare Tunnel cname target
    da3ffda2-68ee-46d1-aa55-ec8dae2bd471.cfargotunnel.com used by the
    forms route, routing browser traffic through the tunnel to the
    in-cluster anubis-archive PoW gate, which fronts the HyperKitty web
    tier (k8s/archive/latoolb-us-production/) serving the PUBLIC discuss@
    archive.

    Defaults FALSE (fail-closed, mirroring var.forms_dns_enabled's
    original shape). Merging the record changes nothing until this flag is
    flipped in a follow-up, so activation stays an operator-reviewable
    plan/apply (dispatch-apply doctrine, D6), not a merge side effect.

    UNIQUE TO THIS ROUTE — do NOT flip true until the PRIVACY PRE-FLIGHT
    passes: one HyperKitty instance serves BOTH lists path-based off this
    one host, so exposing lists.latoolb.us also exposes the web tier that
    serves the PRIVATE keyholders@ archive. Preconditions: keyholders@
    archive_policy=private|never AND HyperKitty (>= 1.3.8, the RSS-feed
    private-leak fix) enforces it for anonymous users, verified read-only.
    Flip sequence + the full pre-flight: tofu/stacks/edge/README.md
    "archives DNS enable sequence" and docs/discuss-archive-packet.md.
  EOT
  type        = bool
  default     = true
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

variable "enable_google_sso" {
  description = <<-EOT
    Master gate for the Google Workspace SSO identity provider added to the
    CF Access account in main.tf (cloudflare_zero_trust_access_identity_provider
    "google_sso", type "google-apps"). Defaults FALSE (fail-closed): with it
    false the IdP resource has count = 0, so merging changes NOTHING (no-op
    plan). Flip to true ONLY after the operator has created the Google Cloud
    OAuth 2.0 Web client and stored its id/secret in the edge-environment
    secrets referenced by var.google_sso_client_id / var.google_sso_client_secret
    (docs/runbooks/cf-access-google-sso.md; README.md "Google Workspace SSO
    enable sequence"). Additive: the existing One-Time-PIN IdP and the apps'
    empty allowed_idps mean BOTH Google and OTP work once this is enabled.
  EOT
  type        = bool
  default     = false
}

variable "google_sso_apps_domain" {
  description = <<-EOT
    Google Workspace primary domain the "google-apps" IdP restricts sign-in to.
    Used only when var.enable_google_sso is true. Defaults to the operator's
    Workspace domain sulliwood.org. Set to a different Workspace primary domain
    if the OAuth client belongs to another tenant.
  EOT
  type        = string
  default     = "sulliwood.org"
}

variable "google_sso_client_id" {
  description = <<-EOT
    OAuth 2.0 client id of the Google Cloud "Web application" credential backing
    the Google Workspace IdP. Supply at plan/apply time from operator custody as
    the edge-environment secret GOOGLE_SSO_CLIENT_ID (fed as
    TF_VAR_google_sso_client_id); on the operator machine, the sops-lane
    credential google-sso-client-id. NEVER committed. "" (the default) plus
    var.enable_google_sso = false means the IdP is not created.
  EOT
  type        = string
  sensitive   = true
  default     = ""
}

variable "google_sso_client_secret" {
  description = <<-EOT
    OAuth 2.0 client secret paired with var.google_sso_client_id. Supply at
    plan/apply time from operator custody as the edge-environment secret
    GOOGLE_SSO_CLIENT_SECRET (fed as TF_VAR_google_sso_client_secret); on the
    operator machine, the sops-lane credential google-sso-client-secret. NEVER
    committed. "" (the default) plus var.enable_google_sso = false means the IdP
    is not created.
  EOT
  type        = string
  sensitive   = true
  default     = ""
}
