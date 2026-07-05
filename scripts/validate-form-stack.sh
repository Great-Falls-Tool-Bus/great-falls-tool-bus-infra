#!/usr/bin/env bash
set -euo pipefail

# Offline validation for the GFTB Anubis-protected direct-submit form origin
# (TIN-2420). This never contacts a cluster and never needs a secret.

dir="${1:?usage: validate-form-stack.sh <manifest-dir>}"
account_file="${dir}/mailaccount-form-intake.yaml"
deploy_file="${dir}/deployment-form-origin.yaml"
svc_file="${dir}/service-form-origin.yaml"
netpol_file="${dir}/networkpolicy.yaml"
handler_file="${dir}/configmap-form-handler.yaml"
policy_file="${dir}/configmap-anubis-policy.yaml"
kustomization_file="${dir}/kustomization.yaml"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_file() {
  test -f "$1" || fail "missing $1"
}

field() {
  yq -r "$1" "$2"
}

assert_eq() {
  if [ "$1" != "$2" ]; then
    fail "$3: got '$1', want '$2'"
  fi
}

command -v yq >/dev/null 2>&1 || fail "yq is required"
command -v kubectl >/dev/null 2>&1 || fail "kubectl is required for kubectl kustomize"

require_file "${account_file}"
require_file "${deploy_file}"
require_file "${svc_file}"
require_file "${netpol_file}"
require_file "${handler_file}"
require_file "${policy_file}"
require_file "${kustomization_file}"

# --- Submission identity ---------------------------------------------------
assert_eq "$(field '.apiVersion' "${account_file}")" "mail.tinyland.dev/v1alpha1" "MailAccount apiVersion"
assert_eq "$(field '.kind' "${account_file}")" "MailAccount" "MailAccount kind"
assert_eq "$(field '.metadata.name' "${account_file}")" "form-intake" "MailAccount metadata.name"
assert_eq "$(field '.metadata.namespace' "${account_file}")" "latoolb-us-production" "MailAccount metadata.namespace"
assert_eq "$(field '.spec.email' "${account_file}")" "form-intake@latoolb.us" "MailAccount spec.email"
assert_eq "$(field '.spec.domainRef' "${account_file}")" "latoolb-us" "MailAccount spec.domainRef"
assert_eq "$(field '.spec.enabled' "${account_file}")" "true" "MailAccount spec.enabled"
if [ "$(field '.spec.passwordSecretRef // ""' "${account_file}")" != "" ]; then
  fail "MailAccount must not declare passwordSecretRef; the controller generates the credential"
fi

# --- Runtime shape ---------------------------------------------------------
assert_eq "$(field '.kind' "${deploy_file}")" "Deployment" "form origin Deployment kind"
assert_eq "$(field '.metadata.name' "${deploy_file}")" "gftb-form-origin" "form origin Deployment name"
replicas="$(field '.spec.replicas' "${deploy_file}")"
assert_eq "${replicas}" "1" "Anubis memory store requires single replica until a shared store is wired"

handler_image="$(field '.spec.template.spec.containers[] | select(.name == "form-handler") | .image' "${deploy_file}")"
anubis_image="$(field '.spec.template.spec.containers[] | select(.name == "anubis") | .image' "${deploy_file}")"
if [[ "${handler_image}" == *":latest" || "${anubis_image}" == *":latest" ]]; then
  fail "container images must be pinned to explicit non-latest tags"
fi
assert_eq "${anubis_image}" "ghcr.io/techarohq/anubis:v1.25.0" "Anubis image"

target="$(field '.spec.template.spec.containers[] | select(.name == "anubis") | .env[] | select(.name == "TARGET") | .value' "${deploy_file}")"
bind="$(field '.spec.template.spec.containers[] | select(.name == "anubis") | .env[] | select(.name == "BIND") | .value' "${deploy_file}")"
policy="$(field '.spec.template.spec.containers[] | select(.name == "anubis") | .env[] | select(.name == "POLICY_FNAME") | .value' "${deploy_file}")"
assert_eq "${target}" "http://127.0.0.1:5000" "Anubis TARGET"
assert_eq "${bind}" ":8080" "Anubis BIND"
assert_eq "${policy}" "/etc/anubis/policies.yaml" "Anubis POLICY_FNAME"

anubis_secret="$(field '.spec.template.spec.containers[] | select(.name == "anubis") | .env[] | select(.name == "ED25519_PRIVATE_KEY_HEX") | .valueFrom.secretKeyRef.name' "${deploy_file}")"
anubis_secret_key="$(field '.spec.template.spec.containers[] | select(.name == "anubis") | .env[] | select(.name == "ED25519_PRIVATE_KEY_HEX") | .valueFrom.secretKeyRef.key' "${deploy_file}")"
assert_eq "${anubis_secret}" "gftb-form-anubis-key" "Anubis signing Secret name"
assert_eq "${anubis_secret_key}" "ed25519-private-key-hex" "Anubis signing Secret key"

smtp_host="$(field '.spec.template.spec.containers[] | select(.name == "form-handler") | .env[] | select(.name == "SMTP_HOST") | .value' "${deploy_file}")"
smtp_port="$(field '.spec.template.spec.containers[] | select(.name == "form-handler") | .env[] | select(.name == "SMTP_PORT") | .value' "${deploy_file}")"
from_addr="$(field '.spec.template.spec.containers[] | select(.name == "form-handler") | .env[] | select(.name == "FORM_FROM_ADDRESS") | .value' "${deploy_file}")"
to_addr="$(field '.spec.template.spec.containers[] | select(.name == "form-handler") | .env[] | select(.name == "FORM_TO_ADDRESS") | .value' "${deploy_file}")"
smtp_secret="$(field '.spec.template.spec.containers[] | select(.name == "form-handler") | .env[] | select(.name == "FORM_SMTP_PASSWORD") | .valueFrom.secretKeyRef.name' "${deploy_file}")"
py_no_bytecode="$(field '.spec.template.spec.containers[] | select(.name == "form-handler") | .env[] | select(.name == "PYTHONDONTWRITEBYTECODE") | .value' "${deploy_file}")"
handler_nonroot="$(field '.spec.template.spec.containers[] | select(.name == "form-handler") | .securityContext.runAsNonRoot' "${deploy_file}")"
handler_uid="$(field '.spec.template.spec.containers[] | select(.name == "form-handler") | .securityContext.runAsUser' "${deploy_file}")"
assert_eq "${smtp_host}" "postfix.tinyland-dev-production.svc.cluster.local" "form handler SMTP host"
assert_eq "${smtp_port}" "587" "form handler SMTP port"
assert_eq "${from_addr}" "form-intake@latoolb.us" "form handler sender"
assert_eq "${to_addr}" "keyholders@latoolb.us" "form handler recipient"
assert_eq "${smtp_secret}" "form-intake-smtp" "form handler SMTP Secret name"
assert_eq "${py_no_bytecode}" "1" "form handler must not write bytecode into the ConfigMap mount"
assert_eq "${handler_nonroot}" "true" "form handler must run non-root"
assert_eq "${handler_uid}" "65532" "form handler numeric non-root UID"

# The site-facing Service must expose Anubis, never the handler directly.
svc_target="$(field '.spec.ports[] | select(.name == "http") | .targetPort' "${svc_file}")"
assert_eq "${svc_target}" "http" "form origin Service targetPort"
if yq -r '.spec.ports[]?.targetPort // ""' "${svc_file}" | grep -q "handler"; then
  fail "Service must not expose the form-handler container directly; Anubis owns ingress"
fi

# --- Policy and network invariants ----------------------------------------
policy_text="$(yq -r '.data["policies.yaml"]' "${policy_file}")"
echo "${policy_text}" | grep -q "action: CHALLENGE" || fail "Anubis policy must challenge browser-like traffic"
echo "${policy_text}" | grep -q "difficulty: 4" || fail "Anubis policy must pin challenge difficulty"
echo "${policy_text}" | grep -q "backend: memory" || fail "Anubis policy must state the single-replica memory store explicitly"

ingress_port="$(field '.spec.ingress[].ports[] | select(.port == 8080) | .port' "${netpol_file}")"
egress_smtp="$(field '.spec.egress[].to[]?.ipBlock?.cidr // ""' "${netpol_file}" | grep -x "192.168.70.10/32" || true)"
assert_eq "${ingress_port}" "8080" "NetworkPolicy ingress to Anubis"
assert_eq "${egress_smtp}" "192.168.70.10/32" "NetworkPolicy egress to host-networked postfix"

# --- No secret material committed -----------------------------------------
if grep -REn "^\s*(password|smtp_pass|FORM_SMTP_PASSWORD|ED25519_PRIVATE_KEY_HEX|SECRET_KEY)\s*:\s*['\"]?[A-Za-z0-9+/=]{6,}" "${dir}" \
    | grep -v "secretKeyRef" | grep -v "valueFrom" >/dev/null 2>&1; then
  fail "possible committed secret value under ${dir}; secrets must be referenced by name only"
fi
if grep -REn "BEGIN (RSA|OPENSSH|EC|PRIVATE) KEY|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9_]{20,}" "${dir}" >/dev/null 2>&1; then
  fail "secret-shaped material found under ${dir}"
fi

kubectl kustomize "${dir}" >/dev/null

echo "form stack validation passed: Anubis :8080 -> handler :5000 -> postfix 587 -> keyholders@latoolb.us, no committed secrets"
