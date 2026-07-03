# GFTB edge: zones, zone-scoped token, NS repoint (operator console runbook)

**TIN-2378 prep + TIN-2385 (zone-scoped CF token in this repo's
protected environment).** This runbook is the console/registrar half of
[`tofu/stacks/edge/`](../../tofu/stacks/edge/README.md) — everything
here is an **operator action**; no agent session mutates Cloudflare,
DreamHost, or GitHub settings. Doctrine:
[`docs/mvp-decision-packet.md`](../mvp-decision-packet.md) (row g
REVISED + REV-2 — the gated apex moves to a CF zone; this runbook is the
TIN-2385 realization of that path) and the substrate-boundary memo
(greatfallstoolbus.org `docs/decisions/0002`). Secret **names only** —
no values, ever.

Sibling runbook: [`docs/edge-apply-runbook.md`](../edge-apply-runbook.md)
(the pre-TIN-2385 `edge-dns/` stack, zone-creating + fail-closed). When
this runbook executes, that stack's `manage_*` toggles stay `false` —
see the stack README for the reconciliation rules.

## Registrar facts (whois, captured 2026-07-02 — TIN-2378 open question)

| Domain | Registrar | Created | Expires | NS (current) |
| --- | --- | --- | --- | --- |
| `greatfallstoolbus.org` | DreamHost, LLC (IANA 431) | 2026-06-29 | **2027-06-29** | ns1/ns2/ns3.dreamhost.com |
| `latoolb.us` | eNom, LLC (IANA 48 — DreamHost's .us registrations resolve through its eNom channel; managed from the DreamHost panel) | 2026-06-29 | **2027-06-29** | ns1/ns2/ns3.dreamhost.com |

Both expire 2027-06-29 — set a renewal reminder well before June 2027.
Registrar-side management for BOTH is the DreamHost panel; whois'ing
`latoolb.us` shows eNom because that is DreamHost's .us registry channel,
not a second vendor to manage.

## 1. Add both zones to the house Cloudflare account (console)

Cloudflare dashboard → house account → **Add a site**, once for
`greatfallstoolbus.org` and once for `latoolb.us` (Free plan; skip the
record-import wizard — records are managed by `tofu/stacks/edge/`, and
DreamHost currently serves zero records on both zones per the
edge-apply-runbook step-0 baseline). Each zone sits `pending` and shows
its two assigned Cloudflare nameservers — note them for step 4.

Posture note (TIN-2385): default is **same-account + zone-scoped token**
— the blast radius control is the token scope, not a separate account.
An entirely separate GFTB Cloudflare account is a possible stricter
variant (harder tenant isolation, but a second login/billing/audit
surface and no house-zone reuse); if the operator prefers it, create the
account first and do steps 1–3 there instead — the stack is
account-agnostic (it reads the account id off the zone lookup, never
from config).

## 2. Mint the zone-scoped API token (console)

Dashboard → My Profile → API Tokens → **Create Custom Token**:

- Permissions:
  - Zone → **DNS → Edit**
  - Zone → **Dynamic Redirect → Edit** (the redirect-rules ruleset
    phase; on older dashboards this appears under Config Rules /
    Zone Rulesets)
  - Zone → **Access: Apps and Policies → Edit**
- Zone Resources: **Include → Specific zone →** `greatfallstoolbus.org`
  **and** `latoolb.us` — EXACTLY these two; never "All zones".
- No account-level permission groups, no TTL-unbounded client IP
  allowances beyond house norms.

Caveat to verify at mint time: the stack's Access **policy** is a
reusable (account-level) API object even though the **application** is
zone-level. If the first `just edge-zones-plan`/apply returns a 403 on
the policy call, add the narrowest account-scope Access permission
(Account → Access: Apps and Policies → Edit) to this token — scoped to
the house account resource only — and record that exception here. Do
not broaden any other permission.

## 3. Store the token as a protected-environment secret (console)

Repo Settings → Environments → **`edge`** (create it if absent):

- Protection: required reviewer = the operator; no self-review bypass.
- Environment secret: **`CLOUDFLARE_API_TOKEN_GFTB_ZONES`** = the token
  value from step 2. Name only anywhere in Git; the value lives ONLY in
  this environment (and, for operator-machine use, the sops-lane
  credential `cloudflare-api-token-gftb-zones` — `secrets/README.md`).
- Consumed by [`edge-plan.yml`](../../.github/workflows/edge-plan.yml)
  as `TF_VAR_cloudflare_api_token`. Until the secret exists the workflow
  skips green with a notice (house skip-green idiom).

Rotation: quarterly, or immediately on suspicion — mint a replacement
token (step 2), overwrite the environment secret and the sops-lane copy,
then **Roll** (revoke) the old token in the CF dashboard. No config
change is needed; nothing in Git references the value.

## 4. Repoint nameservers at DreamHost (registrar panel)

`whois` first (re-verify the table above still holds), then DreamHost
panel → **Domains → Registrations** → manage nameservers, per domain:
replace `ns1/ns2/ns3.dreamhost.com` with the two Cloudflare-assigned
hosts from step 1. The DreamHost API has **no registration-NS mutation**
— this is panel-only. Pre-stage records first: run the stack
(`just edge-zones-plan` / CI plan, then operator-gated apply) BEFORE the
NS flip so the cutover is atomic; records added while `pending` activate
with the zone.

Sequencing per TIN-2378: the site repo's `static/CNAME` +
`BASE_PATH=""` precondition must be merged before the apex points at
Pages, and the `alias_redirect_target` variable stays at its raw-Pages
default until the Access gate is verified working (then flip it to
`https://greatfallstoolbus.org/` in a one-line PR).

## 5. Verification matrix (TIN-2378)

```bash
# NS cutover took (expect the two assigned CF hosts per zone)
dig NS greatfallstoolbus.org +short @1.1.1.1
dig NS latoolb.us +short @1.1.1.1

# Apex + www resolve through the CF proxy (expect CF anycast IPs, flattened apex)
dig A greatfallstoolbus.org +short @1.1.1.1
dig CNAME www.greatfallstoolbus.org +short @1.1.1.1
dig A latoolb.us +short @1.1.1.1

# Access gate: expect 302 to <team>.cloudflareaccess.com, NOT the site
curl -sI https://greatfallstoolbus.org/ | sed -n '1p;/^location/Ip'
curl -sI https://www.greatfallstoolbus.org/ | sed -n '1p;/^location/Ip'

# latoolb.us 301s (expect Location: the alias_redirect_target value)
curl -sI http://latoolb.us/ | sed -n '1p;/^location/Ip'
curl -sI https://latoolb.us/ | sed -n '1p;/^location/Ip'
curl -sI https://www.latoolb.us/ | sed -n '1p;/^location/Ip'

# Origin still healthy independent of the edge
curl -sI https://great-falls-tool-bus.github.io/greatfallstoolbus.org/ | sed -n '1p'

# NO mail records materialized by this stack (TIN-2379 owns them)
dig MX latoolb.us +short @1.1.1.1   # empty until TIN-2379
dig MX greatfallstoolbus.org +short @1.1.1.1   # empty, and stays empty (row a)
```

Exit: hand back to the site repo's `docs/runbooks/dns-mail-checklist.md`
for the operator-facing what+verify surface; mail records continue in
TIN-2379.
