# `tofu/stacks/edge/` — GFTB zone stack (TIN-2378 prep + TIN-2385)

The records / Access-gate / redirect surface for the two GFTB zones once
they exist as **console-created zones on the house Cloudflare account**
(same-account + zone-scoped token per TIN-2385). This stack:

- **looks zones up by name** (`data "cloudflare_zone"`) — it never
  creates them; zone add is an operator console step
  ([`docs/runbooks/edge-token-and-zones.md`](../../docs/runbooks/edge-token-and-zones.md)
  step 1)
- manages `greatfallstoolbus.org` apex CNAME (CF-flattened) + `www`
  CNAME → `great-falls-tool-bus.github.io`, proxied
- gates the apex behind a Cloudflare Access application + allow policy
  (allowlist `jess@sulliwood.org`; Alex/Kate/Joe are a one-line
  `access_allowed_emails` expansion) — packet row (g) REV-2
- serves the `latoolb.us` root+`www` 301 redirect ruleset; the target is
  `var.alias_redirect_target`, defaulting to the raw Pages project URL
  (`https://great-falls-tool-bus.github.io/greatfallstoolbus.org/`) and
  flipping to the apex when the Access gate opens
- carries **no mail DNS records** — MX/SPF/DKIM/DMARC are TIN-2379's

Auth is exclusively `TF_VAR_cloudflare_api_token`: a token scoped to
EXACTLY these two zones, held as the protected-environment secret
`CLOUDFLARE_API_TOKEN_GFTB_ZONES` in CI and as the sops-lane credential
`cloudflare-api-token-gftb-zones` on the operator machine
([`secrets/README.md`](../../secrets/README.md)). No account id input:
the account id the Access policy needs is read off the zone lookup.

## Relationship to `tofu/stacks/edge-dns/` (read before touching either)

`edge-dns/` predates TIN-2385 and codifies packet row (g) REVISED +
REV-2 as **zone-creating, fail-closed** (both `manage_*` toggles false;
empty default plan; DreamHost stays DNS authority unless the operator
picks REV-2 path A). THIS stack is the TIN-2385 realization of REV-2
path A with the zone-create step moved console-side and the token
narrowed from `Account: Zone Create` to zone-scoped only — and it
extends path A to `latoolb.us` for the redirect ruleset (records only;
`latoolb.us` mail posture is untouched until TIN-2379). The two stacks
overlap on the web-zone record surface, so they must never both apply:
`edge-dns` `manage_*` toggles stay `false` when this stack is live. If
the operator instead rejects the latoolb.us-on-CF extension, the
redirect half of this stack is dropped and `latoolb.us` redirects stay
DreamHost-side per the edge-dns runbook — that reconciliation is an
explicit operator decision recorded on the PR, not a default.

State: `tofu/backend/honey-edge.s3.hcl` — same bucket/endpoint shape as
the other stacks, key `great-falls-tool-bus-infra/edge/terraform.tfstate`.

## Operating it

```bash
just edge-zones-fmt-check   # formatting
just edge-zones-validate    # init -backend=false + validate (no state, no creds)
just edge-zones-init        # backend: tofu/backend/honey-edge.s3.hcl
just edge-zones-plan        # needs TF_VAR_cloudflare_api_token + backend keys
just edge-zones-plan-show
just edge-zones-apply       # destroy-checked, ALLOW_EDGE_ZONES_DESTROY-gated
```

CI: [`.github/workflows/edge-plan.yml`](../../.github/workflows/edge-plan.yml)
plans on PR/push against the protected `edge` environment and applies
only via `workflow_dispatch` `action=apply`; it skips green with a
notice while `CLOUDFLARE_API_TOKEN_GFTB_ZONES` is unset (the token does
not exist until the runbook's mint step).

Precondition: both zones exist on the house account (console step) —
until then `plan` fails on the zone lookups by design; there is nothing
fail-open to guess.
