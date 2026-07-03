#!/usr/bin/env bash
# Chaos-loop: wait until validator-N is caught up, kill it, restart it, repeat.

SEQ="${1:-1}"                              # 0-based sequence (1 = validator-2)
RPC_PORT=$((8545 - SEQ))
VAL_NUM=$((SEQ + 1))
PIDFILE="./etc/test-network/local-validators/validator-${VAL_NUM}.pid"

# Reference validator to confirm sync against (any node we are not stopping). Override with $2.
if [[ "$SEQ" -eq 0 ]]; then DEFAULT_REF=1; else DEFAULT_REF=0; fi
REF_SEQ="${2:-$DEFAULT_REF}"
REF_PORT=$((8545 - REF_SEQ))
REF_NUM=$((REF_SEQ + 1))

if [[ "$REF_SEQ" -eq "$SEQ" ]]; then
  echo "Error: reference seq ($REF_SEQ) must differ from the target seq ($SEQ)" >&2
  exit 1
fi

# is_caught_up alone is unreliable: an ActiveCvv reports it on promotion, before its chain has
# converged. So also sample the EVM tip against a live reference validator across a window.
SYNC_SAMPLES="${SYNC_SAMPLES:-4}"
SYNC_INTERVAL="${SYNC_INTERVAL:-1}"
LAG_TOLERANCE="${LAG_TOLERANCE:-2}"        # blocks behind reference tolerated (absorbs read skew)
POLL_INTERVAL="${POLL_INTERVAL:-2}"

# Print the latest EVM block height for the node on $1, or fail if unreachable.
block_number() {
  local port="$1" resp hex
  resp=$(curl -sS --max-time 2 -X POST "http://localhost:${port}" \
    -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' 2>/dev/null) || return 1
  hex=$(printf '%s' "$resp" | grep -oE '"result":"0x[0-9a-fA-F]+"' | grep -oE '0x[0-9a-fA-F]+')
  [[ -n "$hex" ]] || return 1
  printf '%d\n' "$hex"
}

is_caught_up() {
  curl -sS --max-time 2 -X POST "http://localhost:${RPC_PORT}" \
    -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"rayls_nodeStatus","params":[]}' 2>/dev/null \
    | grep -q '"is_caught_up":true'
}

# Query the target before the reference so read skew leaves the reference marginally ahead
# (positive gap, absorbed by tolerance); a node still catching up shows a persistent gap.
is_synced_with_ref() {
  local i node ref gap
  for ((i = 0; i < SYNC_SAMPLES; i++)); do
    node=$(block_number "$RPC_PORT") || { echo "  validator-${VAL_NUM} RPC unreachable"; return 1; }
    ref=$(block_number "$REF_PORT")  || { echo "  reference validator-${REF_NUM} RPC unreachable"; return 1; }
    gap=$((ref - node))
    if (( gap > LAG_TOLERANCE )); then
      echo "  validator-${VAL_NUM} behind validator-${REF_NUM} by ${gap} blocks (${node} vs ${ref})"
      return 1
    fi
    (( i < SYNC_SAMPLES - 1 )) && sleep "$SYNC_INTERVAL"
  done
  echo "  validator-${VAL_NUM} in sync with validator-${REF_NUM} (tip ${node}, ref ${ref})"
  return 0
}

wait_until_caught_up() {
  local waited=0
  until is_caught_up && is_synced_with_ref; do
    sleep "$POLL_INTERVAL"; waited=$((waited + POLL_INTERVAL))
    (( waited % 30 == 0 )) && echo "  validator-${VAL_NUM} still catching up (${waited}s)..."
  done
  echo "validator-${VAL_NUM} caught up and in sync with validator-${REF_NUM} after ~${waited}s"
}

while true; do
  wait_until_caught_up
  sleep 30

  if [[ -f "$PIDFILE" ]] && PID=$(cat "$PIDFILE") && kill -0 "$PID" 2>/dev/null; then
    echo "Stopping validator-${VAL_NUM} (pid $PID) with SIGTERM..."
    kill -TERM "$PID"

    # Wait up to 60 seconds for graceful shutdown
    terminated=false
    for ((i = 1; i <= 60; i++)); do
      if ! kill -0 "$PID" 2>/dev/null; then
        terminated=true
        break
      fi
      sleep 1
    done

    # Fall back to SIGKILL if the process persists after the timeout
    if [[ "$terminated" = false ]]; then
      echo "validator-${VAL_NUM} did not exit within 60 seconds. Sending SIGKILL..."
      kill -KILL "$PID" 2>/dev/null

      for ((i = 1; i <= 10; i++)); do
        if ! kill -0 "$PID" 2>/dev/null; then
          break
        fi
        sleep 0.5
      done
    fi
    echo "validator-${VAL_NUM} (pid $PID) has terminated."
  else
    echo "validator-${VAL_NUM} not running, skipping kill"
  fi

  echo "restarting validator-${VAL_NUM}"
  bash -x ./etc/test-network/local-testnet.sh --start-validator "$SEQ"
done
