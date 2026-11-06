#!/usr/bin/env bash
#
# Prove that the Vault pod reaches Dex's issuer (make lab-dex, DX.3). Vault
# fetches the issuer's discovery document from inside its pod, so the probe
# runs there.
#
# lab-dex calls this right after it restarts Dex. A connection can then go to
# the old pod's address while kube-proxy still has it, and hang for the
# kernel's connect timeout (about 127 s). So each try has a short timeout
# (wget -T), and a failed try is tried again until DEX_WAIT runs out. A Dex
# that answers as another issuer fails at once: that is a wrong config, not a
# race, and a retry would only hide it.
set -euo pipefail

: "${CONTEXT:?CONTEXT must name the kube context}"
: "${DEX_ISSUER:?DEX_ISSUER must be Dex issuer URL}"
KUBECTL=${KUBECTL:-kubectl}
VAULT_NS=${VAULT_NS:-vault}
DEX_WAIT=${DEX_WAIT:-120}
DEX_RETRY_SLEEP=${DEX_RETRY_SLEEP:-3}

err=$(mktemp)
trap 'rm -f "$err"' EXIT

deadline=$((SECONDS + DEX_WAIT))
try=0
while :; do
  try=$((try + 1))
  if doc=$("$KUBECTL" --context "$CONTEXT" -n "$VAULT_NS" exec vault-0 -- \
      wget -T 5 -qO- "$DEX_ISSUER/.well-known/openid-configuration" 2>"$err"); then
    if jq -e --arg i "$DEX_ISSUER" '.issuer == $i' >/dev/null 2>&1 <<<"$doc"; then
      echo "Dex answers as $DEX_ISSUER inside the Vault pod"
      exit 0
    fi
    echo "error: Dex's issuer is not $DEX_ISSUER" >&2
    exit 1
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "error: the Vault pod cannot reach Dex at $DEX_ISSUER (tried for ${DEX_WAIT}s): $(tr '\n' ' ' <"$err")" >&2
    exit 1
  fi
  # Each retry is in the log, so a race that a retry hid is still visible.
  echo "Dex not reachable yet (try $try), trying again: $(tr '\n' ' ' <"$err")" >&2
  sleep "$DEX_RETRY_SLEEP"
done
