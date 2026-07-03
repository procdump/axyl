#!/bin/bash -i

function makeGenesis() {
    if [[ "$UPGRADE_ONLY" == "1" ]]; then
        exit 0
    fi

    echo -ne "Making genesis...";

    local firstValidatorId=$(getValidatorComputerIdByIndex "0")
    local firstValidatorIndex=$(getComputerIndexById $firstValidatorId)

    local containerName="$DOCKER_TAG_RAYLS_NODE_CLIENT--$firstValidatorId"

    _=$(executeOnNodeClientStopAndRemoveDocker $firstValidatorIndex "$containerName")

    _=$(executeOnNodeClient $firstValidatorIndex "sudo rm -rf /usr/src/rayls-network/genesis && sudo mkdir -p /usr/src/rayls-network/genesis && sudo chmod 777 /usr/src/rayls-network/genesis")

    local dockerArgName="--name $containerName"
    local dockerArgUser="-u root"
    local dockerArgEnv="-e RL_BLS_PASSPHRASE=local"
    local dockerArgEntryPoint="--entrypoint /bin/bash"
    _=$(executeOnNodeClient $firstValidatorIndex "sudo docker run -d $dockerArgName $dockerArgUser $dockerArgEnv $dockerArgEntryPoint $DOCKER_TAG_RAYLS_NODE_CLIENT -c 'sleep infinity'")
    if [ "$?" != 0 ]; then
        echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} Unable to start client on computer[$firstValidatorIndex]";
        exit 1
    fi

    _=$(executeOnNodeClient $firstValidatorIndex "sudo docker exec $containerName rm -rf /home/nonroot/data/genesis")
    _=$(executeOnNodeClient $firstValidatorIndex "sudo docker exec $containerName mkdir -p /home/nonroot/data/genesis/validators")
    _=$(executeOnNodeClient $firstValidatorIndex "sudo docker exec $containerName mkdir -p /home/nonroot/data/genesis/observers")

    local validatorsSize=$(getValidatorsSize)
    for j in $(seq 0 $(($validatorsSize-1)))
    do
        local validatorComputerId=$(getValidatorComputerIdByIndex $j)
        local computerIndex=$(getComputerIndexById $validatorComputerId)

        _=$(copyOnNodeClient $firstValidatorIndex "$DIST_DIR/validator-$computerIndex.yaml" "/usr/src/rayls-network/genesis")

        _=$(executeOnNodeClient $firstValidatorIndex "sudo docker cp /usr/src/rayls-network/genesis/validator-$computerIndex.yaml '$containerName:/home/nonroot/data/genesis/validators'")

        rm -rf "$DIST_DIR/validator-$computerIndex.yaml"
    done

    local observersSize=$(getObserversSize)
    if [[ "$observersSize" -gt 0 ]]; then
        for j in $(seq 0 $(($observersSize-1)))
        do
            local observerComputerId=$(getObserverComputerIdByIndex $j)
            local computerIndex=$(getComputerIndexById $observerComputerId)

            _=$(copyOnNodeClient $firstValidatorIndex "$DIST_DIR/observer-$computerIndex.yaml" "/usr/src/rayls-network/genesis")

            _=$(executeOnNodeClient $firstValidatorIndex "sudo docker cp /usr/src/rayls-network/genesis/observer-$computerIndex.yaml '$containerName:/home/nonroot/data/genesis/observers'")

            rm -rf "$DIST_DIR/observer-$computerIndex.yaml"
        done
    fi

    local chainId=$(getConfigChainId)
    local epochDurationInSecs=$(getConfigEpochDurationInSecs)
    local maxHeaderDelayMs=$(getConfigMaxHeaderDelayMs)
    local minHeaderDelayMs=$(getConfigMinHeaderDelayMs)
    local consensusRegistryOwner=$(getConfigConsensusRegistryOwner)
    local networkAdmin=$(getConfigNetworkAdmin)

    local genesisCmd="sudo docker exec $containerName /usr/local/bin/rayls genesis --datadir /home/nonroot/data/ --chain-id $chainId --epoch-duration-in-secs $epochDurationInSecs --max-header-delay-ms $maxHeaderDelayMs --min-header-delay-ms $minHeaderDelayMs --consensus-registry-owner $consensusRegistryOwner --network-admin $networkAdmin --fee-aggregator-admin $networkAdmin"

    local accountsPath="$SCRIPT_DIR/config/accounts.yaml"
    if [[ -f "$accountsPath" ]]; then
        _=$(copyOnNodeClient $firstValidatorIndex "$accountsPath" "/usr/src/rayls-network/genesis/accounts.yaml")
        _=$(executeOnNodeClient $firstValidatorIndex "sudo docker cp /usr/src/rayls-network/genesis/accounts.yaml '$containerName:/home/nonroot/data/genesis/accounts.yaml'")
        genesisCmd="$genesisCmd --accounts /home/nonroot/data/genesis/accounts.yaml"
    fi

    local rlsAccountsPath="$SCRIPT_DIR/config/rls-accounts.yaml"
    if [[ -f "$rlsAccountsPath" ]]; then
        _=$(copyOnNodeClient $firstValidatorIndex "$rlsAccountsPath" "/usr/src/rayls-network/genesis/rls-accounts.yaml")
        _=$(executeOnNodeClient $firstValidatorIndex "sudo docker cp /usr/src/rayls-network/genesis/rls-accounts.yaml '$containerName:/home/nonroot/data/genesis/rls-accounts.yaml'")
        genesisCmd="$genesisCmd --rls-accounts /home/nonroot/data/genesis/rls-accounts.yaml"
    fi

    local opResult
    opResult=$(executeOnNodeClient $firstValidatorIndex "$genesisCmd")
    if [ "$?" != 0 ]; then
        echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} Unable to generate genesis: $opResult";
        exit 1
    fi

    _=$(executeOnNodeClient $firstValidatorIndex "sudo docker cp $containerName:/home/nonroot/data/parameters.yaml /usr/src/rayls-network/genesis")
    _=$(executeOnNodeClient $firstValidatorIndex "sudo docker cp $containerName:/home/nonroot/data/genesis/committee.yaml /usr/src/rayls-network/genesis")
    _=$(executeOnNodeClient $firstValidatorIndex "sudo docker cp $containerName:/home/nonroot/data/genesis/genesis.yaml /usr/src/rayls-network/genesis")
    _=$(executeOnNodeClient $firstValidatorIndex "sudo chmod -R 777 /usr/src/rayls-network/genesis")

    _=$(executeOnNodeClientStopAndRemoveDocker $firstValidatorIndex "$containerName")

    _=$(copyFromNodeClient $firstValidatorIndex "/usr/src/rayls-network/genesis/parameters.yaml" "$DIST_DIR")
    _=$(copyFromNodeClient $firstValidatorIndex "/usr/src/rayls-network/genesis/committee.yaml" "$DIST_DIR")
    _=$(copyFromNodeClient $firstValidatorIndex "/usr/src/rayls-network/genesis/genesis.yaml" "$DIST_DIR")

    _=$(executeOnNodeClient $firstValidatorIndex "sudo rm -rf /usr/src/rayls-network/genesis")

    echo -e "${STYLE_GREEN}OK${STYLE_DEFAULT}";
}
