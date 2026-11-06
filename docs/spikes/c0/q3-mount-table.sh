#!/usr/bin/env bash
#
# C.0 question 3: the mount table with hundreds of tenant mounts on integrated
# storage (Raft). The lab's Vault is in-memory dev mode, so this runs its own
# single-node Vault 2.1.1 container with Raft, initialised with one key share.
# The unseal key and root token stay in WORKDIR, never in the repo.
#
#   WORKDIR=<scratch dir> ./q3-mount-table.sh 500 1000 2000
#
# Each argument is a total mount count to reach; after each step the script
# prints the mount table's size from Vault's own telemetry, the time the step
# took, and the time a restart takes to unseal and serve a read.
set -euo pipefail

: "${WORKDIR:?WORKDIR must name a scratch directory for the unseal key}"
NAME=${NAME:-c0-vault-raft}
IMAGE=${IMAGE:-hashicorp/vault:2.1.1}
STEPS=("$@")
[ "${#STEPS[@]}" -gt 0 ] || STEPS=(500)

ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
dx() { docker exec -i -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN="$(cat "$WORKDIR/root-token" 2>/dev/null)" "$NAME" "$@"; }

if ! docker inspect "$NAME" >/dev/null 2>&1; then
  docker run -d --name "$NAME" --cap-add IPC_LOCK -e 'VAULT_LOCAL_CONFIG={
      "storage": {"raft": {"path": "/vault/file", "node_id": "n1"}},
      "listener": [{"tcp": {"address": "0.0.0.0:8200", "tls_disable": true}}],
      "api_addr": "http://127.0.0.1:8200", "cluster_addr": "http://127.0.0.1:8201",
      "disable_mlock": true,
      "telemetry": {"disable_hostname": true, "prometheus_retention_time": "1h"}}' \
    "$IMAGE" server >/dev/null
  sleep 3
  dx vault operator init -key-shares=1 -key-threshold=1 -format=json > "$WORKDIR/init.json"
  jq -r '.unseal_keys_b64[0]' "$WORKDIR/init.json" > "$WORKDIR/unseal-key"
  jq -r '.root_token' "$WORKDIR/init.json" > "$WORKDIR/root-token"
  rm "$WORKDIR/init.json"
fi
unseal() { dx vault operator unseal "$(cat "$WORKDIR/unseal-key")" >/dev/null; }
unseal
for i in $(seq 1 30); do dx vault status >/dev/null 2>&1 && break; sleep 1; done
dx vault version

metric() { # mount table gauges for the replicated logical table
  dx vault read -format=json sys/metrics | jq -r '
    .data.Gauges[] | select(.Name | test("core.mount_table")) |
    select(.Labels.type == "logical" and .Labels.local == "false") | "\(.Name)=\(.Value)"' | sort | tr '\n' ' '
}

have=$(dx vault secrets list -format=json | jq '[keys[] | select(test("^t[0-9]+/kv/$"))] | length')
for target in "${STEPS[@]}"; do
  start=$(date +%s)
  # BSD seq counts down when first > last, so a step already reached is skipped here.
  if [ "$target" -gt "$have" ]; then
    seq $((have + 1)) "$target" | awk '{ printf "vault secrets enable -path=t%05d/kv -version=2 -listing-visibility=hidden kv >/dev/null || echo fail t%05d\n", $1, $1 }' \
      | dx sh
  fi
  have=$target
  took=$(( $(date +%s) - start ))
  sleep 11  # the gauges are published per 10s interval
  echo "mounts=$have step_took=${took}s $(metric)"
  # One enable and one disable at this size: what each tenant create costs.
  s=$(ms); dx vault secrets enable -path=probe/kv kv >/dev/null; e=$(ms)
  dx vault secrets disable probe/kv >/dev/null
  echo "  one more enable at this size: $(( e - s ))ms"
  start=$(date +%s); docker restart "$NAME" >/dev/null; sleep 1
  for i in $(seq 1 30); do dx vault operator unseal "$(cat "$WORKDIR/unseal-key")" >/dev/null 2>&1 && break; sleep 1; done
  for i in $(seq 1 60); do dx vault read -format=json "t00001/kv/config" >/dev/null 2>&1 && break; sleep 1; done
  echo "  restart to first read: $(( $(date +%s) - start ))s"
done
dx sh -c 'du -sh /vault/file'
