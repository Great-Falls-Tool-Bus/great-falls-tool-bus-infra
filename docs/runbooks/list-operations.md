# GFTB Mailman list-operations runbook

Tracking: TIN-2380. Companion to
[`docs/runbooks/list-bringup.md`](list-bringup.md). The bring-up runbook covers
**deploying** the engine; this runbook covers **operating** the lists day to
day: managing members, moderating traffic, changing settings, and running the
stack. It is written for operators and agents with read/write REST access to
the running `mailman-core` pod.

Verified read-only against the live stack on 2026-07-04 (GNU Mailman 3.3.10,
REST API 3.1) in namespace `latoolb-us-production`, context `honey`.

## 1. Mental model: two lists, one engine

One GNU Mailman 3 stack in `latoolb-us-production` hosts **two** lists on the
same engine. Both are owned by `jess@sulliwood.org`, who is the first member and
first owner of each.

| List | Role | archive_policy | subscription_policy | default_nonmember_action | advertised |
| --- | --- | --- | --- | --- | --- |
| `keyholders@latoolb.us` | Private access-gating role list | `private` | `moderate` (owner-approved) | `accept` | `false` |
| `discuss@latoolb.us` | Public community board | `public` | `confirm` (open, email-confirmed) | `hold` | `true` |

- **`keyholders@latoolb.us`** federates keyholders through their own mail
  clients so any keyholder can pick up an access request. Membership is
  owner-curated (`moderate`). Non-member posts are **accepted**, so a stranger
  can send a first-contact access request that fans out to every keyholder.
  Because those requests can carry names, contact details, tool needs, and
  scheduling context, the archive is **private** and must stay that way.
- **`discuss@latoolb.us`** is the open board. Anyone can subscribe with email
  confirmation (`confirm`), the archive is **public**, and non-member posts are
  **held** for moderation rather than accepted.

Both lists share one transport into the engine. The substrate postfix map routes
list mail to the LMTP listener at
`lmtp:[mailman-core.latoolb-us-production.svc.cluster.local]:8024`. Outbound
fan-out submits as `lists-bounces@latoolb.us` over 587 STARTTLS + SASL to
`postfix.tinyland-dev-production.svc.cluster.local`.

### Where config lives, and what that means for drift

List settings (archive policy, subscription policy, moderation actions, rosters,
held messages) live in the **Mailman Postgres database**, NOT in this repo's
manifests. The Kubernetes manifests under `k8s/list/latoolb-us-production/`
define the **engine** (pods, services, PVCs, network policy, the SMTP/LMTP
wiring). They do not define list-level configuration.

Consequences:

- You cannot restore a list setting with `kubectl apply`. A setting changed
  through REST, the CLI, or Postorius is authoritative in the database and
  survives pod restarts (state is on the retained PVCs).
- There is no GitOps reconciliation of list settings. The ratified baseline in
  section 5 is the written source of truth; if the database drifts from it, an
  operator must PATCH it back by hand.
- Back up by protecting the `mailman-postgres-data` PVC, not by trusting Git.

## 2. Admin access pattern

### REST is bound to the pod IP, so port-forward does not work

> **WARNING.** `mailman-core` binds its REST API to the **pod IP** on `:8001`,
> not to `0.0.0.0` or `127.0.0.1`. A `kubectl port-forward` to the pod or
> service reaches `localhost` inside the target, which the REST server is NOT
> listening on, so the connection is refused. The only supported admin path is
> `kubectl exec` into the pod and curling `$(hostname -i):8001` from inside. The
> REST port is also intra-namespace-only by NetworkPolicy (web -> core), so
> there is no external surface to forward to regardless.

### REST recipe (copy-paste)

The REST password is in the pod environment as `MAILMAN_REST_PASSWORD` (from the
`mailman-app` Secret); the REST user is `restadmin`. Never echo the password
value; reference it by variable only.

```bash
# Resolve the running core pod once.
CORE=$(kubectl --context honey -n latoolb-us-production \
  get pod -l app.kubernetes.io/name=mailman-core \
  -o jsonpath='{.items[0].metadata.name}')

# List both lists (smoke that REST is answering).
kubectl --context honey -n latoolb-us-production exec "$CORE" -- sh -c '
  curl -s -u restadmin:"$MAILMAN_REST_PASSWORD" \
    "http://$(hostname -i):8001/3.1/lists"
'
```

Every REST call in this runbook follows the same shape: `kubectl exec` into
`$CORE`, then `curl -s -u restadmin:"$MAILMAN_REST_PASSWORD"
"http://$(hostname -i):8001/3.1/..."`. List paths accept either the dotted
`list_id` (`keyholders.latoolb.us`) or the `fqdn_listname`
(`keyholders@latoolb.us`).

### Mailman CLI (run as the `mailman` user)

Some operations are cleaner through the `mailman` CLI. The CLI must run as the
`mailman` user or it fails on permissions; wrap it in `su`:

```bash
kubectl --context honey -n latoolb-us-production exec "$CORE" -- \
  su mailman -s /bin/sh -c "mailman lists"
```

Use `mailman members <list>@latoolb.us`, `mailman info`, and
`mailman withlist` for read and scripted operations. Prefer REST for member and
moderation changes so the actions are uniform and auditable.

## 3. Member management (per list)

The write field on a member-add POST is **`subscriber`** (the email address),
NOT `subject`. Getting this wrong is the most common failed call.

### Roster: who is on a list

```bash
# roles: member | owner | moderator | nonmember
kubectl --context honey -n latoolb-us-production exec "$CORE" -- sh -c '
  curl -s -u restadmin:"$MAILMAN_REST_PASSWORD" \
    "http://$(hostname -i):8001/3.1/lists/keyholders.latoolb.us/roster/member"
'
```

Each entry carries a `member_id` and a `self_link`
(`.../3.1/members/<member_id>`). You need the `member_id` to remove or inspect a
specific membership.

### Add a member (direct REST)

```bash
kubectl --context honey -n latoolb-us-production exec "$CORE" -- sh -c '
  curl -s -u restadmin:"$MAILMAN_REST_PASSWORD" \
    -d "list_id=keyholders.latoolb.us" \
    -d "subscriber=newkeyholder@example.org" \
    -d "display_name=New Keyholder" \
    -d "pre_verified=true" \
    -d "pre_confirmed=true" \
    -d "pre_approved=true" \
    -d "role=member" \
    "http://$(hostname -i):8001/3.1/members"
'
```

The three `pre_*` flags decide how much of the join workflow is skipped, and
they are how an owner adds a member without a round of confirmation email:

- `pre_verified=true`: treat the address as already verified (skip address
  verification).
- `pre_confirmed=true`: skip the subscriber's own email confirmation step.
- `pre_approved=true`: skip owner/moderator approval. On `keyholders@`, whose
  `subscription_policy` is `moderate`, omitting `pre_approved` leaves the add
  sitting in the subscription-request queue (see section 4) instead of taking
  effect. Set all three when you, the owner, are intentionally adding a known
  keyholder.

### keyholders join flow: two supported paths

`keyholders@` is `moderate` (owner-approved). There are two supported ways a
person becomes a member:

1. **Email flow (candidate-initiated).** The candidate emails
   `keyholders-join@latoolb.us` (the Mailman join address). Mailman verifies and
   confirms the address, then places an owner-approval request in the list's
   requests queue. An owner approves it (section 4). This is the expected path
   for someone who is becoming a keyholder and can act for themselves.
2. **Direct REST add (owner-initiated).** The owner adds the address with all
   three `pre_*` flags set, as shown above. Use this when the owner is
   provisioning a known keyholder directly.

Do not subscribe people just because the list exists; add a member only with
their consent.

### Remove or boot a member

Find the `member_id` from the roster, then DELETE the member resource:

```bash
kubectl --context honey -n latoolb-us-production exec "$CORE" -- sh -c '
  curl -s -u restadmin:"$MAILMAN_REST_PASSWORD" -X DELETE \
    "http://$(hostname -i):8001/3.1/members/<member_id>"
'
```

Deleting the `member` membership removes them from delivery. If they also hold
an `owner` or `moderator` membership, that is a **separate** membership resource
with its own `member_id`; delete each role you want to revoke.

### Promote to owner or moderator

Ownership and moderation are memberships with a different `role` on the same
address. Add one the same way as a member, with `role=owner` or
`role=moderator`:

```bash
kubectl --context honey -n latoolb-us-production exec "$CORE" -- sh -c '
  curl -s -u restadmin:"$MAILMAN_REST_PASSWORD" \
    -d "list_id=keyholders.latoolb.us" \
    -d "subscriber=trusted@example.org" \
    -d "role=owner" \
    -d "pre_verified=true" -d "pre_confirmed=true" -d "pre_approved=true" \
    "http://$(hostname -i):8001/3.1/members"
'
```

List the owner or moderator roster with `.../roster/owner` or
`.../roster/moderator`.

## 4. Moderation

### Held messages (non-member posts)

`discuss@` **holds** non-member posts (`default_nonmember_action=hold`).
`keyholders@` **accepts** them (`default_nonmember_action=accept`), so on
`keyholders@` there is normally nothing in the held queue; access requests flow
straight through to keyholders. View the held queue:

```bash
kubectl --context honey -n latoolb-us-production exec "$CORE" -- sh -c '
  curl -s -u restadmin:"$MAILMAN_REST_PASSWORD" \
    "http://$(hostname -i):8001/3.1/lists/discuss.latoolb.us/held"
'
```

Each held entry has a `request_id`. Act on one by POSTing an `action` of
`accept`, `discard`, `reject`, or `defer`:

```bash
kubectl --context honey -n latoolb-us-production exec "$CORE" -- sh -c '
  curl -s -u restadmin:"$MAILMAN_REST_PASSWORD" \
    -d "action=accept" \
    "http://$(hostname -i):8001/3.1/lists/discuss.latoolb.us/held/<request_id>"
'
```

### Subscription requests (owner approval)

On `keyholders@` (`moderate`), a candidate who mails `keyholders-join@` or a
REST add without `pre_approved` lands in the requests queue. List pending
requests and approve one with an `action` of `accept`, `discard`, `reject`, or
`defer`:

```bash
# View pending subscription requests.
kubectl --context honey -n latoolb-us-production exec "$CORE" -- sh -c '
  curl -s -u restadmin:"$MAILMAN_REST_PASSWORD" \
    "http://$(hostname -i):8001/3.1/lists/keyholders.latoolb.us/requests"
'

# Approve one (token comes from the request entry).
kubectl --context honey -n latoolb-us-production exec "$CORE" -- sh -c '
  curl -s -u restadmin:"$MAILMAN_REST_PASSWORD" \
    -d "action=accept" \
    "http://$(hostname -i):8001/3.1/lists/keyholders.latoolb.us/requests/<token>"
'
```

`admin_immed_notify=true` on both lists means owners are emailed immediately
when a request needs attention.

## 5. List settings changes

Change a setting by PATCHing the list `config` resource. Send only the fields you
are changing:

```bash
kubectl --context honey -n latoolb-us-production exec "$CORE" -- sh -c '
  curl -s -u restadmin:"$MAILMAN_REST_PASSWORD" -X PATCH \
    -d "default_nonmember_action=hold" \
    "http://$(hostname -i):8001/3.1/lists/discuss.latoolb.us/config"
'
```

### Ratified baseline (restore target)

If the database drifts, restore these values. They are the operator-ratified
2026-07-04 baseline, confirmed live the same day.

**`keyholders@latoolb.us`:**

| Setting | Value |
| --- | --- |
| `archive_policy` | `private` |
| `subscription_policy` | `moderate` |
| `default_member_action` | `accept` |
| `default_nonmember_action` | `accept` |
| `advertised` | `false` |
| `admin_immed_notify` | `true` |

**`discuss@latoolb.us`:**

| Setting | Value |
| --- | --- |
| `archive_policy` | `public` |
| `subscription_policy` | `confirm` |
| `default_member_action` | `accept` |
| `default_nonmember_action` | `hold` |
| `advertised` | `true` |
| `admin_immed_notify` | `true` |

### Safety-critical settings

> **`archive_policy` on `keyholders@` MUST stay `private`.** Never set it to
> `public`. Because `keyholders@` accepts non-member posts, a stranger's
> first-contact access request (names, contact details, tool needs, location and
> scheduling context) is delivered to the list and archived. A public archive
> would publish that PII to anyone. This is the single most dangerous setting on
> the stack. `discuss@` is public by design and carries no such data.

`subscription_policy=moderate` on `keyholders@` is the other guardrail: it keeps
membership owner-curated so the keyholder set is not open to self-subscription.

## 6. Stack management

### Pod layout

> **Note (2026-07-04, TIN-2493):** `mailman-core` and `mailman-web` are
> **co-located in one pod** (two containers in the `mailman-core` Deployment) so
> the HyperKitty archive POST travels over loopback and its source IP matches
> the archiver trust. See section 7 for the root cause this replaced.

| Pod (Deployment) | Containers | Role | Data |
| --- | --- | --- | --- |
| `mailman-core` | `mailman-core` | Mailman 3 core: LMTP listener `:8024`, REST `:8001` (pod IP), outgoing runner (587 STARTTLS + SASL) | `mailman-core-data` PVC at `/opt/mailman` (message store + queue) |
| `mailman-core` | `mailman-web` | Postorius (list admin UI) + HyperKitty (archive), uwsgi HTTP on container port `8000` (Service `mailman-web:8080`) | `mailman-web-data` PVC at `/opt/mailman-web-data` (search index, static, uploads) |
| `mailman-postgres` | `mailman-postgres` | PostgreSQL 16.4 backing both `mailman` (core) and `mailmanweb` (web) databases | `mailman-postgres-data` PVC (authoritative list state) |

The `mailman-web` Service still exists and now selects the `mailman-core` pod
(targetPort `8000`, external `:8080` unchanged). All three PVCs use
`storageClassName: local-path-retain`, so the volumes survive a PVC reclaim. The
Postgres PVC is the one that holds all list configuration and membership; protect
it.

### Safe restart order

The Deployments use `Recreate` strategy. After co-location (TIN-2493) the
restart set is two Deployments, not three:

1. `mailman-postgres` first; wait for it to be Ready (`pg_isready`).
2. `mailman-core` next; it now runs both the core and web containers, so one
   `rollout restart` cycles the whole list engine plus the archive/admin UI. It
   needs the database and hosts REST/LMTP; the co-located web tier reaches core
   REST over the `mailman-core` Service and archives over loopback once core is
   up.

Restart a Deployment with
`kubectl --context honey -n latoolb-us-production rollout restart deploy/<name>`
and wait for Ready. A core restart briefly drops the LMTP listener (substrate
deliveries retry until it returns) and the web UI at the same time, since they
share the pod.

### Operator secrets (by name only)

Three operator-owned Secrets live in `latoolb-us-production`, referenced by name
from the Deployments. No values are in Git.

- `mailman-db`: Postgres credentials and the two `DATABASE_URL_*` connection
  strings.
- `mailman-app`: Django secret key, HyperKitty API key, `MAILMAN_REST_PASSWORD`,
  `MAILMAN_ADMIN_PASSWORD`.
- `lists-bounces-smtp`: the `lists-bounces@latoolb.us` SASL submission username
  and password.

### Credential custody

Custody of these secret values is the operator's keychain, not this repo and not
the cluster as a source of truth. The `lists-bounces-smtp` password is the
controller-generated `MailAccount` credential, projected in by the operator
after the `lists-bounces` `MailAccount` reconciles. Never hand-mint it (see
section 7).

### Dovecot bridge note

New `MailAccount` resources for this tenant currently require a manual merge of
the tenant namespace's dovecot user into the mail namespace `dovecot-users`
until blahaj #872 defect 3 is fixed. When you add a `MailAccount` (for example a
future list submission identity), plan for that hand-merge step; the account
controller does not yet converge it automatically.

## 7. Known gaps and do-not-do list

### Known gaps

- **TIN-2493, HyperKitty archiver 403 (High) — fix staged, operator-gated.**
  In the original two-Deployment shape the archive POST from `mailman-core` to
  `mailman-web` returned 403 because `MAILMAN_ARCHIVER_FROM` trusts a fixed IP
  but the POST arrived from the core **pod IP** (dynamic, `10.244.x`). The fix
  (this manifest revision, 2026-07-04) co-locates the web tier in the
  `mailman-core` pod so the POST goes over loopback (`127.0.0.1:8000`) with
  `MAILMAN_HOST_IP=127.0.0.1`, and it survives a core restart because the
  loopback source is stable. Until the co-located manifests are applied,
  archives do **not** populate; do not treat an empty archive as message loss,
  since delivery and fan-out are independent of archiving.
- **`lists.latoolb.us` has no DNS or tunnel.** The public archive/admin
  hostname is not published. There is no MX, no A/AAAA, and no Cloudflare tunnel
  route pointing at `mailman-web`.
- **Postorius/HyperKitty are unexposed.** The `mailman-web` UI (container port
  `8000`, Service `:8080`) exists in-cluster but has no public ingress. Admin
  today is REST-over-exec (section 2), not the web UI.

### What NOT to do

- **Never hand-mint `lists-bounces` credentials.** The password is
  controller-generated on `MailAccount` reconcile and projected into
  `lists-bounces-smtp` by the operator. Minting your own breaks SASL submission
  and diverges from the account controller's source of truth.
- **Never flip `keyholders@` `archive_policy` to `public`.** See section 5:
  access-request PII would be published. This is a hard stop.
- **Do not rely on `kubectl port-forward` for REST.** It cannot reach the
  pod-IP-bound listener; use `kubectl exec` (section 2).
- **Do not expect list settings in Git.** They live in Postgres; restore drift
  from the section 5 baseline, not from `kubectl apply`.
