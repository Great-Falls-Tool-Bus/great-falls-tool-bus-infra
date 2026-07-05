# edge-dns stack — GFTB apply-plane consumption of the site repo's
# declare-only DNS/mail intent (greatfallstoolbus.org tofu/dns-intent +
# tofu/mail-intent). TIN-2360 row (c) as amended 2026-07-02: apply-plane
# consumption lives in THIS consumer overlay, never in the blahaj substrate repo.

terraform {
  required_version = ">= 1.6.0"

  # Configured via -backend-config=tofu/backend/honey-edge-dns.s3.hcl.
  # Archived reference only; no public Justfile recipe currently initializes it.
  backend "s3" {}

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

provider "cloudflare" {
  # Auth comes exclusively from CLOUDFLARE_API_TOKEN in the environment,
  # decrypted at run time from the tenant sops lane (named
  # cloudflare-api-token-gftb-zones in secrets/README.md). Never committed.
}
