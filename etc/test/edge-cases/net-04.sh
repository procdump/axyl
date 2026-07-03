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

if [[ "$NODE_RPCS_LEN" -lt 4 ]]; then
    echo "ERROR: NET-04 requires at least 4 validators to model 25% churn safely. Current NODE_RPCS_LEN=$NODE_RPCS_LEN"
    exit 1
fi

churnPercent=25
churnCycles=5
disconnectDuration=2
reconnectStabilization=2

numOfNodesToChurn=$(( NODE_RPCS_LEN * churnPercent / 100 ))
if [[ "$numOfNodesToChurn" -lt 1 ]]; then
    numOfNodesToChurn=1
fi

# Keep the churn safely below the quorum-break threshold.
maxChurnWithoutQuorumBreak=$(( (NODE_RPCS_LEN - 1) / 3 ))
if [[ "$numOfNodesToChurn" -gt "$maxChurnWithoutQuorumBreak" ]]; then
    numOfNodesToChurn="$maxChurnWithoutQuorumBreak"
fi

if [[ "$numOfNodesToChurn" -lt 1 ]]; then
    echo "ERROR: Unable to choose a churn set that stays below the quorum-break threshold."
    exit 1
fi

startChurnIndex=$(( NODE_RPCS_LEN - numOfNodesToChurn ))
for (( i=startChurnIndex; i<NODE_RPCS_LEN; i++ )); do
    CHURNED_NODE_INDEXES+=("$i")
done

trap cleanup EXIT

echo "Querying Node 1 for latest block number..."
blockNumber=$(getBlockNumber "${NODE_RPCS[0]}")
if [[ -z "$blockNumber" || "$blockNumber" == "null" ]]; then
    echo "ERROR: Could not retrieve a valid block height from ${NODE_RPCS[0]}"
    exit 1
fi
echo "Latest block height (hex): $blockNumber"

ensureAllNodesSynchronizedAtHeight "$blockNumber"

echo "Selected $numOfNodesToChurn node(s) for churn: ${CHURNED_NODE_INDEXES[*]}"
echo "Running $churnCycles churn cycle(s) with ${churnPercent}% target connectivity loss."

initialStableHeight=$(getBlockNumber "${NODE_RPCS[0]}")
if [[ -z "$initialStableHeight" || "$initialStableHeight" == "null" ]]; then
    echo "ERROR: Could not retrieve a valid block height from ${NODE_RPCS[0]}"
    exit 1
fi

for (( cycle=1; cycle<=churnCycles; cycle++ )); do
    echo "------------------------------------------------"
    echo "Starting churn cycle $cycle/$churnCycles"
    echo "------------------------------------------------"

    blockNumberBeforeDisconnect=$(getBlockNumber "${NODE_RPCS[0]}")
    if [[ -z "$blockNumberBeforeDisconnect" || "$blockNumberBeforeDisconnect" == "null" ]]; then
        echo "ERROR: Could not retrieve a valid block height from ${NODE_RPCS[0]}"
        exit 1
    fi

    disconnectChurnedNodes

    echo "Sleeping $disconnectDuration second(s) during network churn"
    sleep "$disconnectDuration"

    blockNumberDuringDisconnect=$(getBlockNumber "${NODE_RPCS[0]}")
    if [[ -z "$blockNumberDuringDisconnect" || "$blockNumberDuringDisconnect" == "null" ]]; then
        echo "ERROR: Could not retrieve a valid block height from ${NODE_RPCS[0]}"
        exit 1
    fi

    echo "Height before disconnect: $blockNumberBeforeDisconnect"
    echo "Height during disconnect: $blockNumberDuringDisconnect"

    if [[ "$blockNumberDuringDisconnect" -le "$blockNumberBeforeDisconnect" ]]; then
        echo "ERROR: Network did not progress during churn cycle $cycle"
        exit 1
    fi

    reconnectChurnedNodes

    echo "Sleeping $reconnectStabilization second(s) after reconnect"
    sleep "$reconnectStabilization"

    for nodeIndex in "${CHURNED_NODE_INDEXES[@]}"; do
        waitForNodeToReachHeight "$nodeIndex" "$blockNumberDuringDisconnect"
    done

done

finalHeight=$(getBlockNumber "${NODE_RPCS[0]}")
if [[ -z "$finalHeight" || "$finalHeight" == "null" ]]; then
    echo "ERROR: Could not retrieve a valid block height from ${NODE_RPCS[0]}"
    exit 1
fi

echo "Initial stable height: $initialStableHeight"
echo "Final height after churn: $finalHeight"

if [[ "$finalHeight" -le "$initialStableHeight" ]]; then
    echo "ERROR: Network did not advance after churn test"
    exit 1
fi

for nodeIndex in "${CHURNED_NODE_INDEXES[@]}"; do
    waitForNodeToReachHeight "$nodeIndex" "$finalHeight"
done

ensureAllNodesSynchronizedAtHeight "$finalHeight"

echo "------------------------------------------------"
echo "Success: Flickering connectivity introduced latency, but the network continued producing blocks and converged after churn."
echo "------------------------------------------------"
