# Tinyland edge + mail substrate — CF-reductive design + ground-truth briefing (TIN-2593)

Status: **RESEARCH BRIEF, not a decision** (synthesized 2026-07-07 from
read-only exploration of the live honey cluster, this `great-falls-tool-bus-infra`
repo, the blahaj mail render, and the Gateway API / edge state of the art).
Nothing was applied or mutated. Scope is more org / Tinyland substrate than GFTB
specifically. This document does **not** flip any switch, mint any grant, or apply
any config; it assembles grounded evidence a CF-reductive edge ADR (0010 shape)
and the mail-hardening tickets would build on. Every posture claim is grounded in
the read-only exploration cited in the source packet; the org-scoped follow-ups it
recommends are minted as **TIN-2586 … TIN-2594** (§8, §Cross-links). The doc
corrections it calls for (§8 item 9 / TIN-2594) land in the same PR as this brief.

## 0. Bottom line

Design CF-**reductive**, not CF-elimination, in two decoupled tracks. **Track 1
(now, netpol-only, edge-independent):** close the archive-gate bypass and prune
drift. **Track 2 (incremental):** a beachhead house edge on a dedicated small VPS
(NOT the mail relay box) reaching the NAT cluster over WireGuard/Tailscale, one
low-risk static spoke first, in-cluster routing modernized to GA Gateway API on
Traefik or Envoy. Keep Canal (a Cilium migration would break verified mail-netpol
SNAT asymmetry). Keep Cloudflare for DNS, Access gating, and optional per-hostname
DDoS fronting. Never touch the mail path.

## 1. What the live system actually is

- **3-node bare-metal RKE2 HA** (honey/bumble/sting, all control-plane+etcd,
  v1.33.11+rke2r1, Rocky 10.1). **All nodes private `192.168.70.10-12` behind NAT;
  no public IP anywhere** — the entire reason cloudflared exists.
- **CNI = Canal** (Calico policy + Flannel vxlan), NOT Cilium. Only standard
  `networking.k8s.io/v1` NetworkPolicy, no Gateway API CRDs, no L7 policy.
- Ingress = a separately-installed **ingress-nginx** (73 Ingresses) — upstream
  **retired after March 2026**; RKE2 moves to Traefik (v1.36 default, ingress-nginx
  removed v1.37). **Tailscale is deep** (nodes on the tailnet, operator + ingress).
- MetalLB installed but its only pool is a private `/32` for Liqo — not an edge.
- North-south HTTP: CF edge -> shared honey-ingress tunnel `da3ffda2-...` (2
  token-managed cloudflared connectors, ingress map in the CF dashboard) -> cluster.
- External public node already owned: **`relay.tinyland.dev` = BuyVM/Frantech
  `45.61.188.177`** — the mail MX + inbound smarthost, reaching honey over Tailscale.

## 2. Netpol vs the mail cert fix: two orthogonal layers, both load-bearing

**Netpol = connectivity/admission** (Calico must ALLOW before a byte moves).
**Cert fix = TLS-trust** on already-permitted connections. Proof they are separate:
the entire cert saga (#68 `InsecureTLSEmailBackend` stopgap, retired by #74/#78 with
a Postfix `:587` leaf carrying a SAN for the in-cluster svc DNS, issued by the private
Blahaj Mail CA and pinned via `SSL_CERT_FILE`) happened with **zero netpol changes**.

**Correction to an earlier assumption:** the HyperKitty archiver `core->web:8000` is
**intra-pod loopback** (`127.0.0.1:8000`; core+web co-located in one pod) — invisible
to netpol, needs no rule. Do not add rules for it.

**Mail flows a NetworkPolicy must never break** (latoolb-us-production is per-workload
default-deny):

| Flow | Rule shape | Why |
|---|---|---|
| postfix -> mailman-core:8024 (LMTP in) | ingress `ipBlock 10.244.0.0/24` | host-networked postfix SNATs to honey's Flannel node CIDR on ingress |
| form-handler -> core:8024 | ingress podSelector | in-namespace pod, any node |
| core/web -> postfix :587 (submission out) | egress `ipBlock 192.168.70.10/32` | egress not SNAT'd; raw host IP; asymmetric with the ingress leg |
| readers -> web :8000 | ingress from ns cloudflared, arc-runners, greatfallstoolbus-org-production + additive anubis-archive | post-DNAT: dial Service :8080, rule targets container :8000 |
| form gate chain | cloudflared->anubis:8081, anubis->form-handler:8080, ->core:8024 | reciprocal pairs |
| core -> postgres:5432; DNS 53 | egress | |

Substrate flows to preserve: postfix 25/587/465; postfix->dovecot LMTP:24 + SASL:12345;
postfix->rspamd milter:11332 (**where latoolb.us DKIM actually signs**); BuyVM MX->honey
over Tailscale; print@ -> Tailscale `100.122.197.52:2424`.

**House precedent:** `k8s/web/greatfallstoolbus-org-production/networkpolicy.yaml`
(PRs #48/#61/#60) — default-deny-ingress + cloudflared namespaceSelector admission +
prometheus scrape + DNS egress + one least-privilege data-plane peer (post-DNAT aware).
Any future edge slots in by swapping the admitted peer, which is why the pattern is
already CF-reductive-friendly.

## 3. Archive-gate gap: surgical netpol fix — NOW UNBLOCKED

The `anubis-archive` PoW gate is enforced only by CF dashboard routing: the
`mailman-core` policy admits the whole `cloudflared` namespace to `:8000`. **PR #77**
removes that one peer.

**GATE CLEARED (2026-07-07):** the connector-received tunnel config (v32, identical
on both replicas; full retained history v26-v32) contains **zero routes to
`mailman-web:8080/:8000`** — the only path to the web tier is `lists.latoolb.us ->
anubis-archive:8081` (PoW gate), and no k8s Ingress side-path exists. This supplies the
positive proof PR #77 flagged as missing. **Dropping the cloudflared->:8000 leg is
provably safe against current state. GO.** (Optional belt-and-suspenders: an operator
CF-dashboard read of tunnel `da3ffda2` covers the pre-v26 window connector logs cannot
reach.)

Also done: the **orphan inert `mailman-web` NetworkPolicy was pruned** 2026-07-07
(selected 0 pods; latent all-namespaces `:8000` exposure removed).

## 4. Mail I/O ground truth (resolved)

- **Outbound egress = `71.168.64.84` (wire-proven).** Both tinyland.dev mailbox mail
  and latoolb.us list/bounce mail leave from the SAME host-networked `postfix-0` on
  honey (`relayhost` empty = direct-to-MX, no `smtp_bind_address`); source
  `192.168.70.10` SNATs at the CRS309 MikroTik to the Fidium static WAN `71.168.64.84`.
  A 2026-07-04 port25 round-trip observed source `71.168.64.84` / HELO `mail.tinyland.dev`.
- **BuyVM `45.61.188.177` is inbound-MX-ONLY** (contract-explicit), not a smarthost;
  it relays accepted inbound to honey over Tailscale `100.113.89.12:25`. The SPF pair
  `ip4:71.168.64.84 ip4:45.61.188.177 mx ~all` = the real egress IP + the MX/relay.
- **NEW GAP — FCrDNS fails:** PTR of `71.168.64.84` is the Fairpoint/Fidium pool name,
  not `mail.tinyland.dev` -> forward-confirmed reverse DNS fails (TIN-39). Deliverability
  reputation risk; ISP/operator action to set a custom PTR.
- **DKIM: both domains genuinely signed + valid** at the rspamd-normal milter (:11332)
  using substrate-owned keys (Secret `dkim-keys`); TXT published + privkey<->pubkey match
  for both tinyland.dev (`mail`) and latoolb.us (`latoolb.us.mail.key`). latoolb.us
  `MailDomain DKIMReady=False` is **cosmetic** (controller only checks `spec.dkimSecretRef`,
  unset by design; TIN-2499). No broken DKIM.
- **Certs: fully private-CA** (Blahaj Mail CA self-signed leaf, SAN =
  `postfix.tinyland-dev-production.svc.cluster.local`, in Secret `mail-tinyland-dev-tls`);
  NO cert-manager/ACME on the SMTP path. **Residual drift: live `mailman-core` still has
  `SMTP_VERIFY_HOSTNAME/CERT=False`** (pre-#78 workaround, issue #74). **PR #78 (merged
  2026-07-07) is the fix** but the cluster is NOT yet rolled — blocked on the operator
  creating Secret `mail-substrate-ca` in `latoolb-us-production` (from `mail-tinyland-dev-tls`
  `ca.crt`) then applying #78.
- **Printstack** = external off-cluster appliance (mbp-13) over Tailscale
  `100.122.197.52:2424` (LMTP); `print@tinyland.dev` static transport in; confirmations
  out via the `printstack` MailAccount CR (Active). **Dovecot** healthy (2-replica dsync
  mesh, 0 restarts).
- **Transport-map: no functional drift** — live and declared route entries are
  byte-identical (keyholders@/discuss@/print@ all ACTIVE). The ONLY divergence is a stale
  `(GATED - NOT ACTIVE)` COMMENT in the live configmap; the repo carries the newer `ACTIVE`
  annotation. The earlier "live ahead of declared" premise is inverted (postfix ignores
  `#` lines; no routing effect).
- **NEW BUG — postorius@ deferred outbound:** something addresses mail to the
  `lists.latoolb.us` domain whose A record is the CF proxy (`172.64.80.1`), so SMTP `:25`
  times out and defers. Needs a Mailman config read (which setting mints `lists.latoolb.us`
  as a mail domain).
- **prometheus-mail-0 CrashLoopBackOff (~907 restarts)** -> mail-plane observability is
  dark, which is what let the postorius@ defer go unnoticed. Restore before other mail work.
- Lab-wide posture: both mail domains at DMARC `p=none` (monitoring-only); MTA-STS staged
  in tofu but not enforced.

## 5. Should the house build its own edge? Yes, reductively

- No node has a public IP -> **Gateway API alone solves nothing** (it is only in-cluster
  routing spec; reachability still needs a tunnel or a public box). Gateway API is at
  v1.5 (Feb 2026) stable: HTTPRoute, BackendTLSPolicy, L4 routes moving to Standard.
- CNI is Canal, not Cilium; Cilium Gateway's self-provisioned LB-IP advantage is moot
  behind NAT, and a CNI migration would invalidate the verified mail-netpol SNAT asymmetry.
  **Keep Canal.**
- The house owns a public node, but it is the mail relay. A web edge co-located there
  couples web DDoS/compromise to mail IP reputation + DKIM custody + the MX path.
  **Recommend AGAINST co-locating; use a separate dedicated edge VPS.**
- What CF gives free: anycast DDoS absorption, valid TLS, origin-IP hiding, Access gating.
  What it costs: CF terminates TLS (sees plaintext) and the tunnel map is dashboard state.
  So the posture is **per-hostname**: house edge with e2e TLS for static spokes wanting
  independence; CF proxy retained for DDoS-sensitive + Access-gated surfaces; CF DNS
  retained throughout. Mail is already fully off the CF data plane and stays untouched.

## 6. Phased path (each phase independently valuable, reversible, no big-bang)

- **Phase 0 (now, netpol only):** DONE — orphan pruned. NEXT — apply PR #77's
  cloudflared-peer removal (now provably safe); optionally add a `podSelector:{}`
  default-deny catch-all to latoolb-us-production for parity with GFTB web + MI.
- **Phase 1 (make CF legible):** land the TIN-991 successor so the shared tunnel's full
  20-hostname ingress map lives in tofu next to DNS/Access; inventory + classify each
  hostname needs-CF vs candidate-for-house-edge. No traffic moves.
- **Phase 2 (edge beachhead):** dedicated small edge VPS (separate box + IP from
  `45.61.188.177`); outbound WireGuard from the cluster or reuse the Tailscale mesh;
  Caddy/Traefik/Envoy terminating ACME TLS; route ONE low-risk static spoke; CF DNS-only
  or CF-in-front hybrid per hostname.
- **Phase 3 (in-cluster routing modernization, parallel-safe):** Traefik or Envoy
  Gateway with GA Gateway API (HTTPRoute, BackendTLSPolicy); migrate Ingresses off the
  retired ingress-nginx; keep Canal; reachability still from cloudflared and/or the VPS.
- **Phase 4 (steady state):** per-hostname placement; house edge for independence-seeking
  spokes; CF proxy for Access-gated/DDoS-sensitive; CF DNS everywhere; mail path untouched.

## 7. Not worth doing

Second cloudflared connector (more CF, not less); Tailscale Funnel for custom-domain sites
(HTTPS-only, bandwidth-capped, ts.net hostname, headscale can't Funnel); MetalLB as a
public edge on a NAT cluster; CNI migration to Cilium; co-locating the web edge on the mail
relay VPS; netpol rules for loopback flows; "fixing" the cosmetic latoolb.us DKIMReady=False;
full CF elimination; building anything new on ingress-nginx.

## 8. Recommended tickets (org-scoped, now minted)

1. **[High] TIN-2586 — Mail auth + cert lab-hardening.** FCrDNS/PTR for 71.168.64.84
   (TIN-39), DMARC p=none -> quarantine/reject ramp, MTA-STS go-live, SPF tighten,
   TIN-2499 cosmetic close.
2. **[High] TIN-2587 — Roll verified STARTTLS mailman->postfix (GFTB #78).** Mint Secret
   `mail-substrate-ca` in `latoolb-us-production` from `mail-tinyland-dev-tls` `ca.crt`,
   apply #78, retire the `SMTP_VERIFY=False` drift.
3. **[High] TIN-2588 — prometheus-mail-0 CrashLoopBackOff (~907 restarts).** Restore
   mail-plane observability.
4. **[Medium] TIN-2589 — Postfix defers outbound to postorius@lists.latoolb.us.** Find the
   Mailman setting minting `lists.latoolb.us` as a mail domain (it dials the CF proxy :25).
5. **[Medium] TIN-2590 — Transport-map render reconcile.** Live postfix-config carries the
   stale `(GATED - NOT ACTIVE)` comment while entries are ACTIVE; converge with declared.
6. **[Medium] TIN-2591 — Tunnel route authority into git (TIN-991 successor).** Bring the
   full 20-hostname honey-ingress map into tofu.
7. **[Medium] TIN-2592 — Tighten mailman-core netpol: drop cloudflared->:8000** (PR #77
   follow-through, now proven safe per §3).
8. **[Medium] TIN-2593 — CF-reductive edge initiative.** Codify the on-prem-first serving
   doctrine (ADR 0010 shape): beachhead house edge VPS + GA Gateway API (Traefik/Envoy).
9. **[Medium] TIN-2594 — GFTB docs truth pass #2.** Apply the doc corrections
   (`docs/architecture/diagrams.md` Diagrams 1/2/5, `k8s/web/README.md`,
   `k8s/list/README.md`, `docs/mvp-decision-packet.md` row g). Landed alongside this brief.

## 9. Remaining operator actions / unknowns

- CF-dashboard read of tunnel `da3ffda2` stored spec (belt-and-suspenders for #77; pre-v26 window).
- #78 rollout: create `mail-substrate-ca` Secret + roll mailman-core/web (until then live dials TLS-unverified).
- FCrDNS remediation: ISP/PTR delegation for 71.168.64.84 (TIN-39).
- postorius@ deferred root cause (Mailman REST/config read).
- DMARC p=none -> quarantine/reject intent; MTA-STS go-live intent.
- TIN-991 disposition: extend the MI-scoped ticket to org-wide, or mint the successor (TIN-2591).

## Cross-links

- **Linear (org-scoped, minted from §8):** TIN-2586 (mail auth + cert lab-hardening:
  FCrDNS/PTR, DMARC ramp, MTA-STS, SPF tighten), TIN-2587 (roll verified STARTTLS
  mailman->postfix, GFTB #78; mint `mail-substrate-ca`), TIN-2588 (prometheus-mail-0
  CrashLoopBackOff), TIN-2589 (postfix defers outbound to postorius@lists.latoolb.us),
  TIN-2590 (transport-map render reconcile), TIN-2591 (tunnel route authority into git,
  TIN-991 successor), TIN-2592 (tighten mailman-core NetworkPolicy, drop cloudflared->:8000,
  PR #77 follow-through), TIN-2593 (CF-reductive edge initiative, this brief's anchor),
  TIN-2594 (GFTB docs truth pass #2). Prior context: TIN-39 (FCrDNS), TIN-991 (tunnel route
  authority), TIN-2499 (DKIMReady cosmetic), TIN-2528 (public discuss@ archive route).
- **Peer briefs (this repo):** `docs/research/full-oncluster-web-serving-2026-07.md`
  (TIN-2537), `docs/research/gloriousflywheel-overlay-leverage-2026-07.md` (TIN-2545).
- **Org sibling — `tinyland-inc/site.scaffold`:** the scaffold this overlay's public spoke
  (`greatfallstoolbus.org`) was spawned from; source of the `tinyland.repo.json` boundaries
  schema + `.gitleaks.toml` rules the spoke inherits, and the CF-reductive edge doctrine
  (§5, §8 TIN-2593) is drafted org-wide there for reuse by future static spokes.

## Sources (all read READ-ONLY)

- Live honey cluster (rke2, 2026-07-04 / 2026-07-07 read-only kubectl): pod/Service/
  NetworkPolicy/ConfigMap/Secret shapes across `latoolb-us-production`,
  `tinyland-dev-production`, `cloudflared`, `kube-system`; connector-received tunnel
  config v26-v32; postfix/dovecot/rspamd/prometheus-mail pod state.
- This overlay (`great-falls-tool-bus-infra`): `tofu/stacks/edge/`, `k8s/{form,list,mail,web,archive}/latoolb-us-production/`,
  `docs/architecture/diagrams.md`, `docs/mvp-decision-packet.md`, `docs/discuss-archive-packet.md`.
- `tinyland-inc/blahaj`: mail substrate render (postfix/dovecot/rspamd, DKIM key material,
  transport map, `deploy/honey/retained-cloudflared.yaml`).
- `Great-Falls-Tool-Bus/greatfallstoolbus.org` (public spoke) and
  `tinyland-inc/site.scaffold` (scaffold source): boundaries schema + gitleaks rules.
- Edge/Gateway state of the art: Gateway API v1.5 (Feb 2026), ingress-nginx retirement,
  RKE2 Traefik default trajectory, Canal vs Cilium tradeoffs (public docs).
