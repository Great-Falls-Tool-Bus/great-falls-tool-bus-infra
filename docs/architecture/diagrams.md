# Architecture diagrams

Grounded mermaid diagrams for the Great Falls Tool Bus (GFTB) apply-plane
overlay. Every diagram cites the source-of-truth files it is drawn from, all in
this repository unless noted. Substrate-owned facts (postfix, dovecot, rspamd,
the DKIM key material, the transport map) live in `tinyland-inc/blahaj` and are
consumed by reference through named contracts; they are labelled as substrate
in the diagrams and are not committed here.

Live state was verified read-only against the `honey` cluster on 2026-07-04
(namespaces `latoolb-us-production` and `tinyland-dev-production`, get/describe
only). Pod, Service, and NetworkPolicy shapes below match that live state.

## 1. Mail flow, end to end

**Claim.** Inbound mail for `latoolb.us` enters through the house MX
`relay.tinyland.dev`, reaches the host-networked substrate postfix on honey,
and is split by the transport map: `tinyland.dev` mailboxes land in dovecot,
while the `keyholders@` and `discuss@` list families are delivered by
recipient-scoped LMTP to `mailman-core:8024`. Mailman moderates and fans out,
then submits outbound over 587 STARTTLS with SASL as `lists-bounces@latoolb.us`;
the substrate rspamd milter adds the `d=latoolb.us` DKIM signature (selector
`mail`) before the message leaves for the world. The DNS edge authorizes both
egress IPs in SPF and publishes MX, DKIM, and a start-observing DMARC record.

**Sources of truth.** Edge DNS records: `tofu/stacks/edge/main.tf` (MX ->
`relay.tinyland.dev`, `priority 10`; SPF `v=spf1 ip4:45.61.188.177
ip4:71.168.64.84 mx ~all`; DMARC `p=none`; DKIM selector `mail`, all gated on
`var.mail_dns_enabled`). LMTP target: `k8s/list/latoolb-us-production/service-mailman-core.yaml`
(port `8024`) and `docs/runbooks/list-bringup.md` pre-apply gate 1 (transport
`<list-domain> lmtp:[mailman-core.latoolb-us-production.svc.cluster.local]:8024`).
Outbound submission: `k8s/list/latoolb-us-production/deployment-mailman-core.yaml`
and `configmap-mailman.yaml` (`SMTP_HOST
postfix.tinyland-dev-production.svc.cluster.local`, `SMTP_PORT 587`,
`smtp_secure_mode starttls`, SASL from the `lists-bounces-smtp` Secret). DKIM
selector: `k8s/mail/latoolb-us-production/maildomain-latoolb-us.yaml`
(`dkimSelector: mail`). Substrate postfix/dovecot/rspamd and the DKIM private
key are blahaj-owned (ADR 010). The `45.61.188.177` relay and `71.168.64.84`
honey egress facts are the SPF comment in `tofu/stacks/edge/main.tf`.

```mermaid
flowchart TD
    sender["External sender"]
    dns["DNS edge for latoolb.us<br/>MX 10 relay.tinyland.dev<br/>SPF v=spf1 ip4:45.61.188.177 ip4:71.168.64.84 mx ~all<br/>DKIM selector mail<br/>DMARC p=none rua postmaster@<br/>src: tofu/stacks/edge/main.tf"]
    mx["MX relay.tinyland.dev<br/>BuyVM 45.61.188.177"]
    postfix["Substrate postfix on honey<br/>host-networked 192.168.70.10<br/>ports 25 / 587 / 465<br/>SUBSTRATE (blahaj)"]
    transport{"virtual_domains<br/>+ transport map<br/>by recipient"}
    dovecot["dovecot<br/>tinyland.dev mailboxes<br/>IMAP 993<br/>SUBSTRATE"]
    lmtp["LMTP to mailman-core:8024<br/>keyholders@ / discuss@ latoolb.us"]
    pipeline["Mailman pipeline<br/>moderation + fan-out<br/>mailman-core"]
    submit["Outbound submission 587<br/>STARTTLS + SASL<br/>as lists-bounces@latoolb.us<br/>to postfix.tinyland-dev-production:587"]
    rspamd["rspamd DKIM milter<br/>sign d=latoolb.us selector mail<br/>SUBSTRATE"]
    world["World"]

    sender -->|"resolve + deliver"| dns
    dns --> mx
    mx -->|"tailscale to honey"| postfix
    postfix --> transport
    transport -->|"tinyland.dev recipient"| dovecot
    transport -->|"list-family recipient"| lmtp
    lmtp --> pipeline
    pipeline --> submit
    submit --> rspamd
    rspamd --> world
```

## 2. Network and ports: `latoolb-us-production` NetworkPolicy graph

**Claim.** The namespace is default-deny; each Mailman pod is opened only for
the flows drawn here. `mailman-core` admits LMTP `8024` from the flannel node
CIDR `10.244.0.0/24` (not a podSelector) because the substrate postfix is
host-networked and its source is SNAT'd to the node CIDR on the ingress leg; it
admits REST `8001` from `mailman-web`. On egress, `mailman-core` reaches the
substrate postfix at the raw host IP `192.168.70.10/32` on `587` (destination
is not SNAT'd, the asymmetric quirk), Postgres on `5432`, `mailman-web` on
`8000`/`8080` for the HyperKitty archive POST, plus DNS. `mailman-web` admits
HTTP `8000` from any namespace and egresses to core REST `8001` and Postgres
`5432`. `mailman-postgres` admits `5432` only from core and web.

**Source of truth.** `k8s/list/latoolb-us-production/networkpolicy.yaml`
verbatim (ingress CIDR `10.244.0.0/24` at lines 37-42; egress host IP
`192.168.70.10/32` at lines 65-70; core -> web `8000`/`8080` at lines 85-93;
web ingress `namespaceSelector {}` on `8000` at lines 115-119). The two
asymmetric host-networked quirks are annotated in that file's comments (ingress
sees the SNAT node CIDR; egress targets the raw host IP). Live pod IPs on
2026-07-04 (`mailman-core 10.244.0.17`) confirm the `10.244.0.0/24` node CIDR.

```mermaid
flowchart LR
    postfix["Substrate postfix<br/>host-networked<br/>SUBSTRATE (blahaj)"]
    web["mailman-web<br/>Postorius + HyperKitty"]
    core["mailman-core<br/>list engine"]
    pg["mailman-postgres"]
    anyns["Any namespace<br/>(future tunnel ingress)"]
    dns(["DNS 53"])

    postfix -->|"ingress 8024 LMTP<br/>from ipBlock 10.244.0.0/24<br/>SNAT node CIDR (quirk 1)"| core
    web -->|"ingress 8001 REST"| core
    anyns -->|"ingress 8000 HTTP"| web
    core -->|"egress 587 STARTTLS+SASL<br/>to ipBlock 192.168.70.10/32<br/>raw host IP (quirk 2)"| postfix
    core -->|"egress 5432"| pg
    core -->|"egress 8000/8080<br/>archive POST"| web
    web -->|"egress 8001 REST"| core
    web -->|"egress 5432"| pg
    core -.->|"egress"| dns
    web -.->|"egress"| dns
    pg -.->|"egress"| dns
```

## 3. Repository and plane topology

**Claim.** Three planes with a strict artifact boundary. The public spoke
`greatfallstoolbus.org` is declare-only and holds zero secrets: it emits
`tofu/dns-intent/` and `tofu/mail-intent/` intent that names, but never
applies, mail and list posture. This overlay, `great-falls-tool-bus-infra`, is
the org apply plane: it runs `tofu` apply for the edge/DNS zones, owns the
`mail.tinyland.dev` custom resources (`MailDomain`, `MailAccount`, `MailAlias`)
and the Mailman list stack, and gates applies behind the protected `mail`
environment. The blahaj substrate owns postfix, dovecot, rspamd, the transport
map, and the DKIM keys; it is swappable behind the named contracts of ADR
009/010. Intent flows spoke -> overlay; CRs and manifests apply overlay ->
cluster; transport-map lines and DKIM material stay substrate-side.

**Sources of truth.** Spoke intent: `greatfallstoolbus.org`
`tofu/mail-intent/intent.yaml` (`applied_by: great-falls-tool-bus-infra`, "No
endpoints, no state, no credentials, ever"). Overlay apply role and CR
ownership: `README.md` ("Mail CR apply plane (TIN-2379)", "Edge/DNS apply
plane") and `k8s/mail/latoolb-us-production/` (`MailDomain`/`MailAccount`/
`MailAlias`). Environment gate: `.github/workflows/mail-crs.yml` and
`list-crs.yml` (`environment: mail`, `MAIL_APPLY_KUBECONFIG_B64`). Substrate
boundary and contracts: `k8s/mail/README.md`, `docs/runbooks/list-bringup.md`
(ADR 010 / `tenant-list-engine-smtp` contract, blahaj as "replaceable IaC layer
consumed as a service").

```mermaid
flowchart TD
    subgraph spoke["Public spoke: greatfallstoolbus.org (declare-only, zero secrets)"]
        dnsintent["tofu/dns-intent/intent.yaml"]
        mailintent["tofu/mail-intent/intent.yaml<br/>applied_by: infra overlay"]
    end

    subgraph overlay["Apply plane: great-falls-tool-bus-infra"]
        edge["tofu apply<br/>edge-dns / edge zones"]
        crs["Mail CRs<br/>MailDomain / MailAccount / MailAlias<br/>k8s/mail/"]
        liststack["Mailman list stack<br/>k8s/list/"]
        gate["Protected env gate: mail<br/>mail-crs.yml / list-crs.yml"]
    end

    subgraph substrate["Substrate: tinyland-inc/blahaj (swappable, ADR 009/010)"]
        pfx["postfix + transport map"]
        dov["dovecot"]
        rsp["rspamd + DKIM keys"]
    end

    dnsintent -->|"names posture"| edge
    mailintent -->|"names posture"| crs
    gate --> crs
    gate --> liststack
    crs -->|"reconciled by house mail controller"| substrate
    edge -->|"MX / SPF / DKIM / DMARC records"| substrate
    liststack -->|"LMTP target + submission identity"| pfx
    pfx --- dov
    pfx --- rsp
```

## 4. Bazel and GloriousFlywheel flow

**Claim.** The public spoke's `ci.yml` is a thin wrapper over
`tinyland-inc/ci-templates` `spoke-ci.yml`, pinned at `v2.9.0`, running on the
`tinyland-nix` runner class (honey/sting pool). Bazel work goes through the
`scripts/gloriousflywheel-bazel.sh` wrapper, which holds the endpoint authority
and injects `--remote_cache` (and, only when executor mode is selected,
`--remote_executor`) so `.bazelrc.flywheel` stays endpoint-free. Registries
resolve `tinyland-inc/bazel-registry` first, then BCR. The shared cache is
read-only on PRs (`--remote_upload_local_results=false`); the `gf-reapi-cell`
executor is configured as a documented substrate fact but is opt-in and not
wired into the primary lane, and cache-write publication is blocked pending
TIN-1147.

**Sources of truth.** Runner class and template pin:
`greatfallstoolbus.org` `.github/workflows/ci.yml`
(`uses: tinyland-inc/ci-templates/.github/workflows/spoke-ci.yml@v2.9.0`,
`default_runner_class: tinyland-nix`, `flywheel_config: flywheel`,
`cache_backed: true`). Registry chain and endpoint-free posture:
`greatfallstoolbus.org` `.bazelrc` (two `--registry` lines, bazel-registry
first) and `.bazelrc.flywheel` (`remote_upload_local_results=false`, TIN-1147
invariant, `flywheel-executor` config separate and tag-gated). Wrapper
authority: `greatfallstoolbus.org` `scripts/gloriousflywheel-bazel.sh` and
`Justfile` `flywheel-*` recipes. Executor endpoint as documented-only fact:
this repo's `README.md` ("Shared Bazel executor
`grpc://gf-reapi-cell.gf-rbe.svc.cluster.local:8980`, documented substrate
fact, NOT wired into the primary lane yet").

```mermaid
flowchart TD
    ci["Spoke ci.yml"]
    tmpl["ci-templates spoke-ci.yml@v2.9.0<br/>runs-on tinyland-nix (honey/sting)"]
    wrapper["scripts/gloriousflywheel-bazel.sh<br/>endpoint authority<br/>injects --remote_cache / --remote_executor"]
    rc[".bazelrc.flywheel<br/>endpoint-free<br/>upload_local_results=false"]
    cache["GF shared Bazel cache<br/>read-only on PRs<br/>cache-write blocked TIN-1147"]
    exec["gf-reapi-cell executor<br/>configured, opt-in<br/>NOT in primary lane"]
    reg1["Registry 1<br/>tinyland-inc/bazel-registry"]
    reg2["Registry 2<br/>BCR"]

    ci -->|"uses"| tmpl
    tmpl -->|"bazel via"| wrapper
    wrapper -->|"reads"| rc
    wrapper -->|"--remote_cache"| cache
    wrapper -.->|"--remote_executor (opt-in)"| exec
    wrapper -->|"resolve first"| reg1
    reg1 -->|"fallback"| reg2
```
