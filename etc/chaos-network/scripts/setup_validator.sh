#!/bin/bash
# Generate validator keys for chaos testing.
# Reused from etc/docker-network/setup_validator.sh.

# `set -e` so a failed `keytool generate` aborts before the `rm -rf` stanza below
# (matches the other scripts in this dir). Without it, a silent keygen failure
# would fall through and wipe the database directories of an otherwise valid node.
set -e

USER_ID=1101

if [ ! -d /home/nonroot/data/node-keys ]; then
    /usr/local/bin/rayls keytool generate validator \
        --datadir /home/nonroot/data \
        --address "${EXECUTION_ADDRESS}"
    chown -R ${USER_ID}:${USER_ID} /home/nonroot/data
    echo "Keys generated"
else
    echo "Setup already complete"
fi

# Clean stale databases
rm -rf /home/nonroot/data/blobstore
rm -rf /home/nonroot/data/consensus-db
rm -rf /home/nonroot/data/db
rm -rf /home/nonroot/data/rocksdb
rm -rf /home/nonroot/data/static_files
