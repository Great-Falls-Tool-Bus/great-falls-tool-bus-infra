variable "manage_web_zone" {
  description = <<-EOT
    Create + manage the greatfallstoolbus.org Cloudflare zone. Default
    false: packet row (g) REVISED keeps DreamHost as DNS authority; flip
    to true ONLY when the operator picks REV-2 path A (move the web zone
    to CF so the apex can sit proxied behind Cloudflare Access for the
    GATED phase). See docs/edge-apply-runbook.md step 1.
  EOT
  type        = bool
  default     = false
}

variable "manage_alias_zone" {
  description = <<-EOT
    Create + manage the latoolb.us Cloudflare zone. Default false and
    expected to STAY false: packet row (g) REVISED says latoolb.us (mail
    MX + redirect) stays DreamHost either way; whole-zone CF migration is
    explicitly deferred. This toggle exists only so that deferred
    decision, if ever taken, lands as a one-line diff.
  EOT
  type        = bool
  default     = false
}

variable "cloudflare_account_id" {
  description = <<-EOT
    House Cloudflare account id (any managed zone sits on the house
    account; the *apply plane* is this overlay). Named cf-account-id in
    secrets/README.md; supply via TF_VAR_cloudflare_account_id at run
    time — never committed. Only needed when a manage_* toggle is on, but
    required input always so the stack fails closed toward the operator.
  EOT
  type        = string
  sensitive   = true
}

variable "github_pages_verification_txt" {
  description = <<-EOT
    Value of the _github-pages-challenge-great-falls-tool-bus TXT record,
    issued in the GitHub org settings custom-domain flow at execution time
    (edge-apply-runbook step 3). Leave null until issued — never guess it.
  EOT
  type        = string
  default     = null
}

variable "web_records_proxied" {
  description = <<-EOT
    Flip the greatfallstoolbus.org apex A set + www CNAME to
    Cloudflare-proxied only AFTER GitHub Pages issues the custom-domain
    certificate. Grey-cloud (false) until then, per the site repo's
    tofu/dns-intent/intent.yaml.
  EOT
  type        = bool
  default     = false
}

variable "dkim_selector" {
  description = <<-EOT
    DKIM selector for latoolb.us, minted together with the key pair on the
    house mail plane (TIN-2379). Leave null until minted — never guess.
  EOT
  type        = string
  default     = null
}

variable "dkim_public_key" {
  description = <<-EOT
    DKIM public key (the p= value) for latoolb.us. Public half only — the
    private half is latoolbus-dkim-private-key, held in this overlay's
    tenant sops lane (secrets/README.md), never in the public site repo.
    Leave null until minted.
  EOT
  type        = string
  default     = null
}

variable "dmarc_rua_mailbox" {
  description = <<-EOT
    DMARC aggregate-report mailbox (rua=mailto:...) for latoolb.us. Must be
    a real, operator-chosen mailbox (TIN-2379 sequencing). Leave null until
    chosen — never guess.
  EOT
  type        = string
  default     = null
}
