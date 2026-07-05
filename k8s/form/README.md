# GFTB contact-intake stack

This directory contains the tenant-owned **contact form intake** for Great Falls
Tool Bus (TIN-2420 Path B). A visitor's contact submission from
`greatfallstoolbus.org` is proof-of-work gated by **Anubis** (the house's first
Anubis deployment), validated by a tiny stdlib-only **form-handler**, and
injected over **LMTP** into the `keyholders@latoolb.us` Mailman list, which fans
out to every keyholder.

```
visitor -> POST https://forms.latoolb.us/api/contact
        -> cloudflared tunnel
        -> anubis (PoW gate, :8081)
        -> form-handler (:8080, validate + rate-limit + honeypot)
        -> LMTP mailman-core.latoolb-us-production.svc.cluster.local:8024
        -> keyholders@latoolb.us  (non-member post accepted BY DESIGN)
        -> substrate 587/SASL + DKIM fan-out to all keyholders
```

Deployed **overlay-side** into `latoolb-us-production`. It reuses the list
stack's LMTP listener and the substrate's certified outbound path — **no SMTP
credential** is minted here (LMTP injection needs none; the list accepts
non-member posts, `default_nonmember_action=accept`).

Mail shape (DMARC-safe):

- **From**: `"Tool Bus contact form" <form-intake@latoolb.us>` (domain aligns
  with `latoolb.us` DKIM signed substrate-side on the fan-out leg)
- **Reply-To**: the visitor's address
- **To**: `keyholders@latoolb.us`
- **X-GFTB-Form**: `contact`; **Subject**: `Tool Bus contact: <name>`

These manifests intentionally do **not** contain:

- any Secret, credential, or SMTP password (LMTP injection needs none)
- the Cloudflare tunnel public-hostname route (Cloudflare-side, token-managed;
  not a ConfigMap in this repo)
- DNS records
- a built/pushed container image (the handler is stdlib `server.py` mounted from
  a ConfigMap onto the digest-pinned upstream `python:3.12-alpine`)

Images are pinned by digest. Anti-bot is layered and split by surface: the
Anubis bot policy (`configmap-anubis-policy.yaml`, mounted via `POLICY_FNAME`)
**ALLOWs** the `/api/contact` JSON route — a cross-origin `fetch()` POST cannot
solve Anubis's browser proof-of-work, so the route is allowlisted and guarded by
the handler's per-client token bucket (5/min), honeypot field, validation, and
CORS — while the **browsing surface stays CHALLENGEd** (founding row `f`). See
`docs/runbooks/form-intake.md` for the policy rationale, the challenge-vs-fetch
evidence, and citations.

```bash
just form-stack-validate
just form-stack-render
GFTB_MAIL_KUBECONFIG=/path/to/form-apply.kubeconfig just form-stack-server-dry-run
GFTB_MAIL_KUBECONFIG=/path/to/form-apply.kubeconfig just form-stack-apply
```

See `docs/runbooks/form-intake.md` for bring-up, the tunnel route, the netpol
reciprocal-admission pre-apply gate, the smoke curl, and rollback.
