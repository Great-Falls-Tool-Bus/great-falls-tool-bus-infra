#!/usr/bin/env bash
set -euo pipefail

dir="${1:?usage: validate-mail-crs.sh <manifest-dir>}"
domain_file="${dir}/maildomain-latoolb-us.yaml"
account_file="${dir}/mailaccount-keyholders.yaml"
kustomization_file="${dir}/kustomization.yaml"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_file() {
  local path="$1"
  test -f "${path}" || fail "missing ${path}"
}

field() {
  local expr="$1"
  local path="$2"
  yq -r "${expr}" "${path}"
}

assert_eq() {
  local got="$1"
  local want="$2"
  local label="$3"
  if [ "${got}" != "${want}" ]; then
    fail "${label}: got '${got}', want '${want}'"
  fi
}

require_file "${domain_file}"
require_file "${account_file}"
require_file "${kustomization_file}"

command -v yq >/dev/null 2>&1 || fail "yq is required"
command -v kubectl >/dev/null 2>&1 || fail "kubectl is required for kubectl kustomize"

assert_eq "$(field '.apiVersion' "${domain_file}")" "mail.tinyland.dev/v1alpha1" "MailDomain apiVersion"
assert_eq "$(field '.kind' "${domain_file}")" "MailDomain" "MailDomain kind"
assert_eq "$(field '.metadata.name' "${domain_file}")" "latoolb-us" "MailDomain metadata.name"
assert_eq "$(field '.metadata.namespace' "${domain_file}")" "latoolb-us-production" "MailDomain metadata.namespace"
assert_eq "$(field '.spec.domain' "${domain_file}")" "latoolb.us" "MailDomain spec.domain"
assert_eq "$(field '.spec.dkimSelector' "${domain_file}")" "mail" "MailDomain spec.dkimSelector"
assert_eq "$(field '.spec.enabled' "${domain_file}")" "true" "MailDomain spec.enabled"

if [ "$(field '.spec.dkimSecretRef // ""' "${domain_file}")" != "" ]; then
  fail "MailDomain must not declare dkimSecretRef; DKIM key material is substrate/operator-owned"
fi
if [ "$(field '.spec.catchAll // ""' "${domain_file}")" != "" ]; then
  fail "MailDomain must not declare catchAll until an operator chooses the mailbox policy"
fi

assert_eq "$(field '.apiVersion' "${account_file}")" "mail.tinyland.dev/v1alpha1" "MailAccount apiVersion"
assert_eq "$(field '.kind' "${account_file}")" "MailAccount" "MailAccount kind"
assert_eq "$(field '.metadata.name' "${account_file}")" "keyholders" "MailAccount metadata.name"
assert_eq "$(field '.metadata.namespace' "${account_file}")" "latoolb-us-production" "MailAccount metadata.namespace"
assert_eq "$(field '.spec.email' "${account_file}")" "keyholders@latoolb.us" "MailAccount spec.email"
assert_eq "$(field '.spec.domainRef' "${account_file}")" "latoolb-us" "MailAccount spec.domainRef"
assert_eq "$(field '.spec.enabled' "${account_file}")" "true" "MailAccount spec.enabled"

if [ "$(field '.spec.passwordSecretRef // ""' "${account_file}")" != "" ]; then
  fail "MailAccount must not declare passwordSecretRef; the controller generates initial credentials"
fi

kubectl kustomize "${dir}" >/dev/null

echo "mail CR validation passed: latoolb.us MailDomain + keyholders@latoolb.us MailAccount"
