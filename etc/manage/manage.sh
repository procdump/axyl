#!/bin/bash -i

# set -e

directory=$(dirname "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(cd "$directory" && pwd)
envPath="$SCRIPT_DIR/config/.env"
if [[ ! -e "$envPath" ]]; then
    echo "Error: .env file not found at $envPath"
    exit 1
fi
. "$envPath"

. "$SCRIPT_DIR/src/utils/init.sh"
. "$SCRIPT_DIR/src/utils/topology.sh"
. "$SCRIPT_DIR/src/utils/ssh.sh"

. "$SCRIPT_DIR/src/validate/script-requirements.sh"
. "$SCRIPT_DIR/src/validate/topology.sh"
. "$SCRIPT_DIR/src/validate/host-nodes.sh"

. "$SCRIPT_DIR/src/host-node/docker-host-nodes.sh"
. "$SCRIPT_DIR/src/host-node/host-nodes.sh"

. "$SCRIPT_DIR/src/client-node/client-nodes.sh"
. "$SCRIPT_DIR/src/client-node/genesis.sh"
. "$SCRIPT_DIR/src/client-node/start.sh"

init
validateScriptRequirements
validateTopology

initSsh
setupHostEnvironments

validateHostNodes
prepareHostEnvironments

makeClientNodes
makeGenesis
startClientNodes
