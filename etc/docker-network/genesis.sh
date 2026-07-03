#!/bin/bash
set -e

# Gasless network flags
GASLESS_FLAGS=""
if [ "$GASLESS" = "true" ]; then
    GASLESS_FLAGS="--base-fee 0 --min-base-fee 0"
    echo "Gasless mode enabled: base fee and min base fee set to 0"
fi

# Gas limit flag
GAS_LIMIT_FLAGS=""
if [ -n "$GAS_LIMIT" ]; then
    GAS_LIMIT_FLAGS="--gas-limit $GAS_LIMIT"
    echo "Custom gas limit: $GAS_LIMIT"
fi

mkdir -p /home/nonroot/data/genesis/validators
cp -r /home/nonroot/data/validator-1/node-info.yaml /home/nonroot/data/genesis/validators/validator-1.yaml
cp -r /home/nonroot/data/validator-2/node-info.yaml /home/nonroot/data/genesis/validators/validator-2.yaml
cp -r /home/nonroot/data/validator-3/node-info.yaml /home/nonroot/data/genesis/validators/validator-3.yaml
cp -r /home/nonroot/data/validator-4/node-info.yaml /home/nonroot/data/genesis/validators/validator-4.yaml

/usr/local/bin/rayls genesis \
    --datadir /home/nonroot/data/ \
    --chain-id 0x1e7 \
    --epoch-duration-in-secs 60 \
    --dev-funded-account 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
    --max-header-delay-ms 1000 \
    --min-header-delay-ms 500 \
    --consensus-registry-owner 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
    --network-admin 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
    --fee-aggregator-admin 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
    ${GASLESS_FLAGS} \
    ${GAS_LIMIT_FLAGS}
    # 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266's private key: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Create directories and copy files for each validator
for i in {1..4}; do
    mkdir -p /home/nonroot/data/validator-$i/genesis/
    cp /home/nonroot/data/genesis/genesis.yaml /home/nonroot/data/genesis/committee.yaml /home/nonroot/data/validator-$i/genesis/
    cp /home/nonroot/data/parameters.yaml /home/nonroot/data/validator-$i/
done
chown -R 1101:1101 /home/nonroot/data

echo "done"
