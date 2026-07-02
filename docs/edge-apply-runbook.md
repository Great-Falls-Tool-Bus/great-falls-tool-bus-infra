# GFTB edge/DNS apply runbook (Cloudflare + DreamHost)

**TIN-2360 rows (b)/(c)/(g); row (c) amended 2026-07-02 — apply home is
THIS overlay, not blahaj; row (g) REVISED + REV-2 (packet-final,
operator-attested 2026-07-02) — DreamHost stays DNS authority; only the
GATED apex may move to a CF zone.** This runbook realizes the declare-only
intent in the public site repo (`greatfallstoolbus.org` →
`tofu/dns-intent/intent.yaml` + `tofu/mail-intent/intent.yaml`) through
the [`tofu/stacks/edge-dns`](../tofu/stacks/edge-dns/README.md) stack,
reconciled against the newer
[`docs/mvp-decision-packet.md`](./mvp-decision-packet.md) row (g). The
operator-facing *what + verify* surface stays the site repo's
`docs/runbooks/dns-mail-checklist.md`. This runbook supersedes the
site-repo draft `docs/runbooks/dns-apply-blahaj.md` as the apply
authority; the DNS cutover chain (TIN-2378 → TIN-2379 → TIN-2380)
executes from sessions in **this repo**.

Credentials are referenced **by name only** and resolve from the tenant
sops lane ([`secrets/README.md`](../secrets/README.md)) — never from this
file, never committed:

| Name | Scope needed |
| --- | --- |
| `cloudflare-api-token-gftb-zones` (`CLOUDFLARE_API_TOKEN`) | Account: Zone Create; Zone: DNS Edit, Config Rules Edit, Access: Apps Edit (GFTB zones only) |
| `cf-account-id` (`TF_VAR_cloudflare_account_id`) | House Cloudflare account id |
| `dreamhost-api-key` (`DREAMHOST_API_KEY`) | Registrar/DNS capture + (if the operator chooses API over panel) `dns-add_record`/`dns-remove_record` on the DreamHost-authority zones |

Values written `<like-this>` are chosen/minted at execution time — never
guessed. **No agent session mutates Cloudflare or DreamHost; every
mutation is an operator-gated step below.**

---

## 0. Capture current state (read-only; safe to re-run any time)

```bash
# DreamHost registrar + zone view (expect both domains, NS = ns*.dreamhost.com)
curl -s "https://api.dreamhost.com/?key=$DREAMHOST_API_KEY&cmd=domain-list_domains&format=json" \
  | jq '.data[] | select(.domain | test("greatfallstoolbus|latoolb"))'
curl -s "https://api.dreamhost.com/?key=$DREAMHOST_API_KEY&cmd=dns-list_records&format=json" \
  | jq '.data[] | select(.zone | test("greatfallstoolbus|latoolb"))'

# Cloudflare view (expect no GFTB zones unless REV-2 path A has run)
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones?account.id=$TF_VAR_cloudflare_account_id&per_page=50" \
  | jq -r '.result[].name'

# Public DNS view
dig NS greatfallstoolbus.org +short @1.1.1.1
dig NS latoolb.us +short @1.1.1.1
```

Baseline captured 2026-07-02: both domains registered at DreamHost, NS
`ns1/ns2/ns3.dreamhost.com`, zero records on both zones, no Cloudflare
zone for either.

## 1. REV-2 path decision (operator; blocks everything below)

Row (g) REV-2: the live apex serves **GATED behind Cloudflare Access**
(allow `jess@sulliwood.org`, expandable to Alex/Kate/Joe) until public
un-gating is deliberately flipped. Access requires the apex hostname
proxied on a Cloudflare zone, so pick one:

- **Path A — move the web zone to CF (this stack).** Set
  `manage_web_zone = true` in the tfvars and continue with steps 2–5.
  The Access application + allow policy are added to this stack alongside
  that flip (they are deliberately not pre-authored while the path is
  undecided).
- **Path B — gate a CF-zone preview host** (e.g. a host on an existing
  house zone) until public cutover. Nothing to apply in this stack;
  `greatfallstoolbus.org` DNS stays entirely at DreamHost (GH Pages
  A/CNAME records set DreamHost-side, panel or `dns-add_record`) and this
  stack stays dormant until the un-gating cutover.

Either way: `latoolb.us` stays DreamHost — its GH-Pages-independent
records (MX `10 relay.tinyland.dev`, SPF, later DKIM/DMARC, and the 301
redirect to the canonical site) are **DreamHost-side operator steps**
mirroring the site repo's `tofu/mail-intent/intent.yaml`, sequenced by
TIN-2378/TIN-2379. `manage_alias_zone` exists only for the explicitly
deferred whole-zone migration and is expected to stay `false`.

## 2. Plan + apply the stack (path A only)

```bash
sops exec-env secrets/edge-dns.enc.yaml 'just edge-init && just edge-plan'
just edge-plan-show     # expect: web zone + A×4 + www (+ verification TXT when set)
sops exec-env secrets/edge-dns.enc.yaml 'just edge-apply'
```

Records are pre-staged **before** the NS flip, so the cutover is atomic.
The zone sits `pending` until step 3; records added meanwhile activate
with the zone. Web records stay **DNS-only (grey cloud)** until GitHub
Pages issues the custom-domain certificate (`web_records_proxied =
false`) — then flip to proxied, which REV-2 needs for Access anyway.

Repo precondition first (site repo, separate PR there): `static/CNAME`
containing `greatfallstoolbus.org` + a `BASE_PATH=""` build must land
before DNS points at Pages, otherwise Pages serves broken project-path
URLs.

## 3. NS flip at DreamHost (path A; panel — the API cannot do this)

Read the assigned NS hosts from the stack outputs:

```bash
just edge-init >/dev/null && tofu -chdir=tofu/stacks/edge-dns output
```

The DreamHost API has **no registration-nameserver mutation**; the flip
is a DreamHost **panel** step (Domains → Registrations → nameservers):
replace `ns*.dreamhost.com` with the two Cloudflare-assigned hosts for
`greatfallstoolbus.org` only. Re-run the step-0 capture afterward and the
site-repo checklist step 1 to verify the zone answers from Cloudflare
(status flips `pending` → `active`). `latoolb.us` NS is not touched.

## 4. GitHub Pages custom domain (web zone live)

After the site-repo precondition PR lands and (path A) NS is flipped: set
the custom domain on the Pages site
(`PUT /repos/Great-Falls-Tool-Bus/greatfallstoolbus.org/pages` with
`{"cname":"greatfallstoolbus.org"}`, or repo Settings → Pages). GitHub
issues the org verification TXT value in that flow — set
`github_pages_verification_txt` in
`tofu/stacks/edge-dns/great-falls-tool-bus.tfvars` and re-run step 2 to
create the record (path B: add the TXT DreamHost-side instead). Wait for
the certificate, then set `web_records_proxied = true`, re-apply, and add
the Access application + allow policy (REV-2 gate) in the same change.
Verify with the site-repo checklist step 2 — expect the Access
interstitial, not the public site, until un-gating.

## 5. Mail records that need minted values (DKIM, DMARC — DreamHost-side)

Blocked on the TIN-2379 mail-plane mints, never guessed: DKIM selector +
key pair (private key = `latoolbus-dkim-private-key`, held ONLY in this
overlay's tenant sops lane) and the DMARC `rua` mailbox. Apply as
DreamHost TXT records on `latoolb.us` per the site-repo checklist steps
6–7 (panel or `dns-add_record`). MTA-STS stays deferred while the mail
plane ships `enable_mta_sts = False`.

## Boundary notes (what stays house-plane, consumed as services)

- `relay.tinyland.dev` is the house public MX target — a service this
  tenant points at, not infrastructure this repo manages.
- The honey-cluster mail stack (MailDomain/MailAccount CRDs under
  `mail.tinyland.dev/v1alpha1`, the Mailman3/Postorius/HyperKitty trio,
  Anubis behind the tunnel — TIN-2379/TIN-2380) runs on the house
  substrate. The **GFTB tenant-side CR declarations** land in this repo
  when those issues execute, applied with the same operator-gated posture
  as ARC (kubectl context `honey`); the blahaj repo takes no GFTB content.

## Exit

Hand back to the site repo's `docs/runbooks/dns-mail-checklist.md` — its
exit criteria (site + 301s serving — behind Access while gated,
MX/SPF/DKIM/DMARC resolving, round-trip list mail passing SPF+DKIM+DMARC)
are the completion definition for this runbook too.
