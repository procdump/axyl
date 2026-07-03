#!/bin/bash -i

topology=$(cat $SCRIPT_DIR/config/topology.json)

# computers
function getComputersSize {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(len(obj['computers']))"
}

function getComputerId {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(obj['computers'][$1]['id'])"
}

function getComputerDataDirPath {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(obj['computers'][$1]['dataDirPath'])"
}

function getComputerConsensusIp {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(obj['computers'][$1]['consensusIp'])"
}

function getComputerConsensusPort {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(obj['computers'][$1]['consensusPort'])"
}

function getComputerConsensusRegion {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(obj['computers'][$1]['consensusRegion'])"
}

function getComputerRpcPort {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(obj['computers'][$1]['rpcPort'])"
}

function getComputerMetricsPort {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(obj['computers'][$1]['metricsPort'])"
}

function getComputerSshIp {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(obj['computers'][$1]['sshIp'])"
}

function getComputerSshPort {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(obj['computers'][$1]['sshPort'])"
}

function getComputerSshUser {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(obj['computers'][$1]['sshUser'])"
}

function getComputerSshKeyPath {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(obj['computers'][$1]['sshKeyPath'])"
}

function getComputerSshPass {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(obj['computers'][$1]['sshPass'])"
}

# validators
function getValidatorsSize {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(len(obj['validators']))"
}

function getValidatorComputerIdByIndex {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(obj['validators'][$1]['computerId'])"
}

function getValidatorWalletAddressIdByIndex {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(obj['validators'][$1]['walletAddress'])"
}

function getValidatorBlsPassphraseByIndex {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(obj['validators'][$1].get('blsPassphrase', 'local'))"
}

function getValidatorBlsPassphraseByComputerId {
    local targetComputerId="$1"
    local result="local"
    local validatorsSize=$(getValidatorsSize)
    for j in $(seq 0 $(($validatorsSize-1)))
    do
        local validatorComputerId=$(getValidatorComputerIdByIndex $j)
        if [[ "$validatorComputerId" == "$targetComputerId" ]]; then
            result=$(getValidatorBlsPassphraseByIndex $j)
            break
        fi
    done
    echo "$result"
}

function isValidatorByComputerId {
    local targetValidatorComputerId="$1"
    local isValidator="0"
    local validatorsSize=$(getValidatorsSize)
    for j in $(seq 0 $(($validatorsSize-1)))
    do
        local validatorComputerId=$(getValidatorComputerIdByIndex $j)
        if [[ "$validatorComputerId" == "$targetValidatorComputerId" ]]; then
            isValidator="1"
            break
        fi
    done
    echo $isValidator
}

# observers
function getObserversSize {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(len(obj['observers']))"
}

function getObserverComputerIdByIndex {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(obj['observers'][$1])"
}

# regions
function getRegionsSize {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(len(obj['regions']))"
}

function getRegionName {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(obj['regions'][$1])"
}

function getRegionNetworkNumber {
    echo $(( 100 + $1 + 1 ))
}

# topology utils
function getComputerIndexById {
    local result="-1"
    local computersSize=$(getComputersSize)
    for i in $(seq 0 $(($computersSize-1)))
    do
        local computerId=$(getComputerId $i)
        if [[ "$computerId" == "$1" ]]; then
            result="$i"
            break
        fi
    done
    echo "$result"
}

function getRegionIndexByName {
    local result="-1"
    local regionsSize=$(getRegionsSize)
    for i in $(seq 0 $(($regionsSize-1)))
    do
        local regionName=$(getRegionName $i)
        if [[ "$regionName" == "$1" ]]; then
            result="$i"
            break
        fi
    done
    echo "$result"
}

function calcConsensusIpByComputerIndex {
    local computerIndex=$1
    local regionName=$(getComputerConsensusRegion $computerIndex)
    local regionIndex=$(getRegionIndexByName "$regionName")
    local regionNetworkNumber=$(getRegionNetworkNumber $regionIndex)
    echo "172.$regionNetworkNumber.2.$computerIndex"
}

# config utils
function getConfigChainId() {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(obj['config']['chainId'])"
}

function getConfigEpochDurationInSecs() {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(obj['config']['epochDurationInSecs'])"
}

function getConfigDevFundedAccount() {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(obj['config']['devFundedWalletAddress'])"
}

function getConfigMaxHeaderDelayMs() {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(obj['config']['maxHeaderDelayMs'])"
}

function getConfigMinHeaderDelayMs() {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(obj['config']['minHeaderDelayMs'])"
}

function getConfigConsensusRegistryOwner() {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(obj['config']['consensusRegistryOwner'])"
}

function getConfigNetworkAdmin() {
    echo $topology | python3 -c "import json, sys; obj = json.load(sys.stdin); print(obj['config']['networkAdmin'])"
}