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

numOfNodesToStop=$(((NODE_RPCS_LEN + 1) / 3))
churnedNodeIndex=$((NODE_RPCS_LEN - numOfNodesToStop))
for (( i=churnedNodeIndex; i<NODE_RPCS_LEN; i++ )); do
    CHURNED_NODE_INDEXES+=("$i")
done
disconnectChurnedNodes

blockNumberBeforeSleep=$(getBlockNumber "${NODE_RPCS[0]}")
if [[ -z "$blockNumberBeforeSleep" || "$blockNumberBeforeSleep" == "null" ]]; then
    echo "ERROR: Could not retrieve a valid block height from ${NODE_RPCS[0]}"
    exit 1
fi

echo "Sleeping 5 seconds"
sleep 5;

echo "Querying Node 1 for latest block number..."
blockNumberAfterStop=$(getBlockNumber "${NODE_RPCS[0]}")
if [[ -z "$blockNumberAfterStop" || "$blockNumberAfterStop" == "null" ]]; then
    echo "ERROR: Could not retrieve a valid block height from ${NODE_RPCS[0]}"
    exit 1
fi
echo "Latest block height (hex): $blockNumberAfterStop"

if [[ "$blockNumberBeforeSleep" != "$blockNumberAfterStop" ]]; then
    echo "ERROR: Network is producing blocks";
    exit 1
fi

echo "------------------------------------------------"
echo "Success: Network is not producing blocks."
echo "------------------------------------------------"

reconnectChurnedNodes

echo "Sleeping 5 seconds"
sleep 5

blockNumber=$(getBlockNumber "${NODE_RPCS[0]}")
for nodeIndex in "${CHURNED_NODE_INDEXES[@]}"; do
    waitForNodeToReachHeight "$nodeIndex" "$blockNumber"
done
ensureAllNodesSynchronizedAtHeight "$blockNumber"
