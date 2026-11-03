#!/usr/bin/env bash
#
# The bootstrap chart's admission policies (templates/50-admission.yaml)
# against good and bad VCO CRs, on a live cluster where the chart is installed.
# Each case is a server-side dry run in the config namespace, so nothing
# reaches VCO. A refusal counts only when an admission policy gives it, and
# each refused case changes one field of an admitted one. Ported from C.0's
# docs/spikes/c0/q18-admission.sh, with the share roles on the tenant's own
# mount (ADR-0007).
#
# Run by the e2e suite's admission step and by `make admission-test`. Tenant
# names here are never created: the cases are dry runs.
set -euo pipefail

: "${CONTEXT:?CONTEXT must name the kube context}"
KUBECTL=${KUBECTL:-kubectl}
CONFIG_NS=${CONFIG_NS:-vault-config}
ISSUER=${ISSUER:-}
# check runs at the end of a pipeline, in a subshell (bash 3.2 has no
# lastpipe), so each failure is a line in a file.
FAILS=$(mktemp); trap 'rm -f "$FAILS"' EXIT
fail() { echo "FAIL  $*"; echo >>"$FAILS"; }
kc() { "$KUBECTL" --context "$CONTEXT" "$@"; }

kc get validatingadmissionpolicy mto-extension-vault-community-vco-scope >/dev/null \
  || { echo "error: the bootstrap chart's admission policies are not installed (make lab-bootstrap)" >&2; exit 1; }

AUTH='  authentication: { path: kubernetes, role: vco-admin, serviceAccount: { name: vco-admin } }'
V=redhatcop.redhat.io/v1alpha1

# check <admit|refuse> <description>; the CR is read from stdin.
check() {
  local want=$1 what=$2 out rc=0
  out=$(kc -n "$CONFIG_NS" apply --dry-run=server -f - 2>&1) || rc=$?
  if [ "$want" = admit ]; then
    if [ "$rc" = 0 ]; then echo "PASS  admit:  $what"; else fail "admit:  $what: $out"; fi
  else
    if [ "$rc" != 0 ] && grep -q 'ValidatingAdmissionPolicy' <<<"$out"; then
      echo "PASS  refuse: $what"
    else fail "refuse: $what: rc=$rc $out"; fi
  fi
}

policy() { # <name> <policy text>
  printf 'apiVersion: %s\nkind: Policy\nmetadata: { name: %s }\nspec:\n%s\n  name: %s\n  policy: |\n' "$V" "$1" "$AUTH" "$1"
  sed 's/^/    /' <<<"$2"
}
k8srole() { # <name> <path> <sa> <policies> <targetNamespaces block>
  printf 'apiVersion: %s\nkind: KubernetesAuthEngineRole\nmetadata: { name: %s }\nspec:\n%s\n  name: %s\n  path: %s\n  targetServiceAccounts: [%s]\n  policies: [%s]\n  targetNamespaces:\n%s\n' "$V" "$1" "$AUTH" "$1" "$2" "$3" "$4" "$5"
}
sel() { printf '    targetNamespaceSelector:\n      matchLabels: { kubernetes.io/metadata.name: %s, stakater.com/tenant: %s }' "$1" "$2"; }
ssorole() { # <name> <path> <groups or empty> [extra spec line]
  local claims=""
  [ -n "$3" ] && claims="  boundClaims: { groups: [$3] }"
  printf 'apiVersion: %s\nkind: JWTOIDCAuthEngineRole\nmetadata: { name: %s }\nspec:\n%s\n  name: %s\n  path: %s\n  roleType: oidc\n  userClaim: sub\n  tokenPolicies: [%s]\n  allowedRedirectURIs: ["http://localhost:8250/oidc/callback"]\n%s\n%s\n' \
    "$V" "$1" "$AUTH" "$1" "$2" "$1" "$claims" "${4:-}"
}
mount() { # <kind> <name> <path> <name-field> <type> [extra config]
  printf 'apiVersion: %s\nkind: %s\nmetadata: { name: %s }\nspec:\n%s\n  path: %s\n  name: %s\n  type: %s\n  config: { listingVisibility: hidden%s }\n' "$V" "$1" "$2" "$AUTH" "$3" "$4" "$5" "${6:-}"
}
k8sconfig() { # <path> <host> [extra spec line]
  printf 'apiVersion: %s\nkind: KubernetesAuthEngineConfig\nmetadata: { name: adm-x-kubernetes-config }\nspec:\n%s\n  path: %s\n  name: workloads\n  kubernetesHost: %s\n%s\n' "$V" "$AUTH" "$1" "$2" "${3:-}"
}

web='path "adm-a/kv/data/dev/adm-a-api/web/*"     { capabilities = ["create", "read", "update", "patch", "list"] }
path "adm-a/kv/metadata/dev/adm-a-api/web/*" { capabilities = ["read", "list"] }
path "adm-a/kv/data/dev/_shared/from-adm-a-api/*" { capabilities = ["read", "list"] }'

echo "== Policies"
policy kv.adm-a.adm-a-api.web "$web" | check admit "a workload policy in its tenant's scope"
policy kv.x.y.z 'path "*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }' | check refuse "path \"*\" with sudo (Q16)"
policy kv.adm-a.adm-a-api.web 'path "adm-a*" { capabilities = ["read"] }' | check refuse "a tenant segment not closed by /"
policy kv.adm-a.adm-a-api.web 'path "adm-b/kv/data/dev/adm-b-api/api/*" { capabilities = ["read"] }' | check refuse "another tenant's path"
policy kv.adm.adm-core.core 'path "adm-a/kv/data/dev/adm-a-api/web/*" { capabilities = ["read"] }' | check refuse "the prefix tenant adm on adm-a's path"
policy kv.adm-a.adm-a-api.web 'path "adm-a/kv/config" { capabilities = ["update"] }' | check refuse "the tenant mount's config"
policy kv.adm-a.adm-a-api.web 'path "adm-a/kv/data/dev/+/web/*" { capabilities = ["read"] }' | check refuse "a + wildcard"
policy kv.adm-a.adm-a-api.web '{"path": {"*": {"capabilities": ["read"]}}}' | check refuse "a JSON policy body"
policy kv.adm-a.adm-a-api.web 'path "adm-a/kv/data/dev/adm-a-api/web/*" {
  capabilities = ["read"]
}' | check refuse "a stanza over several lines"
policy kv.adm-a.adm-a-api.web 'path "adm-a/kv/data/dev/adm-a-api/web/*" { capabilities = ["read", "sudo"] }' | check refuse "sudo on its own path"
policy vco-admin2 'path "adm-a/kv/data/dev/x/*" { capabilities = ["read"] }' | check refuse "a name outside the families"
policy kv.kubernetes.ns.sa 'path "kubernetes/kv/data/dev/ns/sa/*" { capabilities = ["read"] }' | check refuse "a policy for a reserved tenant name"
policy share.adm-a.adm-a-api.web.out.adm-b 'path "shared/kv/data/dev/from-adm-a/to-adm-b/*" { capabilities = ["create", "read", "update", "list"] }' | check admit "an export policy"
policy share.adm-a.adm-a-api.web.out.adm-b 'path "shared/kv/data/dev/from-adm-b/to-adm-a/*" { capabilities = ["create", "read", "update", "list"] }' | check refuse "an export policy writing the peer's direction"
policy share.adm-b.adm-b-api.api.in.adm-a 'path "shared/kv/data/dev/from-adm-a/to-adm-b/*" { capabilities = ["read", "list"] }' | check admit "an import policy"
policy share.adm-b.adm-b-api.api.in.adm-a 'path "shared/kv/data/dev/from-adm-a/to-adm-b/*" { capabilities = ["read", "create"] }' | check refuse "an import policy that writes"
policy sso.adm-a.editor 'path "adm-a/kv/metadata" { capabilities = ["list"] }
path "adm-a/kv/data/dev/*" { capabilities = ["create", "read", "update", "patch", "list"] }' | check admit "an SSO role's policy"

echo "== Workload roles"
k8srole kv.adm-a.adm-a-api.web adm-a/kubernetes/workloads web kv.adm-a.adm-a-api.web "$(sel adm-a-api adm-a)" | check admit "a workload role"
k8srole kv.adm-a.adm-a-api.web adm-a/kubernetes/workloads web kv.adm-b.adm-b-api.api "$(sel adm-a-api adm-a)" | check refuse "a role bound to another tenant's policy"
k8srole kv.adm-a.adm-a-api.web adm-a/kubernetes/workloads web kv.adm-a.adm-a-api.web '    targetNamespaces: [adm-a-api]' | check refuse "a namespace bound by name only"
k8srole kv.adm-a.adm-a-api.web adm-a/kubernetes/workloads web kv.adm-a.adm-a-api.web "$(sel adm-a-api adm-b)" | check refuse "a namespace bound with another tenant's label"
k8srole kv.adm-a.adm-a-api.web adm-b/kubernetes/workloads web kv.adm-a.adm-a-api.web "$(sel adm-a-api adm-a)" | check refuse "a role on another tenant's mount"
k8srole kv.adm-a.adm-a-api.web kubernetes web kv.adm-a.adm-a-api.web "$(sel adm-a-api adm-a)" | check refuse "a role on VCO's own login mount"
k8srole kv.adm-a.adm-a-api.web adm-a/kubernetes/workloads jobs kv.adm-a.adm-a-api.web "$(sel adm-a-api adm-a)" | check refuse "a role for another ServiceAccount"
k8srole share.adm-b.adm-b-api.api.in.adm-a adm-b/kubernetes/workloads api share.adm-b.adm-b-api.api.in.adm-a "$(sel adm-b-api adm-b)" | check admit "a share role on its tenant's own mount"
k8srole share.adm-b.adm-b-api.api.in.adm-a shared/kubernetes/workloads api share.adm-b.adm-b-api.api.in.adm-a "$(sel adm-b-api adm-b)" | check refuse "a share role on a shared auth mount (ADR-0007)"

echo "== SSO roles"
ssorole sso.adm-a.editor adm-a/oidc/sso adm-a-editors | check admit "an SSO role for its tenant's group"
ssorole sso.adm-a.editor adm-a/oidc/sso adm-b-editors | check refuse "an SSO role for another tenant's group"
ssorole sso.adm-a.editor adm-a/oidc/sso adm-a-admins | check refuse "an SSO role for another role's group"
ssorole sso.adm-a.editor adm-a/oidc/sso adm-a-editors '  boundClaimsType: glob' | check refuse "an SSO role with glob claims"
ssorole sso.adm-a.editor adm-a/oidc/sso "" | check refuse "an SSO role with no bound claims (a fallback)"
ssorole sso.adm-a.fallback adm-a/oidc/sso adm-a-fallbacks | check refuse "an SSO role outside the install's roles"

echo "== Mounts and configs"
mount SecretEngineMount adm-c-kv adm-c kv kv | check admit "a tenant mount"
mount SecretEngineMount adm-c-kv adm-c kv kv ', auditNonHMACRequestKeys: [data]' | check refuse "a tenant mount that logs request data in clear"
mount SecretEngineMount adm-c-kv adm-c kv transit | check refuse "a transit engine in a tenant's kv place"
mount SecretEngineMount sys-kv sys kv kv | check refuse "a kv mount under a reserved name"
mount AuthEngineMount adm-c-kubernetes adm-c/kubernetes workloads kubernetes | check admit "a tenant's Kubernetes auth mount"
mount AuthEngineMount adm-c-kubernetes adm-c/kubernetes workloads userpass | check refuse "a userpass mount in its place"
mount AuthEngineMount shared-kubernetes shared/kubernetes workloads kubernetes | check refuse "a shared auth mount (ADR-0007)"
mount AuthEngineMount adm-c-oidc adm-c/oidc sso oidc | check admit "a tenant's OIDC auth mount"
k8sconfig adm-c/kubernetes https://kubernetes.default.svc:443 | check admit "a Kubernetes auth config for this cluster"
k8sconfig adm-c/kubernetes https://evil.example.com:6443 | check refuse "a config for another cluster's API"
k8sconfig adm-c/kubernetes https://kubernetes.default.svc:443 '  kubernetesCACert: "-----BEGIN CERTIFICATE-----another CA"' | check refuse "a config that trusts another CA"
if [ -n "$ISSUER" ]; then
  oidc() { printf 'apiVersion: %s\nkind: JWTOIDCAuthEngineConfig\nmetadata: { name: adm-c-oidc-config }\nspec:\n%s\n  path: adm-c/oidc/sso\n  OIDCDiscoveryURL: %s\n  OIDCClientID: vault\n' "$V" "$AUTH" "$1"; }
  oidc "$ISSUER" | check admit "an OIDC config at the install's issuer"
  oidc https://evil.example.com | check refuse "an OIDC config at another issuer"
fi

fails=$(wc -l <"$FAILS" | tr -d " ")
echo "== result: $fails failed"
[ "$fails" = 0 ]
