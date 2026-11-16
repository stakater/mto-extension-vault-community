#!/usr/bin/env bash
#
# C.0: the hand-run acceptance scenarios (AC-ISO-1, -2, -3, -5, -7, -9) and
# question 11, on the spike lab. Every check runs as the caller itself: a
# workload logs in with its own ServiceAccount token. A denial counts only as
# a 403, and each denial is paired with an allow on the same path.
#
# Needs: the lab context, fixture.yaml, platform.yaml and tenants.yaml applied,
# and one secret per app (the spike writes them as root before this runs).
# MOUNTS=per-tenant runs every check on the per-tenant auth mounts of
# question 17 (per-tenant.yaml applied); the default is the first run's one
# shared mount, K8S_MOUNT.
set -euo pipefail

CONTEXT=${CONTEXT:-kind-vault-ce-lab}
K8S_MOUNT=${K8S_MOUNT:-mto/workloads}
MOUNTS=${MOUNTS:-shared}
fails=0

mount_for() { # <role>: the auth mount the role lives on
  if [ "$MOUNTS" = per-tenant ]; then
    case $1 in share.*) echo shared/kubernetes/workloads ;; *) echo "$(cut -d. -f2 <<<"$1")/kubernetes/workloads" ;; esac
  else echo "$K8S_MOUNT"; fi
}

kc() { kubectl --context "$CONTEXT" "$@"; }
# vault CLI inside the Vault pod, with the token given as the first argument.
vt() { local t=$1; shift; kc -n vault exec -i vault-0 -- env VAULT_TOKEN="$t" VAULT_ADDR=http://127.0.0.1:8200 vault "$@"; }

login() { # <namespace> <serviceaccount> <role>
  local jwt
  jwt=$(kc -n "$1" create token "$2")
  vt "" write -field=token "auth/$(mount_for "$3")/login" role="$3" jwt="$jwt"
}

ok()   { echo "PASS  $*"; }
bad()  { echo "FAIL  $*"; fails=$((fails + 1)); }

# expect <allow|deny> <description> <token> <vault args...>
expect() {
  local want=$1 what=$2 tok=$3 out rc=0; shift 3
  out=$(vt "$tok" "$@" 2>&1) || rc=$?
  if [ "$want" = allow ]; then
    if [ "$rc" = 0 ]; then ok "$what"; else bad "$what: wanted allow, got: $(grep -m1 -E 'Code|\*' <<<"$out")"; fi
  else
    if grep -q 'Code: 403' <<<"$out"; then ok "$what (403)"; else bad "$what: wanted 403, rc=$rc: $(grep -m1 -E 'Code|\*' <<<"$out")"; fi
  fi
}

web=$(login team-a-api web kv.team-a.team-a-api.web)
jobs=$(login team-a-api jobs kv.team-a.team-a-api.jobs)
api=$(login team-b-api api kv.team-b.team-b-api.api)
core=$(login team-core core kv.team.team-core.core)

echo "== AC-ISO-1 an app can't read a sibling app"
expect allow "web reads its own secret"            "$web"  read team-a/kv/data/dev/team-a-api/web/postgres
expect deny  "jobs reads web's secret"             "$jobs" read team-a/kv/data/dev/team-a-api/web/postgres

echo "== AC-ISO-2 a tenant can't reach another tenant's mount"
expect allow "api reads its own secret"            "$api"  read team-b/kv/data/dev/team-b-api/api/postgres
expect deny  "web reads team-b's secret"           "$web"  read team-b/kv/data/dev/team-b-api/api/postgres
expect allow "api lists its own prefix"            "$api"  list team-b/kv/metadata/dev/team-b-api/api/
expect deny  "web lists team-b's prefix"           "$web"  list team-b/kv/metadata/dev/team-b-api/api/

echo "== AC-ISO-3 a prefix tenant can't reach its longer neighbour"
expect allow "core reads its own secret"           "$core" read team/kv/data/dev/team-core/core/postgres
expect deny  "core reads team-a's secret"          "$core" read team-a/kv/data/dev/team-a-api/web/postgres
expect deny  "core lists team-a's mount"           "$core" list team-a/kv/metadata/

echo "== AC-ISO-5 / question 11: another tenant's login role"
jwt_web=$(kc -n team-a-api create token web)
jwt_api=$(kc -n team-b-api create token api)
out=$(vt "" write "auth/$(mount_for kv.team-b.team-b-api.api)/login" role=kv.team-b.team-b-api.api jwt="$jwt_web" 2>&1) && bad "web logged in with team-b's role" \
  || { ok "web refused team-b's role"; echo "      observed: $(grep -m1 'Code' <<<"$out") $(grep -m1 '^\s*\*' <<<"$out")"; }
expect allow "api logs in with its own role"       "" write "auth/$(mount_for kv.team-b.team-b-api.api)/login" role=kv.team-b.team-b-api.api jwt="$jwt_api"

echo "== AC-ISO-9 no tier administers Vault (admin-tier token, no IdP in the spike)"
erin=$(vt root token create -field=token -policy=sso.team-a.admin -no-default-policy=false -ttl=10m)
expect allow "admin tier destroys a version in its tenant" "$erin" write team-a/kv/destroy/dev/team-a-api/web/postgres versions=99
expect deny  "admin tier writes sys/policy/x"      "$erin" policy write x - <<<'path "team-a/*" { capabilities = ["read"] }'
expect deny  "admin tier mounts sys/mounts/x"      "$erin" secrets enable -path=x kv
expect deny  "admin tier writes a workload role"   "$erin" write "auth/$(mount_for kv.team-a.x.x)/role/x" bound_service_account_names=x bound_service_account_namespaces=x

if [ "${SHARES:-1}" = 1 ]; then  # q15-shares.yaml applied
echo "== AC-SHR-3 a share reaches its peer only, in its direction"
share=shared/kv/data/dev
out=$(login team-a-api web share.team-a.team-a-api.web.out.team-b)
in=$(login team-b-api api share.team-b.team-b-api.api.in.team-a)
cout=$(login team-core core share.team.team-core.core.out.team-b)
expect allow "web writes its export to team-b"     "$out"  kv put -mount=shared/kv dev/from-team-a/to-team-b/token v=1
expect allow "api reads team-a's export"           "$in"   read  "$share/from-team-a/to-team-b/token"
expect deny  "api writes team-a's export"          "$in"   kv put -mount=shared/kv dev/from-team-a/to-team-b/token v=2
expect deny  "web's own token reads the export"    "$web"  read  "$share/from-team-a/to-team-b/token"
expect deny  "core's export reads from-team-a/"    "$cout" read  "$share/from-team-a/to-team-b/token"
expect deny  "core's export writes from-team-a/"   "$cout" kv put -mount=shared/kv dev/from-team-a/to-team-b/token v=3
expect allow "api lists the export folder"         "$in"   list  shared/kv/metadata/dev/from-team-a/to-team-b/
expect deny  "api lists every share"               "$in"   list  shared/kv/metadata/dev/
expect allow "web reads its own secret"            "$web"  read  team-a/kv/data/dev/team-a-api/web/postgres
expect deny  "web's export token reads web's secret" "$out" read team-a/kv/data/dev/team-a-api/web/postgres
jwt_web=$(kc -n team-a-api create token web)
expect deny  "web logs in with api's import role"  ""     write "auth/$(mount_for share.x)/login" role=share.team-b.team-b-api.api.in.team-a jwt="$jwt_web"
fi

echo "== result: $fails failed"
[ "$fails" = 0 ]
