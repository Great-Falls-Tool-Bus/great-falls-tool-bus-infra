# GFTB tenant list stack

This directory contains the tenant-owned **mailing-list engine** for Great
Falls Tool Bus: GNU Mailman 3 core + Postorius + HyperKitty for
`keyholders@latoolb.us` (TIN-2380 — the house's first-of-kind list engine).

It is deployed **overlay-side** into the tenant namespace
`latoolb-us-production` and consumes the blahaj mail substrate through the named
**tenant list-engine SMTP relay contract v0** (blahaj ADR 010):

- **Incoming**: the substrate postfix routes list mail to this stack's LMTP
  listener at `mailman-core.latoolb-us-production.svc.cluster.local:8024`
  (contract capability #4). The transport-map entry that does the routing is a
  **substrate change (blahaj PR)** — it does not live here.
- **Outgoing**: Mailman submits via `postfix.tinyland-dev-production.svc
  .cluster.local:587` (STARTTLS + SASL, contract capabilities #1/#2), using a
  tenant-minted `MailAccount` credential (`lists-bounces@latoolb.us`).
- **DKIM**: signing happens substrate-side via the rspamd milter for the
  registered `latoolb.us` domain (capability #5). No DKIM key material lives in
  this repo.

These manifests intentionally do **not** contain:

- DKIM private keys or DKIM references (substrate-owned)
- password material, `passwordSecretRef`, or any Secret with values
- DNS records
- the postfix transport-map / `extraDomains` entries (substrate-owned)
- a public ingress / Cloudflare tunnel route (follow-up; nothing exposed
  before the round-trip smoke passes)

Secrets are referenced by name only and are operator-owned (see
`docs/runbooks/list-bringup.md`): `mailman-db`, `mailman-app`,
`lists-bounces-smtp`.

```bash
just list-stack-validate
just list-stack-render
GFTB_MAIL_KUBECONFIG=/path/to/list-apply.kubeconfig just list-stack-server-dry-run
GFTB_MAIL_KUBECONFIG=/path/to/list-apply.kubeconfig just list-stack-apply
```

> **DRAFT — reviewable, not applied.** Every pre-apply verification item
> (image digests, controller secret wiring, node CIDRs, the RBAC scope of the
> apply kubeconfig) is listed in `docs/runbooks/list-bringup.md`. Do not apply
> until they are resolved.
