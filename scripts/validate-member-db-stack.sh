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
readonly WANT_MIGRATOR_ENTRYPOINT='["/usr/local/bin/migrator"]'
readonly WANT_IMAGE_PLACEHOLDER="PLACEHOLDER-MEMBER-DB-MIGRATOR-IMAGE"
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
  "${job_template}" "${secrets_contract}"; do
  require_file "${f}"
done

# --- stack identity ----------------------------------------------------------
# Every assertion below binds to the namespace this stack declares, so a copy of
# this tree pointed at some other namespace fails here instead of inheriting the
# member database's admission decisions.
stack_ns="$(yq -r 'select(.kind == "Cluster") | .metadata.namespace' "${cluster}")"
assert_eq "${stack_ns}" "${WANT_DB_NS}" "CNPG Cluster namespace"
cluster_name="$(yq -r 'select(.kind == "Cluster") | .metadata.name' "${cluster}")"
assert_eq "${cluster_name}" "${WANT_CLUSTER}" "CNPG Cluster name"
api="$(yq -r 'select(.kind == "Cluster") | .apiVersion' "${cluster}")"
assert_eq "${api}" "postgresql.cnpg.io/v1" "CNPG Cluster apiVersion"

# --- axis 1: PostgreSQL 16.15, pinned by digest ------------------------------
# A tag would let the served minor drift off the acceptance row without any
# change to this repository. Nothing but this repository at this digest passes:
# no tag, no truncated or uppercase digest, no other registry or fork.
image="$(yq -r 'select(.kind == "Cluster") | .spec.imageName' "${cluster}")"
case "${image}" in
*PLACEHOLDER*) fail "CNPG imageName must be a real digest-pinned reference: '${image}'" ;;
esac
if [[ ! "${image}" =~ ^"${WANT_PG_REPO}"@sha256:[0-9a-f]{64}$ ]]; then
  fail "CNPG imageName must be ${WANT_PG_REPO} pinned by @sha256:<64 lowercase hex>; got '${image}'"
fi
assert_eq "${image}" "${WANT_PG_REPO}@${WANT_PG_DIGEST}" \
  "CNPG image digest (TIN-3817 acceptance row 1 pins PostgreSQL 16.15)"

# --- axis 2: single instance on the purpose-built, node-pinned class ---------
instances="$(yq -r 'select(.kind == "Cluster") | .spec.instances' "${cluster}")"
assert_eq "${instances}" "1" "CNPG instances"
data_sc="$(yq -r 'select(.kind == "Cluster") | .spec.storage.storageClass' "${cluster}")"
wal_sc="$(yq -r 'select(.kind == "Cluster") | .spec.walStorage.storageClass' "${cluster}")"
assert_eq "${data_sc}" "${WANT_STORAGE_CLASS}" "data storageClass"
assert_eq "${wal_sc}" "${WANT_STORAGE_CLASS}" "WAL storageClass"
# WAL on its own volume is what stops an archive stall from filling the data
# volume; losing the separation is a durability regression, not a tidy-up.
wal_size="$(yq -r 'select(.kind == "Cluster") | .spec.walStorage.size' "${cluster}")"
test -n "${wal_size}" && [ "${wal_size}" != "null" ] || fail "walStorage.size must be declared (WAL must not share the data volume)"

# --- axis 3: no superuser reachable after bootstrap --------------------------
superuser="$(yq -r 'select(.kind == "Cluster") | .spec.enableSuperuserAccess' "${cluster}")"
assert_eq "${superuser}" "false" "enableSuperuserAccess"

# --- axis 4: RPO control (acceptance row 8) ----------------------------------
# archive_timeout is what bounds RPO on an IDLE database. Without it a quiet
# cluster holds an unarchived partial segment indefinitely and the real RPO is
# unbounded, while every dashboard still looks healthy.
archive_timeout="$(yq -r 'select(.kind == "Cluster") | .spec.postgresql.parameters.archive_timeout' "${cluster}")"
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
endpoint="$(yq -r 'select(.kind == "Cluster") | .spec.backup.barmanObjectStore.endpointURL' "${cluster}")"
if [[ ! "${endpoint}" =~ ^https?://[a-z0-9.-]+\.svc\.cluster\.local:[0-9]{2,5}/?$ ]]; then
  fail "barmanObjectStore.endpointURL must be an in-cluster <service>.<ns>.svc.cluster.local:<port> address; got '${endpoint}'"
fi
destination="$(yq -r 'select(.kind == "Cluster") | .spec.backup.barmanObjectStore.destinationPath' "${cluster}")"
case "${destination}" in
s3://gftb-member-db-backups*) ;;
*) fail "barmanObjectStore.destinationPath must be the GFTB-scoped bucket s3://gftb-member-db-backups; got '${destination}'" ;;
esac
retention="$(yq -r 'select(.kind == "Cluster") | .spec.backup.retentionPolicy' "${cluster}")"
test -n "${retention}" && [ "${retention}" != "null" ] || fail "backup.retentionPolicy must be declared"
# Credentials by NAME only. A literal `value:` anywhere under s3Credentials would
# mean a secret value had entered git.
if yq -r 'select(.kind == "Cluster") | .spec.backup.barmanObjectStore.s3Credentials | .. | select(type == "object") | keys[]?' "${cluster}" | grep -Ex "value|stringValue" >/dev/null 2>&1; then
  fail "s3Credentials must reference Secret keys by name only; an inline value is present"
fi

# --- axis 6: the two-role separation (acceptance row 2) ----------------------
database="$(yq -r 'select(.kind == "Cluster") | .spec.bootstrap.initdb.database' "${cluster}")"
owner="$(yq -r 'select(.kind == "Cluster") | .spec.bootstrap.initdb.owner' "${cluster}")"
assert_eq "${database}" "${WANT_DATABASE}" "bootstrap database"
assert_eq "${owner}" "${WANT_OWNER_ROLE}" "bootstrap owner (the narrow migration credential)"
if [ "${owner}" = "${WANT_RUNTIME_ROLE}" ]; then
  fail "the migration owner and the runtime role must be distinct roles"
fi

managed_count="$(yq -r 'select(.kind == "Cluster") | [.spec.managed.roles[]?] | length' "${cluster}")"
assert_eq "${managed_count}" "1" "managed.roles entries (exactly the DML-only runtime role)"
runtime_name="$(yq -r --arg r "${WANT_RUNTIME_ROLE}" 'select(.kind == "Cluster") | .spec.managed.roles[] | select(.name == $r) | .name' "${cluster}")"
assert_eq "${runtime_name}" "${WANT_RUNTIME_ROLE}" "managed runtime role name"

runtime_field() {
  yq -r --arg r "${WANT_RUNTIME_ROLE}" --arg f "$1" \
    'select(.kind == "Cluster") | .spec.managed.roles[] | select(.name == $r) | .[$f]' "${cluster}"
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
runtime_secret="$(yq -r --arg r "${WANT_RUNTIME_ROLE}" 'select(.kind == "Cluster") | .spec.managed.roles[] | select(.name == $r) | .passwordSecret.name' "${cluster}")"
assert_eq "${runtime_secret}" "${WANT_RUNTIME_SECRET}" "runtime role passwordSecret (by name only)"

# The DML-only grant surface is set at bootstrap; losing the default-privileges
# statements means the runtime role silently loses access to every table a later
# migration creates, which surfaces as a production outage rather than a test
# failure.
init_sql="$(yq -r 'select(.kind == "Cluster") | (.spec.bootstrap.initdb.postInitSQL // [])[] , (.spec.bootstrap.initdb.postInitApplicationSQL // [])[]' "${cluster}")"
grep -qi "CREATE ROLE ${WANT_RUNTIME_ROLE}" <<<"${init_sql}" || fail "bootstrap SQL must create the runtime role"
grep -qi "ALTER DEFAULT PRIVILEGES FOR ROLE ${WANT_OWNER_ROLE}" <<<"${init_sql}" || fail "bootstrap SQL must attach default privileges to the migration owner, not to the bootstrap superuser"
grep -qi "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${WANT_RUNTIME_ROLE}" <<<"${init_sql}" || fail "bootstrap SQL must grant DML (and only DML) on future tables to the runtime role"
if grep -Eqi "GRANT (ALL|CREATE)[^;]*TO ${WANT_RUNTIME_ROLE}" <<<"${init_sql}"; then
  fail "the runtime role must never receive ALL or CREATE; it is DML-only"
fi

# --- axis 7: metrics posture matches the estate ------------------------------
# The Prometheus Operator CRDs are absent on honey, so a PodMonitor request
# would make the Cluster unappliable.
pod_monitor="$(yq -r 'select(.kind == "Cluster") | .spec.monitoring.enablePodMonitor' "${cluster}")"
assert_eq "${pod_monitor}" "false" "monitoring.enablePodMonitor (Prometheus Operator CRDs are absent on this estate)"

# --- axis 8: RTO control, the scheduled base backup --------------------------
sb_ns="$(yq -r 'select(.kind == "ScheduledBackup") | .metadata.namespace' "${schedbackup}")"
sb_cluster="$(yq -r 'select(.kind == "ScheduledBackup") | .spec.cluster.name' "${schedbackup}")"
assert_eq "${sb_ns}" "${WANT_DB_NS}" "ScheduledBackup namespace"
assert_eq "${sb_cluster}" "${WANT_CLUSTER}" "ScheduledBackup target cluster"
assert_eq "$(yq -r 'select(.kind == "ScheduledBackup") | .spec.method' "${schedbackup}")" \
  "barmanObjectStore" "ScheduledBackup method"
# A suspended schedule is an RTO breach that looks green on every dashboard.
assert_eq "$(yq -r 'select(.kind == "ScheduledBackup") | .spec.suspend' "${schedbackup}")" \
  "false" "ScheduledBackup suspend (a suspended schedule breaches RTO<=4h while looking healthy)"
schedule="$(yq -r 'select(.kind == "ScheduledBackup") | .spec.schedule' "${schedbackup}")"
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
deny="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "default-deny-ingress") | .metadata.name' "${netpol}")"
assert_eq "${deny}" "default-deny-ingress" "default-deny-ingress NetworkPolicy present"
deny_selector="$(yq -c 'select(.kind == "NetworkPolicy" and .metadata.name == "default-deny-ingress") | .spec.podSelector' "${netpol}")"
assert_eq "${deny_selector}" "{}" "default-deny-ingress selects every pod in the namespace"

admit_ns="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-platform-postgres-ingress") | .spec.ingress[].from[].namespaceSelector.matchLabels["kubernetes.io/metadata.name"]' "${netpol}")"
assert_eq "${admit_ns}" "${WANT_PLATFORM_NS}" "PostgreSQL ingress source namespace"
admit_port="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-platform-postgres-ingress") | .spec.ingress[].ports[].port' "${netpol}")"
assert_eq "${admit_port}" "5432" "PostgreSQL ingress port"
admit_components="$(yq -c 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-platform-postgres-ingress") | [.spec.ingress[].from[].podSelector.matchExpressions[] | select(.key == "app.kubernetes.io/component") | .values[]] | sort' "${netpol}")"
assert_eq "${admit_components}" '["migrator","web","worker"]' \
  "PostgreSQL ingress admits exactly the platform web/worker/migrator components"
admit_partof="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-platform-postgres-ingress") | .spec.ingress[].from[].podSelector.matchLabels["app.kubernetes.io/part-of"]' "${netpol}")"
assert_eq "${admit_partof}" "gftb-platform" "PostgreSQL ingress part-of selector"

# No blanket allows in either direction, and no bare port-only egress rule (a
# rule with no `to:` admits every destination on that port, including off-estate).
if yq -r 'select(.kind == "NetworkPolicy") | (.spec.ingress[]?, .spec.egress[]?) | (.to[]?, .from[]?) | select(has("ipBlock")) | .ipBlock.cidr' "${netpol}" | grep -qx "0.0.0.0/0"; then
  fail "member-db NetworkPolicies must not include an ipBlock 0.0.0.0/0"
fi
if yq -r 'select(.kind == "NetworkPolicy") | .spec.egress[]? | select((.to // []) | length == 0) | "bare"' "${netpol}" | grep -q bare; then
  fail "member-db egress rules must name their destination; a rule with no 'to:' admits every destination on that port"
fi

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
job_command="$(yq -c '.spec.template.spec.containers[] | select(.name == "migrator") | .command' "${job_template}")"
assert_eq "${job_command}" "${WANT_MIGRATOR_ENTRYPOINT}" "migration Job entrypoint (one image, three entrypoints)"

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

# --- Full render must succeed (parse-only; never contacts a cluster) ---------
kubectl kustomize "${dir}" >/dev/null

echo "member-db stack validation passed for ${WANT_CLUSTER} in ${stack_ns}: DECLARE-ONLY (no namespace, no Secret object, no CI apply path), PostgreSQL 16.15 pinned to ${WANT_PG_REPO}@sha256:<64 hex> on ${WANT_STORAGE_CLASS} with a separate WAL volume, RPO bounded by archive_timeout ${archive_seconds}s to an in-cluster object store, RTO bounded by '${schedule}' base backups with ${retention} retention, ${WANT_OWNER_ROLE} (DDL) and ${WANT_RUNTIME_ROLE} (DML-only, bypassrls false) separated, default-deny admitting only ${WANT_PLATFORM_NS} ${admit_components} on 5432, migration Job entrypoint ${WANT_MIGRATOR_ENTRYPOINT} carrying only ${WANT_MIGRATOR_SECRET}"
