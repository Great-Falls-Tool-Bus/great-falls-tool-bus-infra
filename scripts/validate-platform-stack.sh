#!/usr/bin/env bash
set -euo pipefail
dir="${1:?usage: validate-platform-stack.sh <manifest-dir>}"; root="$(cd "${dir}/.." && pwd)"
route="${root}/../../tofu/intent/great-falls-tool-bus/staging-platform-route.json"; secrets="${root}/secrets.contract.yaml"
image="ghcr.io/great-falls-tool-bus/greatfallstoolbus.org@sha256:10f853938dc6823afe8c9bdc54943587f963d22117aafd17247350b2b5712b35"; tenant="PLACEHOLDER-GFTB-TENANT-ID"; ns="members-greatfallstoolbus-org-production"
fail(){ echo "ERROR: $*" >&2; exit 1; }
for x in yq jq kubectl; do command -v "$x" >/dev/null 2>&1 || fail "$x required"; done
v="$(yq --version 2>&1||true)"; printf '%s' "${v}"|grep -qi mikefarah && printf '%s' "${v}"|grep -Eqi 'version v?4\.' || fail "mikefarah yq-go v4 required"
for f in deployment-web.yaml deployment-worker.yaml service-web.yaml networkpolicy.yaml kustomization.yaml; do test -f "${dir}/${f}"||fail "missing ${f}"; done
test -f "${route}" && test -f "${secrets}" || fail "missing authority file"
yaml="$(mktemp)"; json="$(mktemp)"; contract="$(mktemp)"; mut="$(mktemp)"; trap 'rm -f "${yaml}" "${json}" "${contract}" "${mut}"' EXIT
kubectl kustomize "${dir}">"${yaml}"; yq eval-all -o=json -I=0 '.' "${yaml}"|jq --slurp '.'>"${json}"
cat >"${contract}" <<'JQ'
def one($k;$n):[.[]|select(.kind==$k and .metadata.name==$n)]as$x|if($x|length)==1 then$x[0]else error("identity/cardinality")end;
def cs:{"matchLabels":{"app.kubernetes.io/part-of":"great-falls-tool-bus"},"matchExpressions":[{"key":"app.kubernetes.io/component","operator":"In","values":["web","worker","migrator"]}]};
def hp($p;$g):$p.automountServiceAccountToken==false and $p.terminationGracePeriodSeconds==$g and $p.securityContext=={"runAsNonRoot":true,"runAsUser":1001,"runAsGroup":1001,"fsGroup":1001,"seccompProfile":{"type":"RuntimeDefault"}};
def hc($c):$c.securityContext=={"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}} and ($c|has("envFrom")|not);
def np($n;$s):one("NetworkPolicy";$n)as$p|$p.apiVersion=="networking.k8s.io/v1" and $p.metadata.namespace==$ns and $p.spec==$s;
one("Deployment";"gftb-platform-web")as$w|one("Deployment";"gftb-platform-worker")as$k|one("Service";"gftb-platform-web")as$s
|$w.spec.template.spec as$wp|$k.spec.template.spec as$kp|$wp.containers as$wc|$kp.containers as$kc
|(type=="array" and length==9 and all(.[];type=="object" and .metadata.namespace==$ns and .metadata.labels["app.kubernetes.io/part-of"]=="great-falls-tool-bus"))
and([.[]|"\(.kind)/\(.metadata.name)"]|sort)==["Deployment/gftb-platform-web","Deployment/gftb-platform-worker","NetworkPolicy/allow-cloudflared-tunnel-ingress","NetworkPolicy/allow-egress-dns","NetworkPolicy/allow-egress-member-db","NetworkPolicy/allow-prometheus-scrape","NetworkPolicy/default-deny-egress","NetworkPolicy/default-deny-ingress","Service/gftb-platform-web"]
and $w.spec.replicas==2 and $w.spec.strategy=={"type":"RollingUpdate","rollingUpdate":{"maxUnavailable":0,"maxSurge":1}} and $k.spec.replicas==1 and $k.spec.strategy=={"type":"Recreate"}
and $w.spec.template.metadata.labels["app.kubernetes.io/part-of"]=="great-falls-tool-bus" and $k.spec.template.metadata.labels["app.kubernetes.io/part-of"]=="great-falls-tool-bus"
and($wc|length)==1 and($kc|length)==1 and $wc[0].name=="gftb-platform-web" and $kc[0].name=="gftb-platform-worker" and $wc[0].image==$image and $kc[0].image==$image
and $wp.imagePullSecrets==[{"name":"ghcr-pull"}] and $kp.imagePullSecrets==[{"name":"ghcr-pull"}] and($wc[0]|has("command")|not)and($wc[0]|has("args")|not)and($kc[0]|has("command")|not)and $kc[0].args==["worker"]
and hp($wp;15) and hp($kp;30) and hc($wc[0]) and hc($kc[0])
and($wc[0].env|map(.name))==["NODE_ENV","PORT","DATABASE_URL","GFTB_TENANT_ID","STRIPE_SECRET_KEY","STRIPE_WEBHOOK_SECRET","STRIPE_PUBLISHABLE_KEY"]
and($kc[0].env|map(.name))==["NODE_ENV","DATABASE_URL","GFTB_TENANT_ID","GFTB_WORKER_ID","STRIPE_SECRET_KEY","STRIPE_WEBHOOK_SECRET"]
and all([$wc[0],$kc[0]][];[.env[]|select(.name=="DATABASE_URL")|.valueFrom.secretKeyRef]==[{"name":"gftb-member-db-runtime-dsn","key":"dsn"}])
and([$wc[0].env[]|select(.name|startswith("STRIPE_"))|.valueFrom.secretKeyRef]==[{"name":"gftb-platform-stripe-testmode","key":"STRIPE_SECRET_KEY","optional":true},{"name":"gftb-platform-stripe-testmode","key":"STRIPE_WEBHOOK_SECRET","optional":true},{"name":"gftb-platform-stripe-testmode","key":"STRIPE_PUBLISHABLE_KEY","optional":true}])
and([$kc[0].env[]|select(.name|startswith("STRIPE_"))|.valueFrom.secretKeyRef]==[{"name":"gftb-platform-stripe-testmode","key":"STRIPE_SECRET_KEY","optional":true},{"name":"gftb-platform-stripe-testmode","key":"STRIPE_WEBHOOK_SECRET","optional":true}])
and $s.spec=={"type":"ClusterIP","selector":{"app.kubernetes.io/name":"gftb-platform-web","app.kubernetes.io/component":"web"},"ports":[{"name":"http","port":80,"protocol":"TCP","targetPort":"http"}]}
and np("default-deny-ingress";{"podSelector":{},"policyTypes":["Ingress"]}) and np("default-deny-egress";{"podSelector":{},"policyTypes":["Egress"]})
and np("allow-cloudflared-tunnel-ingress";{"podSelector":{"matchLabels":{"app.kubernetes.io/name":"gftb-platform-web","app.kubernetes.io/component":"web"}},"policyTypes":["Ingress"],"ingress":[{"from":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"cloudflared"}}}],"ports":[{"protocol":"TCP","port":3000}]}]})
and np("allow-prometheus-scrape";{"podSelector":{"matchLabels":{"app.kubernetes.io/name":"gftb-platform-web","app.kubernetes.io/component":"web"}},"policyTypes":["Ingress"],"ingress":[{"from":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"tinyland-dev-production"}},"podSelector":{"matchLabels":{"app.kubernetes.io/name":"prometheus"}}}],"ports":[{"protocol":"TCP","port":3000}]}]})
and np("allow-egress-dns";{"podSelector":cs,"policyTypes":["Egress"],"egress":[{"to":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}],"ports":[{"protocol":"UDP","port":53},{"protocol":"TCP","port":53}]}]})
and np("allow-egress-member-db";{"podSelector":cs,"policyTypes":["Egress"],"egress":[{"to":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"members-greatfallstoolbus-org-db-production"}},"podSelector":{"matchLabels":{"cnpg.io/cluster":"gftb-member-db"}}}],"ports":[{"protocol":"TCP","port":5432}]}]})
JQ
check(){ jq -e --arg image "${image}" --arg tenant "${tenant}" --arg ns "${ns}" -f "${contract}" "$1">/dev/null; }
check "${json}"||fail "exact stack contract mismatch"
reject(){ jq "$2" "${json}">"${mut}"; if check "${mut}";then fail "negative accepted: $1";fi; }
reject source 'map(if .metadata.name=="allow-cloudflared-tunnel-ingress" then .spec.ingress[0].from=[] else . end)'
reject extra-ingress 'map(if .metadata.name=="allow-cloudflared-tunnel-ingress" then .spec.ingress+=[.spec.ingress[0]] else . end)'
reject prometheus-source 'map(if .metadata.name=="allow-prometheus-scrape" then .spec.ingress[0].from=[{}] else . end)'
reject prometheus-port 'map(if .metadata.name=="allow-prometheus-scrape" then .spec.ingress[0].ports[0].port=3001 else . end)'
reject ipblock 'map(if .metadata.name=="allow-egress-member-db" then .spec.egress[0].to=[{"ipBlock":{"cidr":"0.0.0.0/0"}}] else . end)'
reject missing-to 'map(if .metadata.name=="allow-egress-dns" then .spec.egress[0].to=[] else . end)'
reject policytypes 'map(if .metadata.name=="default-deny-ingress" then .spec.policyTypes=["Ingress","Egress"] else . end)'
reject stripe 'map(if .metadata.name=="gftb-platform-web" then .spec.template.spec.containers[0].env|=map(select(.name!="STRIPE_SECRET_KEY")) else . end)'
reject envfrom 'map(if .metadata.name=="gftb-platform-worker" then .spec.template.spec.containers[0].envFrom=[{}] else . end)'
reject extra-credential 'map(if .metadata.name=="gftb-platform-web" then .spec.template.spec.containers[0].env+=[{"name":"EXTRA_TOKEN","value":"x"}] else . end)'
reject sidecar 'map(if .metadata.name=="gftb-platform-web" then .spec.template.spec.containers += [.spec.template.spec.containers[0]] else . end)'
reject privilege 'map(if .metadata.name=="gftb-platform-worker" then .spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation=true else . end)'
reject pull 'map(if .metadata.name=="gftb-platform-web" then del(.spec.template.spec.imagePullSecrets) else . end)'
grep -REn "gftb-member-db-migrator-dsn" "${dir}" 2>/dev/null|grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'>/dev/null && fail "migrator DSN executable"||true
grep -Fq "PR #118's" "${secrets}"&&grep -Fq "gftb-site was authorized public" "${secrets}"||fail "pull/visibility SSOT missing"
jq -e '.applied==false and .dns_enabled==false and .route_enabled==false and .planned_route.dns_record.enabled==false and .planned_route.hostname=="staging.greatfallstoolbus.org"' "${route}">/dev/null||fail "route intent open"
echo "platform stack validation passed"
