#!/usr/bin/env bash
#
# The bootstrap chart's admission policies (templates/50-admission.yaml)
# against good and bad VCO CRs. Each refused case changes one field of an
# admitted one, and a refusal counts only when an admission policy gives it.
# Ported from C.0's docs/spikes/c0/q18-admission.sh, with the share roles on
# the tenant's own mount (ADR-0007).
#
# Two modes, one list of cases:
#   live     (CONTEXT set): each case is a server-side dry run in the config
#            namespace of a cluster where the chart is installed, so nothing
#            reaches VCO. Run by the e2e suite and `make admission-test`.
#   offline  (EMIT=<dir>): each case is written to <dir> for
#            hack/admission-eval, which runs the rendered policies through
#            k8s.io/apiserver's own admission plugin (`make admission-offline`,
#            part of `make verify`).
# An UPDATE case needs an old object. Live, check_update creates it for real
# (VCO reconciles it like any other), holds it in deletion with the finalizer
# $HOLD when the case is about a deletion, sends the update as a server-side
# dry run, and then removes it. An old object that admission refuses (a spec
# out of scope, or no spec) can't be created while admission is on:
# check_offline runs those cases offline only, and the live result says how
# many.
#
# ISSUER (the install's parent.sso.issuerUrl) and TOV_USER (Template
# Operator's username, system:serviceaccount:<ns>:<sa>) are required: without
# them the OIDC and origin cases could not run, and a skipped case must never
# read as a pass. Tenant names here are never created.
set -euo pipefail

EMIT=${EMIT:-}
KUBECTL=${KUBECTL:-kubectl}
CONFIG_NS=${CONFIG_NS:-vault-config}
: "${ISSUER:?ISSUER must be the install's parent.sso.issuerUrl: the OIDC cases need it}"
: "${TOV_USER:?TOV_USER must be Template Operator's username (system:serviceaccount:<ns>:<sa>): the origin cases need it}"
if [ -z "$EMIT" ]; then
  : "${CONTEXT:?CONTEXT must name the kube context (or set EMIT=<dir> to write the cases for the offline run)}"
fi
# check runs at the end of a pipeline, in a subshell (bash 3.2 has no
# lastpipe), so each failure, case and skip is a line in a file.
STATE=$(mktemp -d); trap 'rm -rf "$STATE"' EXIT
: >"$STATE/fails"; : >"$STATE/cases"; : >"$STATE/skips"
fail() { echo "FAIL  $*"; echo >>"$STATE/fails"; }
kc() { "$KUBECTL" --context "$CONTEXT" "$@"; }

if [ -n "$EMIT" ]; then
  mkdir -p "$EMIT"
else
  kc get validatingadmissionpolicy mto-extension-vault-community-vco-kinds >/dev/null \
    || { echo "error: the bootstrap chart's admission policies are not installed, or are older than C.17 (make lab-bootstrap)" >&2; exit 1; }
fi

AUTH='  authentication: { path: kubernetes, role: vco-admin, serviceAccount: { name: vco-admin } }'
V=redhatcop.redhat.io/v1alpha1

# A refusal names the policy that must give it: refuse:<kinds|origin|scope|
# cluster>. A denial from another policy, or one a policy gives because it
# failed to configure, compile or evaluate (failure policy Fail), must never
# read as the rule under test doing its work.
POLICY_PREFIX=mto-extension-vault-community-vco-
refused_by() { # refused_by <policy> <output>
  grep -q "ValidatingAdmissionPolicy '$POLICY_PREFIX$1' with binding '[^']*' denied request" <<<"$2" \
    && ! grep -qiE 'failed to configure|resulted in error|compil|evaluation|cost|budget' <<<"$2"
}
emit() { # emit <want> <description> <as-user> <old object file or empty>; the CR on stdin
  local n
  n=$(wc -l <"$STATE/cases" | tr -d ' ')
  { printf '# want: %s\n# what: %s\n' "${1%%:*}" "$2"
    case "$1" in refuse:*) printf '# policy: %s\n' "$POLICY_PREFIX${1#refuse:}" ;; esac
    if [ -n "$3" ]; then printf '# as: %s\n' "$3"; fi
    printf -- '---\n'; cat
    if [ -n "$4" ]; then printf -- '---\n'; cat "$4"; fi
  } >"$EMIT/$(printf '%03d' "$n").yaml"
}

# check <admit|refuse:<policy>> <description> [as-user]; the CR is read from
# stdin. As a person (the caller) unless a user is named.
check() {
  local want=$1 what=$2 as=${3:-} out rc=0
  case "$want" in admit|refuse:kinds|refuse:origin|refuse:scope|refuse:cluster) ;;
    *) echo "error: case '$what' wants '$want'" >&2; exit 2 ;; esac
  echo >>"$STATE/cases"
  if [ -n "$EMIT" ]; then emit "$want" "$what" "$as" ""; return; fi
  if [ -n "$as" ]; then
    out=$(kc -n "$CONFIG_NS" apply --dry-run=server --as="$as" -f - 2>&1) || rc=$?
  else
    out=$(kc -n "$CONFIG_NS" apply --dry-run=server -f - 2>&1) || rc=$?
  fi
  if [ "$want" = admit ]; then
    if [ "$rc" = 0 ]; then echo "PASS  admit:  $what"; else fail "admit:  $what: $out"; fi
  elif [ "$rc" != 0 ] && refused_by "${want#refuse:}" "$out"; then
    echo "PASS  refuse: $what"
  else
    fail "refuse: $what (by ${want#refuse:}): rc=$rc $out"
  fi
}

# The finalizer that holds a live old object in deletion. The case files say
# [x] and a deletionTimestamp; live, the old object is created with this
# finalizer and then deleted, and the API server keeps the deletionTimestamp
# on every update.
HOLD=admission-cases.stakater.com/hold
live() { # live <file>: the object as it can be written live
  sed -e 's/, deletionTimestamp: "[^"]*"//' -e "s#finalizers: \[x\]#finalizers: [$HOLD]#" "$1"
}
obj_kind() { sed -n 's/^kind: //p' "$1"; }
obj_name() { sed -n 's/^metadata: { name: \([^,} ]*\).*/\1/p' "$1"; }
resource() { # resource <kind>: its full resource name (Policy -> policies.redhatcop.redhat.io)
  local r
  r=$(tr '[:upper:]' '[:lower:]' <<<"$1")
  case "$r" in *y) r="${r%y}ies" ;; *) r="${r}s" ;; esac
  echo "$r.redhatcop.redhat.io"
}
gone() { # gone <resource> <name>
  [ -z "$(kc -n "$CONFIG_NS" get "$1" "$2" --ignore-not-found -o name 2>/dev/null)" ]
}
release() { # release <resource> <name>: delete the object, drop the hold finalizer, and wait
  local rest i
  gone "$1" "$2" && return
  kc -n "$CONFIG_NS" delete "$1" "$2" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  rest=$(kc -n "$CONFIG_NS" get "$1" "$2" --ignore-not-found \
    -o go-template='{{range .metadata.finalizers}}{{if ne . "'"$HOLD"'"}}"{{.}}",{{end}}{{end}}' 2>/dev/null || true)
  kc -n "$CONFIG_NS" patch "$1" "$2" --type=merge -p "{\"metadata\":{\"finalizers\":[${rest%,}]}}" >/dev/null 2>&1 || true
  # VCO removes its own finalizer once it has deleted the object in Vault.
  for i in $(seq 1 60); do gone "$1" "$2" && return; sleep 1; done
  echo "error: $1 $2 is still in $CONFIG_NS after 60s (is VCO running?): later cases would update it" >&2
  exit 1
}

# check_update <admit|refuse:<policy>> <description> <old object file>
# [as-user]; the new object is read from stdin. Live: the old object is
# created for real (as the user), deleted first when its file says so, and
# the new one is sent as a server-side dry run of a replace (an UPDATE).
check_update() {
  local want=$1 what=$2 old=$3 as=${4:-} kind name new out rc=0 try
  case "$want" in admit|refuse:kinds|refuse:origin|refuse:scope|refuse:cluster) ;;
    *) echo "error: case '$what' wants '$want'" >&2; exit 2 ;; esac
  echo >>"$STATE/cases"
  if [ -n "$EMIT" ]; then emit "$want" "$what" "$as" "$old"; return; fi
  new="$STATE/new.yaml"; cat >"$new"
  kind=$(resource "$(obj_kind "$old")"); name=$(obj_name "$old")
  release "$kind" "$name"
  if [ -n "$as" ]; then
    out=$(live "$old" | kc -n "$CONFIG_NS" create --as="$as" -f - 2>&1) || rc=$?
  else
    out=$(live "$old" | kc -n "$CONFIG_NS" create -f - 2>&1) || rc=$?
  fi
  if [ "$rc" != 0 ]; then
    fail "$want: $what: the old object was not created: $out"; release "$kind" "$name"; return
  fi
  if grep -q deletionTimestamp "$old"; then
    kc -n "$CONFIG_NS" delete "$kind" "$name" --wait=false >/dev/null 2>&1 \
      || { fail "$want: $what: the old object could not be deleted"; release "$kind" "$name"; return; }
    # Held by $HOLD: without it the case would update an object that is gone,
    # or one that is not being deleted, and prove nothing.
    if [ -z "$(kc -n "$CONFIG_NS" get "$kind" "$name" --ignore-not-found -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)" ]; then
      fail "$want: $what: the old object is not held in deletion"; release "$kind" "$name"; return
    fi
  fi
  # A replace reads the object's resourceVersion first; VCO may update the
  # object in between (its finalizer, its status), so a conflict is retried.
  for try in 1 2 3 4 5; do
    rc=0
    if [ -n "$as" ]; then
      out=$(live "$new" | kc -n "$CONFIG_NS" replace --dry-run=server --as="$as" -f - 2>&1) || rc=$?
    else
      out=$(live "$new" | kc -n "$CONFIG_NS" replace --dry-run=server -f - 2>&1) || rc=$?
    fi
    grep -q 'the object has been modified' <<<"$out" || break
  done
  release "$kind" "$name"
  if [ "$want" = admit ]; then
    if [ "$rc" = 0 ]; then echo "PASS  admit:  $what"; else fail "admit:  $what: $out"; fi
  elif [ "$rc" != 0 ] && refused_by "${want#refuse:}" "$out"; then
    echo "PASS  refuse: $what"
  else
    fail "refuse: $what (by ${want#refuse:}): rc=$rc $out"
  fi
}

# check_offline <admit|refuse:<policy>> <description> <old object file>
# <why>: an UPDATE case whose old object admission refuses, so it can't be
# made live; offline only.
check_offline() {
  echo >>"$STATE/cases"
  if [ -z "$EMIT" ]; then
    cat >/dev/null
    echo "SKIP  offline only ($4): $2"; echo >>"$STATE/skips"
    return
  fi
  emit "$1" "$2" "" "$3"
}

nospec() { # <name> [extra metadata]: a Policy with no spec at all
  printf 'apiVersion: %s\nkind: Policy\nmetadata: { name: %s%s }\n' "$V" "$1" "${2:-}"
}
policy() { # <name> <policy text> [extra metadata] [extra spec lines] [authentication]
  printf 'apiVersion: %s\nkind: Policy\nmetadata: { name: %s%s }\nspec:\n%s\n  name: %s\n%s  policy: |\n' \
    "$V" "$1" "${3:-}" "${5:-$AUTH}" "$1" "${4:+$4
}"
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
policy kv.x.y.z 'path "*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }' | check refuse:scope "path \"*\" with sudo (Q16)"
policy kv.adm-a.adm-a-api.web 'path "adm-a*" { capabilities = ["read"] }' | check refuse:scope "a tenant segment not closed by /"
policy kv.adm-a.adm-a-api.web 'path "adm-b/kv/data/dev/adm-b-api/api/*" { capabilities = ["read"] }' | check refuse:scope "another tenant's path"
policy kv.adm.adm-core.core 'path "adm-a/kv/data/dev/adm-a-api/web/*" { capabilities = ["read"] }' | check refuse:scope "the prefix tenant adm on adm-a's path"
policy kv.adm-a.adm-a-api.web 'path "adm-a/kv/config" { capabilities = ["update"] }' | check refuse:scope "the tenant mount's config"
policy kv.adm-a.adm-a-api.web 'path "adm-a/kv/data/dev/+/web/*" { capabilities = ["read"] }' | check refuse:scope "a + wildcard"
policy kv.adm-a.adm-a-api.web '{"path": {"*": {"capabilities": ["read"]}}}' | check refuse:scope "a JSON policy body"
policy kv.adm-a.adm-a-api.web 'path "adm-a/kv/data/dev/adm-a-api/web/*" {
  capabilities = ["read"]
}' | check refuse:scope "a stanza over several lines"
policy kv.adm-a.adm-a-api.web 'path "adm-a/kv/data/dev/adm-a-api/web/*" { capabilities = ["read", "sudo"] }' | check refuse:scope "sudo on its own path"
policy vco-admin2 'path "adm-a/kv/data/dev/x/*" { capabilities = ["read"] }' | check refuse:scope "a name outside the families"
policy kv.kubernetes.ns.sa 'path "kubernetes/kv/data/dev/ns/sa/*" { capabilities = ["read"] }' | check refuse:scope "a policy for a reserved tenant name"
policy share.adm-a.adm-a-api.web.out.adm-b 'path "shared/kv/data/dev/from-adm-a/to-adm-b/*" { capabilities = ["create", "read", "update", "list"] }' | check admit "an export policy"
policy share.adm-a.adm-a-api.web.out.adm-b 'path "shared/kv/data/dev/from-adm-b/to-adm-a/*" { capabilities = ["create", "read", "update", "list"] }' | check refuse:scope "an export policy writing the peer's direction"
policy share.adm-b.adm-b-api.api.in.adm-a 'path "shared/kv/data/dev/from-adm-a/to-adm-b/*" { capabilities = ["read", "list"] }' | check admit "an import policy"
policy share.adm-b.adm-b-api.api.in.adm-a 'path "shared/kv/data/dev/from-adm-a/to-adm-b/*" { capabilities = ["read", "create"] }' | check refuse:scope "an import policy that writes"
policy sso.adm-a.editor 'path "adm-a/kv/metadata" { capabilities = ["list"] }
path "adm-a/kv/data/dev/*" { capabilities = ["create", "read", "update", "patch", "list"] }' | check admit "an SSO role's policy"
policy kv.adm-a.adm-a-api.web "$web" '' '  type: acl' | check refuse:scope "a policy with a type (VCO would write sys/policies/acl/)"

echo "== Every kind, connection and login"
policy kv.adm-a.adm-a-api.web "$web" '' '  connection: { address: "https://vault.evil.example.com:8200" }' | check refuse:kinds "a policy in scope that sends VCO's login to another Vault"
policy kv.adm-a.adm-a-api.web "$web" '' '' '  authentication: { path: kubernetes, role: other-role, serviceAccount: { name: vco-admin } }' | check refuse:kinds "a policy that logs in with another role"
policy kv.adm-a.adm-a-api.web "$web" '' '' '  authentication: { path: kubernetes, role: vco-admin, serviceAccount: { name: default } }' | check refuse:kinds "a policy that logs in as another ServiceAccount"
policy kv.adm-a.adm-a-api.web "$web" '' '' '  authentication: { path: other-login, role: vco-admin, serviceAccount: { name: vco-admin } }' | check refuse:kinds "a policy that logs in at another auth mount"
policy kv.adm-a.adm-a-api.web "$web" '' '' '  authentication: { path: kubernetes, role: vco-admin, namespace: org, serviceAccount: { name: vco-admin } }' | check refuse:kinds "a policy that logs in to a Vault namespace"
policy kv.adm-a.adm-a-api.web "$web" '' '' '  authentication: { path: kubernetes, role: vco-admin, targetNamespace: org, serviceAccount: { name: vco-admin } }' | check refuse:kinds "a policy that writes into a Vault namespace"
nospec kv.adm-a.adm-a-api.web | check refuse:kinds "a VCO CR without a spec"
printf 'apiVersion: %s\nkind: AppRoleAuthEngineRole\nmetadata: { name: kv.adm-a.adm-a-api.web }\nspec:\n%s\n  path: adm-a/kubernetes/workloads\n  name: kv.adm-a.adm-a-api.web\n  tokenPolicies: [kv.adm-a.adm-a-api.web]\n' "$V" "$AUTH" \
  | check refuse:kinds "a kind the extension does not render (an AppRole role on a tenant's mount)"
printf 'apiVersion: %s\nkind: RandomSecret\nmetadata: { name: adm-a-x }\nspec:\n%s\n  path: adm-a/kv/data/dev/x\n  secretKey: password\n  secretFormat: { passwordPolicyName: simple }\n' "$V" "$AUTH" \
  | check refuse:kinds "a RandomSecret writing into a tenant's mount"

echo "== Origin"
policy kv.adm-a.adm-a-api.web "$web" ', labels: { templates.v2.stakater.com/instance-namespace: '"$CONFIG_NS"' }' | check admit "Template Operator's object from a TemplateInstance in the config namespace" "$TOV_USER"
policy kv.adm-a.adm-a-api.web "$web" ', labels: { templates.v2.stakater.com/instance-namespace: adm-a-api }' | check refuse:origin "Template Operator's object from a TemplateInstance in a tenant namespace" "$TOV_USER"
policy kv.adm-a.adm-a-api.web "$web" | check refuse:origin "Template Operator's object without its source label" "$TOV_USER"
policy kv.adm-a.adm-a-api.web "$web" ', labels: { templates.v2.stakater.com/instance-namespace: adm-a-api }' | check refuse:origin "a tenant TemplateInstance's object written by another identity (templateOperator.* wrong)"

echo "== Updates"
policy kv.adm-a.adm-a-api.web "$web" >"$STATE/old-web.yaml"
policy kv.adm-a.adm-a-api.web "$web" ', annotations: { note: x }' \
  | check_update admit "an update that stays in scope" "$STATE/old-web.yaml"
policy kv.adm-a.adm-a-api.web "$web" '' '  connection: { address: "https://vault.evil.example.com:8200" }' \
  | check_update refuse:kinds "an update that adds a connection" "$STATE/old-web.yaml"
policy kv.adm-a.adm-a-api.web "$web" ', labels: { templates.v2.stakater.com/instance-namespace: '"$CONFIG_NS"' }' >"$STATE/old-tov.yaml"
policy kv.adm-a.adm-a-api.web "$web" ', labels: { templates.v2.stakater.com/instance-namespace: adm-a-api }' \
  | check_update refuse:origin "Template Operator moves an object to a tenant's TemplateInstance" "$STATE/old-tov.yaml" "$TOV_USER"

echo "== Deletion"
deleting=', deletionTimestamp: "2026-11-04T00:00:00Z", finalizers: [x]'
policy kv.adm-a.adm-a-api.web "$web" "$deleting" >"$STATE/old-web-del.yaml"
policy kv.adm-a.adm-a-api.web "$web" ', deletionTimestamp: "2026-11-04T00:00:00Z"' \
  | check_update admit "a finalizer removed during a deletion of an object in scope" "$STATE/old-web-del.yaml"
policy kv.adm-a.adm-a-api.web 'path "*" { capabilities = ["read"] }' "$deleting" \
  | check_update refuse:scope "a spec widened during a deletion" "$STATE/old-web-del.yaml"
policy kv.adm-a.adm-a-api.web "$web" "$deleting" '  connection: { address: "https://vault.evil.example.com:8200" }' \
  | check_update refuse:kinds "a connection added during a deletion" "$STATE/old-web-del.yaml"
# The two steps of one attack: the spec removed, then put back with a
# connection. Each step is refused on its own. The second step's old object
# (a CR without a spec) can't exist while admission is on: offline only.
nospec kv.adm-a.adm-a-api.web "$deleting" \
  | check_update refuse:kinds "a spec removed during a deletion" "$STATE/old-web-del.yaml"
nospec kv.adm-a.adm-a-api.web "$deleting" >"$STATE/old-nospec.yaml"
policy kv.adm-a.adm-a-api.web "$web" "$deleting" '  connection: { address: "https://vault.evil.example.com:8200" }' \
  | check_offline refuse:kinds "a spec with a connection put back during a deletion" "$STATE/old-nospec.yaml" "no spec"
# A deletion is never blocked: an object written before the policies (or
# with them off) loses its finalizers, whatever its spec, or without one.
policy kv.adm-a.adm-a-api.web 'path "*" { capabilities = ["read"] }' "$deleting" >"$STATE/old-wide.yaml"
policy kv.adm-a.adm-a-api.web 'path "*" { capabilities = ["read"] }' ', deletionTimestamp: "2026-11-04T00:00:00Z"' \
  | check_offline admit "a finalizer removed during a deletion, the spec unchanged" "$STATE/old-wide.yaml" "a spec out of scope"
nospec kv.adm-a.adm-a-api.web ', deletionTimestamp: "2026-11-04T00:00:00Z"' \
  | check_offline admit "a finalizer removed during a deletion of a CR without a spec" "$STATE/old-nospec.yaml" "no spec"

echo "== Workload roles"
k8srole kv.adm-a.adm-a-api.web adm-a/kubernetes/workloads web kv.adm-a.adm-a-api.web "$(sel adm-a-api adm-a)" | check admit "a workload role"
k8srole kv.adm-a.adm-a-api.web adm-a/kubernetes/workloads web kv.adm-b.adm-b-api.api "$(sel adm-a-api adm-a)" | check refuse:scope "a role bound to another tenant's policy"
k8srole kv.adm-a.adm-a-api.web adm-a/kubernetes/workloads web kv.adm-a.adm-a-api.web '    targetNamespaces: [adm-a-api]' | check refuse:scope "a namespace bound by name only"
k8srole kv.adm-a.adm-a-api.web adm-a/kubernetes/workloads web kv.adm-a.adm-a-api.web "$(sel adm-a-api adm-b)" | check refuse:scope "a namespace bound with another tenant's label"
k8srole kv.adm-a.adm-a-api.web adm-b/kubernetes/workloads web kv.adm-a.adm-a-api.web "$(sel adm-a-api adm-a)" | check refuse:scope "a role on another tenant's mount"
k8srole kv.adm-a.adm-a-api.web kubernetes web kv.adm-a.adm-a-api.web "$(sel adm-a-api adm-a)" | check refuse:scope "a role on VCO's own login mount"
k8srole kv.adm-a.adm-a-api.web adm-a/kubernetes/workloads jobs kv.adm-a.adm-a-api.web "$(sel adm-a-api adm-a)" | check refuse:scope "a role for another ServiceAccount"
k8srole share.adm-b.adm-b-api.api.in.adm-a adm-b/kubernetes/workloads api share.adm-b.adm-b-api.api.in.adm-a "$(sel adm-b-api adm-b)" | check admit "a share role on its tenant's own mount"
k8srole share.adm-b.adm-b-api.api.in.adm-a shared/kubernetes/workloads api share.adm-b.adm-b-api.api.in.adm-a "$(sel adm-b-api adm-b)" | check refuse:scope "a share role on a shared auth mount (ADR-0007)"

echo "== SSO roles"
ssorole sso.adm-a.editor adm-a/oidc/sso adm-a-editors | check admit "an SSO role for its tenant's group"
ssorole sso.adm-a.editor adm-a/oidc/sso adm-b-editors | check refuse:scope "an SSO role for another tenant's group"
ssorole sso.adm-a.editor adm-a/oidc/sso adm-a-admins | check refuse:scope "an SSO role for another role's group"
ssorole sso.adm-a.editor adm-a/oidc/sso adm-a-editors '  boundClaimsType: glob' | check refuse:scope "an SSO role with glob claims"
ssorole sso.adm-a.editor adm-a/oidc/sso "" | check refuse:scope "an SSO role with no bound claims (a fallback)"
ssorole sso.adm-a.fallback adm-a/oidc/sso adm-a-fallbacks | check refuse:scope "an SSO role outside the install's roles"

echo "== Mounts and configs"
mount SecretEngineMount adm-c-kv adm-c kv kv | check admit "a tenant mount"
mount SecretEngineMount adm-c-kv adm-c kv kv ', auditNonHMACRequestKeys: [data]' | check refuse:scope "a tenant mount that logs request data in clear"
mount SecretEngineMount adm-c-kv adm-c kv transit | check refuse:scope "a transit engine in a tenant's kv place"
mount SecretEngineMount sys-kv sys kv kv | check refuse:scope "a kv mount under a reserved name"
mount AuthEngineMount adm-c-kubernetes adm-c/kubernetes workloads kubernetes | check admit "a tenant's Kubernetes auth mount"
mount AuthEngineMount adm-c-kubernetes adm-c/kubernetes workloads userpass | check refuse:scope "a userpass mount in its place"
mount AuthEngineMount shared-kubernetes shared/kubernetes workloads kubernetes | check refuse:scope "a shared auth mount (ADR-0007)"
mount AuthEngineMount adm-c-oidc adm-c/oidc sso oidc | check admit "a tenant's OIDC auth mount"
mount AuthEngineMount adm-c-kubernetes adm-c/kubernetes workloads kubernetes ', passthroughRequestHeaders: [Authorization]' | check refuse:scope "an auth mount that passes request headers through"
mount SecretEngineMount adm-c-kv adm-c kv kv ', allowedResponseHeaders: [Set-Cookie]' | check refuse:scope "a tenant mount that returns response headers"
k8sconfig adm-c/kubernetes https://kubernetes.default.svc:443 | check admit "a Kubernetes auth config for this cluster"
k8sconfig adm-c/kubernetes https://evil.example.com:6443 | check refuse:cluster "a config for another cluster's API"
k8sconfig adm-c/kubernetes https://kubernetes.default.svc:443 '  kubernetesCACert: "-----BEGIN CERTIFICATE-----another CA"' | check refuse:cluster "a config that trusts another CA"
k8sconfig adm-c/kubernetes https://kubernetes.default.svc:443 '  PEMKeys: ["-----BEGIN PUBLIC KEY-----another issuer"]' | check refuse:cluster "a config that trusts another issuer's keys"
k8sconfig adm-c/kubernetes https://kubernetes.default.svc:443 '  issuer: https://evil.example.com' | check refuse:cluster "a config that names another issuer"
k8sconfig adm-c/kubernetes https://kubernetes.default.svc:443 '  tokenReviewerServiceAccount: { name: someone-else }' | check refuse:cluster "a config that reviews tokens as another ServiceAccount"
k8sconfig adm-c/kubernetes https://kubernetes.default.svc:443 '  disableLocalCAJWT: true' | check refuse:cluster "a config that drops the local CA and JWT"
oidc() { printf 'apiVersion: %s\nkind: JWTOIDCAuthEngineConfig\nmetadata: { name: adm-c-oidc-config }\nspec:\n%s\n  path: adm-c/oidc/sso\n  OIDCDiscoveryURL: %s\n  OIDCClientID: vault\n%s\n' "$V" "$AUTH" "$1" "${2:-}"; }
oidc "$ISSUER" | check admit "an OIDC config at the install's issuer"
oidc https://evil.example.com | check refuse:scope "an OIDC config at another issuer"
oidc "$ISSUER" '  JWKSURL: https://evil.example.com/keys' | check refuse:scope "an OIDC config that also trusts another key set"
oidc "$ISSUER" '  JWTValidationPubKeys: ["-----BEGIN PUBLIC KEY-----another key"]' | check refuse:scope "an OIDC config that also trusts another key"

cases=$(wc -l <"$STATE/cases" | tr -d " ")
if [ -n "$EMIT" ]; then
  echo "== wrote $cases cases to $EMIT"
  exit 0
fi
fails=$(wc -l <"$STATE/fails" | tr -d " ")
skips=$(wc -l <"$STATE/skips" | tr -d " ")
echo "== result: $cases cases, $fails failed, $skips offline only (make admission-offline runs them)"
[ "$fails" = 0 ]
