# edge-dns execution-time values. Everything here is PUBLIC-BY-DESIGN once
# minted (verification TXT, DKIM public half, DMARC rua). Named credentials
# are NEVER committed — they are env-delivered at run time:
#   CLOUDFLARE_API_TOKEN           (provider auth; tenant sops lane)
#   TF_VAR_cloudflare_account_id   (house account id; tenant sops lane)
#
# Default posture (packet row g REVISED + REV-2, attested 2026-07-02):
# BOTH toggles off — DreamHost stays DNS authority; the plan is empty.
# Flip manage_web_zone only when the operator picks REV-2 path A (apex
# behind Cloudflare Access requires a CF zone). manage_alias_zone is
# expected to stay false (latoolb.us stays DreamHost either way).

# manage_web_zone   = true   # REV-2 path A only (runbook step 1)
# manage_alias_zone = true   # deferred whole-zone migration only — expected false

# Uncomment each value as it is minted; never guess a value. Sources:
# GitHub org settings (verification TXT), TIN-2379 mail-plane mint (DKIM),
# operator decision (DMARC rua).

# github_pages_verification_txt = "<issued-by-github-at-domain-verification>"

# Flip to true only AFTER GitHub Pages issues the custom-domain cert:
# web_records_proxied = true

# dkim_selector     = "<minted-with-key-pair-TIN-2379>"
# dkim_public_key   = "<public-half-only>"
# dmarc_rua_mailbox = "<operator-chosen-report-mailbox>"
