# FOSS captcha and bot mitigation for the GFTB contact form (research brief)

Status: **RESEARCH BRIEF, not a decision** (authored 2026-07-07, under the
operator's standing drive/decide/adversarially-review delegation). This document
implements **nothing**: it applies no config, changes no handler code, and sends
**zero** live form traffic. Every claim about the current posture is cited to a
repo path read READ-ONLY (the `k8s/form/latoolb-us-production/` stack) or to a
named upstream source (see Sources). It exists to pick, and to shape the
integration of, a self-hostable form-submit bot mitigation that **complements**
Anubis on the one route Anubis structurally cannot gate.

Scope anchor (TIN-2420 Path B): the contact form on the static site
(`greatfallstoolbus.org`) reaches an in-cluster form-handler with a cross-origin
`fetch()` JSON `POST /api/contact`, which injects over LMTP to the
`keyholders@latoolb.us` Mailman list, which fans out to every keyholder. The
Anubis proof-of-work gate that protects the rest of the forms hostname
**explicitly ALLOWs `/api/contact`** because a browser PoW interstitial cannot
be solved by a scripted JSON XHR. That ALLOW is correct and unavoidable at the
Anubis layer, but it means the delivery path to a human distribution list has
**no human-presence proof on the POST itself**. This brief closes that.

## 0. Bottom line up front: ranked recommendation (5 lines)

1. **Adopt ALTCHA as the durable fix.** MIT-licensed, 100% self-hosted, WCAG 2.2
   AA, no third party, and its proof-of-work verify is reimplementable in Python
   **stdlib only** (SHA-256 + HMAC-SHA256), so it preserves the handler's
   zero-pip / zero-supply-chain invariant. Add an `<altcha-widget>` to the
   SvelteKit `/contact` form and a challenge+verify step in the handler.
2. **Ship the interim hardening THIS week; it is cheap and mostly already
   built.** The handler already has honeypot + token-bucket rate-limit + CORS +
   validation; add a **signed time-trap** and a **global aggregate ceiling** so
   an IP-rotating flood still hits a cap. No new dependency, stdlib only.
3. **Reject Friendly Captcha** (real anti-bot backend is closed + hosted:
   reintroduces the exact third-party dependency Anubis was chosen to avoid) and
   **mCaptcha** (AGPL, Rust+Redis, effectively stale). **Cap (capjs)** is a
   credible #2 but needs a stateful standalone server; ALTCHA's verify is
   stateless HMAC, which fits a single tiny stdlib pod far better.
4. **HyperKitty/Postorius is a real spam target but a DIFFERENT problem:** it is
   a server-rendered browser surface, so the **existing Anubis gate already
   covers it**. Keep those paths OFF the allowlist, enforce django-allauth
   email confirmation + Mailman confirm-and-moderate. A captcha there is
   optional defense-in-depth, lower priority than the `/api/contact` gap.
5. **Sequence:** land the honeypot/rate-limit hardening now (stdlib, no deps),
   then ALTCHA as the per-submission proof. Together they turn `/api/contact`
   from "publicly POST-able to a human list" into "costs a bot real work per
   message, capped in aggregate, and stamped with a server-verified proof."

## 1. The exact gap Anubis leaves open (why a captcha is even needed)

Anubis protects the **browsing surface** of the forms hostname and nothing else
on the API route, by design. The deployed policy prepends one rule to the
upstream default: `{"name":"gftb-contact-api","path_regex":"^/api/contact$",
"action":"ALLOW"}` (`k8s/form/latoolb-us-production/configmap-anubis-policy.yaml`).
The in-repo rationale is precise and worth restating because it defines the gap:

- Anubis's PoW is a **JavaScript/WASM challenge served as an HTML interstitial
  into a browsing context**. The static site reaches the handler with a
  cross-origin `fetch()` POST; that fetch receives the challenge HTML as an
  opaque body and **cannot** execute or solve it. "A programmatic JSON client
  can never clear a browser challenge" (configmap comment, cited).
- Anubis **v1.13.0 has no HTTP-method matcher** and `path_regex` matches
  `r.URL.Path` only, so the ALLOW is path-scoped, not method-scoped. Upstream's
  own documented answer for JSON/API callers is exactly this path ALLOW
  (TecharoHQ/anubis discussion #1543). No released version through **v1.17.0**
  ships a fetch/XHR-solvable challenge.
- **Consequence:** with `/api/contact` ALLOWed, the only controls on that route
  are the handler's own. The route is publicly POST-able. A recent accidental
  probe delivered test submissions straight to the keyholders list, proving the
  gap is live, not theoretical.

The takeaway is structural: **Anubis is the right gate for the browser surface
and the wrong tool for the JSON POST.** The complement must be a proof the
*client computes and includes in the POST body*, that the *handler verifies*
before it injects to LMTP. That is precisely the ALTCHA shape.

## 2. What the handler ALREADY does (the "cheap interim" is largely built)

Reading `k8s/form/latoolb-us-production/configmap-form-handler.yaml` (the
stdlib-only `server.py` mounted into `python:3.12-alpine`, pinned by digest in
`deployment-form-handler.yaml`), the interim layer the task asks for is, in
large part, **already shipped**:

| Control | Present today | Where (server.py) |
|---|---|---|
| Honeypot field (`website`) | Yes, non-empty trips a **silent success** (200, delivers nothing), so a bot is not tipped off | `validate()`, `do_POST()` |
| Per-client rate-limit | Yes, in-memory continuous-refill **token bucket, 5/min/client**, `429` on empty | `TokenBucket`, `do_POST()` |
| Rate-limit key hygiene | Yes, keys on Cloudflare's trusted `CF-Connecting-IP`, **never** a client-supplied `X-Forwarded-For` (which non-browser clients can forge); falls back to socket peer | `_client_key()` |
| Body cap | Yes, 64 KiB `Content-Length` cap so a client cannot exhaust RAM | `do_POST()` |
| Field validation | Yes, types, length bounds, pragmatic email regex | `validate()` |
| Header-injection defense | Yes, CR/LF stripped from any value reaching a header | `_sanitize_header()` |
| CORS | Yes, locked to `https://greatfallstoolbus.org` only | `_cors_origin()` |
| Bucket coherence | Yes, single replica, `Recreate` strategy, so the in-memory bucket stays coherent | `deployment-form-handler.yaml` |

So the recommendation for part 2 is **not** "add a honeypot and a rate-limit"
(they exist). It is: (a) recognize the interim is built, (b) **harden the two
weakest assumptions** in it (below), and (c) add the durable per-submission
proof (ALTCHA) that none of the above provides.

## 3. Residual gaps a captcha (and the hardening) must close

The existing controls are good hygiene but each has a known bypass against a
motivated sender aiming at a human list:

1. **Honeypot is defeated by any bot that parses the form.** Mainstream spam
   frameworks fill only visible fields; a static hidden `website` input is
   trivially skipped. It stops naive form-fillers, not targeted abuse.
2. **The IP token bucket is defeated by IP rotation.** Botnets and cheap
   residential-proxy pools rotate source IPs, so a 5/min *per-IP* budget still
   permits thousands of deliveries/day in aggregate. There is **no global
   ceiling**: nothing caps total inject rate across all clients.
3. **CORS/Origin is not a control against non-browser clients.** CORS only binds
   *browsers*; a scripted client omits or forges `Origin` and the server still
   processes the POST (the browser-only preflight is advisory to the browser,
   not enforced against curl). This is why the accidental probe worked.
4. **No human-work / presence proof on the POST.** Nothing currently makes the
   sender *spend* anything per message. This is the load-bearing gap and the one
   only a captcha/PoW closes.
5. **Single replica + in-memory bucket** means a restart resets all buckets and
   there is no HA. A stateless HMAC proof (ALTCHA) survives restarts and would
   even survive a future multi-replica move (with a shared replay set).

## 4. Candidate evaluation (self-hostable, privacy-first, accessible)

| Option | License | Truly self-host / no 3rd party | Mechanism | Server cost | a11y | Fit for a stdlib pod |
|---|---|---|---|---|---|---|
| **ALTCHA** | MIT | **Yes** (100% self-hosted, no external API) | PoW: SHA-256 challenge + HMAC-SHA256 signature | **Stateless verify** (HMAC); a challenge endpoint | WCAG 2.2 AA, EAA; no visual puzzle; audio/code fallback | **Best**, verify is stdlib `hashlib`+`hmac` |
| **Cap (capjs)** | Apache 2.0 | Yes | PoW (SHA-256/WASM) + optional instrumentation challenge | **Standalone Docker server** holding challenge state | Good; no visual puzzle | Weaker, adds a stateful service + store |
| **mCaptcha** | AGPL-3.0 | Yes | PoW | Rust server **+ Redis** | OK | Poor, heavy, effectively stale/deprecated |
| **Friendly Captcha** | SDK MPL-2.0; backend **closed** | **No**, real backend is a hosted subscription; "lite server" is non-commercial/Commons-Clause | PoW, adaptive difficulty in the closed backend | Managed (theirs) | Good | **Disqualified**, reintroduces a third party |
| Honeypot (field) | n/a | Yes | Trap field | ~0 | n/a | Already present; keep + harden |
| Server rate-limit | n/a | Yes | Token bucket | ~0 | n/a | Already present; add global ceiling |
| Time-trap | n/a | Yes | Min/max fill time, HMAC-signed | ~0 | n/a | Cheap add, stdlib |

**Why ALTCHA over Cap.** Both are sound FOSS PoW captchas. The deciding factor
for GFTB is operational shape: the handler's entire design thesis is a **single,
tiny, stdlib-only, digest-pinned pod with zero supply-chain of our own**
(configmap header comment). Cap's standalone mode wants a **separate server
process holding challenge tokens** (state), which contradicts that thesis and
adds a component to operate, patch, and monitor. ALTCHA's server side is
**stateless cryptographic verification**: the challenge is HMAC-signed by our
secret, the client returns the solution, and verification is a local recompute
with no store and no callback. That drops cleanly into the existing pod and even
survives a future multi-replica move (the only shared state a captcha needs is a
best-effort replay set, and ALTCHA's signed `expires` bounds that window).

**Why not Friendly Captcha.** Its frontend SDK is open (MPL-2.0), but the
anti-bot intelligence lives in a **closed, hosted backend** on a commercial
subscription; the self-host "lite server" is non-commercial / Commons-Clause
"fair-code," not FOSS. Choosing it would re-add exactly the third-party runtime
dependency the whole Anubis-plus-in-cluster posture exists to avoid. Rejected.

**Why not mCaptcha.** AGPL Rust service plus Redis, a large widget bundle, and
low current momentum. The operational cost dwarfs a contact form's needs.

## 5. ALTCHA fit, cost, a11y, and the exact integration shape

### 5a. What ALTCHA is and why it fits

ALTCHA ("Alternative CAPTCHA") is a privacy-first, MIT-licensed, self-hosted
proof-of-work widget. For most users it is **frictionless and invisible**: the
widget auto-solves a small PoW in a Web Worker on load or submit, with no puzzle
to click. It sets **no cookies and does no tracking** (GDPR-clean), and the
widget is engineered to **exceed WCAG 2.2 AA** (EAA compliant) with a keyboard
path and an "enter code from image" + audio fallback for the rare interactive
case. It is distributable as a self-hosted `<script>` / npm bundle with **no CDN
or third-party dependency** required.

### 5b. The proof-of-work, and why verify is stdlib-only

The classic ALTCHA scheme (its SHA-256 mode; PBKDF2-SHA256 and scrypt modes are
also covered by Python's `hashlib`) is:

- **Challenge issuance (server):** pick a random `salt` (carrying a signed
  `expires`) and a secret integer `number` in `[0, maxnumber]`; compute
  `challenge = SHA-256(salt + number)` and `signature = HMAC-SHA256(secret,
  challenge)`. Return `{algorithm:"SHA-256", challenge, salt, signature,
  maxnumber}` to the widget.
- **Solve (client, in a Web Worker):** iterate `n = 0..maxnumber` until
  `SHA-256(salt + n) == challenge`; the found `n` is the proof of spent work.
- **Payload (client submits):** base64 of JSON `{algorithm, challenge, number,
  salt, signature}`.
- **Verify (server):** recompute `SHA-256(salt + number)` and require it equals
  `challenge`; require `HMAC-SHA256(secret, challenge) == signature` (proves
  *we* issued it, unforgeable without the secret); require the salt's `expires`
  is in the future; and best-effort record the `challenge` to reject replays.

Every primitive there is Python **standard library** (`hashlib.sha256`,
`hmac.compare_digest`, `base64`, `json`). **This is the decisive fit point:**
ALTCHA can be added without a single pip dependency, so the handler keeps its
"stdlib only, zero supply-chain surface of our own" property intact
(configmap header). The official `altcha-lib` (MIT) is the reference for the
exact byte layout; we mirror it in stdlib rather than vendoring a wheel.

### 5c. Self-host cost

- **Frontend:** one self-hosted JS bundle (`altcha.min.js`) served from the
  static site; one `<altcha-widget>` element on `/contact`. No CDN.
- **Backend:** two tiny stdlib additions to `server.py`: a `GET /api/challenge`
  that issues a signed challenge, and a verify branch at the top of
  `do_POST /api/contact`. One new secret (the HMAC key) via a K8s Secret / env,
  same pattern as existing env config in `deployment-form-handler.yaml`.
- **No new pod, no new image, no external service, no store** (replay set is a
  bounded in-memory dict like the existing token bucket). Effectively free at a
  contact form's volume.

### 5d. The exact integration shape (design, NOT applied)

Client (SvelteKit `/contact`, illustrative, not a patch):

```
<!-- self-hosted bundle, no CDN -->
<script src="/altcha.min.js" async defer></script>

<altcha-widget challengeurl="https://forms.latoolb.us/api/challenge"
               auto="onsubmit" name="altcha"></altcha-widget>
```

On submit, the widget exposes the base64 payload (hidden input named `altcha`,
or via its `verified` event). Because the form uses a `fetch()` JSON POST rather
than a native form submit, the page reads that value and **includes it in the
JSON body** it already sends:

```
// illustrative only
const altcha = form.querySelector('[name=altcha]').value;
await fetch('https://forms.latoolb.us/api/contact', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ name, email, message, website: '', altcha }),
});
```

Handler (`server.py`, illustrative verify sketch, NOT applied, stdlib only):

```
# at the top of do_POST for /api/contact, BEFORE validate()/deliver():
#   payload = json.loads(base64.b64decode(fields_json["altcha"]))
#   recomputed = hashlib.sha256((payload["salt"] + str(payload["number"]))
#                               .encode()).hexdigest()
#   ok = (recomputed == payload["challenge"]
#         and hmac.compare_digest(
#               hmac.new(SECRET, payload["challenge"].encode(),
#                        hashlib.sha256).hexdigest(),
#               payload["signature"])
#         and salt_not_expired(payload["salt"])
#         and not seen_before(payload["challenge"]))
#   if not ok: return 400  # reject before any LMTP inject
```

The verify runs **before** the honeypot/validation/deliver path, so a POST
without a valid, unexpired, unreplayed proof never reaches LMTP. Keep the
existing honeypot silent-success semantics for a *tripped honeypot*; a *missing
or bad ALTCHA* is a hard `400` (a real browser always attaches one).

### 5e. Known limits (stated honestly)

- PoW raises the *cost* of each message; it does not make abuse impossible. A
  determined attacker with CPU can still solve challenges. That is why it is a
  **complement** to the aggregate rate ceiling (below), not a replacement.
- The challenge endpoint is itself unauthenticated (it must be, to serve the
  widget). It is cheap to serve and carries no secret in its output beyond the
  HMAC *signature*; keep it behind the same handler and let its own rate-limit
  bucket cover it.
- Multi-replica later needs a shared replay set; today's single replica makes an
  in-memory set sufficient, bounded by the signed `expires`.

## 6. Layered defense: the cheap interim, then the durable fix

Recommended order, because the interim is nearly free and the durable fix takes
a frontend change:

### 6a. Interim (ship now, stdlib, no new dependency)

The honeypot and rate-limit already exist (section 2). Two hardening deltas
close the biggest holes from section 3:

- **Signed time-trap (defeats instant replays and dumb bots).** Have the page
  stamp render time; carry it as an HMAC-signed hidden field (or fold it into
  the ALTCHA `salt` `expires` once ALTCHA lands). In the handler, reject a
  submission that arrives **faster than ~3 s** (no human fills a form that fast)
  or **older than ~30 min** (stale/replayed). Pure `hmac` + `time`, stdlib.
- **Global aggregate ceiling (defeats IP rotation).** Add a *second* token
  bucket keyed on a constant (e.g. total **30 injects/min** across all clients)
  in addition to the per-IP bucket, and consider lowering the per-IP burst from
  5 to **3/min**. An IP-rotating flood then still slams into the aggregate cap
  and gets `429`, protecting the keyholders list from a distributed burst. Same
  `TokenBucket` class already in `server.py`; just a second instance plus a
  fixed key. (Note: at a single replica the global bucket is exact; document
  that a multi-replica move would need an external counter.)
- Keep every existing control (CORS, body cap, header sanitize, honeypot
  silent-success, `CF-Connecting-IP` keying, do **not** start trusting
  `X-Forwarded-For`).

### 6b. Durable fix (land next)

ALTCHA per section 5. Once live, the per-message PoW is the primary control and
the rate limits become the aggregate backstop. The honeypot stays as a free
extra tripwire.

## 7. HyperKitty / Postorius signup surface: is it a spam target?

**Yes, it is a known and actively-exploited spam target, but it is a different
problem with a different, already-available answer.** Two distinct abuse vectors
are documented upstream (mailman3.org lists, django-mailman3 issue #33):

1. **Subscription / account-registration spam** through the Postorius +
   django-allauth signup form.
2. **Authenticated posting spam**: bots complete signup, then post to a list
   through the Postorius web "post" interface.

Crucially, **HyperKitty and Postorius are server-rendered Django browser
surfaces**, not JSON XHR endpoints. That means the *same Anubis PoW gate already
deployed on the forms hostname works here*. Unlike `/api/contact`, a real
browser navigating the signup page **can** solve the interstitial. So the
correct posture is:

- **Keep the HyperKitty/Postorius signup, login, and subscribe paths BEHIND
  Anubis, i.e. do NOT allowlist them** (contrast the deliberate `/api/contact`
  ALLOW). Anubis then imposes the browser PoW on the exact pages the bots load.
- **Enforce django-allauth mandatory email confirmation** (double opt-in): both
  Postorius and HyperKitty use django-allauth, and confirmed-email + Mailman's
  own **confirm-and-moderate** subscription policy stop the residual
  self-service subscription spam without a captcha at all.
- **Captcha here is optional defense-in-depth, not the primary control.** Mailman
  3 ships **no canonical captcha**; the community path is `django-simple-captcha`
  with unclear wiring. If a captcha is later wanted on the allauth signup form,
  ALTCHA has a Django integration and would be the consistent house choice, but
  because Anubis already covers this browser surface, it is **lower priority than
  the `/api/contact` gap**, which has no such coverage.

Net: the recently-fixed signup surface does **not** need the ALTCHA work on a
critical path. Verify it is not allowlisted in Anubis and that allauth
email-confirmation is on; treat a captcha there as a later, optional layer.

## Sources (all read READ-ONLY; nothing applied, no live form traffic)

- Repo (private overlay, `great-falls-tool-bus-infra`):
  `k8s/form/latoolb-us-production/configmap-form-handler.yaml` (the stdlib
  `server.py`: honeypot, `TokenBucket`, `_client_key`, `_sanitize_header`,
  `validate`, CORS, 64 KiB cap),
  `k8s/form/latoolb-us-production/deployment-form-handler.yaml` (digest-pinned
  `python:3.12-alpine`, single replica, `Recreate`, env config),
  `k8s/form/latoolb-us-production/configmap-anubis-policy.yaml` (the
  `/api/contact` ALLOW rule and its cited rationale: Anubis PoW is a browser
  interstitial, no method matcher through v1.13.0, upstream discussion #1543).
- Linear/context: TIN-2420 (form-handler Path B), TIN-2528 / TIN-2535 (archive
  and preview posture), TIN-2537 (on-cluster serving brief, same `docs/research/`
  peer). No Linear issue is filed for *this* brief yet; file one to track the
  ALTCHA adoption and the interim hardening as separate, sequenced work.
- ALTCHA: altcha.org docs (self-hosted, no cookies/tracking, WCAG 2.2 AA / EAA,
  stateless cryptographic verify), `github.com/altcha-org/altcha` (MIT, 100%
  self-hosted, no CDN dependency), `github.com/altcha-org/altcha-lib` (MIT;
  createChallenge / verifySolution reference, SHA-256 challenge + HMAC-SHA256
  signature + `expires`, all stdlib-reimplementable).
- Cap (capjs): `github.com/tiagozip/cap`, capjs.js.org (Apache 2.0, self-hosted,
  standalone Docker server holds challenge state, ~20 KB widget).
- mCaptcha: AGPL-3.0, Rust + Redis, low momentum (per 2026 comparisons).
- Friendly Captcha: friendlycaptcha.com + `FriendlyCaptcha/friendly-lite-server`
  (SDK MPL-2.0; anti-bot backend closed + hosted; "lite" server
  non-commercial / Commons-Clause, NOT self-hostable FOSS for production).
- Mailman 3 spam surface: docs.mailman3.org (config-web, allauth), GNU Mailman
  `django-mailman3` issue #33 (django-simple-captcha request), mailman3.org list
  threads on Postorius subscription/posting spam.
