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


while [ "$1" != "" ]; do
    case $1 in
        --dev-funds )
                shift
                DEV_FUNDS=$1
                ;;
        * )     echo "Invalid option: $1"
                exit 1
    esac
    shift
done

# if EPOCH_DURATION is not set or not number, set to default of 86400 seconds (1 day)
if ! [[ "$EPOCH_DURATION" =~ ^[0-9]+$ ]]; then
    EPOCH_DURATION=86400
fi

# Loop through all the validators and generate their keys and validator infos.
for ((i=0; i<$LENGTH; i++)); do
    VALIDATOR="${VALIDATORS[$i]}"
    ADDRESS="${ADDRESSES[$i]}"
    DATADIR="${ROOTDIR}/${VALIDATOR}"
    echo "creating validator keys/info for ${VALIDATOR}"
    RL_BLS_PASSPHRASE="local" "${scriptDir}/../../target/${BUILD_CONFIG}/rayls-network" keytool generate validator \
        --datadir "${DATADIR}" \
        --address "${ADDRESS}" \
        --force

    # cp validator info into shared genesis dir
    echo "copying validator info to shared genesis dir"
    cp "${DATADIR}/node-info.yaml" "${SHARED_GENESISDIR}/${VALIDATOR}.yaml"
    echo ""
    echo ""
done

# Use the validator infos to Create genesis, committee and worker cache yamls.
# Speed up blocks for testing, use a bogus chain id
if [ "$BASEFEE_ADDRESS" = "" ]; then
    RL_BLS_PASSPHRASE="local" "${scriptDir}/../../target/${BUILD_CONFIG}/rayls-network" genesis \
        --datadir "${ROOTDIR}" \
        --chain-id 0x1e7 \
        --epoch-duration-in-secs $EPOCH_DURATION \
        --dev-funded-account $DEV_FUNDS \
        --max-header-delay-ms 1000 \
        --min-header-delay-ms 1000 \
        --consensus-registry-owner $DEV_FUNDS \
        --network-admin $DEV_FUNDS
else
    RL_BLS_PASSPHRASE="local" "${scriptDir}/../../target/${BUILD_CONFIG}/rayls-network" genesis \
        --datadir "${ROOTDIR}" \
        --chain-id 0x1e7 \
        --epoch-duration-in-secs $EPOCH_DURATION \
        --dev-funded-account $DEV_FUNDS \
        --basefee-address $BASEFEE_ADDRESS \
        --max-header-delay-ms 1000 \
        --min-header-delay-ms 1000 \
        --consensus-registry-owner $DEV_FUNDS \
        --network-admin $DEV_FUNDS
fi

# Copy the generated genesis, committee and parameters to each validator.
for ((i=0; i<$LENGTH; i++)); do
    VALIDATOR="${VALIDATORS[$i]}"
    DATADIR="${ROOTDIR}/${VALIDATOR}"
    mkdir "${DATADIR}/genesis"
    # cp validator info into shared genesis dir
    echo "copying validator info to shared genesis dir"
    cp "${ROOTDIR}/${GENESISDIR}/genesis.yaml" "${DATADIR}/genesis"
    cp "${ROOTDIR}/${GENESISDIR}/committee.yaml" "${DATADIR}/genesis"
    cp "${ROOTDIR}/parameters.yaml" "${DATADIR}/"
    echo ""
    echo ""
done

if [[ "$HAS_OBSERVER" == "1" ]]; then
    echo "creating datadir for observer"
    DATADIR="${ROOTDIR}/observer"
    mkdir -p "${DATADIR}/genesis"
    # Generate an observers "validator info"- still needs this for it's p2p netork settings and keys.
    RL_BLS_PASSPHRASE="local" "${scriptDir}/../../target/${BUILD_CONFIG}/rayls-network" keytool generate observer \
        --datadir "${DATADIR}" \
        --address 0x4444444444444444444444444444444444444444
        # Copy the chain config files over to the new observer config directories.
    cp "${ROOTDIR}/${GENESISDIR}/genesis.yaml" "${DATADIR}/genesis"
    cp "${ROOTDIR}/${GENESISDIR}/committee.yaml" "${DATADIR}/genesis"
    cp "${ROOTDIR}/parameters.yaml" "${DATADIR}/"
fi
