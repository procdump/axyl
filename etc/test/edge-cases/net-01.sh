#!/bin/bash
set -u

directory=$(dirname "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(cd "$directory" && pwd)
envPath="$SCRIPT_DIR/net.env"
if [[ ! -e "$envPath" ]]; then
    echo "Error: ./net.env file not found at $envPath"
    exit 1
fi
. "$envPath"
utilsPath="$SCRIPT_DIR/utils.sh"
if [[ ! -e "$utilsPath" ]]; then
    echo "Error: ./utils.sh file not found at $utilsPath"
    exit 1
fi
. "$utilsPath"

trap cleanup EXIT

echo "Querying Node 1 for latest block number..."
blockNumber=$(getBlockNumber "${NODE_RPCS[0]}")
if [[ -z "$blockNumber" || "$blockNumber" == "null" ]]; then
    echo "ERROR: Could not retrieve a valid block height from ${NODE_RPCS[0]}"
    exit 1
fi
echo "Latest block height (hex): $blockNumber"

ensureAllNodesSynchronizedAtHeight "$blockNumber"

churnedNodeIndex=$((NODE_RPCS_LEN - 1))
CHURNED_NODE_INDEXES+=("$churnedNodeIndex")
disconnectChurnedNodes

blockNumberBeforeSleep=$(getBlockNumber "${NODE_RPCS[0]}")
if [[ -z "$blockNumberBeforeSleep" || "$blockNumberBeforeSleep" == "null" ]]; then
    echo "ERROR: Could not retrieve a valid block height from ${NODE_RPCS[0]}"
    exit 1
fi

echo "Sleeping 10 seconds to ensure that the rest of the nodes are working"
sleep 10;

echo "Querying Node 1 for latest block number..."
blockNumberAfterStop=$(getBlockNumber "${NODE_RPCS[0]}")
if [[ -z "$blockNumberAfterStop" || "$blockNumberAfterStop" == "null" ]]; then
    echo "ERROR: Could not retrieve a valid block height from ${NODE_RPCS[0]}"
    exit 1
fi
echo "Latest block height (hex): $blockNumberAfterStop"

if [[ "$blockNumberBeforeSleep" == "$blockNumberAfterStop" ]]; then
    echo "ERROR: Network is not producing blocks";
    exit 1
fi

refHashAfterStop=$(getBlockHash "${NODE_RPCS[0]}" "$blockNumberAfterStop")
if [[ -z "$refHashAfterStop" || "$refHashAfterStop" == "null" ]]; then
    echo "ERROR: Failed to get hash for height $blockNumberAfterStop from Node 1."
    exit 1
fi
echo "Reference hash (Node 1): $refHashAfterStop"

for i in "${!NODE_RPCS[@]}"; do
    NODE_URL=${NODE_RPCS[$i]}
    hash=$(getBlockHash "$NODE_URL" "$blockNumberAfterStop")

    if [[ "$i" -lt "$((NODE_RPCS_LEN - 1))" ]]; then
        if [[ -z "$hash" || "$hash" == "null" ]]; then
            echo "ERROR: Node $((i+1)) ($NODE_URL) returned an invalid response."
            exit 1
        fi

        if [[ "$hash" != "$refHashAfterStop" ]]; then
            echo "CRITICAL: Hash mismatch at Node $((i+1))!"
            echo "Reference: $refHashAfterStop"
            echo "Node Result: $hash"
            exit 1
        fi
    else 
        if ! [[ -z "$hash" || "$hash" == "null" ]]; then
            echo "CRITICAL: Hash is not empty at Node $((i+1))!"
            echo "Reference: $refHashAfterStop"
            echo "Node Result: $hash"
            exit 1
        fi
    fi
done

echo "------------------------------------------------"
echo "Success: Last node got disconnected while the rest of the network is producing blocks."
echo "------------------------------------------------"

reconnectChurnedNodes

blockNumber=$(getBlockNumber "${NODE_RPCS[0]}")
waitForNodeToReachHeight "$churnedNodeIndex" "$blockNumberAfterStop"
ensureAllNodesSynchronizedAtHeight "$blockNumber"
