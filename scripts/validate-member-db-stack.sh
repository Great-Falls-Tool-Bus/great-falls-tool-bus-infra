#!/usr/bin/env bash
# shellcheck disable=SC2016
# SC2016 is intentional throughout: the `$var` inside every single-quoted jq
# program is a jq variable bound by `--arg`, not a shell expansion. yq-go is
# used only to decode YAML into JSON; jq owns every query. Binding values through
# --arg keeps names from being able to inject jq syntax.
set -euo pipefail

# Source-contract guard for the GFTB member database substrate (TIN-3817,
# Member v0 slice S1 infra half). It never contacts a cluster or acquires a
# credential.
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
# than left as unchecked prose.

run_self_test() {
  local script_dir repo_root source_root validator temp_root fixtures
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/.." && pwd)"
  source_root="${repo_root}/k8s/member-db"
  validator="${MEMBER_DB_VALIDATOR:-${BASH_SOURCE[0]}}"
  test -d "${source_root}" || fail "missing ${source_root}"
  test -f "${validator}" || fail "missing validator ${validator}"

  temp_root="$(mktemp -d)"
  fixtures="${temp_root}/fixtures"
  mkdir -m 700 "${fixtures}"
  cleanup_self_test() {
    case "${fixtures}" in
      "${temp_root}"/fixtures) rm -rf -- "${fixtures}" ;;
      *) echo "refusing unsafe self-test cleanup target: ${fixtures}" >&2; return 1 ;;
    esac
    rmdir -- "${temp_root}"
  }
  trap cleanup_self_test EXIT

  mutate_once() {
    local path="$1" old="$2" new="$3"
    python3 -I - "${path}" "${old}" "${new}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
old = sys.argv[2]
new = sys.argv[3]
text = path.read_text()
count = text.count(old)
if count != 1:
    raise SystemExit(f"{path}: mutation anchor count {count}, want 1")
path.write_text(text.replace(old, new))
PY
  }

  expect_failure() {
    local name="$1" relative_path="$2" old="$3" new="$4" diagnostic="$5"
    local fixture="${fixtures}/${name}" log="${fixtures}/${name}.log"
    mkdir -m 700 "${fixture}"
    cp -R "${source_root}/." "${fixture}/"
    mutate_once "${fixture}/${relative_path}" "${old}" "${new}"
    if bash "${validator}" "${fixture}/members-greatfallstoolbus-org-db-production" >"${log}" 2>&1; then
      echo "negative control ${name} unexpectedly passed" >&2
      exit 1
    fi
    if ! grep -Fq -- "${diagnostic}" "${log}"; then
      echo "negative control ${name} failed without expected diagnostic: ${diagnostic}" >&2
      sed -n '1,120p' "${log}" >&2
      exit 1
    fi
    echo "negative control passed: ${name}"
  }

  local job="members-greatfallstoolbus-org-production/job-migrator.template.yaml"
  expect_failure image-tag "${job}"     'ghcr.io/great-falls-tool-bus/greatfallstoolbus.org@sha256:10f853938dc6823afe8c9bdc54943587f963d22117aafd17247350b2b5712b35'     'ghcr.io/great-falls-tool-bus/greatfallstoolbus.org:sha-af60fcd7539a4beff6f24e1a95eb11160df7c166'     'migration Job image must be the exact greatfallstoolbus.org publisher repository pinned by @sha256:<64 lowercase hex>'
  expect_failure foreign-image "${job}"     'ghcr.io/great-falls-tool-bus/greatfallstoolbus.org@sha256:10f853938dc6823afe8c9bdc54943587f963d22117aafd17247350b2b5712b35'     'ghcr.io/not-great-falls-tool-bus/greatfallstoolbus.org@sha256:10f853938dc6823afe8c9bdc54943587f963d22117aafd17247350b2b5712b35'     'migration Job image must be the exact greatfallstoolbus.org publisher repository pinned by @sha256:<64 lowercase hex>'
  expect_failure wrong-source "${job}"     $'  annotations:\n    app.tinyland.dev/source-sha: af60fcd7539a4beff6f24e1a95eb11160df7c166'     $'  annotations:\n    app.tinyland.dev/source-sha: 0000000000000000000000000000000000000000'     'migration Job source identity'
  expect_failure command-override "${job}"     '          imagePullPolicy: IfNotPresent'     $'          imagePullPolicy: IfNotPresent\n          command: ["migrator"]'     'migration Job command (must be absent'
  expect_failure wrong-args "${job}"     '          args: ["migrator"]'     '          args: ["worker"]'     'migration Job entrypoint'
  expect_failure runtime-dsn "${job}"     '                  name: gftb-member-db-migrator-dsn'     '                  name: gftb-member-db-runtime'     'migration Job secret references (only the narrow migration credential)'
  expect_failure pull-secret "${job}"     '        - name: ghcr-pull'     '        - name: ghcr-pull-broken'     'migration Job imagePullSecrets'
  expect_failure pull-secret-duplicate     'secrets.contract.yaml'     $'    - name: ghcr-pull\n      namespace: members-greatfallstoolbus-org-production\n      type: kubernetes.io/dockerconfigjson'     $'    - name: ghcr-pull\n      namespace: members-greatfallstoolbus-org-production\n      type: kubernetes.io/dockerconfigjson\n    - name: ghcr-pull\n      namespace: members-greatfallstoolbus-org-production\n      type: kubernetes.io/dockerconfigjson'     'GHCR pull Secret declaration cardinality'
  expect_failure pull-secret-manual-origin     'secrets.contract.yaml'     $'    - name: ghcr-pull\n      namespace: members-greatfallstoolbus-org-production'     $'    - name: ghcr-pull\n      namespace: members-greatfallstoolbus-org-production\n      origin: operator-provisioned'     'names-only Secret contract forbidden fields'
  expect_failure pull-secret-manual-provisioner     'secrets.contract.yaml'     $'      role: registry_pull\n      authority: >-'     $'      role: registry_pull\n      provisioned_by: operator via kubectl\n      authority: >-'     'names-only Secret contract forbidden fields'
  expect_failure non-pull-secret-inline-value     'secrets.contract.yaml'     $'      role: gftb_app\n      authority: >-'     $'      role: gftb_app\n      value: harmless-placeholder\n      authority: >-'     'names-only Secret contract forbidden fields'
  expect_failure restore-egress-selector     'members-greatfallstoolbus-org-db-production/networkpolicy.yaml'     $'  name: allow-restore-postgres-egress\n  namespace: members-greatfallstoolbus-org-db-production\n  labels:\n    app.kubernetes.io/name: gftb-member-db-restore\nspec:\n  podSelector:\n    matchLabels:\n      cnpg.io/cluster: gftb-member-db-restore'     $'  name: allow-restore-postgres-egress\n  namespace: members-greatfallstoolbus-org-db-production\n  labels:\n    app.kubernetes.io/name: gftb-member-db-restore\nspec:\n  podSelector:\n    matchLabels:\n      cnpg.io/cluster: gftb-member-db-restore-broken'     'allow-restore-postgres-egress podSelector'
  expect_failure root-as-scoped-authority     'secrets.contract.yaml'     'app.tinyland.dev/object-store-authority: object-read-write-no-admin'     'app.tinyland.dev/object-store-authority: server-root-admin'     'bucket-scoped backup Secret authority annotation contract'
  expect_failure invalid-yaml "${job}"     'apiVersion: batch/v1'     'apiVersion: ['     'YAML decode or jq query failed'
  echo "member-db validator negative controls passed"
  cleanup_self_test
  trap - EXIT
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit 0
fi

dir="${1:?usage: validate-member-db-stack.sh <db-manifest-dir> | --self-test}"
member_root="$(cd "${dir}/.." && pwd)"
platform_dir="${member_root}/members-greatfallstoolbus-org-production"

cluster="${dir}/cluster.yaml"
schedbackup="${dir}/scheduledbackup.yaml"
netpol="${dir}/networkpolicy.yaml"
kustomization="${dir}/kustomization.yaml"
job_template="${platform_dir}/job-migrator.template.yaml"
secrets_contract="${member_root}/secrets.contract.yaml"
rustfs="${dir}/rustfs.yaml"
bucket_create="${dir}/bucket-create.template.yaml"
restore_cluster="${dir}/restore-cluster.template.yaml"

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
# B-5 (PR #118 review round): the restore rehearsal is a
# SECOND Cluster in this namespace, and two ingress policies must admit its
# pods alongside the primary's or the rehearsal — the RTO<=4h row's only
# proof path — cannot run.
readonly WANT_RESTORE_CLUSTER="gftb-member-db-restore"
readonly WANT_DATABASE="gftb_member"
readonly WANT_OWNER_ROLE="gftb_migrator"
readonly WANT_RUNTIME_ROLE="gftb_app"
readonly WANT_RUNTIME_SECRET="gftb-member-db-runtime"
readonly WANT_MIGRATOR_SECRET="gftb-member-db-migrator-dsn"
readonly WANT_PLATFORM_PART_OF="great-falls-tool-bus"
readonly WANT_MIGRATOR_NAME="gftb-member-db-migrator"
readonly WANT_IMAGE_PULL_SECRET="ghcr-pull"
readonly WANT_BACKUP_SECRET="gftb-member-db-backup-s3"
readonly WANT_BUCKET="gftb-member-db-backups"
readonly WANT_MIGRATOR_ARGS='["migrator"]'
readonly WANT_MIGRATOR_CONTAINERS='["migrator"]'
readonly WANT_MIGRATOR_SOURCE_SHA="af60fcd7539a4beff6f24e1a95eb11160df7c166"
readonly WANT_MIGRATOR_IMAGE="ghcr.io/great-falls-tool-bus/greatfallstoolbus.org@sha256:10f853938dc6823afe8c9bdc54943587f963d22117aafd17247350b2b5712b35"
readonly WANT_PUBLISHER_RUN="33279762284"
readonly WANT_PUBLISHER_ATTEMPT="1"
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
readonly MIN_RUSTFS_STORAGE_GI=50
# B-3 (PR #118 review round): the bucket-create Job. Image digest reused
# verbatim from the estate's already-vetted mc pin (blahaj
# scripts/ci-ensure-rustfs-bucket.sh TOFU_RUSTFS_BUCKET_MC_IMAGE default).
readonly WANT_MC_REPO="quay.io/minio/mc"
readonly WANT_MC_DIGEST="sha256:b55b1283c0b81b8bb473c94133d4e00a552518c4796a954ddb04bb7b6e05927d"
readonly WANT_RUSTFS_ROOT_SECRET="gftb-member-db-backup-store-root"
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

command -v yq >/dev/null 2>&1 || fail "yq-go v4 is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v kubectl >/dev/null 2>&1 || fail "kubectl is required for the render check"
yq_version="$(yq --version 2>&1)" || fail "could not determine yq implementation"
case "${yq_version}" in
  *mikefarah/yq*version\ v4.*) ;;
  *) fail "yq-go v4 is required; got: ${yq_version}" ;;
esac

# Decode YAML with yq-go, then query the resulting JSON with jq. This wrapper
# deliberately accepts only -r/-c and repeated --arg bindings. The decoder and
# jq statuses are both load-bearing: pipefail plus this explicit guard makes a
# malformed YAML document or invalid filter a hard failure even when a caller
# captures the result.
yaml_query() {
  local mode="${1:?yaml_query requires -r or -c}"
  shift
  case "${mode}" in
    -r|-c) ;;
    *) fail "yaml_query output mode must be -r or -c, got '${mode}'" ;;
  esac

  local -a jq_args=()
  while [ "${1:-}" = "--arg" ]; do
    [ "$#" -ge 3 ] || fail "yaml_query --arg requires NAME VALUE"
    jq_args+=("--arg" "$2" "$3")
    shift 3
  done
  [ "$#" -eq 2 ] || fail "yaml_query requires FILTER FILE"
  local filter="$1"
  local input="$2"
  if ! yq eval-all -o=json -I=0 '.' "${input}" \
    | jq --slurp "${mode}" "${jq_args[@]}" ".[] | (${filter})"; then
    fail "YAML decode or jq query failed for ${input}"
  fi
}

for f in "${cluster}" "${schedbackup}" "${netpol}" "${kustomization}" \
  "${job_template}" "${secrets_contract}" "${rustfs}" "${bucket_create}" \
  "${restore_cluster}"; do
  require_file "${f}"
done

# --- render ONCE, up front. Every assertion below that cares about the
# composed desired state reads THIS file, never a source YAML directly — kustomize
# (the `resources:` list, the `labels:` transformer) sits between the two,
# and a regression there (a dropped `- networkpolicy.yaml` line, a dropped
# `- rustfs.yaml` or `- scheduledbackup.yaml` line) can leave every
# source-file assertion green while the composed bytes are missing an entire
# NetworkPolicy, the backup store, or the RTO control. `kubectl kustomize`
# only parses the local tree; it never touches a cluster. The migration Job
# template is deliberately NOT part of this
# render (axis 12 below asserts it never becomes one), so its own assertions
# keep reading the source file directly.
rendered="$(mktemp)"
trap 'rm -f "${rendered}"' EXIT
kubectl kustomize "${dir}" > "${rendered}"

# --- stack identity ----------------------------------------------------------
# Every assertion below binds to the namespace this stack declares, so a copy of
# this tree pointed at some other namespace fails here instead of inheriting the
# member database's admission decisions.
stack_ns="$(yaml_query -r 'select(.kind == "Cluster") | .metadata.namespace' "${rendered}")"
assert_eq "${stack_ns}" "${WANT_DB_NS}" "CNPG Cluster namespace"
cluster_name="$(yaml_query -r 'select(.kind == "Cluster") | .metadata.name' "${rendered}")"
assert_eq "${cluster_name}" "${WANT_CLUSTER}" "CNPG Cluster name"
api="$(yaml_query -r 'select(.kind == "Cluster") | .apiVersion' "${rendered}")"
assert_eq "${api}" "postgresql.cnpg.io/v1" "CNPG Cluster apiVersion"

# --- axis 1: PostgreSQL 16.15, pinned by digest ------------------------------
# A tag would let the served minor drift off the acceptance row without any
# change to this repository. Nothing but this repository at this digest passes:
# no tag, no truncated or uppercase digest, no other registry or fork.
image="$(yaml_query -r 'select(.kind == "Cluster") | .spec.imageName' "${rendered}")"
case "${image}" in
*PLACEHOLDER*) fail "CNPG imageName must be a real digest-pinned reference: '${image}'" ;;
esac
if [[ ! "${image}" =~ ^"${WANT_PG_REPO}"@sha256:[0-9a-f]{64}$ ]]; then
  fail "CNPG imageName must be ${WANT_PG_REPO} pinned by @sha256:<64 lowercase hex>; got '${image}'"
fi
assert_eq "${image}" "${WANT_PG_REPO}@${WANT_PG_DIGEST}" \
  "CNPG image digest (TIN-3817 acceptance row 1 pins PostgreSQL 16.15)"

# --- axis 2: single instance, with provider placement absent -----------------
instances="$(yaml_query -r 'select(.kind == "Cluster") | .spec.instances' "${rendered}")"
assert_eq "${instances}" "1" "CNPG instances"
assert_eq "$(yaml_query -r 'select(.kind == "Cluster") | .spec.storage | has("storageClass")' "${rendered}")" \
  "false" "consumer Cluster must not select a provider storageClass"
assert_eq "$(yaml_query -r 'select(.kind == "Cluster") | .spec.walStorage | has("storageClass")' "${rendered}")" \
  "false" "consumer Cluster WAL volume must not select a provider storageClass"
# WAL on its own volume is what stops an archive stall from filling the data
# volume; losing the separation is a durability regression, not a tidy-up.
wal_size="$(yaml_query -r 'select(.kind == "Cluster") | .spec.walStorage.size' "${rendered}")"
test -n "${wal_size}" && [ "${wal_size}" != "null" ] || fail "walStorage.size must be declared (WAL must not share the data volume)"

# --- axis 3: no superuser reachable after bootstrap --------------------------
superuser="$(yaml_query -r 'select(.kind == "Cluster") | .spec.enableSuperuserAccess' "${rendered}")"
assert_eq "${superuser}" "false" "enableSuperuserAccess"

# --- axis 4: RPO control (acceptance row 8) ----------------------------------
# archive_timeout is what bounds RPO on an IDLE database. Without it a quiet
# cluster holds an unarchived partial segment indefinitely and the real RPO is
# unbounded, while every dashboard still looks healthy.
archive_timeout="$(yaml_query -r 'select(.kind == "Cluster") | .spec.postgresql.parameters.archive_timeout' "${rendered}")"
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
endpoint="$(yaml_query -r 'select(.kind == "Cluster") | .spec.backup.barmanObjectStore.endpointURL' "${rendered}")"
if [[ ! "${endpoint}" =~ ^https?://[a-z0-9.-]+\.svc\.cluster\.local:[0-9]{2,5}/?$ ]]; then
  fail "barmanObjectStore.endpointURL must be an in-cluster <service>.<ns>.svc.cluster.local:<port> address; got '${endpoint}'"
fi
destination="$(yaml_query -r 'select(.kind == "Cluster") | .spec.backup.barmanObjectStore.destinationPath' "${rendered}")"
case "${destination}" in
s3://gftb-member-db-backups*) ;;
*) fail "barmanObjectStore.destinationPath must be the GFTB-scoped bucket s3://gftb-member-db-backups; got '${destination}'" ;;
esac
retention="$(yaml_query -r 'select(.kind == "Cluster") | .spec.backup.retentionPolicy' "${rendered}")"
test -n "${retention}" && [ "${retention}" != "null" ] || fail "backup.retentionPolicy must be declared"
# Credentials by NAME only. A literal `value:` anywhere under s3Credentials would
# mean a secret value had entered git.
s3_credential_keys="$(yaml_query -r 'select(.kind == "Cluster") | .spec.backup.barmanObjectStore.s3Credentials | .. | select(type == "object") | keys[]?' "${rendered}")"
if grep -Ex "value|stringValue" <<<"${s3_credential_keys}" >/dev/null 2>&1; then
  fail "s3Credentials must reference Secret keys by name only; an inline value is present"
fi
s3_credential_names="$(yaml_query -c 'select(.kind == "Cluster") | [.spec.backup.barmanObjectStore.s3Credentials.accessKeyId.name, .spec.backup.barmanObjectStore.s3Credentials.secretAccessKey.name] | unique' "${rendered}")"
assert_eq "${s3_credential_names}" "[\"${WANT_BACKUP_SECRET}\"]" "primary backup credential must be the bucket-scoped Secret, never rustfs root"

backup_contract_type="$(yaml_query -r --arg n "${WANT_BACKUP_SECRET}" '.spec.secrets[] | select(.name == $n) | .type' "${secrets_contract}")"
assert_eq "${backup_contract_type}" "Opaque" "bucket-scoped backup Secret type contract"
backup_contract_keys="$(yaml_query -c --arg n "${WANT_BACKUP_SECRET}" '.spec.secrets[] | select(.name == $n) | .keys | sort' "${secrets_contract}")"
assert_eq "${backup_contract_keys}" '["ACCESS_KEY_ID","ACCESS_SECRET_KEY"]' "bucket-scoped backup Secret key contract"
backup_contract_bucket="$(yaml_query -r --arg n "${WANT_BACKUP_SECRET}" '.spec.secrets[] | select(.name == $n) | .scope.bucket' "${secrets_contract}")"
assert_eq "${backup_contract_bucket}" "${WANT_BUCKET}" "bucket-scoped backup Secret bucket contract"
backup_contract_authority="$(yaml_query -r --arg n "${WANT_BACKUP_SECRET}" '.spec.secrets[] | select(.name == $n) | .required_annotations["app.tinyland.dev/object-store-authority"]' "${secrets_contract}")"
assert_eq "${backup_contract_authority}" "object-read-write-no-admin" "bucket-scoped backup Secret authority annotation contract"
backup_contract_scope="$(yaml_query -r --arg n "${WANT_BACKUP_SECRET}" '.spec.secrets[] | select(.name == $n) | .required_annotations["app.tinyland.dev/object-store-scope"]' "${secrets_contract}")"
assert_eq "${backup_contract_scope}" "bucket:${WANT_BUCKET}" "bucket-scoped backup Secret scope annotation contract"
root_excluded="$(yaml_query -r --arg n "${WANT_RUSTFS_ROOT_SECRET}" '.spec.secrets[] | select(.name == $n) | .scope.excluded_from_backup_acceptance_authority' "${secrets_contract}")"
assert_eq "${root_excluded}" "true" "rustfs root must be excluded from backup acceptance authority"
if [ "${WANT_BACKUP_SECRET}" = "${WANT_RUSTFS_ROOT_SECRET}" ]; then
  fail "bucket-scoped backup Secret and rustfs root Secret must be different names"
fi
pull_contract_count="$(yaml_query -r --arg n "${WANT_IMAGE_PULL_SECRET}" '[.spec.secrets[] | select(.name == $n)] | length' "${secrets_contract}")"
assert_eq "${pull_contract_count}" "1" "GHCR pull Secret declaration cardinality"
pull_contract_ns="$(yaml_query -r --arg n "${WANT_IMAGE_PULL_SECRET}" '.spec.secrets[] | select(.name == $n) | .namespace' "${secrets_contract}")"
assert_eq "${pull_contract_ns}" "${WANT_PLATFORM_NS}" "GHCR pull Secret namespace contract"
pull_contract_type="$(yaml_query -r --arg n "${WANT_IMAGE_PULL_SECRET}" '.spec.secrets[] | select(.name == $n) | .type' "${secrets_contract}")"
assert_eq "${pull_contract_type}" "kubernetes.io/dockerconfigjson" "GHCR pull Secret type contract"
pull_contract_keys="$(yaml_query -c --arg n "${WANT_IMAGE_PULL_SECRET}" '.spec.secrets[] | select(.name == $n) | .keys' "${secrets_contract}")"
assert_eq "${pull_contract_keys}" '[".dockerconfigjson"]' "GHCR pull Secret key contract"
forbidden_secret_fields="$(yaml_query -c '[.spec.secrets[] | .name as $name | paths as $path | select(($path[-1] | tostring) as $key | ["origin", "minted_by", "provisioned_by", "apply_prerequisite", "projection", "value", "data", "stringData"] | index($key)) | {name: $name, path: ($path | map(tostring) | join("."))}]' "${secrets_contract}")"
assert_eq "${forbidden_secret_fields}" "[]" "names-only Secret contract forbidden fields"

# --- axis 6: the two-role separation (acceptance row 2) ----------------------
database="$(yaml_query -r 'select(.kind == "Cluster") | .spec.bootstrap.initdb.database' "${rendered}")"
owner="$(yaml_query -r 'select(.kind == "Cluster") | .spec.bootstrap.initdb.owner' "${rendered}")"
assert_eq "${database}" "${WANT_DATABASE}" "bootstrap database"
assert_eq "${owner}" "${WANT_OWNER_ROLE}" "bootstrap owner (the narrow migration credential)"
if [ "${owner}" = "${WANT_RUNTIME_ROLE}" ]; then
  fail "the migration owner and the runtime role must be distinct roles"
fi

managed_count="$(yaml_query -r 'select(.kind == "Cluster") | [.spec.managed.roles[]?] | length' "${rendered}")"
assert_eq "${managed_count}" "1" "managed.roles entries (exactly the DML-only runtime role)"
runtime_name="$(yaml_query -r --arg r "${WANT_RUNTIME_ROLE}" 'select(.kind == "Cluster") | .spec.managed.roles[] | select(.name == $r) | .name' "${rendered}")"
assert_eq "${runtime_name}" "${WANT_RUNTIME_ROLE}" "managed runtime role name"

runtime_field() {
  yaml_query -r --arg r "${WANT_RUNTIME_ROLE}" --arg f "$1" \
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
runtime_secret="$(yaml_query -r --arg r "${WANT_RUNTIME_ROLE}" 'select(.kind == "Cluster") | .spec.managed.roles[] | select(.name == $r) | .passwordSecret.name' "${rendered}")"
assert_eq "${runtime_secret}" "${WANT_RUNTIME_SECRET}" "runtime role passwordSecret (by name only)"

# The DML-only grant surface is set at bootstrap; losing the default-privileges
# statements means the runtime role silently loses access to every table a later
# migration creates, which surfaces as a production outage rather than a test
# failure.
init_sql="$(yaml_query -r 'select(.kind == "Cluster") | (.spec.bootstrap.initdb.postInitSQL // [])[] , (.spec.bootstrap.initdb.postInitApplicationSQL // [])[]' "${rendered}")"
grep -qi "CREATE ROLE ${WANT_RUNTIME_ROLE}" <<<"${init_sql}" || fail "bootstrap SQL must create the runtime role"
grep -qi "ALTER DEFAULT PRIVILEGES FOR ROLE ${WANT_OWNER_ROLE}" <<<"${init_sql}" || fail "bootstrap SQL must attach default privileges to the migration owner, not to the bootstrap superuser"
grep -qi "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${WANT_RUNTIME_ROLE}" <<<"${init_sql}" || fail "bootstrap SQL must grant DML (and only DML) on future tables to the runtime role"
if grep -Eqi "GRANT (ALL|CREATE)[^;]*TO ${WANT_RUNTIME_ROLE}" <<<"${init_sql}"; then
  fail "the runtime role must never receive ALL or CREATE; it is DML-only"
fi

# --- axis 7: no consumer-side observability provider assumption --------------
# Provider observability is a protected composition concern, not a consumer
# placement field or CRD assumption.
pod_monitor="$(yaml_query -r 'select(.kind == "Cluster") | .spec.monitoring.enablePodMonitor' "${rendered}")"
assert_eq "${pod_monitor}" "false" "monitoring.enablePodMonitor (provider observability is not consumer-owned)"

# --- axis 8: RTO control, the scheduled base backup --------------------------
sb_ns="$(yaml_query -r 'select(.kind == "ScheduledBackup") | .metadata.namespace' "${rendered}")"
sb_cluster="$(yaml_query -r 'select(.kind == "ScheduledBackup") | .spec.cluster.name' "${rendered}")"
assert_eq "${sb_ns}" "${WANT_DB_NS}" "ScheduledBackup namespace"
assert_eq "${sb_cluster}" "${WANT_CLUSTER}" "ScheduledBackup target cluster"
assert_eq "$(yaml_query -r 'select(.kind == "ScheduledBackup") | .spec.method' "${rendered}")" \
  "barmanObjectStore" "ScheduledBackup method"
assert_eq "$(yaml_query -r 'select(.kind == "ScheduledBackup") | .spec.immediate' "${rendered}")" \
  "true" "ScheduledBackup immediate start"
# A suspended schedule is an RTO breach that looks green on every dashboard.
assert_eq "$(yaml_query -r 'select(.kind == "ScheduledBackup") | .spec.suspend' "${rendered}")" \
  "false" "ScheduledBackup suspend (a suspended schedule breaches RTO<=4h while looking healthy)"
schedule="$(yaml_query -r 'select(.kind == "ScheduledBackup") | .spec.schedule' "${rendered}")"
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
deny="$(yaml_query -r 'select(.kind == "NetworkPolicy" and .metadata.name == "default-deny-ingress") | .metadata.name' "${rendered}")"
assert_eq "${deny}" "default-deny-ingress" "default-deny-ingress NetworkPolicy present"
deny_selector="$(yaml_query -c 'select(.kind == "NetworkPolicy" and .metadata.name == "default-deny-ingress") | .spec.podSelector' "${rendered}")"
assert_eq "${deny_selector}" "{}" "default-deny-ingress selects every pod in the namespace"

admit_ns="$(yaml_query -r 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-platform-postgres-ingress") | .spec.ingress[].from[].namespaceSelector.matchLabels["kubernetes.io/metadata.name"]' "${rendered}")"
assert_eq "${admit_ns}" "${WANT_PLATFORM_NS}" "PostgreSQL ingress source namespace"
admit_port="$(yaml_query -r 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-platform-postgres-ingress") | .spec.ingress[].ports[].port' "${rendered}")"
assert_eq "${admit_port}" "5432" "PostgreSQL ingress port"
admit_components="$(yaml_query -c 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-platform-postgres-ingress") | [.spec.ingress[].from[].podSelector.matchExpressions[] | select(.key == "app.kubernetes.io/component") | .values[]] | sort' "${rendered}")"
assert_eq "${admit_components}" '["migrator","web","worker"]' \
  "PostgreSQL ingress admits exactly the platform web/worker/migrator components"
admit_partof="$(yaml_query -r 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-platform-postgres-ingress") | .spec.ingress[].from[].podSelector.matchLabels["app.kubernetes.io/part-of"]' "${rendered}")"
assert_eq "${admit_partof}" "${WANT_PLATFORM_PART_OF}" "PostgreSQL ingress part-of selector"

# No blanket allows in either direction, and no bare port-only egress rule (a
# rule with no `to:` admits every destination on that port, including off-estate).
ipblock_cidrs="$(yaml_query -r 'select(.kind == "NetworkPolicy") | (.spec.ingress[]?, .spec.egress[]?) | (.to[]?, .from[]?) | select(has("ipBlock")) | .ipBlock.cidr' "${rendered}")"
if grep -qx "0.0.0.0/0" <<<"${ipblock_cidrs}"; then
  fail "member-db NetworkPolicies must not include an ipBlock 0.0.0.0/0"
fi
bare_egress="$(yaml_query -r 'select(.kind == "NetworkPolicy") | .spec.egress[]? | select((.to // []) | length == 0) | "bare"' "${rendered}")"
if grep -q bare <<<"${bare_egress}"; then
  fail "member-db egress rules must name their destination; a rule with no 'to:' admits every destination on that port"
fi

# Primary and restore egress are separate, exact, closed policies. Keeping them
# separate prevents an In[primary,restore] selector from opening cross-cluster
# traffic during the rehearsal.
assert_closed_pg_egress() {
  local policy="$1" cluster_label="$2"
  local selector policy_types rule_count to_count
  selector="$(yaml_query -c --arg p "${policy}" 'select(.kind == "NetworkPolicy" and .metadata.name == $p) | .spec.podSelector' "${rendered}")"
  assert_eq "${selector}" "{\"matchLabels\":{\"cnpg.io/cluster\":\"${cluster_label}\"}}" "${policy} podSelector"
  policy_types="$(yaml_query -c --arg p "${policy}" 'select(.kind == "NetworkPolicy" and .metadata.name == $p) | .spec.policyTypes | sort' "${rendered}")"
  assert_eq "${policy_types}" '["Egress"]' "${policy} policyTypes"
  rule_count="$(yaml_query -r --arg p "${policy}" 'select(.kind == "NetworkPolicy" and .metadata.name == $p) | [.spec.egress[]] | length' "${rendered}")"
  assert_eq "${rule_count}" "3" "${policy} exact egress rule count"
  to_count="$(yaml_query -r --arg p "${policy}" 'select(.kind == "NetworkPolicy" and .metadata.name == $p) | [.spec.egress[].to[]] | length' "${rendered}")"
  assert_eq "${to_count}" "3" "${policy} exact destination count"
  local dns_ns dns_pod dns_ports store_names store_ports peer_names peer_ports
  dns_ns="$(yaml_query -c --arg p "${policy}" 'select(.kind == "NetworkPolicy" and .metadata.name == $p) | [.spec.egress[].to[] | select((.namespaceSelector.matchLabels["kubernetes.io/metadata.name"] // "") == "kube-system") | .namespaceSelector.matchLabels["kubernetes.io/metadata.name"]]' "${rendered}")"
  assert_eq "${dns_ns}" '["kube-system"]' "${policy} DNS namespace destination"
  dns_pod="$(yaml_query -c --arg p "${policy}" 'select(.kind == "NetworkPolicy" and .metadata.name == $p) | [.spec.egress[].to[] | select((.podSelector.matchLabels["k8s-app"] // "") == "kube-dns") | .podSelector.matchLabels["k8s-app"]]' "${rendered}")"
  assert_eq "${dns_pod}" '["kube-dns"]' "${policy} DNS pod destination"
  dns_ports="$(yaml_query -c --arg p "${policy}" 'select(.kind == "NetworkPolicy" and .metadata.name == $p) | [.spec.egress[] | select(any(.to[]?; (.podSelector.matchLabels["k8s-app"] // "") == "kube-dns")) | .ports[] | (.protocol + ":" + (.port|tostring))] | sort' "${rendered}")"
  assert_eq "${dns_ports}" '["TCP:53","UDP:53"]' "${policy} DNS ports"
  store_names="$(yaml_query -c --arg p "${policy}" 'select(.kind == "NetworkPolicy" and .metadata.name == $p) | [.spec.egress[].to[] | select((.podSelector.matchLabels["app.kubernetes.io/name"] // "") == "gftb-member-db-backup-store") | .podSelector.matchLabels["app.kubernetes.io/name"]]' "${rendered}")"
  assert_eq "${store_names}" '["gftb-member-db-backup-store"]' "${policy} backup-store destination"
  store_ports="$(yaml_query -c --arg p "${policy}" 'select(.kind == "NetworkPolicy" and .metadata.name == $p) | [.spec.egress[] | select(any(.to[]?; (.podSelector.matchLabels["app.kubernetes.io/name"] // "") == "gftb-member-db-backup-store")) | .ports[] | (.protocol + ":" + (.port|tostring))] | sort' "${rendered}")"
  assert_eq "${store_ports}" '["TCP:9000"]' "${policy} backup-store port"
  peer_names="$(yaml_query -c --arg p "${policy}" --arg c "${cluster_label}" 'select(.kind == "NetworkPolicy" and .metadata.name == $p) | [.spec.egress[].to[] | select((.podSelector.matchLabels["cnpg.io/cluster"] // "") == $c) | .podSelector.matchLabels["cnpg.io/cluster"]]' "${rendered}")"
  assert_eq "${peer_names}" "[\"${cluster_label}\"]" "${policy} same-cluster peer destination"
  peer_ports="$(yaml_query -c --arg p "${policy}" --arg c "${cluster_label}" 'select(.kind == "NetworkPolicy" and .metadata.name == $p) | [.spec.egress[] | select(any(.to[]?; (.podSelector.matchLabels["cnpg.io/cluster"] // "") == $c)) | .ports[] | (.protocol + ":" + (.port|tostring))] | sort' "${rendered}")"
  assert_eq "${peer_ports}" '["TCP:5432","TCP:8000"]' "${policy} same-cluster CNPG peer ports"
}
assert_closed_pg_egress "allow-postgres-egress" "${WANT_CLUSTER}"
assert_closed_pg_egress "allow-restore-postgres-egress" "${WANT_RESTORE_CLUSTER}"

# --- render inventory: exact object count and kind, by name (B-7) -----------
# This is what makes the three attacks the review proved (dropping
# `- networkpolicy.yaml`, `- rustfs.yaml`, or `- scheduledbackup.yaml` from
# kustomization.yaml) fail HERE, on a count/name mismatch, rather than
# silently passing every per-field assertion above because those assertions
# now read this same rendered stream and a dropped resource is simply absent
# from it. Named, not just counted, so a rename inside the admitted set is
# caught too.
netpol_names="$(yaml_query -r 'select(.kind == "NetworkPolicy") | .metadata.name' "${rendered}" | sort)"
assert_eq "$(wc -l <<<"${netpol_names}" | tr -d ' ')" "8" "rendered NetworkPolicy count"
assert_eq "${netpol_names}" "$(sort <<<'allow-bucket-create-egress
allow-cnpg-to-backup-store-ingress
allow-intra-cluster
allow-platform-postgres-ingress
allow-postgres-egress
allow-restore-postgres-egress
backup-store-egress-dns-only
default-deny-ingress')" "rendered NetworkPolicy names"
assert_eq "$(yaml_query -r 'select(.kind == "Cluster") | .kind' "${rendered}" | wc -l | tr -d ' ')" "1" "rendered Cluster count"
assert_eq "$(yaml_query -r 'select(.kind == "ScheduledBackup") | .kind' "${rendered}" | wc -l | tr -d ' ')" "1" "rendered ScheduledBackup count"
assert_eq "$(yaml_query -r 'select(.kind == "Service") | .kind' "${rendered}" | wc -l | tr -d ' ')" "1" "rendered Service count (rustfs)"
assert_eq "$(yaml_query -r 'select(.kind == "StatefulSet") | .kind' "${rendered}" | wc -l | tr -d ' ')" "1" "rendered StatefulSet count (rustfs)"
assert_eq "$(yaml_query -r 'select(.kind == "PersistentVolumeClaim") | .kind' "${rendered}" | wc -l | tr -d ' ')" "1" "rendered PersistentVolumeClaim count (rustfs)"
assert_eq "$(yaml_query -r 'select(.kind == "Namespace") | .kind' "${rendered}" | wc -l | tr -d ' ')" "0" "rendered Namespace count (consumer contract)"
assert_eq "$(yaml_query -r 'select(.kind == "Secret") | .kind' "${rendered}" | wc -l | tr -d ' ')" "0" "rendered Secret count (no committed Secrets)"
# Every rendered object lands in the one namespace this stack governs — the
# `namespace:` kustomization directive is itself a single point of failure
# the per-field assertions above never look at directly.
bad_ns="$(yaml_query -r --arg ns "${WANT_DB_NS}" 'select(.metadata.namespace != $ns) | "\(.kind)/\(.metadata.name)=\(.metadata.namespace)"' "${rendered}")"
[ -z "${bad_ns}" ] || fail "rendered object(s) outside namespace ${WANT_DB_NS}: ${bad_ns}"

# --- FAIL-CLOSED: no Namespace, no Secret, no key material -------------------
if grep -REn "^kind:[[:space:]]*Namespace" "${dir}" "${platform_dir}" >/dev/null 2>&1; then
  fail "member-db consumer contract must NOT create its target namespaces"
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
job_kind="$(yaml_query -r '.kind' "${job_template}")"
assert_eq "${job_kind}" "Job" "migration Job kind"
job_ns="$(yaml_query -r '.metadata.namespace' "${job_template}")"
assert_eq "${job_ns}" "${WANT_PLATFORM_NS}" "migration Job namespace (runs platform-side, holds the owner credential)"
# generateName, never a fixed name: a fixed name forces the apply path to remove
# the previous Job first, and removing a workload to make room for its
# replacement is the imperative shape the house release doctrine refuses.
job_generate="$(yaml_query -r '.metadata.generateName' "${job_template}")"
assert_eq "${job_generate}" "gftb-member-db-migrate-" "migration Job generateName"
job_fixed_name="$(yaml_query -r '.metadata.name // "absent"' "${job_template}")"
assert_eq "${job_fixed_name}" "absent" "migration Job must not carry a fixed metadata.name"

# The exact publisher carrier is committed in Git. There is no runtime image
# input, tag, placeholder, alternate repository, or rename-shaped authority.
job_containers="$(yaml_query -c '[.spec.template.spec.containers[].name] | sort' "${job_template}")"
assert_eq "${job_containers}" "${WANT_MIGRATOR_CONTAINERS}" "migration Job container identity"
job_pull_secrets="$(yaml_query -c '[.spec.template.spec.imagePullSecrets[]?.name] | sort | unique' "${job_template}")"
assert_eq "${job_pull_secrets}" "[\"${WANT_IMAGE_PULL_SECRET}\"]" "migration Job imagePullSecrets (exact namespace-local GHCR pull Secret)"
job_name_label="$(yaml_query -r '.metadata.labels["app.kubernetes.io/name"]' "${job_template}")"
pod_name_label="$(yaml_query -r '.spec.template.metadata.labels["app.kubernetes.io/name"]' "${job_template}")"
assert_eq "${job_name_label}" "${WANT_MIGRATOR_NAME}" "migration Job canonical app name label"
assert_eq "${pod_name_label}" "${WANT_MIGRATOR_NAME}" "migration pod canonical app name label"
job_image="$(yaml_query -r '.spec.template.spec.containers[] | select(.name == "migrator") | .image' "${job_template}")"
if [[ ! "${job_image}" =~ ^ghcr\.io/great-falls-tool-bus/greatfallstoolbus\.org@sha256:[0-9a-f]{64}$ ]]; then
  fail "migration Job image must be the exact greatfallstoolbus.org publisher repository pinned by @sha256:<64 lowercase hex>; got '${job_image}'"
fi
assert_eq "${job_image}" "${WANT_MIGRATOR_IMAGE}" "migration Job publisher image"
job_source_sha="$(yaml_query -r '.metadata.annotations["app.tinyland.dev/source-sha"]' "${job_template}")"
pod_source_sha="$(yaml_query -r '.spec.template.metadata.annotations["app.tinyland.dev/source-sha"]' "${job_template}")"
publisher_run="$(yaml_query -r '.metadata.annotations["app.tinyland.dev/publisher-run"]' "${job_template}")"
publisher_attempt="$(yaml_query -r '.metadata.annotations["app.tinyland.dev/publisher-attempt"]' "${job_template}")"
assert_eq "${job_source_sha}" "${WANT_MIGRATOR_SOURCE_SHA}" "migration Job source identity"
assert_eq "${pod_source_sha}" "${WANT_MIGRATOR_SOURCE_SHA}" "migration pod source identity"
assert_eq "${publisher_run}" "${WANT_PUBLISHER_RUN}" "migration Job publisher workflow run"
assert_eq "${publisher_attempt}" "${WANT_PUBLISHER_ATTEMPT}" "migration Job publisher attempt"
# NO command:. B-1 (PR #118 review): `command:` overrides the image
# ENTRYPOINT (`["dumb-init", "--"]`), so a real command would run the migrator
# as PID 1 with no reaper. Dispatch stays through `args:` alone.
job_command="$(yaml_query -r '.spec.template.spec.containers[] | select(.name == "migrator") | .command // "absent"' "${job_template}")"
assert_eq "${job_command}" "absent" "migration Job command (must be absent so the image ENTRYPOINT [dumb-init --] stays PID 1)"
job_args="$(yaml_query -c '.spec.template.spec.containers[] | select(.name == "migrator") | .args' "${job_template}")"
assert_eq "${job_args}" "${WANT_MIGRATOR_ARGS}" "migration Job entrypoint (one image, three entrypoints — positional dispatch, both builders)"

assert_eq "$(yaml_query -r '.spec.backoffLimit' "${job_template}")" "0" \
  "migration Job backoffLimit (a failed migration must stay failed, not retry into a half-applied ledger)"
assert_eq "$(yaml_query -r '.spec.template.spec.restartPolicy' "${job_template}")" "Never" "migration Job restartPolicy"
assert_eq "$(yaml_query -r '.spec.template.spec.automountServiceAccountToken' "${job_template}")" "false" \
  "migration Job automountServiceAccountToken"
assert_eq "$(yaml_query -r '.spec.template.spec.securityContext.runAsNonRoot' "${job_template}")" "true" "migration Job runAsNonRoot"
assert_eq "$(yaml_query -r '.spec.template.spec.securityContext.runAsUser' "${job_template}")" "1001" "migration Job runAsUser (ADR 0008 house standard)"
assert_eq "$(yaml_query -r '.spec.template.spec.containers[] | select(.name == "migrator") | .securityContext.readOnlyRootFilesystem' "${job_template}")" \
  "true" "migration Job readOnlyRootFilesystem"

# Exactly one credential reaches this Job, and it is the narrow one.
job_secret_refs="$(yaml_query -c '[.spec.template.spec.containers[].env[]?.valueFrom.secretKeyRef.name | select(. != null)] | sort | unique' "${job_template}")"
assert_eq "${job_secret_refs}" "[\"${WANT_MIGRATOR_SECRET}\"]" \
  "migration Job secret references (only the narrow migration credential)"
job_all_secret_refs="$(yaml_query -r '.. | select(type == "object") | select(has("secretKeyRef")) | .secretKeyRef.name' "${job_template}")"
if grep -qx "${WANT_RUNTIME_SECRET}" <<<"${job_all_secret_refs}"; then
  fail "the migration Job must never reference the DML-only runtime credential"
fi

# --- axis 11: the Job's labels really match the policy that admits it --------
# Two files, one contract. If these drift apart the migration Job runs and then
# fails to connect, which reads as a database outage rather than a policy edit.
job_partof="$(yaml_query -r '.spec.template.metadata.labels["app.kubernetes.io/part-of"]' "${job_template}")"
job_component="$(yaml_query -r '.spec.template.metadata.labels["app.kubernetes.io/component"]' "${job_template}")"
assert_eq "${job_partof}" "${admit_partof}" "migration Job part-of label vs the NetworkPolicy that admits it"
if ! grep -q "\"${job_component}\"" <<<"${admit_components}"; then
  fail "migration Job component label '${job_component}' is not in the admitted set ${admit_components}"
fi

# --- axis 12: the Job templates are not stack state --------------------------
# Parsed, not grepped: the kustomization's header comment names the templates
# on purpose (to say where they live), and a textual match would reject that.
kustomization_resources="$(yaml_query -r '.resources[]?' "${kustomization}")"
if grep -Fq "job-migrator" <<<"${kustomization_resources}"; then
  fail "the migration Job template must not be a kustomization resource; it is a protected one-shot action input"
fi
if grep -Fq "bucket-create" <<<"${kustomization_resources}"; then
  fail "the bucket-create Job template must not be a kustomization resource; it is a protected one-shot action input"
fi
if grep -Fq "restore-cluster" <<<"${kustomization_resources}"; then
  fail "the restore-cluster template must not be a kustomization resource; it is a protected one-shot rehearsal input"
fi

# --- axis 13: the GFTB-owned rustfs backup store (B1 ruling, 2026-08-20) ----
# Four checked things: the image is digest-pinned (never a tag, never a
# different rustfs repo), provider placement is absent, the PVC is >=50Gi,
# and the closed ingress policy and cluster endpoint name the same Service.
rustfs_image="$(yaml_query -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "rustfs") | .image' "${rendered}")"
if [[ ! "${rustfs_image}" =~ @sha256:[0-9a-f]{64}$ ]]; then
  fail "rustfs StatefulSet image must be pinned by @sha256:<64 lowercase hex>; got '${rustfs_image}'"
fi
assert_eq "${rustfs_image}" "${WANT_RUSTFS_REPO}:${WANT_RUSTFS_TAG}@${WANT_RUSTFS_DIGEST}" \
  "rustfs image digest (B1 ruling: digest reused from the house pin source)"

assert_eq "$(yaml_query -r 'select(.kind == "StatefulSet") | .spec.template.spec | has("nodeSelector")' "${rendered}")" \
  "false" "consumer backup store must not select a provider node"
assert_eq "$(yaml_query -r 'select(.kind == "PersistentVolumeClaim") | .spec | has("storageClassName")' "${rendered}")" \
  "false" "consumer backup PVC must not select a provider storageClass"
rustfs_pvc_size="$(yaml_query -r 'select(.kind == "PersistentVolumeClaim") | .spec.resources.requests.storage' "${rendered}")"
if [[ ! "${rustfs_pvc_size}" =~ ^([0-9]+)Gi$ ]]; then
  fail "rustfs PVC storage request must be an integer Gi quantity; got '${rustfs_pvc_size}'"
fi
if [ "${BASH_REMATCH[1]}" -lt "${MIN_RUSTFS_STORAGE_GI}" ]; then
  fail "rustfs PVC storage request ${rustfs_pvc_size} is below the B1 ruling's >=${MIN_RUSTFS_STORAGE_GI}Gi floor"
fi

rustfs_ingress_pol="select(.kind == \"NetworkPolicy\" and .metadata.name == \"allow-cnpg-to-backup-store-ingress\")"
rustfs_ingress_selector="$(yaml_query -c "${rustfs_ingress_pol} | .spec.podSelector" "${rendered}")"
assert_eq "${rustfs_ingress_selector}" "{\"matchLabels\":{\"app.kubernetes.io/name\":\"${WANT_RUSTFS_NAME}\"}}" \
  "rustfs ingress NetworkPolicy podSelector (must scope to the backup store pod, not the namespace)"
rustfs_ingress_from_ns="$(yaml_query -r "${rustfs_ingress_pol} | .spec.ingress[].from[] | select(has(\"namespaceSelector\"))" "${rendered}")"
test -z "${rustfs_ingress_from_ns}" || fail "rustfs ingress must admit same-namespace pods only (cnpg.io/cluster: ${WANT_CLUSTER}); a namespaceSelector was found"
# B-5: admits the primary AND the restore rehearsal cluster, by matchExpressions
# In [...], never a bare matchLabels (which would admit only one) and never an
# unbounded operator that would admit every cnpg.io/cluster value in the ns.
rustfs_ingress_from_op="$(yaml_query -r "${rustfs_ingress_pol} | .spec.ingress[].from[].podSelector.matchExpressions[] | select(.key == \"cnpg.io/cluster\") | .operator" "${rendered}")"
assert_eq "${rustfs_ingress_from_op}" "In" "rustfs ingress admitted-source operator (must be a closed 'In' list)"
rustfs_ingress_from_values="$(yaml_query -c "${rustfs_ingress_pol} | .spec.ingress[].from[].podSelector.matchExpressions[] | select(.key == \"cnpg.io/cluster\") | .values | sort" "${rendered}")"
assert_eq "${rustfs_ingress_from_values}" "$(jq -nc --arg a "${WANT_CLUSTER}" --arg b "${WANT_RESTORE_CLUSTER}" '[$a,$b] | sort')" \
  "rustfs ingress admitted source set (primary + restore rehearsal cluster, nothing else)"
rustfs_ingress_port="$(yaml_query -r "${rustfs_ingress_pol} | .spec.ingress[].ports[].port" "${rendered}")"
assert_eq "${rustfs_ingress_port}" "9000" "rustfs ingress port"
bucket_ingress_identity="$(yaml_query -c "${rustfs_ingress_pol} | [.spec.ingress[].from[].podSelector.matchLabels | select(.[\"app.kubernetes.io/name\"] == \"gftb-member-db-backup-bucket-create\") | to_entries | sort_by(.key) | from_entries]" "${rendered}")"
assert_eq "${bucket_ingress_identity}" '[{"app.kubernetes.io/component":"object-store-bootstrap","app.kubernetes.io/name":"gftb-member-db-backup-bucket-create","app.kubernetes.io/part-of":"great-falls-tool-bus"}]' \
  "rustfs ingress bucket-create workload identity"

# Egress: exactly the DNS leg, nothing else — "zero egress beyond DNS".
rustfs_egress_pol="select(.kind == \"NetworkPolicy\" and .metadata.name == \"backup-store-egress-dns-only\")"
rustfs_egress_to_count="$(yaml_query -r "${rustfs_egress_pol} | [.spec.egress[].to[]] | length" "${rendered}")"
assert_eq "${rustfs_egress_to_count}" "1" "rustfs egress NetworkPolicy must admit exactly one destination (DNS)"
rustfs_egress_ports="$(yaml_query -c "${rustfs_egress_pol} | [.spec.egress[].ports[].port] | sort" "${rendered}")"
assert_eq "${rustfs_egress_ports}" "[53,53]" "rustfs egress ports (UDP/TCP 53 only)"

bucket_egress_pol='select(.kind == "NetworkPolicy" and .metadata.name == "allow-bucket-create-egress")'
bucket_egress_selector="$(yaml_query -c "${bucket_egress_pol} | .spec.podSelector.matchLabels | to_entries | sort_by(.key) | from_entries" "${rendered}")"
assert_eq "${bucket_egress_selector}" '{"app.kubernetes.io/component":"object-store-bootstrap","app.kubernetes.io/name":"gftb-member-db-backup-bucket-create","app.kubernetes.io/part-of":"great-falls-tool-bus"}' \
  "bucket-create egress workload identity"
bucket_egress_ports="$(yaml_query -c "${bucket_egress_pol} | [.spec.egress[].ports[] | (.protocol + \":\" + (.port|tostring))] | sort" "${rendered}")"
assert_eq "${bucket_egress_ports}" '["TCP:53","TCP:9000","UDP:53"]' \
  "bucket-create egress ports (DNS and backup store only)"
bucket_egress_store="$(yaml_query -c "${bucket_egress_pol} | [.spec.egress[].to[] | select((.podSelector.matchLabels[\"app.kubernetes.io/name\"] // \"\") == \"gftb-member-db-backup-store\") | .podSelector.matchLabels[\"app.kubernetes.io/name\"]]" "${rendered}")"
assert_eq "${bucket_egress_store}" '["gftb-member-db-backup-store"]' \
  "bucket-create egress backup-store destination"

# The CNPG pods' own egress must now reach the rustfs Service, not tcfs — and
# the tcfs leg must be gone entirely, not just superseded, or a stale allow
# keeps pointing at a namespace GFTB does not govern.
pg_egress_to_rustfs="$(yaml_query -r 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-postgres-egress") | .spec.egress[].to[] | select(has("podSelector")) | .podSelector.matchLabels["app.kubernetes.io/name"] // empty' "${rendered}")"
grep -qx "${WANT_RUSTFS_NAME}" <<<"${pg_egress_to_rustfs}" || fail "allow-postgres-egress must admit egress to the rustfs backup store pod (${WANT_RUSTFS_NAME}) on :9000"
# Structural check, not a text grep: comments are allowed to name "tcfs" while
# explaining the rewire (see cluster.yaml and this file's own header), but no
# live namespaceSelector may still target it.
namespace_selectors="$(yaml_query -r 'select(.kind == "NetworkPolicy") | (.spec.ingress[]?, .spec.egress[]?) | (.to[]?, .from[]?) | select(has("namespaceSelector")) | .namespaceSelector.matchLabels["kubernetes.io/metadata.name"]' "${rendered}")"
if grep -qx "tcfs" <<<"${namespace_selectors}"; then
  fail "no live namespaceSelector may target the tcfs namespace in ${netpol} after the B1 ruling rewire"
fi

# endpointURL must actually name the Service declared in rustfs.yaml, not just
# satisfy the generic in-cluster regex from axis 5 above.
rustfs_svc_name="$(yaml_query -r 'select(.kind == "Service") | .metadata.name' "${rendered}")"
assert_eq "${rustfs_svc_name}" "${WANT_RUSTFS_NAME}" "rustfs Service name"
want_endpoint="http://${WANT_RUSTFS_NAME}.${WANT_DB_NS}.svc.cluster.local:9000"
assert_eq "${endpoint}" "${want_endpoint}" "cluster.yaml barmanObjectStore endpointURL must match the rustfs Service declared in rustfs.yaml"

# --- axis 14: the bucket-create Job template (B-3, PR #118 review round) ----
# Source read, deliberately (like axis 10/11 for job-migrator): this template
# is never a kustomization member (axis 12 asserts that), so it never appears
# in the render.
bc_kind="$(yaml_query -r '.kind' "${bucket_create}")"
assert_eq "${bc_kind}" "Job" "bucket-create Job kind"
bc_ns="$(yaml_query -r '.metadata.namespace' "${bucket_create}")"
assert_eq "${bc_ns}" "${WANT_DB_NS}" "bucket-create Job namespace (runs in the database namespace, alongside rustfs)"
bc_fixed_name="$(yaml_query -r '.metadata.name // "absent"' "${bucket_create}")"
assert_eq "${bc_fixed_name}" "absent" "bucket-create Job must not carry a fixed metadata.name (generateName only)"
# The bootstrap Job has its own identity and policy. It must never impersonate
# a CNPG pod and inherit database-peer or Kubernetes-API egress.
bc_labels="$(yaml_query -c '.spec.template.metadata.labels | to_entries | sort_by(.key) | from_entries' "${bucket_create}")"
assert_eq "${bc_labels}" '{"app.kubernetes.io/component":"object-store-bootstrap","app.kubernetes.io/name":"gftb-member-db-backup-bucket-create","app.kubernetes.io/part-of":"great-falls-tool-bus"}' \
  "bucket-create Job workload identity"
bc_cnpg_label="$(yaml_query -r '.spec.template.metadata.labels["cnpg.io/cluster"] // "absent"' "${bucket_create}")"
assert_eq "${bc_cnpg_label}" "absent" "bucket-create Job must not impersonate a CNPG Cluster pod"
bc_image="$(yaml_query -r '.spec.template.spec.containers[] | select(.name == "mc") | .image' "${bucket_create}")"
if [[ ! "${bc_image}" =~ @sha256:[0-9a-f]{64}$ ]]; then
  fail "bucket-create Job mc image must be pinned by @sha256:<64 lowercase hex>; got '${bc_image}'"
fi
assert_eq "${bc_image}" "${WANT_MC_REPO}@${WANT_MC_DIGEST}" \
  "bucket-create Job mc image digest (reused verbatim from the estate's already-vetted pin)"
bc_secret="$(yaml_query -r '.spec.template.spec.containers[] | select(.name == "mc") | .envFrom[]?.secretRef.name // empty' "${bucket_create}")"
assert_eq "${bc_secret}" "${WANT_RUSTFS_ROOT_SECRET}" \
  "bucket-create Job credential (must be the SAME Secret rustfs.yaml's own container consumes)"
bc_bucket="$(yaml_query -r '.spec.template.spec.containers[] | select(.name == "mc") | .env[]? | select(.name == "RUSTFS_BUCKET") | .value' "${bucket_create}")"
case "${destination}" in
"s3://${bc_bucket}/") ;;
*) fail "bucket-create Job RUSTFS_BUCKET ('${bc_bucket}') must match cluster.yaml's barmanObjectStore.destinationPath bucket ('${destination}')" ;;
esac

# --- axis 15: the restore rehearsal template (B-5, PR #118 review round) ----
# Source read, same reasoning as axis 14: never a kustomization member.
rc_kind="$(yaml_query -r '.kind' "${restore_cluster}")"
assert_eq "${rc_kind}" "Cluster" "restore-cluster template kind"
rc_ns="$(yaml_query -r '.metadata.namespace' "${restore_cluster}")"
assert_eq "${rc_ns}" "${WANT_DB_NS}" "restore-cluster template namespace (same namespace as the primary, never over it)"
rc_name="$(yaml_query -r '.metadata.name' "${restore_cluster}")"
assert_eq "${rc_name}" "${WANT_RESTORE_CLUSTER}" "restore-cluster template name (this is the label value both netpol fixes admit)"
rc_server_name="$(yaml_query -r '.spec.externalClusters[] | select(.name == "gftb-member-db-origin") | .barmanObjectStore.serverName' "${restore_cluster}")"
assert_eq "${rc_server_name}" "${WANT_CLUSTER}" "restore-cluster externalClusters.barmanObjectStore.serverName (must read the PRIMARY's WAL/base-backup objects, not its own)"
rc_endpoint="$(yaml_query -r '.spec.externalClusters[] | select(.name == "gftb-member-db-origin") | .barmanObjectStore.endpointURL' "${restore_cluster}")"
assert_eq "${rc_endpoint}" "${want_endpoint}" "restore-cluster externalClusters endpointURL must match the same rustfs Service the primary uses"
rc_secret_names="$(yaml_query -c '.spec.externalClusters[] | select(.name == "gftb-member-db-origin") | [.barmanObjectStore.s3Credentials.accessKeyId.name, .barmanObjectStore.s3Credentials.secretAccessKey.name] | unique' "${restore_cluster}")"
assert_eq "${rc_secret_names}" '["gftb-member-db-backup-s3"]' "restore-cluster s3Credentials (by name only, the SAME credential the primary's archive_command uses)"
rc_superuser="$(yaml_query -r '.spec.enableSuperuserAccess' "${restore_cluster}")"
assert_eq "${rc_superuser}" "false" "restore-cluster enableSuperuserAccess"
assert_eq "$(yaml_query -r '.spec.storage | has("storageClass")' "${restore_cluster}")" \
  "false" "restore template must not select a provider storageClass"

# --- Full render already happened up front (B-7) — this is where every check
# above got its bytes from; nothing left to do here but declare victory.

echo "member-db source contract valid for ${WANT_CLUSTER} in ${stack_ns}: no Namespace or Secret object; PostgreSQL 16.15 pinned to ${WANT_PG_REPO}@sha256:<64 hex> with a separate WAL volume; archive_timeout ${archive_seconds}s; base-backup schedule '${schedule}' with ${retention} retention; ${WANT_OWNER_ROLE} DDL and ${WANT_RUNTIME_ROLE} DML-only roles separated; migration Job uses ${WANT_MIGRATOR_ARGS} and only ${WANT_MIGRATOR_SECRET}; backup destination ${want_endpoint}"
