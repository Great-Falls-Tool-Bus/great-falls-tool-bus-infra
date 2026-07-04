# GFTB Mailman 3 list stack bring-up runbook

Tracking: TIN-2380. Contract: blahaj ADR 010 / `docs/contracts/tenant-list-engine-smtp.md`.

This runbook brings up the first-of-kind GFTB mailing-list engine
(GNU Mailman 3 core + Postorius + HyperKitty) for `keyholders@latoolb.us` in
`latoolb-us-production`, and proves it end to end. `keyholders@latoolb.us` is
the private access-gating role list. It is not the future public discussion
list; that later surface is expected to be `discuss@latoolb.us` or equivalent.
This runbook does **not** mint DNS records, DKIM keys, or the substrate postfix
transport/`extraDomains` entries.

> **Current state (2026-07-04):** stack objects are applied, all three PVCs are
> Bound on `local-path-retain`, and `mailman-postgres`, `mailman-core`, and
> `mailman-web` are Ready. `keyholders@latoolb.us` exists in Mailman with
> private archive policy, moderated subscription, accepted non-member posts, and
> no public advertisement. No members/owners have been added yet. The transport
> cutover remains gated; the substrate transport lines are staged but commented
> out, so `keyholders@` still resolves to the plain mailbox until the operator
> declares cutover.

## Readiness status (checked 2026-07-04, session 1f91b703)

Read-only check against PR #27's review comment (5 named pre-apply gates) and
blahaj substrate truth. No applies, no cluster mutation happened for this
check.

1. **Mail substrate certified (SPF+DKIM both directions). CLEARED.** Done
   2026-07-04; `keyholders@latoolb.us` is live.
2. **Substrate transport for list addresses. STAGED, NOT ACTIVE.** Blahaj PR
   #875 landed recipient-scoped transport lines for the `keyholders@` family,
   but they are deliberately commented out. The cutover is a separate operator
   act: uncomment the recipient-scoped lines, render/apply the substrate, then
   retire the plain Dovecot mailbox. Do not use a domain-wide `latoolb.us`
   route.
3. **Dovecot/controller bridge (blahaj #872 defect 3). PARTIALLY MITIGATED.**
   TIN-2379 proved bidirectional mail with SPF and DKIM pass after a reviewed
   mail-stack apply. Keep #872 open for durable controller/secret convergence;
   do not treat the cosmetic `MailDomain.status.DKIMReady=False` as the list
   go/no-go by itself. The list smoke must verify real outbound DKIM headers.
4. **Validator parity. CLEARED.** `scripts/validate-list-stack.sh` already
   enforces the same class of rule `validate-mail-crs.sh` enforces for
   `MailDomain` (no operator-only field committed): it asserts no
   `passwordSecretRef` on the `lists-bounces` `MailAccount` (lines 49-52),
   the LMTP port/host, and the SMTP submission host/port, then runs
   `kubectl kustomize`. It is wired into `list-crs.yml` on every PR/push
   touching `k8s/list/**` and it already passed in CI ("Validate list
   stack", pass, 3m13s).
5. **Server dry-run before apply. CLEARED FOR CURRENT MANIFEST SHAPE.** The
   2026-07-04 server dry-run caught missing NetworkPolicy RBAC and wrong secret
   resourceNames; blahaj PR #876 records the RBAC correction. Later live
   bring-up caught three more manifest truths now guarded by validation:
   Honey needs explicit `local-path-retain` PVCs, docker-mailman uses
   `MAILMAN_HOSTNAME` as the internal core host while public identity belongs in
   `SERVE_FROM_DOMAIN`, and mailman-web serves HTTP on port 8000, not 8080.

Distance to first test: add the first owner/subscriber addresses with consent,
then perform the operator-approved transport cutover and round-trip smoke. The
cutover is still held until list ownership/membership is configured.

## Keyholders list policy (operator-decided 2026-07-04)

`keyholders@latoolb.us` is the private access-gating role list. It federates
keyholders through their own mail clients and addresses so any keyholder can pick
up an access request. It is not a shared IMAP inbox and not a public discussion
list.

Required list settings:

- **Archive:** private/members-only, or disabled. Never public. Access requests
  may contain names, contact details, tool needs, and location/scheduling
  context.
- **Membership:** owner-approved / curated. A person is subscribed when they
  become a keyholder; random self-subscription is not accepted.
- **Non-member posts:** accepted or moderated-through so first-contact access
  requests from strangers reach the keyholders. Rspamd and Mailman moderation
  are the spam/abuse controls.
- **Future public list:** `discuss@latoolb.us` is the right place for open
  subscription and public HyperKitty archives when that work is explicitly
  started. Do not give `keyholders@` public-archive semantics.

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
   `MailDomain`/`MailAccount`/`MailAlias` **only** (docs/ci-credentials.md), so it
   **cannot** apply the Deployments, Services, PVCs, ConfigMaps, or
   NetworkPolicies in this stack. Before apply, provision either (a) a broadened
   namespace grant (blahaj PR extending the `latoolb-us-production` grant to
   workload verbs) or (b) a dedicated namespace-scoped list-apply kubeconfig,
   and set it as `GFTB_MAIL_KUBECONFIG` (local) or the workflow secret. The
   `MailAccount` (`lists-bounces`) alone can ride the existing mail lane.
3. **Node CIDR in the NetworkPolicy.** `k8s/list/.../networkpolicy.yaml` admits
   LMTP :8024 from a **PLACEHOLDER** `10.0.0.0/8` block. The substrate postfix
   is host-networked, so LMTP arrives from **node** addresses. Replace the
   placeholder with the real mail-egress node CIDR(s); source of truth is
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

1. `just list-stack-validate` (offline invariants + `kubectl kustomize`).
2. If PVCs are not yet bound, apply the storageClassName fix and confirm the
   three PVCs bind.
3. Wait for `mailman-postgres`, then `mailman-core`, then `mailman-web` to be
   Ready (order enforced by readiness, not hard deps).
4. Create the `keyholders@latoolb.us` list; set archive policy to
   **private/members-only or off**; set subscription to owner-approved; accept
   or moderate non-member posts so access requests reach keyholders.
5. Add the first owner/subscriber addresses only after consent; do not subscribe
   people just because the list exists.
6. Smoke list configuration without transport cutover where possible.
7. Only after explicit operator go: uncomment the staged recipient-scoped
   substrate transport lines for the `keyholders@` family, render/apply the
   substrate, and retire the plain mailbox.

## Round-trip smoke (proof)

1. Subscribe a test address (or Jess) to `keyholders@latoolb.us` via Postorius.
2. Send a message **to** `keyholders@latoolb.us` from an external mailbox.
   - Confirms the substrate MX → transport-map → `mailman-core` LMTP :8024
     incoming leg.
3. Confirm the list **fans the message out** to subscribers.
   - Confirms the outgoing runner → `postfix:587` STARTTLS + SASL submission,
     and (check headers) a valid `DKIM-Signature: d=latoolb.us` added by the
     substrate rspamd milter (capability #5, the real DKIM go/no-go, not the
     controller's cosmetic `DKIMReady`).
4. Confirm the message appears in the private/member-visible archive, or confirm
   archive-disabled behavior if the operator chose archive off.

## HyperKitty private archive URL shape

Per TIN-2380, the private keyholders archive, if enabled, is served at:

```text
https://lists.latoolb.us/archives/list/keyholders@latoolb.us/
```

HyperKitty is mounted at `/hyperkitty` inside `mailman-web`; the house tunnel
route exposes it under the `/archives` prefix (the docker-mailman nginx
convention). This keyholders archive must require membership/login or stay off.
A future `discuss@latoolb.us` list can carry the public archive semantics.

## First-tester plan (merged PR #27 to a subscribed external tester)

Ordered steps from a merged PR #27 to `jess@sulliwood.org` (plus a second
external address) subscribed to `keyholders@latoolb.us`, with a round-trip list
message and a private/members-only HyperKitty archive entry or archive-disabled
proof. Each step is tagged with who executes it.

1. **[done 2026-07-04]** Bound storage by applying explicit
   `local-path-retain` storageClassName to the three PVCs.
2. **[done 2026-07-04]** Brought the three deployments Ready. Runtime fixes
   discovered during bring-up: core needed a 2Gi first-start memory cap;
   `MAILMAN_HOSTNAME` must be the internal `mailman-core` host; web HTTP is on
   container port 8000.
3. **[done 2026-07-04]** Created `keyholders@latoolb.us` in Mailman with
   `archive_policy=private`, `subscription_policy=moderate`,
   `default_nonmember_action=accept`, and `advertised=False`.
4. **[operator]** Confirm the pinned image versions and replace the
   `maxking/docker-mailman` tags with `@sha256` digests (Component pins,
   above).
5. **[agent]** `just list-stack-validate` (already passing) then
   `just list-stack-render` to confirm the kustomize build is still clean
   after any manifest changes.
6. **[operator]** Add first owner/subscriber addresses with consent.
7. **[operator]** Explicitly approve the transport cutover. Until then,
    `keyholders@` remains the plain mailbox and no list-family LMTP route is
    active.
8. **[operator/tester]** Send a message to `keyholders@latoolb.us` from one
    of the subscribed external addresses (round-trip smoke, see below).
9. **[agent]** Collect the smoke evidence: `mailman-core` logs showing the
    LMTP delivery, the fanned-out message headers (`DKIM-Signature:
    d=latoolb.us`), and the private/member-visible HyperKitty archive entry at
    `https://lists.latoolb.us/archives/list/keyholders@latoolb.us/`.

The transport cutover is the point of no return for the current plain mailbox;
do not bundle it with storage or readiness fixes.

## Post-apply read-only checks

```bash
kubectl --kubeconfig "$GFTB_MAIL_KUBECONFIG" -n latoolb-us-production get deploy,svc,pvc,networkpolicy
kubectl --kubeconfig "$GFTB_MAIL_KUBECONFIG" -n latoolb-us-production get mailaccount lists-bounces
kubectl --kubeconfig "$GFTB_MAIL_KUBECONFIG" -n latoolb-us-production logs deploy/mailman-core --tail=50
```
