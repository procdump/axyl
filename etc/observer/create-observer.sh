#!/bin/bash

set -e

directory=$(dirname "${BASH_SOURCE[0]}")
workingDir=$(cd "$directory" && pwd)
envPath="$workingDir/.env"
if [[ ! -e "$envPath" ]]; then
    echo "Error: .env file not found at $envPath"
    exit 1
fi
. "$envPath"

cd "$workingDir/../.."

export RL_BLS_PASSPHRASE="local"

# RPC_URL
if [ -z "$RPC_URL" ]; then
    echo "Enter RPC URL:"
    read RPC_URL
    if [ -z "$RPC_URL" ]; then
        echo "Error: RPC URL is required."
        exit 1
    fi
fi

while [ "$1" != "" ]; do
    case $1 in
        --start )
                START=true
                ;;
        * )     echo "Invalid option: $1"
                exit 1
    esac
    shift
done

# root path for observer
DATADIR="$workingDir/local-observer"

# Use RELEASE="debug" below and remove the --release to use a debug build
RELEASE="release"
cargo build --bin rayls-network --release
# Example of using redb for the consensus DB
#cargo build --bin rayls-network --features redb --release

if [ -d "${DATADIR}" ]; then
    echo "The directory ${DATADIR} already exists -- skipping configuration"
    echo "Remove ${DATADIR} if you wish create a new configuration."
    echo ""
else
    echo "creating observer keys/info"

    echo "creating datadir for observer"
    # Generate an observers "validator info"- still needs this for it's p2p netork settings and keys.
    KEYGEN_EXTRA_ARGS=""
    if [ -n "$RL_EXTERNAL_PRIMARY_ADDR" ]; then
        KEYGEN_EXTRA_ARGS="$KEYGEN_EXTRA_ARGS --external-primary-addr ${RL_EXTERNAL_PRIMARY_ADDR}"
    fi
    if [ -n "$RL_EXTERNAL_WORKER_ADDRS" ]; then
        KEYGEN_EXTRA_ARGS="$KEYGEN_EXTRA_ARGS --external-worker-addrs ${RL_EXTERNAL_WORKER_ADDRS}"
    fi

    ${workingDir}/../../target/${RELEASE}/rayls-network keytool generate observer \
        --datadir "${DATADIR}" \
        --address "${ADDRESS}" \
        ${KEYGEN_EXTRA_ARGS}

    mkdir "${DATADIR}/genesis"
    # cp validator info into shared genesis dir
    echo "copying validator info to shared genesis dir"
    cp "${GENESISDIR}/genesis.yaml" "${DATADIR}/genesis"
    cp "${GENESISDIR}/committee.yaml" "${DATADIR}/genesis"
    cp "${GENESISDIR}/../parameters.yaml" "${DATADIR}/"
    echo ""
    echo ""
fi

if [ "$START" = true ]; then
    echo "Starting observer in background, rpc endpoint http://localhost:9106"

    CONSENSUS_METRICS="127.0.0.1:9310"
    echo "Starting Observer in background, rpc endpoint http://localhost:8541"
    RL_BLS_PASSPHRASE="local" target/${RELEASE}/rayls-network node \
        --datadir "${DATADIR}" \
        --observer \
        --metrics "${CONSENSUS_METRICS}" \
        --log.stdout.format log-fmt \
        --full \
        --storage.v2 \
        -vvv \
        --http \
        --http.port 8541
fi
