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
| g | DNS authority | **REVISED from the proposal: Dreamhost STAYS authority for both domains.** Site = GH Pages A/CNAME records in the Dreamhost zones; mail = MX/SPF/DKIM/DMARC at Dreamhost; the ONE tunnel-needing endpoint (the Anubis-guarded form) rides an existing Cloudflare-zone hostname (e.g. `gftb-forms.tinyland.dev`). Whole-zone CF migration deferred until tunnel surfaces accrue. | Adversarial self-correction: the original CF proposal cargo-culted the L0 pattern, but L0 needed a tunnel for an API host — a static Pages site + MX needs NO proxy. Live probe 2026-07-02: both zones on Dreamhost NS. This choice = zero registrar/NS operator work. **REV-2 (operator amendment 2026-07-02): the live apex stays GATED behind Cloudflare Access while prose is refined** — policy allows `jess@sulliwood.org` initially, expandable to Alex / Kate / Joe. CF Access requires the apex hostname on a Cloudflare zone (proxied), so this amendment supersedes the Dreamhost-apex portion for the GATED phase: move the `greatfallstoolbus.org` zone to CF (operator NS change at the registrar) OR gate a CF-zone preview host until public cutover; `latoolb.us` (mail MX + redirect) stays Dreamhost either way. Public un-gating is a later one-line Access-policy change |
| h | Donation legal framing | **ATTESTED by the operator 2026-07-02** ("I agree this is reviewed and correct") — verbatim: *"The Great Falls Tool Bus is an unincorporated community project. Donations of tools and materials are gifts to the project and are not tax-deductible. We are not a 501(c)(3) organization. This is a bus; the shop comes later :)"* | All ten rows now decided; no sub-gates remain |
| i | Linear home (NEW-1/2/4) | **Project-less; no new project/initiative.** NEW-1 = TIN-2360 (minted); NEW-3 mints in "Business Operations — Tinyland, Inc." at execution | Prompt 50 placement rules; GF project gets cross-links only |
| j | "L-A tool bus" reading | **Confirmed: Lewiston-Auburn**; `latoolb.us` = the L-A pun | Golden story (Lewiston alderman, L-A neighbor) |

## Gate state (final — all ten rows decided, (h) attested 2026-07-02)

- UNBLOCKED: everything. Mail/MX lane (NEW-3, blahaj), list engine (NEW-4),
  Anubis (per f), site content incl. the donations page (per attested h).
- ACCESS POSTURE (g REV-2): the live apex serves GATED behind Cloudflare
  Access (jess@sulliwood.org; Alex/Kate/Joe added as prose firms up); public
  un-gating is a deliberate later flip, not a default.
- The site repo predates the packet; audit its config against rows
  (c)/(d)/(g-rev2) rather than assuming conformance.
