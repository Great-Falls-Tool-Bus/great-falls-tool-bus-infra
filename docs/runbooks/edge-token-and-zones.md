# GFTB edge: zones, CF tokens, NS repoint, CF Pages cutover (operator console runbook)

**TIN-2378 prep + TIN-2385 (zone-scoped CF token in this repo's
workflow_dispatch-gated environment) + the ADR 0003 CF Pages cutover
(operator-approved 2026-07-03).** This runbook is the console/registrar
half of [`tofu/stacks/edge/`](../../tofu/stacks/edge/README.md), token
mints, zone adds, NS repoints, and secret stores are **operator
actions**; the CF Pages project setup in step 5 is the one agent-driven
exception, and it runs under the account-scoped Pages:Edit token only
(the token doctrine extension approved with ADR 0003, no agent session
touches DNS, redirects, or Access via that token). Doctrine:
[`docs/mvp-decision-packet.md`](../mvp-decision-packet.md) (row g
REVISED + REV-2, the gated apex moves to a CF zone; this runbook is the
TIN-2385 realization of that path), the substrate-boundary memo
(greatfallstoolbus.org `docs/decisions/0002`), and the CF Pages cutover
ADR (greatfallstoolbus.org `docs/decisions/0003`). Secret **names
only**, no values, ever.

Sibling runbook: [`docs/edge-apply-runbook.md`](../edge-apply-runbook.md)
(the pre-TIN-2385 `edge-dns/` stack, zone-creating + fail-closed). When
this runbook executes, that stack's `manage_*` toggles stay `false`, see the stack README for the reconciliation rules.

## Registrar facts (whois, captured 2026-07-02, TIN-2378 open question)

| Domain | Registrar | Created | Expires | NS (current) |
| --- | --- | --- | --- | --- |
| `greatfallstoolbus.org` | DreamHost, LLC (IANA 431) | 2026-06-29 | **2027-06-29** | ns1/ns2/ns3.dreamhost.com |
| `latoolb.us` | eNom, LLC (IANA 48, DreamHost's .us registrations resolve through its eNom channel; managed from the DreamHost panel) | 2026-06-29 | **2027-06-29** | ns1/ns2/ns3.dreamhost.com |

Both expire 2027-06-29, set a renewal reminder well before June 2027.
Registrar-side management for BOTH is the DreamHost panel; whois'ing
`latoolb.us` shows eNom because that is DreamHost's .us registry channel,
not a second vendor to manage.

## 1. Add both zones to the house Cloudflare account (console)

Cloudflare dashboard → house account → **Add a site**, once for
`greatfallstoolbus.org` and once for `latoolb.us` (Free plan; skip the
record-import wizard, records are managed by `tofu/stacks/edge/`, and
DreamHost currently serves zero records on both zones per the
edge-apply-runbook step-0 baseline). Each zone sits `pending` and shows
its two assigned Cloudflare nameservers, note them for step 4.

Posture note (TIN-2385): default is **same-account + zone-scoped token**, the blast radius control is the token scope, not a separate account.
An entirely separate GFTB Cloudflare account is a possible stricter
variant (harder tenant isolation, but a second login/billing/audit
surface and no house-zone reuse); if the operator prefers it, create the
account first and do steps 1–3 there instead, the stack is
account-agnostic (it reads the account id off the zone lookup, never
from config).

## 2. Mint the two API tokens (console)

Two tokens, two blast radii, never one token with both shapes.
Dashboard → My Profile → API Tokens → **Create Custom Token**, once per
token:

### 2a. Zone-scoped token (the tofu stack's credential)

- Permissions, EXACTLY these three:
  - Zone → **DNS → Edit**
  - Zone → **Dynamic Redirect → Edit** (the redirect-rules ruleset
    phase; on older dashboards this appears under Config Rules /
    Zone Rulesets)
  - Zone → **Access: Apps and Policies → Edit**
- Zone Resources: **Include → Specific zone →** `greatfallstoolbus.org`
  **and** `latoolb.us`, EXACTLY these two; never "All zones".
- No account-level permission groups, no TTL-unbounded client IP
  allowances beyond house norms.

### 2b. Account-scoped Pages token (ADR 0003 doctrine extension, approved 2026-07-03)

- Permissions, EXACTLY one:
  - Account → **Cloudflare Pages → Edit**
- Account Resources: **Include → Specific account →** the house account
  only.
- NO zone permission groups of any kind, this token can create/deploy
  Pages projects and attach custom domains, and nothing else. DNS,
  redirects, and Access stay exclusively behind the zone-scoped token
  (2a) and its operator-gated apply plane.

Caveat to verify at mint time (token 2a): the stack's Access **policy**
is a reusable (account-level) API object even though the
**application** is zone-level. If the first `just edge-zones-plan`/apply
returns a 403 on the policy call, add the narrowest account-scope
Access permission (Account → Access: Apps and Policies → Edit) to the
**zone-scoped token (2a)**, scoped to the house account resource
only, and record that exception here. Do not broaden any other
permission, and never add it to the Pages token (2b).

## 3. Store the tokens as GitHub secrets (operator)

Names only anywhere in Git, the commands below prompt for the value on
stdin; never pass values as arguments or paste them into a transcript.

**Zone-scoped token (2a)** → this repo's protected **`edge`**
environment (Repo Settings → Environments → `edge`, create it if
absent). NOTE: this is a **free community org**, required-reviewer and
branch-policy environment protection are GitHub paid-plan features and are
**deliberately not used** (operator decision 2026-07-03). The apply gate is
**workflow_dispatch `action=apply`** (the workflow never applies on push/PR);
do not set a deployment-branch policy (main is unprotected, so it would block
the dispatch-apply):

```bash
gh secret set CLOUDFLARE_API_TOKEN_GFTB_ZONES --env edge --repo Great-Falls-Tool-Bus/great-falls-tool-bus-infra
```

Consumed by [`edge-plan.yml`](../../.github/workflows/edge-plan.yml) as
`TF_VAR_cloudflare_api_token`. Until the secret exists the workflow
skips green with a notice (house skip-green idiom). Operator-machine
copy: the sops-lane credential `cloudflare-api-token-gftb-zones`
(`secrets/README.md`).

**Account-scoped Pages token (2b)** → the public site repo, where the
wrangler deploy workflow runs (plus the account id wrangler requires, an identifier we still keep out of Git, per house norms):

```bash
gh secret set CLOUDFLARE_API_TOKEN --repo Great-Falls-Tool-Bus/greatfallstoolbus.org
gh secret set CLOUDFLARE_ACCOUNT_ID --repo Great-Falls-Tool-Bus/greatfallstoolbus.org
```

Operator-machine copy of the Pages token: the sops-lane credential
`cloudflare-api-token-gftb-pages` (`secrets/README.md`; account id:
existing `cf-account-id` entry).

Rotation (both tokens): quarterly, or immediately on suspicion, mint a
replacement token (step 2), overwrite the GitHub secret and the
sops-lane copy, then **Roll** (revoke) the old token in the CF
dashboard. No config change is needed; nothing in Git references the
values.

## 4. Repoint nameservers at DreamHost (registrar panel)

`whois` first (re-verify the table above still holds), then DreamHost
panel → **Domains → Registrations** → manage nameservers, per domain:
replace `ns1/ns2/ns3.dreamhost.com` with the two Cloudflare-assigned
hosts from step 1. The DreamHost API has **no registration-NS mutation**, this is panel-only. Pre-stage records first: run the stack
(`just edge-zones-plan` / CI plan, then operator-gated apply) BEFORE the
NS flip so the cutover is atomic; records added while `pending` activate
with the zone.

Sequencing: the serving-origin cutover is step 5 (CF Pages, ADR 0003).
The `alias_redirect_target` variable stays at its default until the
Access gate is verified working (then flip it to
`https://greatfallstoolbus.org/` in a one-line PR).

Rollback-era note (GH Pages): the pre-ADR-0003 sequence required the
site repo's `static/CNAME` + `BASE_PATH=""` precondition merged before
the apex pointed at GH Pages, and the GitHub **org verified-domain TXT**
record (`docs/edge-apply-runbook.md` verification-TXT step) to bind
`greatfallstoolbus.org` to the org. Leave that TXT record in place, it
is harmless, and it keeps the GH Pages origin a working rollback target
(`pages_host` flip back to the default, step 5).

## 5. CF Pages cutover sequence (ADR 0003, operator-approved 2026-07-03)

The order matters: the Pages project + custom domain must exist BEFORE
the `pages_host` flip, or the apex CNAME points at a `pages.dev` host
that won't serve the site.

1. **Operator: mint + store the account-scoped Pages:Edit token**, steps 2b and 3 above (`CLOUDFLARE_API_TOKEN`,
   `CLOUDFLARE_ACCOUNT_ID` in the site repo).
2. **Agent: create the Pages project + attach the custom domain +
   gate previews.** Under the Pages token only: create project
   `greatfallstoolbus-org` (production branch = the site repo's main;
   serving host `greatfallstoolbus-org.pages.dev`), attach the
   `greatfallstoolbus.org` custom domain to it, and enable the Access
   policy on the `*.greatfallstoolbus-org.pages.dev` preview
   deployments (Pages project → Settings → Access policy) so preview
   URLs are never public. Caveat, same shape as the step-2a caveat: if
   the preview Access enable 403s under Pages:Edit only, the operator
   flips that one toggle console-side, do NOT broaden the token.
3. **Site PR merges**, the site repo's wrangler workflow deploys the
   built site to the project; verify
   `https://greatfallstoolbus-org.pages.dev/` serves before touching
   DNS.
4. **`pages_host` flip applied**, set
   `var.pages_host = "greatfallstoolbus-org.pages.dev"` (apply-time
   `TF_VAR_pages_host` or a one-line tfvars change, [`tofu/stacks/edge/README.md`](../../tofu/stacks/edge/README.md),
   "`pages_host` cutover") and run the operator-gated plan/apply. The
   apex Access gate and the `latoolb.us` redirect are untouched by the
   flip.
5. **Verify matrix**, step 6 below. Rollback: flip `pages_host` back
   to the `great-falls-tool-bus.github.io` default (the org
   verified-domain TXT and the GH Pages deploy stay intact for exactly
   this).

## 6. Verification matrix (TIN-2378 + ADR 0003)

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

# Origin still healthy independent of the edge (the var.pages_host value)
curl -sI https://greatfallstoolbus-org.pages.dev/ | sed -n '1p'
# Rollback-era origin (GH Pages), only meaningful while pages_host is at its default
curl -sI https://great-falls-tool-bus.github.io/greatfallstoolbus.org/ | sed -n '1p'

# NO mail records materialized by this stack (TIN-2379 owns them)
dig MX latoolb.us +short @1.1.1.1   # empty until TIN-2379
dig MX greatfallstoolbus.org +short @1.1.1.1   # empty, and stays empty (row a)
```

Exit: hand back to the site repo's `docs/runbooks/dns-mail-checklist.md`
for the operator-facing what+verify surface; mail records continue in
TIN-2379.
