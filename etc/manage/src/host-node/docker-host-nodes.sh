#!/bin/bash -i
function setupHostEnvironments() {
    echo -ne "Setup host environments in docker (if applicable)...";

    if [[ "$USE_DOCKER_FOR_HOST_NODES" == "1" ]]; then
        local dockerBuildArgNoCache=""
        local dockerArgHostNetwork=()
        local opResult=""
        local computerId=""
        local containerName=""
        local computersSize=$(getComputersSize)
        local regionsSize=$(getRegionsSize)

        local dockerArgDevContainerNetwork=""
        if [[ "$DEVCONTAINER_DOCKER_NETWORK_NAME" != "" ]]; then
            dockerArgDevContainerNetwork="--network $DEVCONTAINER_DOCKER_NETWORK_NAME"
        fi

        if [[ "$USE_CACHE" == "0" ]]; then
            dockerBuildArgNoCache="--no-cache"

            docker kill --signal=SIGKILL -f $(docker ps -aq --filter "name=^$DOCKER_RAYLS_STACK") &> /dev/null
            docker rm -f $(docker ps -aq --filter "name=^$DOCKER_RAYLS_STACK") &> /dev/null
            docker image rm $DOCKER_TAG_RAYLS_NODE_HOST &> /dev/null

            for i in $(seq 0 $(($computersSize-1)))
            do
                computerId=$(getComputerId $i)
                containerName="$DOCKER_TAG_RAYLS_NODE_HOST--$computerId"
                local userHomeDir=$(eval echo ~${USER})
                ssh-keygen -f "$userHomeDir/.ssh/known_hosts" -R "$containerName" &> /dev/null
            done
        fi
        docker network ls --filter "name=$DOCKER_RAYLS_STACK_NETWORK" -q | xargs -r docker network rm &> /dev/null

        if [ -z "$(docker image ls -f "reference=$DOCKER_TAG_RAYLS_NODE_HOST" -q)" ]; then
            opResult=$(docker build $dockerBuildArgNoCache -t "$DOCKER_TAG_RAYLS_NODE_HOST" "$SCRIPT_DIR/src/host-node/." 2>&1)
            if [[ "$?" != 0 ]]; then
                echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} There was an error building $DOCKER_TAG_RAYLS_NODE_HOST $?: ${opResult}";
                exit $?;
            fi
        fi

        for i in $(seq 0 $(($regionsSize)))
        do

            local regionName=""
            local regionNetworkNumber=""
            if [[ "$i" == "$regionsSize" ]]; then
                regionName="internal"
                regionNetworkNumber="100"
            else
                regionName=$(getRegionName $i)
                regionNetworkNumber=$(getRegionNetworkNumber $i)
            fi

            local networkName="$DOCKER_RAYLS_STACK_NETWORK-$regionName"
            dockerArgHostNetwork+=("--network $networkName")
            opResult=$(docker network create "$networkName" --driver=bridge --subnet=172.$regionNetworkNumber.0.0/16 --ip-range=172.$regionNetworkNumber.1.0/24 --gateway=172.$regionNetworkNumber.0.1 2>&1)
            if [[ "$?" != 0 ]]; then
                echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} There was an error building $networkName $?: ${opResult}";
                exit $?;
            fi
        done

        for i in $(seq 0 $(($computersSize-1)))
        do
            computerId=$(getComputerId $i)
            containerName="$DOCKER_TAG_RAYLS_NODE_HOST--$computerId"

            docker kill --signal=SIGKILL "$containerName" &> /dev/null; docker rm "$containerName" &> /dev/null

            local dockerArgName="--name $containerName"
            local dockerArgNetwork="$dockerArgDevContainerNetwork ${dockerArgHostNetwork[@]}"
            local dockerArgVolume="-v /var/run/docker.sock:/var/run/docker.sock"
            opResult=$(docker run -d $dockerArgName $dockerArgNetwork $dockerArgVolume "$DOCKER_TAG_RAYLS_NODE_HOST" 2>&1)
            if [[ "$?" != 0 ]]; then
                echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} There was an error building "$containerName" $?: ${opResult}";
                exit $?;
            fi
        done

        opResult=$(cd "$SCRIPT_DIR/../../." && docker build $dockerBuildArgNoCache -t "$DOCKER_TAG_RAYLS_NODE_CLIENT" --file "./etc/docker-network/Dockerfile" ./ 2>&1)
        if [[ "$?" != 0 ]]; then
            echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} There was an error building "$DOCKER_TAG_RAYLS_NODE_CLIENT" $?: ${opResult}";
            exit $?;
        fi

        for i in $(seq 0 $(($computersSize-1)))
        do
            computerId=$(getComputerId $i)
            containerName="$DOCKER_TAG_RAYLS_NODE_HOST--$computerId"

            for j in $(seq 0 3)
            do
                if [[ "$(docker inspect -f '{{.State.Status}}' $containerName)" == *"running"* ]]; then
                    break;
                fi

                if [[ "$j" == "2" ]]; then
                    echo -e "${STYLE_RED}Error:${STYLE_DEFAULT} There was an error starting container $containerName";
                    exit $?;
                fi

                sleep 1
            done
        done
    fi

    echo -e "${STYLE_GREEN}OK${STYLE_DEFAULT}";
}
