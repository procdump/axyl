#!/bin/bash -i

function startClientNodesByComputerIndex() {
    local computerIndex="$1"

    if [[ "$UPGRADE_ONLY" == "0" ]]; then
        _=$(executeOnNodeClient $computerIndex "sudo rm -rf /usr/src/rayls-network/genesis && sudo mkdir -p /usr/src/rayls-network/genesis && sudo chmod 777 /usr/src/rayls-network/genesis")

        _=$(copyOnNodeClient $computerIndex "$DIST_DIR/parameters.yaml" "/usr/src/rayls-network/genesis")
        _=$(copyOnNodeClient $computerIndex "$DIST_DIR/committee.yaml" "/usr/src/rayls-network/genesis")
        _=$(copyOnNodeClient $computerIndex "$DIST_DIR/genesis.yaml" "/usr/src/rayls-network/genesis")
    fi

    local computerId=$(getComputerId $computerIndex)
    local computerRpcPort=$(getComputerRpcPort $computerIndex)
    local computerMetricsPort=$(getComputerMetricsPort $computerIndex)
    local consensusIp=$(getComputerConsensusIp $computerIndex)
    if [[ "$USE_DOCKER_FOR_HOST_NODES" == "1" ]]; then
        consensusIp=$(calcConsensusIpByComputerIndex $computerIndex)
    fi

    local containerName="$DOCKER_TAG_RAYLS_NODE_CLIENT--$computerId"
    local isValidator=$(isValidatorByComputerId $computerId)
    local blsPassphrase="local"
    if [[ "$isValidator" == "1" ]]; then
        blsPassphrase=$(getValidatorBlsPassphraseByComputerId $computerId)
    fi

    _=$(executeOnNodeClientStopAndRemoveDocker $computerIndex "$containerName")

    local dataDirPath=$(getComputerDataDirPath $computerIndex)
    local dockerArgName="--name $containerName"
    local dockerArgUser="-u root"
    local dockerArgVolume="-v '$dataDirPath:/home/nonroot/data'"
    local dockerArgEnv="-e RL_BLS_PASSPHRASE='$blsPassphrase' -e RAYLS_NETWORK=${RAYLS_NETWORK:-testnet}"
    local dockerArgEntryPoint="--entrypoint /bin/bash"

    if [[ "$UPGRADE_ONLY" == "0" ]]; then
        _=$(executeOnNodeClient $computerIndex "sudo docker run -d $dockerArgName $dockerArgUser $dockerArgVolume $dockerArgEnv $dockerArgEntryPoint $DOCKER_TAG_RAYLS_NODE_CLIENT -c 'sleep infinity'")
        if [ "$?" != 0 ]; then
            exit 1
        fi

        _=$(executeOnNodeClient $computerIndex "sudo docker exec $containerName mkdir -p /home/nonroot/data/genesis")
        _=$(executeOnNodeClient $computerIndex "sudo docker exec $containerName sed -i 's/$consensusIp/0\.0\.0\.0/g' /home/nonroot/data/node-info.yaml")
        _=$(executeOnNodeClient $computerIndex "sudo docker cp /usr/src/rayls-network/genesis/parameters.yaml $containerName:/home/nonroot/data")
        _=$(executeOnNodeClient $computerIndex "sudo docker cp /usr/src/rayls-network/genesis/committee.yaml $containerName:/home/nonroot/data/genesis")
        _=$(executeOnNodeClient $computerIndex "sudo docker cp /usr/src/rayls-network/genesis/genesis.yaml $containerName:/home/nonroot/data/genesis")
        _=$(executeOnNodeClient $computerIndex "sudo docker exec $containerName chown -R nonroot:nonroot /home/nonroot/data")

        _=$(executeOnNodeClient $computerIndex "sudo rm -rf /usr/src/rayls-network/genesis")
    fi

    if [[ "$DO_NOT_USE_DEFAULT_DOCKER_NETWORK_IN_COMMITTEE" != "1" ]]; then
        if [[ "$USE_DOCKER_FOR_HOST_NODES" == "1" ]]; then
            local instanceRegion=$(getComputerConsensusRegion $computerIndex)

            local computersSize=$(getComputersSize)
            for i in $(seq 0 $(($computersSize-1)))
            do
                local targetRegion=$(getComputerConsensusRegion $i)
                local targetConsensusIp=$(calcConsensusIpByComputerIndex $i)
                if [[ "$instanceRegion" == "$targetRegion" ]]; then
                    local replacementConsensusIp="172.100.2.$i"
                    _=$(executeOnNodeClient $computerIndex "sudo docker exec $containerName sed -i 's/$targetConsensusIp/$replacementConsensusIp/g' /home/nonroot/data/genesis/committee.yaml")
                fi
            done
        fi
    fi

    if [[ "$UPGRADE_ONLY" == "0" ]]; then
        _=$(executeOnNodeClientStopAndRemoveDocker $computerIndex "$containerName")
    fi

    local dockerCmd="rayls node --datadir=/home/nonroot/data --log.stdout.format log-fmt -vvv --full --storage.v2 --txpool.pending-max-count 50000 --txpool.pending-max-size 62144000 --txpool.basefee-max-count 50000 --txpool.basefee-max-size 1048556000 --txpool.queued-max-count 50000 --txpool.queued-max-size 1048556000 --txpool.max-pending-txns 50000 --txpool.max-new-txns 50000 --txpool.minimal-protocol-fee 0 --txpool.max-tx-input-bytes 999999999999 --txpool.max-account-slots 50000 --gpo.default-suggested-fee 0 --http --http.api all --http.addr 0.0.0.0 --ws --ws.api all --ws.addr 0.0.0.0 --metrics 0.0.0.0:9100 --reth-metrics 0.0.0.0:9200"
    if [[ "$isValidator" == "0" ]]; then
        dockerCmd="$dockerCmd --observer"
    fi

    local dockerArgRestart="--restart unless-stopped"
    local dockerArgNetwork=""
    local dockerArgPort=""
    if [[ "$USE_DOCKER_FOR_HOST_NODES" == "1" ]]; then
        local dockerArgRegionNetworks=("--network=name=$DOCKER_RAYLS_STACK_NETWORK-internal,ip=172.100.2.$computerIndex")
        local regionsSize=$(getRegionsSize)
        for i in $(seq 0 $(($regionsSize-1)))
        do
            local regionName=$(getRegionName $i)
            local regionNetworkNumber=$(getRegionNetworkNumber $i)
            local networkName="$DOCKER_RAYLS_STACK_NETWORK-$regionName"
            dockerArgRegionNetworks+=("--network=name=$networkName,ip=172.$regionNetworkNumber.2.$computerIndex")
        done
        dockerArgNetwork="${dockerArgRegionNetworks[@]} --cap-add=NET_ADMIN"

        dockerArgPort="-p $computerRpcPort:8545"
        # if computerMetricsPort is set add it as well
        if [[ "$computerMetricsPort" != "" ]]; then
            dockerArgPort="$dockerArgPort -p $computerMetricsPort:9100"
        fi
    else
        dockerArgNetwork="--network host"
    fi

    _=$(executeOnNodeClient $computerIndex "sudo docker run -d $dockerArgName $dockerArgRestart $dockerArgNetwork $dockerArgPort $dockerArgVolume $dockerArgEnv $DOCKER_TAG_RAYLS_NODE_CLIENT $dockerCmd")
    if [ "$?" != 0 ]; then
        exit 2
    fi
}

function startClientNodes() {
    echo -ne "Starting nodes...";

    local computersSize=$(getComputersSize)
    local pids=()
    for i in $(seq 0 $(($computersSize-1)))
    do
        startClientNodesByComputerIndex "$i" &
        pids+=($!)
    done

    for i in "${!pids[@]}"; do
        local pid="${pids[$i]}"
        wait "$pid" &> /dev/null
        local exitCode="$?"

        if [[ "$exitCode" != 0 ]]; then
            if [[ "$exitCode" == 1 ]]; then
                echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} Unable to start client for genesis on computer[$i]";
                exit 1;
            elif [[ "$exitCode" == 2 ]]; then
                echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} Unable to start client on computer[$i]";
                exit 1;
            else
                echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} Unable to start a computer[$i]";
                exit 1;
            fi
        fi
    done

    if [[ "$UPGRADE_ONLY" == "0" ]]; then
        rm -rf "$DIST_DIR/committee.yaml"
        rm -rf "$DIST_DIR/genesis.yaml"
        rm -rf "$DIST_DIR/parameters.yaml"
    fi

    echo -e "${STYLE_GREEN}OK${STYLE_DEFAULT}";
}
