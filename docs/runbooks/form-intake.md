# Contact form intake bring-up (TIN-2420 Path B)

Anubis PoW-gated structured contact intake for `greatfallstoolbus.org`,
delivering over LMTP to the `keyholders@latoolb.us` Mailman list. Founding row
`f` DECIDED the Anubis gate; this runbook does not relitigate that.

```
visitor -> POST https://forms.latoolb.us/api/contact (fetch from the static site)
        -> cloudflared tunnel (token-managed; route lives Cloudflare-side)
        -> anubis           Service :8081  (PoW anti-bot, FIRST house Anubis)
        -> form-handler     Service :8080  (validate + rate-limit + honeypot)
        -> mailman-core LMTP :8024          (inject, no SMTP credential)
        -> keyholders@latoolb.us            (non-member post accepted BY DESIGN)
        -> substrate 587/SASL + DKIM        (fan-out to every keyholder)
```

Manifests: `k8s/form/latoolb-us-production/`. Recipes: `just form-stack-*`.

## Bot policy: unchallenged JSON API, challenged browsing surface

**The wrinkle.** Anubis's proof-of-work is a JavaScript/WASM challenge served as
an HTML interstitial into a *browsing context*. The static site reaches the
handler with a cross-origin `fetch()` POST to `/api/contact`. That fetch
receives the challenge HTML as an opaque response body and **cannot solve it** —
there is no browsing context to run the challenge script, and a programmatic
JSON client can never clear a browser challenge. Left at the built-in default,
Anubis would challenge the form POST (the site's `fetch` sends a `Mozilla` user
agent, which the default `generic-browser` rule CHALLENGEs) and every
submission would fail.

**The decision (Option A, evidenced).** No released Anubis version — through
`v1.17.0` as of 2026-07 — ships a fetch/XHR-solvable challenge (a JSON `401` +
retry-after-solve, or a WASM PoW callable from `fetch`). Upstream's own guidance
for JSON/API callers is to **ALLOW the path**, ordered before the browser
CHALLENGE rule; rules evaluate top-to-bottom and the first terminal match wins,
and `ALLOW` "bypasses all further checks and sends the request to the backend."
So we ship a policy that ALLOWs `/api/contact` and keeps the default browser
challenge for everything else. We did **not** take an "Option C" upgrade: there
is nothing to upgrade *to* that would let the `fetch` solve a challenge, and the
image stays digest-pinned at `v1.13.0`.

`configmap-anubis-policy.yaml` is the upstream `v1.13.0` default policy with one
rule prepended:

```json
{ "name": "gftb-contact-api", "path_regex": "^/api/contact$", "action": "ALLOW" }
```

Mounted read-only at `/etc/anubis/botPolicies.json` and selected with
`POLICY_FNAME` (the `policy-fname` flag; `facebookgo/flagenv` maps it
UPPER_SNAKE with dashes→underscores, the same rule that yields `METRICS_BIND`).
`v1.13.0` parses the policy as **JSON only** (`cmd/anubis/policy.go` decodes with
`encoding/json`; YAML policy support landed in `v1.17.0`), and the rule fields at
this version are `name` / `user_agent_regex` / `path_regex` / `action`. There is
**no request-method matcher** at `v1.13.0` (path matches `r.URL.Path` only), so
the ALLOW is path-scoped, not `POST`-scoped.

**Tradeoff (stated crisply).** With `/api/contact` ALLOWed, **Anubis no longer
gates that one path** — any client can reach the handler on it. The handler's
own controls are therefore the primary defense for the API, all smoke-proven:
honeypot (`website` field), a per-client token bucket (5/min), strict JSON
validation with header-injection sanitising, a 64 KiB body cap, and CORS locked
to `https://greatfallstoolbus.org`. Founding row `f` (the Anubis gate) is
**honored**: every other path on the forms hostname — the browsing surface —
still gets the PoW challenge, so a human pointing a browser at the forms host is
challenged exactly as decided.

Citations:

- TecharoHQ/anubis discussion #1543, "How to bypass challenge for special urls
  (api entries)" — ALLOW `path_regex` ordered before the browser CHALLENGE.
- `docs/docs/admin/policies.mdx` — rule fields and the `ALLOW` semantics
  ("bypass all further checks").
- `cmd/anubis/policy.go` + `cmd/anubis/botPolicies.json` at tag `v1.13.0` —
  JSON-only parser, field set, `r.URL.Path` matching, and the default policy we
  extend.

## Why no SMTP credential

The keyholders list is configured `default_nonmember_action=accept` (ratified:
the fan-out to all keyholders IS the feature). LMTP injection to
`mailman-core:8024` needs no authentication, and the outbound fan-out rides the
existing certified `lists-bounces` 587/SASL + DKIM submission path. The message
is shaped DMARC-safe so the `latoolb.us` DKIM signature (applied substrate-side
on the fan-out leg) aligns:

- `From: "Tool Bus contact form" <form-intake@latoolb.us>`
- `Reply-To:` the visitor's address
- `To: keyholders@latoolb.us`
- `X-GFTB-Form: contact`, `Subject: Tool Bus contact: <name>`
- LMTP envelope sender (Return-Path) `form-intake@latoolb.us`

No `MailAccount` is minted for `form-intake@` — LMTP injection does not use a
mailbox; the domain only needs to align for the fan-out DKIM signature, which
the registered `latoolb.us` `MailDomain` already provides.

## Offline validation (no cluster)

```bash
just form-stack-validate    # invariants: digests, Anubis TARGET, LMTP :8024,
                            # CORS greatfallstoolbus.org, honeypot, netpol shape,
                            # server.py byte-compiles, no committed secret
```

The `form-crs.yml` lane runs this on PR/push. It is offline only; live server
dry-run/apply is a manual `workflow_dispatch` protected by the `mail`
environment.

## Pre-apply gates

1. **Reciprocal LMTP admission (in this change).** `mailman-core` runs
   default-deny ingress. This change adds an ingress rule to
   `k8s/list/latoolb-us-production/networkpolicy.yaml` admitting `8024` from the
   `form-handler` podSelector. Without it the handler's LMTP injection fails
   closed. It is applied by re-applying the list stack (`just list-stack-apply`)
   OR by applying just the updated policy; the form stack apply alone does not
   cover it. **Apply the list-stack netpol update before smoke-testing.**

2. **Workload RBAC.** The existing `MAIL_APPLY_KUBECONFIG_B64` is scoped to
   `mail.tinyland.dev` CRs only and CANNOT create Deployments/Services/
   ConfigMaps/NetworkPolicies. Provision a workload-capable namespace-scoped
   kubeconfig for `latoolb-us-production` (same gate the list stack hit) before
   `just form-stack-apply` will succeed.

3. **Tunnel route (Cloudflare-side, out of band).** The cloudflared tunnel on
   this cluster is TOKEN-managed: the public-hostname -> service ingress map
   lives in the Cloudflare zero-trust dashboard/API, NOT in a ConfigMap in this
   repo (verified read-only 2026-07-04 — the `cloudflared` Deployment runs
   `tunnel run --token $(TUNNEL_TOKEN)`, no local `config.yaml`). Add a
   public-hostname entry:

   - Hostname: `forms.latoolb.us` (or the chosen forms host)
   - Service: `http://anubis.latoolb-us-production.svc.cluster.local:8081`

   Nothing is reachable from the internet until this route is added AND a live
   round-trip smoke passes. Only Anubis is ever exposed; the handler is not.

## Bring-up

```bash
# 1. Reciprocal netpol admission (gate 1) — re-apply the list stack policy.
GFTB_MAIL_KUBECONFIG=/path/to/workload.kubeconfig just list-stack-apply

# 2. Form stack (server dry-run first, then apply).
GFTB_MAIL_KUBECONFIG=/path/to/workload.kubeconfig just form-stack-server-dry-run
GFTB_MAIL_KUBECONFIG=/path/to/workload.kubeconfig just form-stack-apply

# 3. Add the Cloudflare public-hostname route (gate 3).
```

## Smoke test

In-cluster, before exposing (proves the PoW gate + handler + LMTP path). A raw
POST straight at the handler bypasses Anubis and should fan out to keyholders:

```bash
# Exec into any pod in the namespace, or port-forward the handler Service.
kubectl --context honey -n latoolb-us-production port-forward svc/form-handler 8080:8080 &

curl -sS -X POST http://127.0.0.1:8080/api/contact \
  -H 'Content-Type: application/json' \
  -H 'Origin: https://greatfallstoolbus.org' \
  -d '{"name":"Smoke Test","email":"smoke@example.com","message":"ignore me","website":""}'
# expect: {"ok": true}   and a message delivered to every keyholder
```

Honeypot check (non-empty `website` -> silent success, NOTHING sent):

```bash
curl -sS -X POST http://127.0.0.1:8080/api/contact \
  -H 'Content-Type: application/json' \
  -d '{"name":"Bot","email":"bot@example.com","message":"spam","website":"http://x"}'
# expect: {"ok": true}   but NO delivery
```

Through Anubis (after exposure), the `/api/contact` POST is ALLOWed by the bot
policy and reaches the handler **without** a challenge — the site's cross-origin
`fetch` cannot solve a browser PoW, so allowlisting the path is what makes the
form work at all (see "Bot policy" above). To confirm the split is live:

```bash
# API route: ALLOWed -> reaches the handler (a bare curl works; the handler's
# honeypot/rate-limit/CORS are the controls here, not Anubis).
curl -sS -X POST https://forms.latoolb.us/api/contact \
  -H 'Content-Type: application/json' -H 'Origin: https://greatfallstoolbus.org' \
  -d '{"name":"Smoke","email":"smoke@example.com","message":"hi","website":""}'
# expect: {"ok": true}

# Browsing surface: still CHALLENGEd -> a browser-like GET to any other path
# gets the Anubis interstitial HTML, not the handler's 404 JSON. Row f honored.
curl -sS -A 'Mozilla/5.0' https://forms.latoolb.us/ | grep -qi 'anubis\|challenge' \
  && echo "browsing surface challenged (expected)"
```

Expected result on success: every address subscribed to `keyholders@latoolb.us`
receives the contact message, `Reply-To` set to the visitor so a keyholder can
reply directly.

## Rollback

Rollback is operator-controlled. First remove the Cloudflare public-hostname
route; that instantly stops internet reach regardless of pod state. A workload
teardown, if needed, should be performed from the private cluster operations
lane with an explicit recorded decision, not copied from this public runbook.

The reciprocal list-stack netpol rule is harmless to leave (it only admits a
pod that no longer exists); remove it on a full revert of this change.

## Notes

- **Single replica** for both pods: the handler's token bucket is in-memory
  (5/min/client) and Anubis auto-generates an ephemeral ed25519 signing key at
  startup (v1.13.0 has no key env). A restart only re-taxes in-flight visitors
  with a fresh PoW; benign for a contact form.
- **Difficulty** is `DIFFICULTY=4` (modest): near-instant for a real visitor,
  still a bulk-bot tax. Raise if abuse appears.
- Anti-bot is layered: Anubis PoW gates the **browsing surface** (only Anubis is
  tunnel-reachable, enforced by NetworkPolicy). For the ALLOWed `/api/contact`
  route the handler's token bucket, honeypot, validation, and CORS are the
  primary controls — see the "Bot policy" section for the tradeoff.
- **Known Anubis advisories on the pinned `v1.13.0`** (tracked, not blocking):
  both touch features this deployment does not use. GHSA-jhjj-2g64-px7c /
  CVE-2025-54414 (fixed `v1.21.3`) is a crafted redirect on the challenge
  "Try Again" page — reachable only on the challenged browsing surface of a
  low-value forms host, never on the ALLOWed API path. GHSA-cf57-c578-7jvv /
  CVE-2025-64716 (fixed `v1.23.0`) is an XSS in **subrequest-auth** mode, which
  we do not run (Anubis is a reverse proxy via `TARGET`, not an auth subrequest).
  A future digest-re-pinned bump to `>= v1.23.0` is the clean way to clear both;
  it is out of scope for this policy-only change and does not gate go-live.
