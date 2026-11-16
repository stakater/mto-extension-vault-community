#!/usr/bin/env bash
#
# C.0 question 18: q18-admission.yaml against good and bad VCO CRs. Each case
# is a server-side dry run in vault-config, so nothing reaches VCO. A refusal
# counts only when the admission policy gives it; each refused case changes
# one field of an admitted one. The last case is a tenant Template that tries
# to write into vault-config through Template Operator (question 18b).
set -euo pipefail

CONTEXT=${CONTEXT:-kind-vault-ce-lab}
# check runs at the end of a pipeline, in a subshell (bash 3.2 has no
# lastpipe), so each failure is a line in a file.
FAILS=$(mktemp); trap 'rm -f "$FAILS"' EXIT
fail() { echo "FAIL  $*"; echo >>"$FAILS"; }
kc() { kubectl --context "$CONTEXT" "$@"; }

AUTH='  authentication: { path: kubernetes, role: vco-admin, serviceAccount: { name: vco-admin } }'
V=redhatcop.redhat.io/v1alpha1

# check <admit|refuse> <description>; the CR is read from stdin.
check() {
  local want=$1 what=$2 out rc=0
  out=$(kc apply --dry-run=server -f - 2>&1) || rc=$?
  if [ "$want" = admit ]; then
    if [ "$rc" = 0 ]; then echo "PASS  admit:  $what"; else fail "admit:  $what: $out"; fi
  else
    if [ "$rc" != 0 ] && grep -q 'ValidatingAdmissionPolicy' <<<"$out"; then
      echo "PASS  refuse: $what"; echo "      $(grep -o "denied request: .*" <<<"$out" | cut -c1-150)"
    else fail "refuse: $what: rc=$rc $out"; fi
  fi
}

policy() { # <name> <policy text>
  printf 'apiVersion: %s\nkind: Policy\nmetadata: { name: %s, namespace: vault-config }\nspec:\n%s\n  name: %s\n  policy: |\n' "$V" "$1" "$AUTH" "$1"
  sed 's/^/    /' <<<"$2"
}
k8srole() { # <name> <path> <sa> <policies> <targetNamespaces block>
  printf 'apiVersion: %s\nkind: KubernetesAuthEngineRole\nmetadata: { name: %s, namespace: vault-config }\nspec:\n%s\n  name: %s\n  path: %s\n  targetServiceAccounts: [%s]\n  policies: [%s]\n  targetNamespaces:\n%s\n' "$V" "$1" "$AUTH" "$1" "$2" "$3" "$4" "$5"
}
sel() { printf '    targetNamespaceSelector:\n      matchLabels: { kubernetes.io/metadata.name: %s, stakater.com/tenant: %s }' "$1" "$2"; }
ssorole() { # <name> <path> <groups or empty> [extra spec line]
  local claims=""
  [ -n "$3" ] && claims="  boundClaims: { groups: [$3] }"
  printf 'apiVersion: %s\nkind: JWTOIDCAuthEngineRole\nmetadata: { name: %s, namespace: vault-config }\nspec:\n%s\n  name: %s\n  path: %s\n  roleType: oidc\n  userClaim: sub\n  tokenPolicies: [%s]\n  allowedRedirectURIs: ["http://localhost:8250/oidc/callback"]\n%s\n%s\n' \
    "$V" "$1" "$AUTH" "$1" "$2" "$1" "$claims" "${4:-}"
}

web='path "team-a/kv/data/dev/team-a-api/web2/*"     { capabilities = ["create", "read", "update", "patch", "list"] }
path "team-a/kv/metadata/dev/team-a-api/web2/*" { capabilities = ["read", "list"] }
path "team-a/kv/data/dev/_shared/from-team-a-api/*" { capabilities = ["read", "list"] }'

echo "== Policies"
policy kv.team-a.team-a-api.web2 "$web" | check admit "a workload policy in its tenant's scope"
policy kv.x.y.z 'path "*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }' | check refuse "question 16's policy: path \"*\" with sudo"
policy kv.team-a.team-a-api.web2 'path "team-a*" { capabilities = ["read"] }' | check refuse "a tenant segment not closed by /"
policy kv.team-a.team-a-api.web2 'path "team-b/kv/data/dev/team-b-api/api/*" { capabilities = ["read"] }' | check refuse "another tenant's path"
policy kv.team.team-core.core 'path "team-a/kv/data/dev/team-a-api/web/*" { capabilities = ["read"] }' | check refuse "the prefix tenant team on team-a's path"
policy kv.team-a.team-a-api.web2 'path "team-a/kv/config" { capabilities = ["update"] }' | check refuse "the tenant mount's config"
policy kv.team-a.team-a-api.web2 '{"path": {"*": {"capabilities": ["read"]}}}' | check refuse "a JSON policy body"
policy kv.team-a.team-a-api.web2 'path "team-a/kv/data/dev/team-a-api/web2/*" {
  capabilities = ["read"]
}' | check refuse "a stanza over several lines"
policy kv.team-a.team-a-api.web2 'path "team-a/kv/data/dev/team-a-api/web2/*" { capabilities = ["read", "sudo"] }' | check refuse "sudo on its own path"
policy vco-admin2 'path "team-a/kv/data/dev/x/*" { capabilities = ["read"] }' | check refuse "a name outside the families"
policy share.team-a.team-a-api.web.out.team-b 'path "shared/kv/data/dev/from-team-a/to-team-b/*" { capabilities = ["create", "read", "update", "list"] }' | check admit "an export policy"
policy share.team-a.team-a-api.web.out.team-b 'path "shared/kv/data/dev/from-team-b/to-team-a/*" { capabilities = ["create", "read", "update", "list"] }' | check refuse "an export policy writing the peer's direction"
policy share.team-b.team-b-api.api.in.team-a 'path "shared/kv/data/dev/from-team-a/to-team-b/*" { capabilities = ["read", "list"] }' | check admit "an import policy"
policy share.team-b.team-b-api.api.in.team-a 'path "shared/kv/data/dev/from-team-a/to-team-b/*" { capabilities = ["read", "create"] }' | check refuse "an import policy that writes"
policy sso.team-a.editor 'path "team-a/kv/metadata" { capabilities = ["list"] }
path "team-a/kv/data/dev/*" { capabilities = ["create", "read", "update", "patch", "list"] }' | check admit "an SSO tier policy"

echo "== Workload roles"
k8srole kv.team-a.team-a-api.web2 team-a/kubernetes/workloads web2 kv.team-a.team-a-api.web2 "$(sel team-a-api team-a)" | check admit "a workload role"
k8srole kv.team-a.team-a-api.web2 team-a/kubernetes/workloads web2 kv.team-b.team-b-api.api "$(sel team-a-api team-a)" | check refuse "a role bound to another tenant's policy"
k8srole kv.team-a.team-a-api.web2 team-a/kubernetes/workloads web2 kv.team-a.team-a-api.web2 '    targetNamespaces: [team-a-api]' | check refuse "a namespace bound by name only"
k8srole kv.team-a.team-a-api.web2 team-a/kubernetes/workloads web2 kv.team-a.team-a-api.web2 "$(sel team-a-api team-b)" | check refuse "a namespace bound with another tenant's label"
k8srole kv.team-a.team-a-api.web2 team-b/kubernetes/workloads web2 kv.team-a.team-a-api.web2 "$(sel team-a-api team-a)" | check refuse "a role on another tenant's mount"
k8srole kv.team-a.team-a-api.web2 team-a/kubernetes/workloads jobs kv.team-a.team-a-api.web2 "$(sel team-a-api team-a)" | check refuse "a role for another ServiceAccount"
k8srole share.team-b.team-b-api.api2.in.team-a shared/kubernetes/workloads api2 share.team-b.team-b-api.api2.in.team-a "$(sel team-b-api team-b)" | check admit "a share role on the shared mount"

echo "== SSO roles"
ssorole sso.team-a.editor team-a/oidc/sso team-a-editors | check admit "an SSO role for its tenant's group"
ssorole sso.team-a.editor team-a/oidc/sso team-b-editors | check refuse "an SSO role for another tenant's group"
ssorole sso.team-a.editor team-a/oidc/sso team-a-editors '  boundClaimsType: glob' | check refuse "an SSO role with glob claims"
ssorole sso.team-a.editor team-a/oidc/sso "" | check refuse "an SSO role with no bound claims (a fallback)"

echo "== Mounts and configs"
printf 'apiVersion: %s\nkind: SecretEngineMount\nmetadata: { name: team-c-kv, namespace: vault-config }\nspec:\n%s\n  path: team-c\n  name: kv\n  type: kv\n  config: { listingVisibility: hidden }\n' "$V" "$AUTH" | check admit "a tenant mount"
printf 'apiVersion: %s\nkind: SecretEngineMount\nmetadata: { name: team-c-kv, namespace: vault-config }\nspec:\n%s\n  path: team-c\n  name: kv\n  type: kv\n  config: { listingVisibility: hidden, auditNonHMACRequestKeys: [data] }\n' "$V" "$AUTH" | check refuse "a tenant mount that logs request data in clear"
printf 'apiVersion: %s\nkind: AuthEngineMount\nmetadata: { name: team-c-kubernetes, namespace: vault-config }\nspec:\n%s\n  path: team-c/kubernetes\n  name: workloads\n  type: kubernetes\n  config: { listingVisibility: hidden }\n' "$V" "$AUTH" | check admit "a tenant's Kubernetes auth mount"
printf 'apiVersion: %s\nkind: AuthEngineMount\nmetadata: { name: team-c-kubernetes, namespace: vault-config }\nspec:\n%s\n  path: team-c/kubernetes\n  name: workloads\n  type: userpass\n  config: { listingVisibility: hidden }\n' "$V" "$AUTH" | check refuse "a userpass mount in its place"
printf 'apiVersion: %s\nkind: KubernetesAuthEngineConfig\nmetadata: { name: team-c-kubernetes-config, namespace: vault-config }\nspec:\n%s\n  path: team-c/kubernetes\n  name: workloads\n  kubernetesHost: https://kubernetes.default.svc:443\n' "$V" "$AUTH" | check admit "its config for this cluster"
printf 'apiVersion: %s\nkind: KubernetesAuthEngineConfig\nmetadata: { name: team-c-kubernetes-config, namespace: vault-config }\nspec:\n%s\n  path: team-c/kubernetes\n  name: workloads\n  kubernetesHost: https://evil.example.com:6443\n' "$V" "$AUTH" | check refuse "a config for another cluster's API"
printf 'apiVersion: %s\nkind: KubernetesAuthEngineConfig\nmetadata: { name: team-c-kubernetes-config, namespace: vault-config }\nspec:\n%s\n  path: team-c/kubernetes\n  name: workloads\n  kubernetesHost: https://kubernetes.default.svc:443\n  kubernetesCACert: "-----BEGIN CERTIFICATE-----another CA"\n' "$V" "$AUTH" | check refuse "a config that trusts another CA"

echo "== question 18b: a tenant Template writing into vault-config"
{ printf 'apiVersion: templates.v2.stakater.com/v2alpha1\nkind: Template\nmetadata: { name: deputy, namespace: team-a-api }\nspec:\n  targetNamespaces: { explicit: { allow: { literal: [team-a-api] } } }\n  gotemplate: |\n    ---\n'
  policy kv.team-a.team-a-api.deputy 'path "team-a/kv/data/dev/team-a-api/deputy/*" { capabilities = ["read"] }' | sed 's/^/    /'
  printf -- '---\napiVersion: templates.v2.stakater.com/v2alpha1\nkind: TemplateInstance\nmetadata: { name: deputy, namespace: team-a-api }\nspec:\n  templateRef: { name: deputy, namespace: team-a-api }\n'
} | kc apply -f - >/dev/null
sleep 8
msg=$(kc -n team-a-api get templateinstance deputy -o jsonpath='{.status.conditions[?(@.type=="Applied")].message}')
if grep -q 'mto-vault-community-vco-origin' <<<"$msg" && ! kc -n vault-config get policy kv.team-a.team-a-api.deputy >/dev/null 2>&1; then
  echo "PASS  refuse: Template Operator writing for a tenant Template"; echo "      $(grep -o "denied request: .*" <<<"$msg" | cut -c1-150)"
else fail "refuse: Template Operator writing for a tenant Template: $msg"; fi
kc -n team-a-api delete templateinstance deputy --wait=true >/dev/null; kc -n team-a-api delete template deputy >/dev/null

fails=$(wc -l <"$FAILS" | tr -d " ")
echo "== result: $fails failed"
[ "$fails" = 0 ]
