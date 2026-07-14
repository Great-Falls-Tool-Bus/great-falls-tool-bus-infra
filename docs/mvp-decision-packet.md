# GFTB MVP decision packet (prompt-50 DAG step 1 — NEW-1 = TIN-2360)

Status: **DECIDED 2026-07-02** (adjudicated under the operator's standing
"drive/decide/adversarially review" delegation, grounded in prompt 50, the
house steering docs, and live probes; row (h) carries an explicit
operator-attestation sub-gate). Rows (a)/(b) were decided by events — the
site repo was spawned before this packet flipped.

| # | Question | DECIDED | Grounding |
|---|----------|---------|-----------|
| a | Repo shape | **One repo** (`greatfallstoolbus.org`, spawned from site.scaffold v0.2.0 at 2026-07-02T16:44Z — decided-by-events, matching the proposal); `latoolb.us` = redirect/alias | Repo exists public in the org; no content divergence justifies two |
| b | Repo home | **`Great-Falls-Tool-Bus` org** (decided-by-events) | Spawned there; org has live ARC tenancy + green CI |
| c | IaC home | **Split by plane**: ARC tenancy = `great-falls-tool-bus-infra` (live); mail/DNS/tunnel/Anubis = blahaj `tofu/stacks/` (massageithaca precedent) | blahaj is the mail/tunnel/SOPS authority; both precedents honored |
| d | Public-repo SOPS posture | **Zero in-repo secrets** | Static public site; scaffold gates (gitleaks + scan-endpoints + conformance) enforce |
| e | List engine | **Mailman3 + HyperKitty**; ADR records alternatives | The operator ask already on record in prompt 50; archive-native |
| f | Anubis placement | **Behind the blahaj tunnel**, join/contact form route ONLY | honey zero-public-IP doctrine; first house Anubis = ADR + runbook |
| g | DNS authority | **REVISED from the proposal: Dreamhost STAYS authority for both domains.** Site = GH Pages A/CNAME records in the Dreamhost zones; mail = MX/SPF/DKIM/DMARC at Dreamhost; the ONE tunnel-needing endpoint (the Anubis-guarded form) rides an existing Cloudflare-zone hostname (e.g. `gftb-forms.tinyland.dev`). Whole-zone CF migration deferred until tunnel surfaces accrue. | Adversarial self-correction: the original CF proposal cargo-culted the L0 pattern, but L0 needed a tunnel for an API host — a static Pages site + MX needs NO proxy. Live probe 2026-07-02: both zones on Dreamhost NS. This choice = zero registrar/NS operator work. **REV-2 (operator amendment 2026-07-02): the live apex stays GATED behind Cloudflare Access while prose is refined** — policy allowlist is supplied from protected operator custody, not committed. CF Access requires the apex hostname on a Cloudflare zone (proxied), so this amendment supersedes the Dreamhost-apex portion for the GATED phase: move the `greatfallstoolbus.org` zone to CF (operator NS change at the registrar) OR gate a CF-zone preview host until public cutover; `latoolb.us` (mail MX + redirect) stays Dreamhost either way. Public un-gating is a later one-line Access-policy change |
| h | Donation legal framing | **ATTESTED by the operator 2026-07-02** ("I agree this is reviewed and correct") — verbatim: *"The Great Falls Tool Bus is an unincorporated community project. Donations of tools and materials are gifts to the project and are not tax-deductible. We are not a 501(c)(3) organization. This is a bus; the shop comes later :)"* | All ten rows now decided; no sub-gates remain |
| i | Linear home (NEW-1/2/4) | **Project-less; no new project/initiative.** NEW-1 = TIN-2360 (minted); NEW-3 mints in "Business Operations — Tinyland, Inc." at execution | Prompt 50 placement rules; GF project gets cross-links only |
| j | "L-A tool bus" reading | **Confirmed: Lewiston-Auburn**; `latoolb.us` = the L-A pun | Local story, no personal details committed |

## Gate state (final — all ten rows decided, (h) attested 2026-07-02)

- UNBLOCKED: everything. Mail/MX lane (NEW-3, blahaj), list engine (NEW-4),
  Anubis (per f), site content incl. the donations page (per attested h).
- ACCESS POSTURE (g REV-2): the live apex serves GATED behind Cloudflare
  Access (operator allowlist supplied from protected custody); public un-gating
  is a deliberate later flip, not a default.
- The site repo predates the packet; audit its config against rows
  (c)/(d)/(g-rev2) rather than assuming conformance.

## Correction — row (c), dated 2026-07-03 (mandated by memo 0002)

Row (c) above is **superseded as written**. The operator boundary correction
of 2026-07-02 (site repo
`docs/decisions/0002-blahaj-substrate-boundary.md`, verbatim intent: "the
apply plane for GFTB belongs in great-falls-tool-bus-infra; blahaj is the IaC
substrate LAYER and must stay logically replaceable, never intertangled with
projects"; acknowledged on TIN-2378, comment b25465d8: "blahaj = swappable
substrate; apply plane re-homes to great-falls-tool-bus-infra") re-homed
**all GFTB apply-plane concerns** — mail intent (CR manifests), DNS/redirect,
Mailman3/Anubis runtime stacks — to THIS repo as the **org apply-plane
overlay**. `tinyland-inc/blahaj` stays the substrate, consumed only through
its named interfaces (MailDomain/MailAccount CRDs, `relay.tinyland.dev`, the
S3 tofu-state endpoint, the tenant SOPS recipient rule); row (c)'s
"massageithaca precedent" grounding was already forbidden by blahaj's own
doctrine (memo 0002 §b). Per the memo 0002 amendment (TIN-2385, ledger item
20), the Cloudflare edge-authority carve-out resolved to option (ii): this
overlay holds the zone-scoped token (`CLOUDFLARE_API_TOKEN_GFTB_ZONES`, edge
environment) and applies GFTB DNS/Access/redirect through
`tofu/stacks/edge/`. DKIM private keys (blahaj-transport-consumed) remain the
one ciphertext staying blahaj-side. Memo 0002's process rule applies here:
this is a dated correction note, never a silent rewrite — row (c)'s original
text stands above as the historical record.

## Correction — row (g), dated 2026-07-03 (decision D1=A)

Row (g)'s "`latoolb.us` (mail MX + redirect) stays Dreamhost either way"
premise is **superseded as written.** Decision **D1=A (2026-07-03)** moved the
`latoolb.us` **nameservers to Cloudflare**; DreamHost is now **registrar-only**,
no longer the DNS authority for the zone. All `latoolb.us` DNS records —
MX/SPF/DKIM/DMARC (mail) plus the apex/www 301-redirect and the `forms.` /
`lists.` tunnel CNAMEs — are authored in this overlay's `tofu/stacks/edge/`
against the Cloudflare `latoolb.us` zone (`data.cloudflare_zone.alias`), not at
DreamHost. Row (g)'s REV-2 amendment (which kept only the `greatfallstoolbus.org`
zone on Cloudflare and left `latoolb.us` on DreamHost) is superseded for the NS
authority accordingly. The mail data plane is unchanged — inbound still flows
through the MX `relay.tinyland.dev` (ADR 010) — only the DNS control plane
moved. Per the memo 0002 process rule this is a dated correction note, never a
silent rewrite; row (g)'s original text stands above as the historical record.
