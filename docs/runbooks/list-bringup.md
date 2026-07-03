# GFTB Mailman 3 list stack bring-up runbook

Tracking: TIN-2380. Contract: blahaj ADR 010 / `docs/contracts/tenant-list-engine-smtp.md`.

This runbook brings up the first-of-kind GFTB mailing-list engine
(GNU Mailman 3 core + Postorius + HyperKitty) for `keyholders@latoolb.us` in
`latoolb-us-production`, and proves it end to end. It does **not** mint DNS
records, DKIM keys, or the substrate postfix transport/`extraDomains` entries.

> **This stack is a DRAFT.** Work the pre-apply gates below in order; several
> are hard blockers that will fail-closed if skipped.

## Component pins (TIN-2380)

| Component | Intended version | Image |
| --- | --- | --- |
| GNU Mailman core | 3.3.10 | `ghcr.io/maxking/mailman-core:0.5` |
| Postorius | 1.3.13 | `ghcr.io/maxking/mailman-web:0.5` |
| HyperKitty | 1.3.12 | `ghcr.io/maxking/mailman-web:0.5` |
| PostgreSQL | 16.4 | `postgres:16.4-alpine` |

`maxking/docker-mailman` ships rolling image tags, not per-Mailman-version
tags; the `0.5` line carries the 3.3.x series. **Pre-apply gate:** pull each
image, confirm it carries the intended component versions
(`mailman-core --version`; the web image's `pip show postorius hyperkitty`),
and replace the tags with immutable `@sha256:` digests in the Deployments.

## Pre-apply gates (hard blockers)

1. **Substrate incoming leg (blahaj PR).** Per ADR 010, list mail only reaches
   this stack once the substrate render carries, for the chosen list domain:
   (a) an Option C `extraDomains` entry (domain admission + DKIM selector), and
   (b) a `transport_maps` line
   `<list-domain> lmtp:[mailman-core.latoolb-us-production.svc.cluster.local]:8024`.
   These are **substrate-owned** and land as one blahaj PR + operator apply.
   The ADR notes the `postfix_transport_config` dhall carrier is a known gap to
   close in that same PR (renders-identical seed). Nothing in this overlay can
   substitute for it.
2. **Apply RBAC scope.** The existing `mail` environment kubeconfig
   (`MAIL_APPLY_KUBECONFIG_B64`) is scoped to `mail.tinyland.dev`
   `MailDomain`/`MailAccount`/`MailAlias` **only** (docs/ci-credentials.md) — it
   **cannot** apply the Deployments, Services, PVCs, ConfigMaps, or
   NetworkPolicies in this stack. Before apply, provision either (a) a broadened
   namespace grant (blahaj PR extending the `latoolb-us-production` grant to
   workload verbs) or (b) a dedicated namespace-scoped list-apply kubeconfig,
   and set it as `GFTB_MAIL_KUBECONFIG` (local) or the workflow secret. The
   `MailAccount` (`lists-bounces`) alone can ride the existing mail lane.
3. **Node CIDR in the NetworkPolicy.** `k8s/list/.../networkpolicy.yaml` admits
   LMTP :8024 from a **PLACEHOLDER** `10.0.0.0/8` block. The substrate postfix
   is host-networked, so LMTP arrives from **node** addresses. Replace the
   placeholder with the real mail-egress node CIDR(s) — source of truth is
   blahaj `dhall/render/mail-honey.dhall` (node CIDRs) / the mail stack's
   `network-policies.tf` node workaround. If the tenant namespace is
   default-deny and this is wrong, the incoming leg fails closed.
4. **Operator-owned Secrets.** Create these in `latoolb-us-production` (no
   values in git):
   - `mailman-db`: `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB=mailman`,
     `DATABASE_URL_CORE` (`postgres://<user>:<pw>@mailman-postgres:5432/mailman`),
     `DATABASE_URL_WEB` (`postgres://<user>:<pw>@mailman-postgres:5432/mailmanweb`).
   - `mailman-app`: `DJANGO_SECRET_KEY`, `HYPERKITTY_API_KEY`,
     `MAILMAN_REST_PASSWORD`, `MAILMAN_ADMIN_PASSWORD`.
   - `lists-bounces-smtp`: key `username` set to `lists-bounces@latoolb.us`,
     and key `password` set to the controller-generated `MailAccount`
     credential. Project it from the account controller's output after the
     `lists-bounces` `MailAccount` reconciles; do not hand-mint it.
5. **Extra-config include hook.** `mailman-core` renders the `[mta]` block
   (STARTTLS + SASL + LMTP :8024) via an initContainer into an emptyDir mounted
   at `/etc/mailman-extra`, wired through `MM_EXTRA_CONFIG`. Confirm the pinned
   image honors `MM_EXTRA_CONFIG`; if not, mount the rendered
   `mailman-extra.cfg` at the image's actual include path (values unchanged).

## Bring-up order

1. Apply the substrate PR (gate 1) and confirm the domain resolves at the MX.
2. `just list-stack-validate` — offline invariants + `kubectl kustomize`.
3. Create the operator Secrets (gate 4).
4. Apply the `lists-bounces` `MailAccount` (mail lane), wait for the controller
   to generate its credential, project it into `lists-bounces-smtp` (gate 4).
5. `GFTB_MAIL_KUBECONFIG=... just list-stack-server-dry-run` with the
   workload-capable kubeconfig (gate 2).
6. `... just list-stack-apply`.
7. Wait for `mailman-postgres`, then `mailman-core`, then `mailman-web` to be
   Ready (order enforced by readiness, not hard deps).
8. In Postorius, create the `keyholders@latoolb.us` list; set Jess as
   owner/moderator; set the archive policy to **public**.

## Round-trip smoke (proof)

1. Subscribe a test address (or Jess) to `keyholders@latoolb.us` via Postorius.
2. Send a message **to** `keyholders@latoolb.us` from an external mailbox.
   - Confirms the substrate MX → transport-map → `mailman-core` LMTP :8024
     incoming leg.
3. Confirm the list **fans the message out** to subscribers.
   - Confirms the outgoing runner → `postfix:587` STARTTLS + SASL submission,
     and (check headers) a valid `DKIM-Signature: d=latoolb.us` added by the
     substrate rspamd milter (capability #5 — the real DKIM go/no-go, not the
     controller's cosmetic `DKIMReady`).
4. Confirm the message appears in the public archive.

## HyperKitty public archive URL shape

Per TIN-2380, the public archive for the list is served at:

```text
https://lists.latoolb.us/archives/list/keyholders@latoolb.us/
```

HyperKitty is mounted at `/hyperkitty` inside `mailman-web`; the house tunnel
route exposes it under the `/archives` prefix (the docker-mailman nginx
convention). Public exposure of this URL rides the Cloudflare tunnel as a
**follow-up** (route intent declared GFTB-side, TIN-2380 Anubis note); nothing
is publicly exposed until the round-trip smoke above passes.

## Post-apply read-only checks

```bash
kubectl --kubeconfig "$GFTB_MAIL_KUBECONFIG" -n latoolb-us-production get deploy,svc,pvc,networkpolicy
kubectl --kubeconfig "$GFTB_MAIL_KUBECONFIG" -n latoolb-us-production get mailaccount lists-bounces
kubectl --kubeconfig "$GFTB_MAIL_KUBECONFIG" -n latoolb-us-production logs deploy/mailman-core --tail=50
```
