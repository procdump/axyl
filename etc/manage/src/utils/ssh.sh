function executeOnNodeClient() {
    local computerIndex="$1"
    local cmd="$2"

    local consensusIp=$(getComputerConsensusIp $computerIndex)
    local sshIp=$(getComputerSshIp $computerIndex)
    local sshPort=$(getComputerSshPort $computerIndex)
    local sshUser=$(getComputerSshUser $computerIndex)
    local sshPass=()
    if [[ "$consensusIp" == "docker" ]]; then
        local computerIndex=$(getComputerId $computerIndex)
        sshIp="$DOCKER_TAG_RAYLS_NODE_HOST--$computerIndex"
        sshPort=22
        sshUser=rayls
        sshPass=(sshpass -p 'rayls')
    fi

    "${sshPass[@]}" ssh -q -o "StrictHostKeyChecking no" ${sshUser}@${sshIp} -p ${sshPort} "$cmd"
}

function executeOnNodeClientStopAndRemoveDocker() {
    local computerIndex="$1"
    local containerName="$2"

    executeOnNodeClient $computerIndex "sudo docker kill --signal=SIGKILL '$containerName' &> /dev/null; sudo docker rm '$containerName' &> /dev/null"
}

function copyOnNodeClient() {
    local computerIndex="$1"
    local src="$2"
    local target="$3"

    local consensusIp=$(getComputerConsensusIp $computerIndex)
    local sshIp=$(getComputerSshIp $computerIndex)
    local sshPort=$(getComputerSshPort $computerIndex)
    local sshUser=$(getComputerSshUser $computerIndex)
    local sshPass=()
    if [[ "$consensusIp" == "docker" ]]; then
        local computerId=$(getComputerId $computerIndex)
        sshIp="$DOCKER_TAG_RAYLS_NODE_HOST--$computerId"
        sshPort=22
        sshUser=rayls
        sshPass=(sshpass -p 'rayls')
    fi

    "${sshPass[@]}" scp -q -o "StrictHostKeyChecking no" -P ${sshPort} "$src" ${sshUser}@${sshIp}:"$target"
}

function copyFromNodeClient() {
    local computerIndex="$1"
    local src="$2"
    local target="$3"

    local consensusIp=$(getComputerConsensusIp $computerIndex)
    local sshIp=$(getComputerSshIp $computerIndex)
    local sshPort=$(getComputerSshPort $computerIndex)
    local sshUser=$(getComputerSshUser $computerIndex)
    local sshPass=()
    if [[ "$consensusIp" == "docker" ]]; then
        local computerId=$(getComputerId $computerIndex)
        sshIp="$DOCKER_TAG_RAYLS_NODE_HOST--$computerId"
        sshPort=22
        sshUser=rayls
        sshPass=(sshpass -p 'rayls')
    fi

    "${sshPass[@]}" scp -q -o "StrictHostKeyChecking no" -P ${sshPort} ${sshUser}@${sshIp}:"$src" "$target"
}

function initSsh() {
    if [ "$SSH_AGENT_PID" = "" ]; then
        eval $(ssh-agent -s) &> /dev/null
    fi

    if [ "$SSH_AGENT_PID" = "" ]; then
        echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} There was an error starting the SSH agent. Please start it manually $?: ${result}";
        exit 1;
    fi

    local computersSize=$(getComputersSize)
    local sshKeyPath=""
    local sshPass=""
    local opResult=""
    local exitCode=""

    for i in $(seq 0 $(($computersSize-1)))
    do
        sshKeyPath=$(getComputerSshKeyPath $i)
        if [[ "$sshKeyPath" == "" ]]; then
            continue;
        fi

        sshPass=$(getComputerSshPass $i)
        if [[ "$sshPass" == "" ]]; then
            opResult=$(ssh-add $sshKeyPath &> /dev/null)
            exitCode="$?"
        else
            echo "echo '$sshPass'" > /tmp/launcher-ask-pass.sh
            chmod +x /tmp/launcher-ask-pass.sh
            opResult=$(DISPLAY=:0 SSH_ASKPASS="/tmp/launcher-ask-pass.sh" ssh-add $sshKeyPath < /dev/null &> /dev/null)
            exitCode="$?"
        fi

        if [ "$exitCode" != 0 ]; then
            echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} There was an error adding SSH key $?: ${result}";
            exit $?;
        fi
    done

    rm -rf /tmp/launcher-ask-pass.sh
}
