# `tofu/stacks/edge-dns/` — superseded GFTB edge/DNS reference

This stack is retained as the pre-TIN-2385 fail-closed reference only. The
live edge apply plane is [`../edge/`](../edge/README.md) and its public
operator recipes are `just edge-zones-*`. Do not apply this stack while the
live `edge/` stack owns the Cloudflare zone surface.

This stack is the **apply-plane consumption** of the declare-only intent
published by the public site repo
(`Great-Falls-Tool-Bus/greatfallstoolbus.org`):

- [`tofu/dns-intent/intent.yaml`](https://github.com/Great-Falls-Tool-Bus/greatfallstoolbus.org/blob/main/tofu/dns-intent/intent.yaml)
  — zones, records, redirect rule (declarations SSOT)
- [`tofu/mail-intent/intent.yaml`](https://github.com/Great-Falls-Tool-Bus/greatfallstoolbus.org/blob/main/tofu/mail-intent/intent.yaml)
  — mail-domain posture (only the MX target + SPF/DKIM/DMARC records
  materialize here)

The site repo declares; this overlay applies. **Freshness order matters:**
the packet ([`docs/mvp-decision-packet.md`](../../docs/mvp-decision-packet.md))
row (g) REVISED + REV-2 (operator-attested 2026-07-02) postdates the site
repo's intent files — DreamHost STAYS DNS authority for both domains; only
the GATED-apex phase moves `greatfallstoolbus.org` to a CF zone (Cloudflare
Access needs the apex proxied on a CF zone); `latoolb.us` stays DreamHost
either way. The stack therefore ships **fail-closed**: both `manage_*`
toggles default `false` and the default plan is empty. When the site
repo's intent and this stack disagree, reconcile against the packet first.

## Why here and not blahaj (TIN-2360 row c, amended 2026-07-02)

Consumer overlays live with the consumer org. `tinyland-inc/blahaj` is the
**house's replaceable IaC layer** — the reference backend an adopter *may*
point at, "never a required dependency" (`house-glorious-build-saas.md`).
The sense-3 adoption doctrine is explicit that adoption happens "without
re-homing any repo" (prompt 53; tinyland-goo `AGENTS.md`) — and the dual of
no-re-homing is that GFTB's apply plane does not get homed into a tinyland
repo either. This overlay repo is the GFTB org's one integration surface;
its edge/DNS consumption belongs here, next to its ARC tenancy.

What remains house-plane (consumed as *services*, by reference):

- the Cloudflare **account** any managed zone sits on (the scoped API
  token is a named credential in this overlay's sops lane)
- `relay.tinyland.dev` as the public MX target
- the honey cluster mail stack (MailDomain/MailAccount CRDs, the Mailman3
  trio, Anubis behind the tunnel — TIN-2379/TIN-2380). The GFTB
  *tenant-side declarations* for those land in this repo when those issues
  execute; the blahaj repo takes no GFTB content.

## Operating it

There is no public Justfile lane for this stack. The repo intentionally exposes
only the live `edge-zones-*` recipes for the current Cloudflare zone surface.
If an operator ever needs to resurrect this stack, first record a superseding
decision and reintroduce recipes in a dedicated PR with a fresh plan proof.

Execution-time values (verification TXT, DKIM selector/public key, DMARC
rua) stay `null`/commented in `great-falls-tool-bus.tfvars` until minted —
the matching resources are gated so `plan` is honest before then.
