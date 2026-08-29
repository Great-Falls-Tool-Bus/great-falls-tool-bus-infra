# Stripe webhook public reachability on staging — design note (TIN-4020 s2)

Status: **DESIGN NOTE, not a decision.** This records the reachability
question the staging Access posture creates for exactly one route and the
recommended answer, grounded in reading the webhook handler's own
verification code (`greatfallstoolbus.org` app repo,
`src/lib/server/stripe/webhook.ts` + `src/routes/api/stripe/webhook/+server.ts`,
TIN-3818). It changes no committed manifest and authorizes no Cloudflare
mutation — the actual Access application and any bypass rule are
dashboard/token-managed, minted at the operator sitting
(`docs/runbooks/staging-platform-serving.md` Step E), same as every other
edge object this repo declares only the *intent* for.

## The conflict

`tofu/intent/great-falls-tool-bus/staging-platform-route.json` and
`docs/runbooks/staging-platform-serving.md` (Step E1) both plan a Cloudflare
**Access application scoped to the whole `staging.greatfallstoolbus.org`
hostname** — staging is private exact-PR/operator QA (TIN-3815), and Access is
explicit that it gates *reachability*, never a substitute for the
application's own auth path underneath it.

Stripe's webhook sender cannot satisfy that gate. It is a server-to-server
HTTPS POST with no browser, no interactive session, and no Access service-token
headers Stripe has any way to attach — Stripe's dashboard has no field for
"send this bearer pair with every delivery." A hostname-wide Access
application would answer Stripe's POST with a 302 to Access's login page (or a
403), Stripe would treat that as a non-2xx, and — per
`docs/runbooks/staging-platform-serving.md`'s own description of the
durability contract — **retry on the same schedule until it exhausts retries
and gives up**, silently starving the durable inbox this route exists to
feed. Standing up staging Access as currently planned and registering the
webhook endpoint with Stripe are mutually exclusive until this is resolved.

## What the handler itself already guarantees

Reading the handler top-to-bottom (`webhook.ts`, `config.ts`, the route):

1. **Raw bytes only, read once.** The route reads
   `request.arrayBuffer()` before any framework body parser touches it,
   because Stripe's signature covers the exact bytes it sent
   (`+server.ts` header comment).
2. **Signature verification is the FIRST gate, before anything else runs.**
   `handleStripeWebhook()` rejects any request with a missing
   `Stripe-Signature` header (400, nothing persisted) and then calls
   `verifyWebhookSignature(rawBody, signatureHeader, webhookSecret)` — an
   HMAC check against `STRIPE_WEBHOOK_SECRET` (`whsec_…`, shape-anchored in
   `config.ts`). Any failure — wrong secret, tampered body, expired
   timestamp, replayed signature outside Stripe's tolerance window — is
   caught and answered 400 with a deliberately generic error body ("signature
   verification failed"); the underlying error message is never echoed, so a
   probe cannot use it to fingerprint *why* it failed.
3. **A second, independent fail-closed check follows.** Even a
   signature-valid event is rejected (400, nothing persisted) unless
   `testModeOnly(event.livemode)` — `gate.ts`'s frozen `LIVE_STRIPE_GATE`,
   which fails closed on a missing or malformed `livemode` field, not just an
   explicit `true` (finding S1 in that module's own header).
4. **Configuration itself fails closed.** `readStripeConfig()` in `config.ts`
   throws on a half-set or live-shaped environment, and the route turns that
   into a 503 with no acknowledgment — Stripe keeps redelivering until the
   deployment is actually configured, rather than the route silently
   swallowing events it cannot process.
5. **Only after all of the above** does the handler persist (dedupe on the
   event's own primary key) and enqueue a projection job, inside one
   transaction, then ack 200.

In short: **the security boundary on this route is already the cryptographic
signature, not network origin.** Nothing about who or what reaches the route
matters to its correctness or safety — only whether the request carries a
valid `Stripe-Signature` computed with the shared `whsec_` secret. That is
true whether the caller is Stripe, a browser, or an anonymous script.

## The two candidate designs

**Option A — IP-allowlist Stripe's published webhook egress ranges.**
Stripe publishes a webhook IP list, and an edge rule could admit only those
ranges to this one path while everything else on the host stays behind
Access. Rejected:

- Stripe's list is not a small static CIDR pinned indefinitely — it is a
  maintained, occasionally-changing set the operator would need to track and
  re-apply by hand (no CI in this repo may auto-apply durable routes, per
  TIN-991's operator-gated posture), which is ongoing operational drift risk
  for a security control.
- An IP allow is not itself authentication. Anything that can reach the
  cluster from an allowed range — a compromised host sharing egress infra
  with Stripe, address-spoofing at a hop the Cloudflare edge cannot see
  through — passes the network check with zero knowledge of `whsec_…` and
  zero ability to produce a valid signature, but every request from an
  allowed range would still need per-request signature verification to be
  handled safely anyway (dead code cannot be trusted as the real gate). The
  IP check would add operational cost without removing or replacing anything
  the app must keep doing regardless.
- It duplicates a boundary the handler already enforces correctly and
  independently of network origin.

**Option B — path-scoped Cloudflare Access bypass for exactly
`/api/stripe/webhook`, relying on the handler's own signature verification as
the sole security boundary. Recommended.**

- This is Stripe's own documented posture for webhook endpoints generally:
  the endpoint is expected to be publicly POST-able, and the signing secret
  is the entire trust mechanism — Stripe does not support putting its
  webhook sender behind any third-party auth gate.
- The handler, read above, already behaves correctly under this exposure: a
  request with no valid signature is refused (400) before any state changes,
  regardless of where it originates. Making the path Access-exempt does not
  weaken anything the handler enforces; it only removes a gate the handler's
  own caller (Stripe) could never have passed in the first place.
- It is the narrowest possible carve-out: an **exact-path** bypass rule
  (`/api/stripe/webhook`, not a prefix, not the whole host) keeps every other
  staging route — the actual product surface under QA — fully behind Access.
  `GET`/other methods on that same path are not part of the app's route
  contract (`+server.ts` exports only `POST`) and answer SvelteKit's default
  405, so a bypass scoped to the path costs nothing beyond what the app
  already refuses on its own.
- No manifest change follows from this in the current PR: NetworkPolicy
  ingress (`allow-cloudflared-tunnel-ingress`) already admits the tunnel to
  the whole web Service on :3000 — Access sits in front of the tunnel route
  at the Cloudflare edge, not inside the cluster, so the bypass is a
  dashboard/token-managed Access-application-rule object, the same
  authority class as the Access application itself (Step E1) and the tunnel
  route (Step E2).

## What this does NOT decide or change

- Live-mode Stripe activation, egress to `api.stripe.com` (still closed —
  `networkpolicy.yaml`'s header, unchanged by this note), and the
  `gftb-platform-stripe-testmode` Secret's minting date all stay exactly
  where the TIN-3818 rails sitting left them: **NOT YET**, deferred.
- Nothing here requires or implies loosening `LIVE_STRIPE_GATE` — Option B is
  about who may knock on the door, never about what the app does once
  someone does.
- The actual Access bypass rule is not created by this change; it is a
  recommendation for the operator's Step E sitting
  (`docs/runbooks/staging-platform-serving.md`), to be minted alongside the
  Access application itself so the two are never live in a state where the
  webhook path is accidentally gated.

## Recommended runbook addition (Step E, not yet applied)

At the same sitting that mints the Access application (Step E1), also mint an
Access **bypass** policy scoped to the exact path
`staging.greatfallstoolbus.org/api/stripe/webhook`, before registering that
URL as a webhook endpoint in the Stripe dashboard — registering the endpoint
first would hand Stripe a URL it cannot yet successfully deliver to, and every
failed delivery counts against Stripe's own retry/backoff budget for that
endpoint.

## Defense-in-depth follow-up (not this sitting)

Because the path is now genuinely internet-reachable (not just
tunnel-internal), a Cloudflare rate-limiting rule scoped to that exact path is
a reasonable operator follow-up — bounding request volume before it reaches
the signature check costs Stripe nothing (its delivery rate is far below any
sane limit) and blunts a blind-flood probe. This is additive hardening, not a
substitute for the signature check, and is not required for correctness: the
handler is already safe with zero rate limiting because every unsigned or
mis-signed request is refused before any state change.
