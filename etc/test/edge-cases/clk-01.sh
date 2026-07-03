#!/bin/bash
set -u

directory=$(dirname "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(cd "$directory" && pwd)
envPath="$SCRIPT_DIR/clk.env"
if [[ ! -e "$envPath" ]]; then
    echo "Error: ./clk.env file not found at $envPath"
    exit 1
fi
. "$envPath"
utilsPath="$SCRIPT_DIR/utils.sh"
if [[ ! -e "$utilsPath" ]]; then
    echo "Error: ./utils.sh file not found at $utilsPath"
    exit 1
fi
. "$utilsPath"

sshTarget() {
    local remoteCommand=$1

    sshpass -p "$SSH_PASS" ssh "${sshOptions[@]}" "$SSH_USER@$targetHost" "$remoteCommand"
}

setTargetManualClock() {
    echo "Disabling automatic clock sync on TARGET ($targetHost)..."
    sshTarget "sudo timedatectl set-ntp false"

    [[ "$USE_POSITIVE_CLOCK_SHIFT" == "1" ]] && op="+" || op="-"
    echo "Modifying TARGET clock by $op$clockSkewSeconds second(s)..."
    sshTarget "current_epoch=\$(date +%s) && sudo date -s @\$((current_epoch $op $clockSkewSeconds))"

    remoteClockSkewApplied=1
}

restoreTargetAutoClock() {
    echo "Restoring automatic clock sync on TARGET ($targetHost)..."
    sshTarget "sudo timedatectl set-ntp true"
    remoteClockSkewApplied=0
}

cleanupClockSkew() {
    if [[ "$remoteClockSkewApplied" -eq 1 ]]; then
        echo "Cleanup: restoring automatic clock sync on TARGET..."
        sshTarget "sudo timedatectl set-ntp true" >/dev/null 2>&1 || true
    fi
}

trap cleanupClockSkew EXIT

SSH_KEY_PATH=${SSH_KEY_PATH:-}
SSH_PASS=${SSH_PASS:-}
SSH_USER=${SSH_USER:-}

remoteClockSkewApplied=0
clockSkewSeconds=$((30 * 60))
skewedNodeIndex=3
postSkewStabilizationSeconds=20
postRestoreStabilizationSeconds=20
sshOptions=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o PreferredAuthentications=publickey,password,keyboard-interactive
    -i "$SSH_KEY_PATH"
)

if [[ -z "$SSH_KEY_PATH" || -z "$SSH_PASS" || -z "$SSH_USER" ]]; then
    echo "ERROR: SSH_KEY_PATH, SSH_PASS and SSH_USER must all be provided."
    exit 1
fi

if [[ ! -f "$SSH_KEY_PATH" ]]; then
    echo "ERROR: SSH key not found at $SSH_KEY_PATH"
    exit 1
fi

if [[ "$NODE_RPCS_LEN" -ne 4 ]]; then
    echo "ERROR: CLK-01 expects exactly 4 RPC URLs. Current NODE_RPCS_LEN=$NODE_RPCS_LEN"
    exit 1
fi

if [[ "$skewedNodeIndex" -ge "$NODE_RPCS_LEN" ]]; then
    echo "ERROR: skewedNodeIndex=$skewedNodeIndex is out of bounds for NODE_RPCS_LEN=$NODE_RPCS_LEN"
    exit 1
fi

targetHost=$(printf '%s' "${NODE_RPCS[3]}" | sed -E 's#^[a-zA-Z]+://([^/:]+).*$#\1#')
if [[ -z "$targetHost" || "$targetHost" == "${NODE_RPCS[3]}" ]]; then
    echo "ERROR: Failed to derive TARGET host from NODE_RPCS[3]=${NODE_RPCS[3]}"
    exit 1
fi

sshTarget "sudo -n date" &> /dev/null
if [[ "$?" != "0" ]]; then
    echo "ERROR: does not have sudo access without password"
    exit 1
fi;

sshTarget "sudo -n timedatectl" &> /dev/null
if [[ "$?" != "0" ]]; then
    echo "ERROR: does not have sudo access without password"
    exit 1
fi;

echo "Querying Node 1 for latest block number..."
blockNumber=$(getBlockNumber "${NODE_RPCS[0]}")
if [[ -z "$blockNumber" || "$blockNumber" == "null" ]]; then
    echo "ERROR: Could not retrieve a valid block height from ${NODE_RPCS[0]}"
    exit 1
fi
echo "Latest block height (hex): $blockNumber"

ensureAllNodesSynchronizedAtHeight "$blockNumber"

preSkewHeight=$(getBlockNumber "${NODE_RPCS[0]}")
if [[ -z "$preSkewHeight" || "$preSkewHeight" == "null" ]]; then
    echo "ERROR: Could not retrieve a valid pre-skew block height from ${NODE_RPCS[0]}"
    exit 1
fi

echo "Checking SSH connectivity to TARGET ($targetHost)..."
sshTarget "echo connected >/dev/null"

echo "------------------------------------------------"
echo "Applying clock skew on TARGET only."
echo "Clock skew amount: +$clockSkewSeconds seconds (+30 minutes)."
echo "Skewed node RPC: ${NODE_RPCS[$skewedNodeIndex]}"
echo "------------------------------------------------"

setTargetManualClock

echo "Sleeping $postSkewStabilizationSeconds second(s) to observe the skewed network..."
sleep "$postSkewStabilizationSeconds"

postSkewHeight=$(getBlockNumber "${NODE_RPCS[0]}")
if [[ -z "$postSkewHeight" || "$postSkewHeight" == "null" ]]; then
    echo "ERROR: Could not retrieve a valid post-skew block height from ${NODE_RPCS[0]}"
    exit 1
fi

echo "Height before skew: $preSkewHeight"
echo "Height after skew:  $postSkewHeight"

if [[ "$postSkewHeight" -le "$preSkewHeight" ]]; then
    echo "ERROR: Network is not producing blocks after applying the clock skew"
    exit 1
fi

ensureAllNodesSynchronizedAtHeight "$postSkewHeight"

echo "------------------------------------------------"
echo "Success: Network remained synchronized while TARGET was 30 minutes ahead."
echo "------------------------------------------------"

restoreTargetAutoClock

echo "Sleeping $postRestoreStabilizationSeconds second(s) after re-enabling automatic clock sync..."
sleep "$postRestoreStabilizationSeconds"

postRestoreHeight=$(getBlockNumber "${NODE_RPCS[0]}")
if [[ -z "$postRestoreHeight" || "$postRestoreHeight" == "null" ]]; then
    echo "ERROR: Could not retrieve a valid post-restore block height from ${NODE_RPCS[0]}"
    exit 1
fi

echo "Height after restore: $postRestoreHeight"

if [[ "$postRestoreHeight" -le "$postSkewHeight" ]]; then
    echo "ERROR: Network is not producing blocks after restoring automatic clock sync"
    exit 1
fi

waitForNodeToReachHeight "$skewedNodeIndex" "$postSkewHeight"
ensureAllNodesSynchronizedAtHeight "$postRestoreHeight"

echo "------------------------------------------------"
echo "Success: TARGET returned to automatic clock sync and the network stayed synchronized."
echo "------------------------------------------------"
