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
just form-stack-render      # kubectl kustomize
```

The `form-crs.yml` lane runs both on PR/push. It is offline only; live server
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

Through Anubis (after exposure), a browser first solves the PoW challenge, then
the same POST reaches the handler. `curl` without solving the challenge gets the
Anubis interstitial, not `{"ok":true}` — that is the gate working.

Expected result on success: every address subscribed to `keyholders@latoolb.us`
receives the contact message, `Reply-To` set to the visitor so a keyholder can
reply directly.

## Rollback

Delete the two Deployments (the gate and the handler); the tunnel route can be
left or removed:

```bash
kubectl --context honey -n latoolb-us-production delete deploy anubis form-handler
# full teardown of the stack:
kubectl --context honey -n latoolb-us-production delete -k k8s/form/latoolb-us-production
```

Removing the Cloudflare public-hostname route (gate 3) instantly stops all
internet reach regardless of pod state. The reciprocal list-stack netpol rule is
harmless to leave (it only admits a pod that no longer exists); remove it on a
full revert of this change.

## Notes

- **Single replica** for both pods: the handler's token bucket is in-memory
  (5/min/client) and Anubis auto-generates an ephemeral ed25519 signing key at
  startup (v1.13.0 has no key env). A restart only re-taxes in-flight visitors
  with a fresh PoW; benign for a contact form.
- **Difficulty** is `DIFFICULTY=4` (modest): near-instant for a real visitor,
  still a bulk-bot tax. Raise if abuse appears.
- Anti-bot is layered: Anubis PoW is the primary gate (only Anubis is
  tunnel-reachable, enforced by NetworkPolicy), with the token bucket and
  honeypot as defense-in-depth.
