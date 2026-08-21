#!/usr/bin/env bash
# shellcheck disable=SC2016
# SC2016 is intentional throughout: the `$var` inside every single-quoted yq
# program is a jq variable bound by `--arg`, not a shell expansion. Binding it
# through --arg (rather than interpolating the shell value into the filter) is
# what keeps a name from being able to inject jq syntax. Same convention as
# scripts/validate-web-stack.sh.
set -euo pipefail

# DECLARE-ONLY guard for the GFTB member database substrate (TIN-3817, Member v0
# slice S1 infra half). Offline: it never contacts a cluster and never needs a
# credential, so it runs in hosted CI through `just check-hosted`.
#
# WHAT THIS GUARD IS FOR. The member database is the first GFTB surface that
# holds personal data under an explicit RPO/RTO acceptance row, and three of its
# invariants fail SILENTLY when they regress:
#
#   1. A tag instead of a digest still deploys "PostgreSQL 16", just not 16.15.
#   2. `bypassrls: true` on the runtime role still works, it just makes every
#      RLS policy the app half writes decorative.
#   3. A missing `archive_timeout` still archives WAL under load, it just leaves
#      an idle database with an unbounded RPO.
#
# None of the three produces an error at apply time. They produce a green
# cluster that does not meet the contract. So each one is asserted here rather
# than described in a runbook.

dir="${1:?usage: validate-member-db-stack.sh <db-manifest-dir>}"
member_root="$(cd "${dir}/.." && pwd)"
platform_dir="${member_root}/members-greatfallstoolbus-org-production"

cluster="${dir}/cluster.yaml"
schedbackup="${dir}/scheduledbackup.yaml"
netpol="${dir}/networkpolicy.yaml"
kustomization="${dir}/kustomization.yaml"
job_template="${platform_dir}/job-migrator.template.yaml"
secrets_contract="${member_root}/secrets.contract.yaml"
rustfs="${dir}/rustfs.yaml"

# --- reviewed constants ------------------------------------------------------
# The exact minor TIN-3817 acceptance row 1 names, and the multi-arch index
# digest that carries it (org.opencontainers.image.version=16.15). Bumping
# PostgreSQL is a reviewed change to BOTH this constant and cluster.yaml, never
# a silent registry-side move.
readonly WANT_PG_REPO="ghcr.io/cloudnative-pg/postgresql"
readonly WANT_PG_DIGEST="sha256:e38d10bb2c7420e62efe9afabf207c005d93cdcf30f19f692d047f7dc660271e"
readonly WANT_DB_NS="members-greatfallstoolbus-org-db-production"
readonly WANT_PLATFORM_NS="members-greatfallstoolbus-org-production"
readonly WANT_CLUSTER="gftb-member-db"
readonly WANT_DATABASE="gftb_member"
readonly WANT_OWNER_ROLE="gftb_migrator"
readonly WANT_RUNTIME_ROLE="gftb_app"
readonly WANT_RUNTIME_SECRET="gftb-member-db-runtime"
readonly WANT_MIGRATOR_SECRET="gftb-member-db-migrator-dsn"
readonly WANT_STORAGE_CLASS="openebs-bumble-postgresql-retain"
readonly WANT_MIGRATOR_ARGS='["migrator"]'
readonly WANT_IMAGE_PLACEHOLDER="PLACEHOLDER-MEMBER-DB-MIGRATOR-IMAGE"
# B1 ruling (2026-08-20): GFTB-owned rustfs backup store. Digest reused
# verbatim from the house pin source, blahaj deploy/nix-cache/
# attic-rustfs-openebs.yaml:214.
readonly WANT_RUSTFS_REPO="docker.io/rustfs/rustfs"
# The house pin source (blahaj attic-rustfs-openebs.yaml:214) carries both a
# tag and a digest; the digest is what actually pins the pull, and this
# validator requires it be present and correct regardless of the tag string.
readonly WANT_RUSTFS_TAG="1.0.0-beta.8"
readonly WANT_RUSTFS_DIGEST="sha256:fa19210ac4697c79d7ccca1ec9b0eb91aebacc6691991ffb14014bb3c67e6cc3"
readonly WANT_RUSTFS_NAME="gftb-member-db-backup-store"
readonly WANT_RUSTFS_STORAGECLASS="local-path-sting"
readonly MIN_RUSTFS_STORAGE_GI=50
# TIN-3817 acceptance row 8: structured-data RPO no worse than one hour. The
# manifest declares 300s; this is the CEILING the guard enforces, so tightening
# the manifest stays legal and loosening it past the acceptance row does not.
readonly MAX_ARCHIVE_TIMEOUT_SECONDS=3600

fail() {
  echo "ERROR: $*" >&2
  exit 1
}
require_file() { test -f "$1" || fail "missing $1"; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: got '$1', want '$2'"; }

command -v yq >/dev/null 2>&1 || fail "yq is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v kubectl >/dev/null 2>&1 || fail "kubectl is required for the render check"

for f in "${cluster}" "${schedbackup}" "${netpol}" "${kustomization}" \
  "${job_template}" "${secrets_contract}" "${rustfs}"; do
  require_file "${f}"
done

# --- render ONCE, up front. Every assertion below that cares what actually
# gets applied reads THIS file, never a source YAML directly — kustomize
# (the `resources:` list, the `labels:` transformer) sits between the two,
# and a regression there (a dropped `- networkpolicy.yaml` line, a dropped
# `- rustfs.yaml` or `- scheduledbackup.yaml` line) can leave every
# source-file assertion green while the applied bytes are missing an entire
# NetworkPolicy, the backup store, or the RTO control. `kubectl kustomize`
# only parses the local tree; it never touches a cluster. (B-7, same class as
# #121's E1.) The migration Job template is deliberately NOT part of this
# render (axis 12 below asserts it never becomes one), so its own assertions
# keep reading the source file directly.
rendered="$(mktemp)"
trap 'rm -f "${rendered}"' EXIT
kubectl kustomize "${dir}" > "${rendered}"

# --- stack identity ----------------------------------------------------------
# Every assertion below binds to the namespace this stack declares, so a copy of
# this tree pointed at some other namespace fails here instead of inheriting the
# member database's admission decisions.
stack_ns="$(yq -r 'select(.kind == "Cluster") | .metadata.namespace' "${rendered}")"
assert_eq "${stack_ns}" "${WANT_DB_NS}" "CNPG Cluster namespace"
cluster_name="$(yq -r 'select(.kind == "Cluster") | .metadata.name' "${rendered}")"
assert_eq "${cluster_name}" "${WANT_CLUSTER}" "CNPG Cluster name"
api="$(yq -r 'select(.kind == "Cluster") | .apiVersion' "${rendered}")"
assert_eq "${api}" "postgresql.cnpg.io/v1" "CNPG Cluster apiVersion"

# --- axis 1: PostgreSQL 16.15, pinned by digest ------------------------------
# A tag would let the served minor drift off the acceptance row without any
# change to this repository. Nothing but this repository at this digest passes:
# no tag, no truncated or uppercase digest, no other registry or fork.
image="$(yq -r 'select(.kind == "Cluster") | .spec.imageName' "${rendered}")"
case "${image}" in
*PLACEHOLDER*) fail "CNPG imageName must be a real digest-pinned reference: '${image}'" ;;
esac
if [[ ! "${image}" =~ ^"${WANT_PG_REPO}"@sha256:[0-9a-f]{64}$ ]]; then
  fail "CNPG imageName must be ${WANT_PG_REPO} pinned by @sha256:<64 lowercase hex>; got '${image}'"
fi
assert_eq "${image}" "${WANT_PG_REPO}@${WANT_PG_DIGEST}" \
  "CNPG image digest (TIN-3817 acceptance row 1 pins PostgreSQL 16.15)"

# --- axis 2: single instance on the purpose-built, node-pinned class ---------
instances="$(yq -r 'select(.kind == "Cluster") | .spec.instances' "${rendered}")"
assert_eq "${instances}" "1" "CNPG instances"
data_sc="$(yq -r 'select(.kind == "Cluster") | .spec.storage.storageClass' "${rendered}")"
wal_sc="$(yq -r 'select(.kind == "Cluster") | .spec.walStorage.storageClass' "${rendered}")"
assert_eq "${data_sc}" "${WANT_STORAGE_CLASS}" "data storageClass"
assert_eq "${wal_sc}" "${WANT_STORAGE_CLASS}" "WAL storageClass"
# WAL on its own volume is what stops an archive stall from filling the data
# volume; losing the separation is a durability regression, not a tidy-up.
wal_size="$(yq -r 'select(.kind == "Cluster") | .spec.walStorage.size' "${rendered}")"
test -n "${wal_size}" && [ "${wal_size}" != "null" ] || fail "walStorage.size must be declared (WAL must not share the data volume)"

# --- axis 3: no superuser reachable after bootstrap --------------------------
superuser="$(yq -r 'select(.kind == "Cluster") | .spec.enableSuperuserAccess' "${rendered}")"
assert_eq "${superuser}" "false" "enableSuperuserAccess"

# --- axis 4: RPO control (acceptance row 8) ----------------------------------
# archive_timeout is what bounds RPO on an IDLE database. Without it a quiet
# cluster holds an unarchived partial segment indefinitely and the real RPO is
# unbounded, while every dashboard still looks healthy.
archive_timeout="$(yq -r 'select(.kind == "Cluster") | .spec.postgresql.parameters.archive_timeout' "${rendered}")"
if [[ ! "${archive_timeout}" =~ ^([0-9]+)s$ ]]; then
  fail "postgresql.parameters.archive_timeout must be declared as '<seconds>s' (RPO<=1h acceptance row); got '${archive_timeout}'"
fi
archive_seconds="${BASH_REMATCH[1]}"
if [ "${archive_seconds}" -gt "${MAX_ARCHIVE_TIMEOUT_SECONDS}" ] || [ "${archive_seconds}" -le 0 ]; then
  fail "archive_timeout ${archive_seconds}s breaches the RPO<=1h acceptance row (must be 1..${MAX_ARCHIVE_TIMEOUT_SECONDS}s)"
fi

# --- axis 5: WAL archiving destination is in-cluster only --------------------
# The backup credential and the archive destination are the two things that make
# the RPO/RTO rows real. The destination must never become an internet endpoint
# by edit: a public endpointURL would ship member data off the estate.
endpoint="$(yq -r 'select(.kind == "Cluster") | .spec.backup.barmanObjectStore.endpointURL' "${rendered}")"
if [[ ! "${endpoint}" =~ ^https?://[a-z0-9.-]+\.svc\.cluster\.local:[0-9]{2,5}/?$ ]]; then
  fail "barmanObjectStore.endpointURL must be an in-cluster <service>.<ns>.svc.cluster.local:<port> address; got '${endpoint}'"
fi
destination="$(yq -r 'select(.kind == "Cluster") | .spec.backup.barmanObjectStore.destinationPath' "${rendered}")"
case "${destination}" in
s3://gftb-member-db-backups*) ;;
*) fail "barmanObjectStore.destinationPath must be the GFTB-scoped bucket s3://gftb-member-db-backups; got '${destination}'" ;;
esac
retention="$(yq -r 'select(.kind == "Cluster") | .spec.backup.retentionPolicy' "${rendered}")"
test -n "${retention}" && [ "${retention}" != "null" ] || fail "backup.retentionPolicy must be declared"
# Credentials by NAME only. A literal `value:` anywhere under s3Credentials would
# mean a secret value had entered git.
if yq -r 'select(.kind == "Cluster") | .spec.backup.barmanObjectStore.s3Credentials | .. | select(type == "object") | keys[]?' "${rendered}" | grep -Ex "value|stringValue" >/dev/null 2>&1; then
  fail "s3Credentials must reference Secret keys by name only; an inline value is present"
fi

# --- axis 6: the two-role separation (acceptance row 2) ----------------------
database="$(yq -r 'select(.kind == "Cluster") | .spec.bootstrap.initdb.database' "${rendered}")"
owner="$(yq -r 'select(.kind == "Cluster") | .spec.bootstrap.initdb.owner' "${rendered}")"
assert_eq "${database}" "${WANT_DATABASE}" "bootstrap database"
assert_eq "${owner}" "${WANT_OWNER_ROLE}" "bootstrap owner (the narrow migration credential)"
if [ "${owner}" = "${WANT_RUNTIME_ROLE}" ]; then
  fail "the migration owner and the runtime role must be distinct roles"
fi

managed_count="$(yq -r 'select(.kind == "Cluster") | [.spec.managed.roles[]?] | length' "${rendered}")"
assert_eq "${managed_count}" "1" "managed.roles entries (exactly the DML-only runtime role)"
runtime_name="$(yq -r --arg r "${WANT_RUNTIME_ROLE}" 'select(.kind == "Cluster") | .spec.managed.roles[] | select(.name == $r) | .name' "${rendered}")"
assert_eq "${runtime_name}" "${WANT_RUNTIME_ROLE}" "managed runtime role name"

runtime_field() {
  yq -r --arg r "${WANT_RUNTIME_ROLE}" --arg f "$1" \
    'select(.kind == "Cluster") | .spec.managed.roles[] | select(.name == $r) | .[$f]' "${rendered}"
}
# bypassrls is the single most load-bearing assertion in this file. RLS is the
# tenant boundary the whole S1 design rests on (spec S4: "row isolation ...
# enforced in PostgreSQL"); a runtime role with BYPASSRLS reads every tenant's
# rows while every policy in the app's migrations still looks correct.
assert_eq "$(runtime_field bypassrls)" "false" "runtime role bypassrls (RLS must not be optional for it)"
assert_eq "$(runtime_field superuser)" "false" "runtime role superuser"
assert_eq "$(runtime_field createdb)" "false" "runtime role createdb"
assert_eq "$(runtime_field createrole)" "false" "runtime role createrole"
assert_eq "$(runtime_field replication)" "false" "runtime role replication"
assert_eq "$(runtime_field login)" "true" "runtime role login"
assert_eq "$(runtime_field ensure)" "present" "runtime role ensure"
runtime_secret="$(yq -r --arg r "${WANT_RUNTIME_ROLE}" 'select(.kind == "Cluster") | .spec.managed.roles[] | select(.name == $r) | .passwordSecret.name' "${rendered}")"
assert_eq "${runtime_secret}" "${WANT_RUNTIME_SECRET}" "runtime role passwordSecret (by name only)"

# The DML-only grant surface is set at bootstrap; losing the default-privileges
# statements means the runtime role silently loses access to every table a later
# migration creates, which surfaces as a production outage rather than a test
# failure.
init_sql="$(yq -r 'select(.kind == "Cluster") | (.spec.bootstrap.initdb.postInitSQL // [])[] , (.spec.bootstrap.initdb.postInitApplicationSQL // [])[]' "${rendered}")"
grep -qi "CREATE ROLE ${WANT_RUNTIME_ROLE}" <<<"${init_sql}" || fail "bootstrap SQL must create the runtime role"
grep -qi "ALTER DEFAULT PRIVILEGES FOR ROLE ${WANT_OWNER_ROLE}" <<<"${init_sql}" || fail "bootstrap SQL must attach default privileges to the migration owner, not to the bootstrap superuser"
grep -qi "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${WANT_RUNTIME_ROLE}" <<<"${init_sql}" || fail "bootstrap SQL must grant DML (and only DML) on future tables to the runtime role"
if grep -Eqi "GRANT (ALL|CREATE)[^;]*TO ${WANT_RUNTIME_ROLE}" <<<"${init_sql}"; then
  fail "the runtime role must never receive ALL or CREATE; it is DML-only"
fi

# --- axis 7: metrics posture matches the estate ------------------------------
# The Prometheus Operator CRDs are absent on honey, so a PodMonitor request
# would make the Cluster unappliable.
pod_monitor="$(yq -r 'select(.kind == "Cluster") | .spec.monitoring.enablePodMonitor' "${rendered}")"
assert_eq "${pod_monitor}" "false" "monitoring.enablePodMonitor (Prometheus Operator CRDs are absent on this estate)"

# --- axis 8: RTO control, the scheduled base backup --------------------------
sb_ns="$(yq -r 'select(.kind == "ScheduledBackup") | .metadata.namespace' "${rendered}")"
sb_cluster="$(yq -r 'select(.kind == "ScheduledBackup") | .spec.cluster.name' "${rendered}")"
assert_eq "${sb_ns}" "${WANT_DB_NS}" "ScheduledBackup namespace"
assert_eq "${sb_cluster}" "${WANT_CLUSTER}" "ScheduledBackup target cluster"
assert_eq "$(yq -r 'select(.kind == "ScheduledBackup") | .spec.method' "${rendered}")" \
  "barmanObjectStore" "ScheduledBackup method"
# A suspended schedule is an RTO breach that looks green on every dashboard.
assert_eq "$(yq -r 'select(.kind == "ScheduledBackup") | .spec.suspend' "${rendered}")" \
  "false" "ScheduledBackup suspend (a suspended schedule breaches RTO<=4h while looking healthy)"
schedule="$(yq -r 'select(.kind == "ScheduledBackup") | .spec.schedule' "${rendered}")"
# CNPG cron carries a LEADING SECONDS field. A five-field expression is read one
# position over and silently changes the cadence, so the field count is asserted
# rather than assumed.
schedule_fields="$(wc -w <<<"${schedule}" | tr -d ' ')"
assert_eq "${schedule_fields}" "6" "ScheduledBackup schedule field count (CNPG cron is 6 fields, leading seconds)"
hour_field="$(awk '{print $3}' <<<"${schedule}")"
if [[ ! "${hour_field}" =~ ^\*/([0-9]+)$ ]]; then
  fail "ScheduledBackup hour field must be an interval (*/N) so the cadence is checkable; got '${hour_field}' in '${schedule}'"
fi
if [ "${BASH_REMATCH[1]}" -gt 6 ]; then
  fail "base backups every ${BASH_REMATCH[1]}h leave more than 6h of WAL to replay, which does not hold the RTO<=4h acceptance row"
fi

# --- axis 9: NetworkPolicy admission list ------------------------------------
deny="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "default-deny-ingress") | .metadata.name' "${rendered}")"
assert_eq "${deny}" "default-deny-ingress" "default-deny-ingress NetworkPolicy present"
deny_selector="$(yq -c 'select(.kind == "NetworkPolicy" and .metadata.name == "default-deny-ingress") | .spec.podSelector' "${rendered}")"
assert_eq "${deny_selector}" "{}" "default-deny-ingress selects every pod in the namespace"

admit_ns="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-platform-postgres-ingress") | .spec.ingress[].from[].namespaceSelector.matchLabels["kubernetes.io/metadata.name"]' "${rendered}")"
assert_eq "${admit_ns}" "${WANT_PLATFORM_NS}" "PostgreSQL ingress source namespace"
admit_port="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-platform-postgres-ingress") | .spec.ingress[].ports[].port' "${rendered}")"
assert_eq "${admit_port}" "5432" "PostgreSQL ingress port"
admit_components="$(yq -c 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-platform-postgres-ingress") | [.spec.ingress[].from[].podSelector.matchExpressions[] | select(.key == "app.kubernetes.io/component") | .values[]] | sort' "${rendered}")"
assert_eq "${admit_components}" '["migrator","web","worker"]' \
  "PostgreSQL ingress admits exactly the platform web/worker/migrator components"
admit_partof="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-platform-postgres-ingress") | .spec.ingress[].from[].podSelector.matchLabels["app.kubernetes.io/part-of"]' "${rendered}")"
assert_eq "${admit_partof}" "gftb-platform" "PostgreSQL ingress part-of selector"

# No blanket allows in either direction, and no bare port-only egress rule (a
# rule with no `to:` admits every destination on that port, including off-estate).
if yq -r 'select(.kind == "NetworkPolicy") | (.spec.ingress[]?, .spec.egress[]?) | (.to[]?, .from[]?) | select(has("ipBlock")) | .ipBlock.cidr' "${rendered}" | grep -qx "0.0.0.0/0"; then
  fail "member-db NetworkPolicies must not include an ipBlock 0.0.0.0/0"
fi
if yq -r 'select(.kind == "NetworkPolicy") | .spec.egress[]? | select((.to // []) | length == 0) | "bare"' "${rendered}" | grep -q bare; then
  fail "member-db egress rules must name their destination; a rule with no 'to:' admits every destination on that port"
fi

# --- render inventory: exact object count and kind, by name (B-7) -----------
# This is what makes the three attacks the review proved (dropping
# `- networkpolicy.yaml`, `- rustfs.yaml`, or `- scheduledbackup.yaml` from
# kustomization.yaml) fail HERE, on a count/name mismatch, rather than
# silently passing every per-field assertion above because those assertions
# now read this same rendered stream and a dropped resource is simply absent
# from it. Named, not just counted, so a rename inside the admitted set is
# caught too.
netpol_names="$(yq -r 'select(.kind == "NetworkPolicy") | .metadata.name' "${rendered}" | sort)"
assert_eq "$(wc -l <<<"${netpol_names}" | tr -d ' ')" "8" "rendered NetworkPolicy count"
assert_eq "${netpol_names}" "$(sort <<<'allow-cnpg-operator-ingress
allow-cnpg-to-backup-store-ingress
allow-intra-cluster
allow-platform-postgres-ingress
allow-postgres-egress
allow-prometheus-scrape
backup-store-egress-dns-only
default-deny-ingress')" "rendered NetworkPolicy names"
assert_eq "$(yq -r 'select(.kind == "Cluster") | .kind' "${rendered}" | wc -l | tr -d ' ')" "1" "rendered Cluster count"
assert_eq "$(yq -r 'select(.kind == "ScheduledBackup") | .kind' "${rendered}" | wc -l | tr -d ' ')" "1" "rendered ScheduledBackup count"
assert_eq "$(yq -r 'select(.kind == "Service") | .kind' "${rendered}" | wc -l | tr -d ' ')" "1" "rendered Service count (rustfs)"
assert_eq "$(yq -r 'select(.kind == "StatefulSet") | .kind' "${rendered}" | wc -l | tr -d ' ')" "1" "rendered StatefulSet count (rustfs)"
assert_eq "$(yq -r 'select(.kind == "PersistentVolumeClaim") | .kind' "${rendered}" | wc -l | tr -d ' ')" "1" "rendered PersistentVolumeClaim count (rustfs)"
assert_eq "$(yq -r 'select(.kind == "Namespace") | .kind' "${rendered}" | wc -l | tr -d ' ')" "0" "rendered Namespace count (declare-only)"
assert_eq "$(yq -r 'select(.kind == "Secret") | .kind' "${rendered}" | wc -l | tr -d ' ')" "0" "rendered Secret count (no committed Secrets)"
# Every rendered object lands in the one namespace this stack governs — the
# `namespace:` kustomization directive is itself a single point of failure
# the per-field assertions above never look at directly.
bad_ns="$(yq -r --arg ns "${WANT_DB_NS}" 'select(.metadata.namespace != $ns) | "\(.kind)/\(.metadata.name)=\(.metadata.namespace)"' "${rendered}")"
[ -z "${bad_ns}" ] || fail "rendered object(s) outside namespace ${WANT_DB_NS}: ${bad_ns}"

# --- FAIL-CLOSED: no Namespace, no Secret, no key material -------------------
if grep -REn "^kind:[[:space:]]*Namespace" "${dir}" "${platform_dir}" >/dev/null 2>&1; then
  fail "declare-only member-db stack must NOT create its target namespaces"
fi
# Anchored at end of line on purpose: `kind: SecretContract` in the names-only
# inventory is not a Secret object, and an unanchored match would reject it.
if grep -REn "^kind:[[:space:]]*Secret[[:space:]]*$" "${dir}" "${platform_dir}" "${secrets_contract}" >/dev/null 2>&1; then
  fail "the member-db stack must not ship a Secret object; credentials are referenced by name only"
fi
if grep -REn "AGE-SECRET-KEY-1|BEGIN [A-Z ]*PRIVATE KEY|cfat_[A-Za-z0-9_-]{8,}" "${member_root}" >/dev/null 2>&1; then
  fail "possible committed key material under ${member_root}; this stack carries none"
fi

# --- axis 10: the migration Job template -------------------------------------
job_kind="$(yq -r '.kind' "${job_template}")"
assert_eq "${job_kind}" "Job" "migration Job kind"
job_ns="$(yq -r '.metadata.namespace' "${job_template}")"
assert_eq "${job_ns}" "${WANT_PLATFORM_NS}" "migration Job namespace (runs platform-side, holds the owner credential)"
# generateName, never a fixed name: a fixed name forces the apply path to remove
# the previous Job first, and removing a workload to make room for its
# replacement is the imperative shape the house release doctrine refuses.
job_generate="$(yq -r '.metadata.generateName' "${job_template}")"
assert_eq "${job_generate}" "gftb-member-db-migrate-" "migration Job generateName"
job_fixed_name="$(yq -r '.metadata.name // "absent"' "${job_template}")"
assert_eq "${job_fixed_name}" "absent" "migration Job must not carry a fixed metadata.name"

# The committed template must NEVER carry a resolvable image. The digest arrives
# at dispatch through the operator input guard; a real reference in the tree
# would be an apply-shaped artifact sitting in a declare-only stack.
job_image="$(yq -r '.spec.template.spec.containers[] | select(.name == "migrator") | .image' "${job_template}")"
assert_eq "${job_image}" "${WANT_IMAGE_PLACEHOLDER}" "migration Job image placeholder (the digest is supplied at dispatch)"
# NO command:. B-1 (PR #118 review): `command:` overrides the image
# ENTRYPOINT (`["dumb-init", "--"]`), so a real command would run the migrator
# as PID 1 with no reaper. Dispatch stays through `args:` alone.
job_command="$(yq -r '.spec.template.spec.containers[] | select(.name == "migrator") | .command // "absent"' "${job_template}")"
assert_eq "${job_command}" "absent" "migration Job command (must be absent so the image ENTRYPOINT [dumb-init --] stays PID 1)"
job_args="$(yq -c '.spec.template.spec.containers[] | select(.name == "migrator") | .args' "${job_template}")"
assert_eq "${job_args}" "${WANT_MIGRATOR_ARGS}" "migration Job entrypoint (one image, three entrypoints — positional dispatch, both builders)"

assert_eq "$(yq -r '.spec.backoffLimit' "${job_template}")" "0" \
  "migration Job backoffLimit (a failed migration must stay failed, not retry into a half-applied ledger)"
assert_eq "$(yq -r '.spec.template.spec.restartPolicy' "${job_template}")" "Never" "migration Job restartPolicy"
assert_eq "$(yq -r '.spec.template.spec.automountServiceAccountToken' "${job_template}")" "false" \
  "migration Job automountServiceAccountToken"
assert_eq "$(yq -r '.spec.template.spec.securityContext.runAsNonRoot' "${job_template}")" "true" "migration Job runAsNonRoot"
assert_eq "$(yq -r '.spec.template.spec.securityContext.runAsUser' "${job_template}")" "1001" "migration Job runAsUser (ADR 0008 house standard)"
assert_eq "$(yq -r '.spec.template.spec.containers[] | select(.name == "migrator") | .securityContext.readOnlyRootFilesystem' "${job_template}")" \
  "true" "migration Job readOnlyRootFilesystem"

# Exactly one credential reaches this Job, and it is the narrow one.
job_secret_refs="$(yq -c '[.spec.template.spec.containers[].env[]?.valueFrom.secretKeyRef.name | select(. != null)] | sort | unique' "${job_template}")"
assert_eq "${job_secret_refs}" "[\"${WANT_MIGRATOR_SECRET}\"]" \
  "migration Job secret references (only the narrow migration credential)"
if yq -r '.. | select(type == "object") | select(has("secretKeyRef")) | .secretKeyRef.name' "${job_template}" | grep -qx "${WANT_RUNTIME_SECRET}"; then
  fail "the migration Job must never reference the DML-only runtime credential"
fi

# --- axis 11: the Job's labels really match the policy that admits it --------
# Two files, one contract. If these drift apart the migration Job runs and then
# fails to connect, which reads as a database outage rather than a policy edit.
job_partof="$(yq -r '.spec.template.metadata.labels["app.kubernetes.io/part-of"]' "${job_template}")"
job_component="$(yq -r '.spec.template.metadata.labels["app.kubernetes.io/component"]' "${job_template}")"
assert_eq "${job_partof}" "${admit_partof}" "migration Job part-of label vs the NetworkPolicy that admits it"
if ! grep -q "\"${job_component}\"" <<<"${admit_components}"; then
  fail "migration Job component label '${job_component}' is not in the admitted set ${admit_components}"
fi

# --- axis 12: the Job template is not stack state ----------------------------
# Parsed, not grepped: the kustomization's header comment names the template on
# purpose (to say where it lives), and a textual match would reject that.
if yq -r '.resources[]?' "${kustomization}" | grep -Fq "job-migrator"; then
  fail "the migration Job template must not be a kustomization resource; it is a one-shot dispatch artifact rendered by the member-db-migrate-render recipe"
fi

# --- axis 13: the GFTB-owned rustfs backup store (B1 ruling, 2026-08-20) ----
# Four checked things: the image is digest-pinned (never a tag, never a
# different rustfs repo), the PVC is on the Retain-carrying local-path-sting
# class at >=50Gi, the ingress NetworkPolicy admits exactly the CNPG cluster
# pods on :9000 and nothing broader, and cluster.yaml's endpointURL actually
# names this Service rather than drifting back toward tcfs.
rustfs_image="$(yq -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "rustfs") | .image' "${rendered}")"
if [[ ! "${rustfs_image}" =~ @sha256:[0-9a-f]{64}$ ]]; then
  fail "rustfs StatefulSet image must be pinned by @sha256:<64 lowercase hex>; got '${rustfs_image}'"
fi
assert_eq "${rustfs_image}" "${WANT_RUSTFS_REPO}:${WANT_RUSTFS_TAG}@${WANT_RUSTFS_DIGEST}" \
  "rustfs image digest (B1 ruling: digest reused from the house pin source)"

rustfs_node_selector="$(yq -r 'select(.kind == "StatefulSet") | .spec.template.spec.nodeSelector["kubernetes.io/hostname"]' "${rendered}")"
assert_eq "${rustfs_node_selector}" "sting" "rustfs StatefulSet nodeSelector (must agree with local-path-sting's allowedTopologies)"

rustfs_pvc_class="$(yq -r 'select(.kind == "PersistentVolumeClaim") | .spec.storageClassName' "${rendered}")"
assert_eq "${rustfs_pvc_class}" "${WANT_RUSTFS_STORAGECLASS}" \
  "rustfs PVC storageClassName (${WANT_RUSTFS_STORAGECLASS} carries reclaimPolicy: Retain per blahaj deploy/honey/local-path-sting.yaml)"
rustfs_pvc_size="$(yq -r 'select(.kind == "PersistentVolumeClaim") | .spec.resources.requests.storage' "${rendered}")"
if [[ ! "${rustfs_pvc_size}" =~ ^([0-9]+)Gi$ ]]; then
  fail "rustfs PVC storage request must be an integer Gi quantity; got '${rustfs_pvc_size}'"
fi
if [ "${BASH_REMATCH[1]}" -lt "${MIN_RUSTFS_STORAGE_GI}" ]; then
  fail "rustfs PVC storage request ${rustfs_pvc_size} is below the B1 ruling's >=${MIN_RUSTFS_STORAGE_GI}Gi floor"
fi

rustfs_ingress_pol="select(.kind == \"NetworkPolicy\" and .metadata.name == \"allow-cnpg-to-backup-store-ingress\")"
rustfs_ingress_selector="$(yq -c "${rustfs_ingress_pol} | .spec.podSelector" "${rendered}")"
assert_eq "${rustfs_ingress_selector}" "{\"matchLabels\":{\"app.kubernetes.io/name\":\"${WANT_RUSTFS_NAME}\"}}" \
  "rustfs ingress NetworkPolicy podSelector (must scope to the backup store pod, not the namespace)"
rustfs_ingress_from_ns="$(yq -r "${rustfs_ingress_pol} | .spec.ingress[].from[] | select(has(\"namespaceSelector\"))" "${rendered}")"
test -z "${rustfs_ingress_from_ns}" || fail "rustfs ingress must admit same-namespace pods only (cnpg.io/cluster: ${WANT_CLUSTER}); a namespaceSelector was found"
rustfs_ingress_from_pod="$(yq -r "${rustfs_ingress_pol} | .spec.ingress[].from[].podSelector.matchLabels[\"cnpg.io/cluster\"]" "${rendered}")"
assert_eq "${rustfs_ingress_from_pod}" "${WANT_CLUSTER}" "rustfs ingress admitted source (cnpg.io/cluster label)"
rustfs_ingress_port="$(yq -r "${rustfs_ingress_pol} | .spec.ingress[].ports[].port" "${rendered}")"
assert_eq "${rustfs_ingress_port}" "9000" "rustfs ingress port"

# Egress: exactly the DNS leg, nothing else — "zero egress beyond DNS".
rustfs_egress_pol="select(.kind == \"NetworkPolicy\" and .metadata.name == \"backup-store-egress-dns-only\")"
rustfs_egress_to_count="$(yq -r "${rustfs_egress_pol} | [.spec.egress[].to[]] | length" "${rendered}")"
assert_eq "${rustfs_egress_to_count}" "1" "rustfs egress NetworkPolicy must admit exactly one destination (DNS)"
rustfs_egress_ports="$(yq -c "${rustfs_egress_pol} | [.spec.egress[].ports[].port] | sort" "${rendered}")"
assert_eq "${rustfs_egress_ports}" "[53,53]" "rustfs egress ports (UDP/TCP 53 only)"

# The CNPG pods' own egress must now reach the rustfs Service, not tcfs — and
# the tcfs leg must be gone entirely, not just superseded, or a stale allow
# keeps pointing at a namespace GFTB does not govern.
pg_egress_to_rustfs="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-postgres-egress") | .spec.egress[].to[] | select(has("podSelector")) | .podSelector.matchLabels["app.kubernetes.io/name"] // empty' "${rendered}")"
grep -qx "${WANT_RUSTFS_NAME}" <<<"${pg_egress_to_rustfs}" || fail "allow-postgres-egress must admit egress to the rustfs backup store pod (${WANT_RUSTFS_NAME}) on :9000"
# Structural check, not a text grep: comments are allowed to name "tcfs" while
# explaining the rewire (see cluster.yaml and this file's own header), but no
# live namespaceSelector may still target it.
tcfs_selectors="$(yq -r 'select(.kind == "NetworkPolicy") | (.spec.ingress[]?, .spec.egress[]?) | (.to[]?, .from[]?) | select(has("namespaceSelector")) | .namespaceSelector.matchLabels["kubernetes.io/metadata.name"]' "${rendered}" | grep -x "tcfs" || true)"
test -z "${tcfs_selectors}" || fail "no live namespaceSelector may target the tcfs namespace in ${netpol} after the B1 ruling rewire"

# endpointURL must actually name the Service declared in rustfs.yaml, not just
# satisfy the generic in-cluster regex from axis 5 above.
rustfs_svc_name="$(yq -r 'select(.kind == "Service") | .metadata.name' "${rendered}")"
assert_eq "${rustfs_svc_name}" "${WANT_RUSTFS_NAME}" "rustfs Service name"
want_endpoint="http://${WANT_RUSTFS_NAME}.${WANT_DB_NS}.svc.cluster.local:9000"
assert_eq "${endpoint}" "${want_endpoint}" "cluster.yaml barmanObjectStore endpointURL must match the rustfs Service declared in rustfs.yaml"

# --- Full render already happened up front (B-7) — this is where every check
# above got its bytes from; nothing left to do here but declare victory.

echo "member-db stack validation passed for ${WANT_CLUSTER} in ${stack_ns}: DECLARE-ONLY (no namespace, no Secret object, no CI apply path), PostgreSQL 16.15 pinned to ${WANT_PG_REPO}@sha256:<64 hex> on ${WANT_STORAGE_CLASS} with a separate WAL volume, RPO bounded by archive_timeout ${archive_seconds}s to an in-cluster object store, RTO bounded by '${schedule}' base backups with ${retention} retention, ${WANT_OWNER_ROLE} (DDL) and ${WANT_RUNTIME_ROLE} (DML-only, bypassrls false) separated, default-deny admitting only ${WANT_PLATFORM_NS} ${admit_components} on 5432, migration Job entrypoint args ${WANT_MIGRATOR_ARGS} (no command:) carrying only ${WANT_MIGRATOR_SECRET}, backup destination ${want_endpoint} (B1 ruling: GFTB-owned rustfs, ${WANT_RUSTFS_REPO}@sha256:<64 hex> on ${WANT_RUSTFS_STORAGECLASS} >=${MIN_RUSTFS_STORAGE_GI}Gi, ingress admitting only cnpg.io/cluster=${WANT_CLUSTER} on :9000, egress DNS-only)"
