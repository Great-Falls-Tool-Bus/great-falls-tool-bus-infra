# GFTB edge zones and on-cluster origin

This is the current operator procedure for the two GFTB Cloudflare zones. The
OpenTofu source is [`tofu/stacks/edge/`](../../tofu/stacks/edge/README.md).
Cloudflare Pages, GitHub Pages, Wrangler publication, and origin flips to a
`pages.dev` host are not deployment or rollback paths.

The repository contains names and declarations only. Token values, account
identifiers, email allowlists, and other secret material remain in operator
custody. This runbook never authorizes a secret mint, rotation, or revocation.

## Current authority and serving shape

- The two zones are console-created on the house Cloudflare account. The stack
  looks them up by name and never creates or transfers a zone.
- `greatfallstoolbus.org` apex and `www` are proxied CNAMEs to the shared
  honey-ingress Cloudflare Tunnel target held by the compatibility-named
  `pages_host` variable.
- The tunnel serves the in-cluster `gftb-site` static Caddy workload. Image
  promotion and rollback use the exact-plan `web-release-*` transaction in
  [`oncluster-web-cutover.md`](oncluster-web-cutover.md).
- Cloudflare Access gates apex and `www` until the separately reviewed public
  flip. Dev and preview hostnames retain their independent Access application.
- `latoolb.us` apex and `www` use the managed redirect ruleset. Mail, forms,
  and archive records are controlled by their explicit variables in the edge
  stack.

## Registrar custody

Both domains renew on 2027-06-29. Registrar-side management is through the
DreamHost panel; the `latoolb.us` WHOIS registrar is eNom because DreamHost
uses that registry channel for `.us` domains.

Zone addition and nameserver changes are operator-console actions. Before any
registrar change, capture current WHOIS and authoritative NS results and
server-dry-run the edge declaration. The DreamHost API can inspect records but
cannot change registration nameservers.

## Active edge token contract

`TF_VAR_cloudflare_api_token` is the one active edge credential. CI names it
`CLOUDFLARE_API_TOKEN_GFTB_ZONES`; the operator SOPS lane names it
`cloudflare-api-token-gftb-zones`. Its scope is exactly:

- Zone DNS Edit for `greatfallstoolbus.org` and `latoolb.us`;
- Zone Dynamic Redirect Edit for those two zones;
- Access Apps and Policies Edit for those two zones; and
- Access Organizations, Identity Providers, and Groups Edit for the house
  account, required by the Google Workspace identity provider.

Do not broaden the token to all zones or all accounts. Do not add Pages,
Workers, storage, or general account-administration permissions.

The repository environment binding, if it must be restored, is:

```bash
gh secret set CLOUDFLARE_API_TOKEN_GFTB_ZONES \
  --env edge \
  --repo Great-Falls-Tool-Bus/great-falls-tool-bus-infra
```

The command reads the value from standard input. Never put a value in argv,
Git, a PR, a CI artifact, or a transcript.

### Retired Pages credential hold

The names `cloudflare-api-token-gftb-pages`,
`CLOUDFLARE_API_TOKEN_GFTB_PAGES`, `CLOUDFLARE_API_TOKEN`, and
`CLOUDFLARE_ACCOUNT_ID` may still exist in operator or repository custody from
the retired Pages publisher. They have no GFTB web deployment consumer and
must not be recreated, copied, exercised, rotated, or revoked without explicit
per-item operator direction.

## Edge plan and apply

Use the registered operator surface:

```bash
just edge-zones-plan
just edge-zones-apply
```

The current workflow carrier is `.github/workflows/edge-plan.yml`; it is
credentialed only for the manually dispatched edge transaction. Direct
Cloudflare API mutation and ad hoc OpenTofu entrypoints are not supported.

The web-origin variable retains the historical name `pages_host` for state and
input compatibility. Its admitted value is the shared tunnel CNAME declared
as the default in `variables.tf`. A `pages.dev` or `github.io` value is a dead
origin, not a rollback. Web rollback changes only the reviewed image digest and
source SHA through `web-release-*`; it does not repoint DNS.

## Verification

Public, non-secret checks:

```bash
dig NS greatfallstoolbus.org +short @1.1.1.1
dig NS latoolb.us +short @1.1.1.1
dig A greatfallstoolbus.org +short @1.1.1.1
dig CNAME www.greatfallstoolbus.org +short @1.1.1.1
dig A latoolb.us +short @1.1.1.1

curl -sI https://greatfallstoolbus.org/ | sed -n '1p;/^location/Ip'
curl -sI https://www.greatfallstoolbus.org/ | sed -n '1p;/^location/Ip'
curl -sI https://latoolb.us/ | sed -n '1p;/^location/Ip'
curl -sI https://www.latoolb.us/ | sed -n '1p;/^location/Ip'
```

For the origin itself, use `just web-release-pinned-running-proof` and
`just web-release-served-proof`. Those recipes bind the exact image digest,
source SHA, live pods, service endpoints, and externally served bytes. An
anonymous Access redirect is not origin evidence.

Mail record verification and enablement remain in the mail-specific runbooks;
forms and archive ingress remain in their stack-specific runbooks. Do not use
this edge procedure to infer or mutate those application lifecycles.
