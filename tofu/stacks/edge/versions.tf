# edge stack — GFTB zone records, Access gate, and latoolb.us redirects
# (TIN-2378 prep + TIN-2385 implementation). Zones are created CONSOLE-SIDE
# on the house Cloudflare account (same-account + zone-scoped token per
# TIN-2385); this stack only LOOKS THEM UP by name and manages records,
# the apex Access application/policy, and the alias redirect ruleset.
# Superseded sibling stack tofu/stacks/edge-dns/ remains an archived,
# fail-closed zone-creating reference (packet row g REVISED + REV-2); the
# two stacks never both apply record resources — see README.md.

terraform {
  required_version = ">= 1.6.0"

  # Configured via -backend-config=tofu/backend/honey-edge.s3.hcl
  # (just edge-zones-init). State coordinates only — no credentials.
  backend "s3" {}

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

provider "cloudflare" {
  # Zone-scoped token (greatfallstoolbus.org + latoolb.us ONLY — never
  # account-wide), fed as TF_VAR_cloudflare_api_token. In CI it is the
  # protected-environment secret CLOUDFLARE_API_TOKEN_GFTB_ZONES (name
  # only; docs/runbooks/edge-token-and-zones.md); on the operator machine
  # it resolves from the tenant sops lane (secrets/README.md,
  # cloudflare-api-token-gftb-zones). Never committed.
  api_token = var.cloudflare_api_token
}
