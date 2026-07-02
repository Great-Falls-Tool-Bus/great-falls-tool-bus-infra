# GFTB MVP decision packet (prompt-50 DAG step 1 — NEW-1)

Status: **PROPOSED 2026-07-02** — authored by the agent per prompt
`50-greatfallstoolbus-mvp`; every decision below is a recommendation and
**binds only on operator sign-off** (this doc flips to DECIDED with a dated
operator line per item). Nothing downstream (repo spawn, DNS, mail, list,
Anubis) may proceed from PROPOSED state.

| # | Question | PROPOSED | Why |
|---|----------|----------|-----|
| a | Repo shape | **One repo**; `latoolb.us` = redirect/alias to `greatfallstoolbus.org` | No content divergence exists to justify two repos; mail on latoolb.us is transport-side (blahaj), not repo-side |
| b | Repo home | **`Great-Falls-Tool-Bus` org** | Consistent with TIN-2299 naming; the org now has live ARC tenancy (scale set + green overlay CI as of 2026-07-02), so org-homed CI works day 1 |
| c | IaC home | **Split by plane**: ARC/runner tenancy = `great-falls-tool-bus-infra` (already live); mail/DNS/tunnel/Anubis = blahaj `tofu/stacks/` per the massageithaca precedent | blahaj is the mail-transport + tunnel + SOPS authority; the sense-3 overlay owns only compute tenancy — honors both precedents without inventing a third |
| d | Public-repo SOPS posture | **Zero in-repo secrets** | Static public site; secrets stay blahaj-side/lab sops; scaffold gates (gitleaks + scan-endpoints + conformance) enforce |
| e | List engine | **Mailman3 + HyperKitty** (per operator ask), ADR records alternatives considered | Archive-native, the operator-named default; ADR keeps the decision falsifiable |
| f | Anubis placement | **Behind the blahaj tunnel**, scoped to the join/contact form route only | Honors honey zero-public-IP doctrine (every public endpoint = named tunnel route); a Caddy edge would be a new unproven pattern |
| g | DNS authority | **Cloudflare (house plane)** for both `greatfallstoolbus.org` + `latoolb.us` | Tunnel-ability requires CF-proxied records (the L0/gf-token-exchange proven pattern); Dreamhost zones stay empty |
| h | Donation legal framing | **Needs operator verbatim**: donations to the unincorporated community project; no 501(c)(3)/tax-deductibility claims; "this is a bus, the shop comes later" | Finances-honesty rules; the exact wording is a legal posture only Jess can sign |
| i | Linear home (NEW-1/2/4) | **Project-less; no new project/initiative.** NEW-3 mints in "Business Operations — Tinyland, Inc." per prompt 50 | Prompt 50 forbids diluting the GF project; cross-links only to TIN-2299/TIN-2126 |
| j | "L-A tool bus" reading | **Confirmed as Lewiston-Auburn**; `latoolb.us` = the L-A pun | Matches the golden story's Lewiston-Auburn neighbor + Joe (Lewiston alderman) |

## Sign-off

- [ ] Operator confirms/edits each row (a–j); this doc flips to DECIDED with
  dated operator initials per row.
- [ ] NEW-1 Linear issue updated to Decided; NEW-2 (repo spawn — **user-only**
  `tinyland-spawn-sister-site` skill) unblocks.
