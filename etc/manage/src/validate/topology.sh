#!/bin/bash -i

function validateTopology() {
    echo -ne "Validating topology...";

    local useDocker="0"
    local useIp="0"

    local computersSize=$(getComputersSize)
    for i in $(seq 0 $(($computersSize-1)))
    do
        id=$(getComputerId $i)
        if [[ "$id" == "" ]]; then
            echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} Computer[$i] does not have an id";
            exit 1;
        fi

        dataDirPath=$(getComputerDataDirPath $i)
        if [[ "$dataDirPath" == "" ]]; then
            echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} Computer[$i] does not have an dataDirPath";
            exit 1;
        fi

        consensusIp=$(getComputerConsensusIp $i)
        if [[ "$consensusIp" == "" ]]; then
            echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} Computer[$i] does not have an consensusIp";
            exit 1;
        fi
        if [[ "$consensusIp" == "docker" ]]; then 
            useDocker="1"
        elif [[ ! "$consensusIp" =~ (^([0-9]{1,3}\.){3}[0-9]{1,3}$) ]]; then
            echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} Computer[$i]'s ip address is not valid";
            exit 1;
        else
            useIp="1"
        fi

        consensusPort=$(getComputerConsensusPort $i)
        if [[ "$consensusIp" != "docker" && "$consensusPort" == "" ]]; then
            echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} Computer[$i] does not have an consensusPort";
            exit 1;
        fi

        rpcPort=$(getComputerRpcPort $i)
        if [[ "$rpcPort" == "" ]]; then
            echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} Computer[$i] does not have an rpcPort";
            exit 1;
        fi

        sshIp=$(getComputerSshIp $i)
        if [[ "$consensusIp" != "docker" && "$sshIp" == "" ]]; then
            echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} Computer[$i] does not have an sshIp";
            exit 1;
        fi

        sshPort=$(getComputerSshPort $i)
        if [[ "$consensusIp" != "docker" && "$sshPort" == "" ]]; then
            echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} Computer[$i] does not have an sshPort";
            exit 1;
        fi

        sshUser=$(getComputerSshUser $i)
        if [[ "$consensusIp" != "docker" && "$sshUser" == "" ]]; then
            echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} Computer[$i] does not have an sshUser";
            exit 1;
        fi

        sshKeyPath=$(getComputerSshKeyPath $i)
        if [[ "$consensusIp" != "docker" && "$sshKeyPath" == "" ]]; then
            echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} Computer[$i] does not have an sshKeyPath";
            exit 1;
        fi
        if [[ "$consensusIp" != "docker" && ! -f "$sshKeyPath" ]]; then
            echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} Cannot find \"$sshKeyPath\" (Computer[$i]'s ssh key)";
            exit 1;
        fi

        sshPass=$(getComputerSshPass $i)
        if [[ "$sshPass" =~ (.*"'".*) ]]; then
            echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} The password must not contain '";
            exit 1;
        fi

    done

    local validatorsSize=$(getValidatorsSize)
    for i in $(seq 0 $(($validatorsSize-1)))
    do
        validatorComputerId=$(getValidatorComputerIdByIndex $i)
        if [[ "$validatorComputerId" == "" ]]; then
            echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} The validator($i) does not have computerId";
            exit 1;
        fi

        validatorComputerIndex=$(getComputerIndexById "$validatorComputerId")
        if [[ "$validatorComputerIndex" == "-1" ]]; then
            echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} The validator($i)'s computer, with id \"$validatorComputerId\", does not exists in computers array.";
            exit 1;
        fi
    done

    local observersSize=$(getObserversSize)
    if [[ "$observersSize" -gt 0 ]]; then
        for i in $(seq 0 $(($observersSize-1)))
        do
            observerComputerId=$(getObserverComputerIdByIndex $i)
            if [[ "$observerComputerId" == "" ]]; then
                echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} The observer($i) does not have computerId";
                exit 1;
            fi

            observerComputerIndex=$(getComputerIndexById "$observerComputerId")
            if [[ "$observerComputerIndex" == "-1" ]]; then
                echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} The observer($i)'s computer, with id \"$observerComputerId\", does not exists in computers array.";
                exit 1;
            fi
        done
    fi

    if [[ "$useDocker" == "1" && "$useIp" == "1" ]]; then
        echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} You must use either fully docker based or fully ip based configuration";
        exit 1;
    fi

    if [[ "$useDocker" == "1" ]]; then
        USE_DOCKER_FOR_HOST_NODES="1"
        if [[ ! -x "$(command -v docker)" ]]; then
            echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} The host does not have docker installed";
            exit 1;
        fi
        if [[ ! -x "$(command -v sshpass)" ]]; then
            echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} The host does not have sshpass installed";
            exit 1;
        fi
    fi

    echo -e "${STYLE_GREEN}OK${STYLE_DEFAULT}";
}
