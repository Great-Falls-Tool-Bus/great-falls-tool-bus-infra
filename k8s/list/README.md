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

### Submission-capability transition

The currently working Mailman sender uses an exact, named Postfix NetworkPolicy
compatibility peer. The `latoolb-us-production` Namespace/domain authorization
remains a cluster-side security grant; the GFTB tenant apply identity cannot
self-grant or widen it.

Do not add `mail.tinyland.dev/submission-client=true` directly to the static
Mailman Deployment. Once generic submission admission is active, a capable
Deployment and its Pod template must also carry
`mail.tinyland.dev/application-mail-projection=true` and the fresh binding for
the current runtime configuration, observation generation, controller
revision, full/Postfix projection hashes and immutable snapshot, and the
Postfix/Dovecot ready revisions. Static YAML cannot safely pin that rotating
state.

TIN-3061 owns the future GFTB protected renderer that must inject and apply that
complete binding. A separate Blahaj change may remove the named compatibility
peer only after the bound workload is admitted and Ready, the substrate
acknowledgement is converged, and cross-node STARTTLS/SASL policy is proven
before `DATA`.

Secrets are referenced by name only and are operator-owned (see
`docs/runbooks/list-bringup.md`): `mailman-db`, `mailman-app`,
`lists-bounces-smtp`.

```bash
just list-stack-validate
GFTB_MAIL_KUBECONFIG=/path/to/list-apply.kubeconfig just list-stack-server-dry-run
GFTB_MAIL_KUBECONFIG=/path/to/list-apply.kubeconfig just list-stack-apply
```

> **Applied stack, operator-gated changes only.** The first bring-up happened
> on 2026-07-04. Future changes must pass `just list-stack-validate`, then
> server dry-run and apply through the protected namespace-scoped kubeconfig.
