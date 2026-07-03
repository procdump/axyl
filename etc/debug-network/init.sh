VALIDATORS=("validator-1" "validator-2" "validator-3" "validator-4")
ADDRESSES=(
    ${DEV_FUNDS}
    "0x2222222222222222222222222222222222222222"
    "0x3333333333333333333333333333333333333333"
    "0x4444444444444444444444444444444444444444"
)

# variables for pulling
LOCAL_PATH="./genesis/validators/"
REMOTE_PATH="/home/share/validators/*"

# root path for all validators
ROOTDIR="$scriptDir/local-validators"
GENESISDIR="genesis"
VALIDATORSDIR="${GENESISDIR}/validators"
SHARED_GENESISDIR="${ROOTDIR}/${VALIDATORSDIR}"
COMMITTEE_PATH="${ROOTDIR}/${GENESISDIR}/committee.yaml"
GENESIS_JSON_PATH="${ROOTDIR}/${GENESISDIR}/genesis.json"

# number of validators
LENGTH="${#VALIDATORS[@]}"

# Make sure we have a test account with funds if configuring.
if [ "$DEV_FUNDS" == "" ]; then
    echo "Must use --dev-funds=[ADDRESS] to fund a test account and own the consensus registry."
    echo "For example: --dev-funds 0x1111111111111111111111111111111111111111"
    echo "This sould be an account you have the private key to allow access to RLS on the test network"
    exit 1
fi

# make local directory for all validators
mkdir -p $SHARED_GENESISDIR
