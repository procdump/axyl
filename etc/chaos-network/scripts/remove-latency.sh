#!/bin/bash
# Remove latency injection from a validator container.
#
# Usage:
#   ./remove-latency.sh <container>
#   ./remove-latency.sh chaos-validator2

set -e

CONTAINER="${1:?Usage: remove-latency.sh <container>}"

echo "Removing latency from ${CONTAINER}..."
docker exec "${CONTAINER}" tc qdisc del dev eth0 root 2>/dev/null || true
echo "Latency removed from ${CONTAINER}"
