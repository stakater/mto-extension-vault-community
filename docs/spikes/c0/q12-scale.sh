#!/usr/bin/env bash
#
# C.0 question 12: identity entities and tokens per tenant at scale. Makes N
# ServiceAccounts in one tenant namespace, one role each on the shared
# workload mount (written as root: the question is Vault's identity store,
# not VCO), logs each in twice, and counts entities, aliases and tokens.
set -euo pipefail

CONTEXT=${CONTEXT:-kind-vault-ce-lab}
N=${N:-100}
NS=${NS:-team-a-scale}
MOUNT=${MOUNT:-mto/workloads}

kc() { kubectl --context "$CONTEXT" "$@"; }
v() { kc -n vault exec -i vault-0 -- env VAULT_TOKEN=root VAULT_ADDR=http://127.0.0.1:8200 vault "$@"; }

count() {
  local e a t
  e=$(v list -format=json identity/entity/id 2>/dev/null | jq length || echo 0)
  a=$(v list -format=json identity/entity-alias/id 2>/dev/null | jq length || echo 0)
  t=$(v list -format=json auth/token/accessors | jq length)
  echo "$1: entities=$e aliases=$a tokens=$t"
}

kc create namespace "$NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc label namespace "$NS" stakater.com/tenant=team-a --overwrite >/dev/null
count "before"

# One stdin stream into one exec: N role writes in the pod, not N execs.
for i in $(seq -w 1 "$N"); do
  kc -n "$NS" create serviceaccount "app$i" --dry-run=client -o yaml
  echo "---"
done | kc apply -f - >/dev/null
for i in $(seq -w 1 "$N"); do
  echo "vault write auth/$MOUNT/role/kv.team-a.$NS.app$i bound_service_account_names=app$i bound_service_account_namespaces=$NS token_policies=default token_ttl=3600 >/dev/null 2>&1"
done | kc -n vault exec -i vault-0 -- env VAULT_TOKEN=root VAULT_ADDR=http://127.0.0.1:8200 sh

login_all() {
  for i in $(seq -w 1 "$N"); do
    echo "vault write auth/$MOUNT/login role=kv.team-a.$NS.app$i jwt=$(kc -n "$NS" create token "app$i") >/dev/null"
  done | kc -n vault exec -i vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 sh
}

start=$(date +%s); login_all; echo "first $N logins took $(( $(date +%s) - start ))s"
count "after one login each"
login_all
count "after two logins each"
