#!/bin/bash

NODE_RPCS_LEN=${#NODE_RPCS[@]}
CHURNED_NODE_INDEXES=()

connectedState=1
syncTimeout=300

getBlockHash() {
    local url=$1
    local blockHex=$2
    
    # Capture the result and use jq's // empty to handle missing fields
    local result=$(curl -s -X POST -H "Content-Type: application/json" \
         --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["'$blockHex'", false],"id":1}' \
         "$url" | jq -r '.result.hash // empty')
    
    echo "$result"
}

getBlockNumber() {
    local url=$1

    local blockNumber=$(curl -s -X POST -H "Content-Type: application/json" \
     --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
     "$url" | jq -r '.result // empty')

     echo "$blockNumber";
}

nodeContainerName() {
    local nodeIndex=$1
    printf "%s%03d" "$CONTAINER_PREFIX" "$((nodeIndex + 1))"
}

disconnectChurnedNodes() {
    for nodeIndex in "${CHURNED_NODE_INDEXES[@]}"; do
        containerName=$(nodeContainerName "$nodeIndex")
        echo "Disconnecting ${containerName}" from "$NETWORK_NAME"
        docker network disconnect "$NETWORK_NAME" "$containerName"
    done
    connectedState=0
}

reconnectChurnedNodes() {
    for nodeIndex in "${CHURNED_NODE_INDEXES[@]}"; do
        containerName=$(nodeContainerName "$nodeIndex")
        echo "Connecting ${containerName}" to "$NETWORK_NAME"
        docker network connect "$NETWORK_NAME" "$containerName"
    done
    connectedState=1
}

cleanup() {
    if [[ "$connectedState" -eq 0 ]]; then
        echo "Cleanup: reconnecting nodes (if stopped)..."
        for nodeIndex in "${CHURNED_NODE_INDEXES[@]}"; do
            containerName=$(nodeContainerName "$nodeIndex")
            docker network connect "$NETWORK_NAME" "$containerName" >/dev/null 2>&1 || true
        done
    fi
}

ensureAllNodesSynchronizedAtHeight() {
    local targetHeight=$1
    local referenceHash

    referenceHash=$(getBlockHash "${NODE_RPCS[0]}" "$targetHeight")
    if [[ -z "$referenceHash" || "$referenceHash" == "null" ]]; then
        echo "ERROR: Failed to get hash for height $targetHeight from Node 1."
        exit 1
    fi
    echo "Reference hash (Node 1 @ $targetHeight): $referenceHash"

    for i in "${!NODE_RPCS[@]}"; do
        local nodeUrl=${NODE_RPCS[$i]}
        local hash
        hash=$(getBlockHash "$nodeUrl" "$targetHeight")

        if [[ -z "$hash" || "$hash" == "null" ]]; then
            echo "ERROR: Node $((i+1)) ($nodeUrl) returned an invalid response for height $targetHeight."
            exit 1
        fi

        if [[ "$hash" != "$referenceHash" ]]; then
            echo "CRITICAL: Hash mismatch at Node $((i+1)) for height $targetHeight!"
            echo "Reference: $referenceHash"
            echo "Node Result: $hash"
            exit 1
        fi
    done

    echo "------------------------------------------------"
    echo "Success: All NODE_RPCS are synchronized."
    echo "------------------------------------------------"
}

waitForNodeToReachHeight() {
    local nodeIndex=$1
    local targetHeight=$2
    local startTs
    startTs=$(date +%s)

    while true; do
        local currentHeight
        currentHeight=$(getBlockNumber "${NODE_RPCS[$nodeIndex]}")
        if [[ -n "$currentHeight" && "$currentHeight" != "null" && "$currentHeight" -gt "$targetHeight" ]]; then
            echo "Node $((nodeIndex+1)) reached target height $currentHeight"
            return 0
        fi

        local nowTs
        nowTs=$(date +%s)
        if (( nowTs - startTs >= syncTimeout )); then
            echo "ERROR: Timed out waiting for Node $((nodeIndex+1)) to reach height $targetHeight"
            exit 1
        fi

        echo "Waiting for Node $((nodeIndex+1)) to sync. Target height: $targetHeight, current: ${currentHeight:-null}"
        sleep 1
    done
}
