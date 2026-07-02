# `tofu/stacks/edge-dns/` — GFTB edge/DNS apply plane

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

```bash
just edge-fmt-check     # formatting
just edge-validate      # init -backend=false + validate (no state, no creds)
just edge-init          # backend: tofu/backend/honey-edge-dns.s3.hcl
just edge-plan          # needs CLOUDFLARE_API_TOKEN + TF_VAR_cloudflare_account_id
just edge-plan-show
just edge-apply         # destroy-checked, ALLOW_EDGE_DESTROY-gated
```

Apply is operator-gated and follows
[`docs/edge-apply-runbook.md`](../../docs/edge-apply-runbook.md), which
starts with the REV-2 path decision (path A: web zone → CF + Access-gated
apex, managed by this stack; path B: gated CF preview host on an existing
house zone — nothing to apply here). Credentials are referenced **by name
only** and resolve from the tenant sops lane (`secrets/README.md`); the
DreamHost API is read-only capture here, never mutation.

Execution-time values (verification TXT, DKIM selector/public key, DMARC
rua) stay `null`/commented in `great-falls-tool-bus.tfvars` until minted —
the matching resources are gated so `plan` is honest before then.
