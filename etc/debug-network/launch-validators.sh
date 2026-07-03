#!/bin/bash

set -e

directory=$(dirname "${BASH_SOURCE[0]}")
scriptDir=$(cd "$directory" && pwd)
envPath="$scriptDir/.env"
if [[ ! -e "$envPath" ]]; then
    echo "Error: .env file not found at $envPath"
    exit 1
fi
. "$envPath"

. "$scriptDir/init.sh"

for ((i=1; i<$LENGTH; i++)); do
    VALIDATOR="${VALIDATORS[$i]}"
    DATADIR="${ROOTDIR}/${VALIDATOR}"
    INSTANCE=$((i+1))
    RPC_PORT=$((8545-i))
    CONSENSUS_METRICS="127.0.0.1:930$i"

    echo "Starting ${VALIDATOR} in background, rpc endpoint http://localhost:$RPC_PORT"
    # -vvv for INFO, -vvvvv for TRACE, etc
    # start validator
    RL_BLS_PASSPHRASE="local" RAYLS_NETWORK=${RAYLS_NETWORK} "$scriptDir/../../target/${BUILD_CONFIG}/rayls-network" node \
        --datadir "${DATADIR}" \
        --instance "${INSTANCE}" \
        --metrics "${CONSENSUS_METRICS}" \
        --log.stdout.format log-fmt \
        --full \
        --storage.v2 \
        --db.growth-step 1MB \
        --consensus-db.growth-step 1MB \
        --txpool.pending-max-count 1000000 \
        --txpool.pending-max-size 1242880000 \
        --txpool.basefee-max-count 1000000 \
        --txpool.basefee-max-size 20971120000 \
        --txpool.queued-max-count 1000000 \
        --txpool.queued-max-size 20971120000 \
        --txpool.max-pending-txns 1000000 \
        --txpool.max-new-txns 1000000 \
        --txpool.minimal-protocol-fee 0 \
        --txpool.max-tx-input-bytes 999999999999 \
        --txpool.max-account-slots 999999999 \
        -${LOG_LEVEL} \
        --http > "${ROOTDIR}/${VALIDATOR}.log" &
done

if [[ "$HAS_OBSERVER" == "1" ]]; then
    DATADIR="${ROOTDIR}/observer"
    CONSENSUS_METRICS="127.0.0.1:9304"
    echo "Starting Observer in background, rpc endpoint http://localhost:8541"
    RL_BLS_PASSPHRASE="local" RAYLS_NETWORK=${RAYLS_NETWORK} "$scriptDir/../../target/${BUILD_CONFIG}/rayls-network" node \
        --datadir "${DATADIR}" \
        --observer \
        --instance 5 \
        --metrics "${CONSENSUS_METRICS}" \
        --log.stdout.format log-fmt \
        --full \
        --storage.v2 \
        --db.growth-step 1MB \
        --consensus-db.growth-step 1MB \
        --txpool.pending-max-count 1000000 \
        --txpool.pending-max-size 1242880000 \
        --txpool.basefee-max-count 1000000 \
        --txpool.basefee-max-size 20971120000 \
        --txpool.queued-max-count 1000000 \
        --txpool.queued-max-size 20971120000 \
        --txpool.max-pending-txns 1000000 \
        --txpool.max-new-txns 1000000 \
        --txpool.minimal-protocol-fee 0 \
        --txpool.max-tx-input-bytes 999999999999 \
        --txpool.max-account-slots 999999999 \
        -${LOG_LEVEL} \
        --http > "${ROOTDIR}/observer.log" &
fi

echo "$LENGTH validators started in background, \
use 'killall rayls-network' to bring the test network down"
