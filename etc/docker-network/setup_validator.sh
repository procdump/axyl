#!/bin/bash

USER_ID=1101

# Ensure the data directory exists and is owned by nonroot user
if [ ! -d /home/nonroot/data/node-keys ]; then
    /usr/local/bin/rayls keytool generate validator --datadir /home/nonroot/data --address "${EXECUTION_ADDRESS}"
    chown -R ${USER_ID}:${USER_ID} /home/nonroot/data
    echo "Keys generated and ownership/permissions set"

    # Clean stale databases on first setup only.
    # Must NOT run when keys already exist — the validator may be running
    # and deleting these directories would crash it.
    rm -rf /home/nonroot/data/blobstore
    rm -rf /home/nonroot/data/consensus-db
    rm -rf /home/nonroot/data/db
    rm -rf /home/nonroot/data/rocksdb
    rm -rf /home/nonroot/data/static_files
    mkdir -p /home/nonroot/data/static_files
    chown ${USER_ID}:${USER_ID} /home/nonroot/data/static_files
else
    echo "Setup already complete"
fi
