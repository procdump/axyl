#!/bin/bash
# Remove partition from a validator container.
#
# Usage:
#   ./remove-partition.sh <container>
#   ./remove-partition.sh chaos-validator2

set -e

CONTAINER="${1:?Usage: remove-partition.sh <container>}"

echo "Removing partition from ${CONTAINER}..."
# Delete exactly the rules inject-partition.sh added (mirror of its `-A` calls),
# rather than `iptables -F` which flushes the entire INPUT/OUTPUT chains and would
# also drop any rules the node process (or another injector) installed.
# Each `-D` is idempotent via `|| true` so re-running is safe.
docker exec "${CONTAINER}" iptables -D INPUT -p udp -j DROP 2>/dev/null || true
docker exec "${CONTAINER}" iptables -D OUTPUT -p udp -j DROP 2>/dev/null || true
docker exec "${CONTAINER}" iptables -D INPUT -p tcp --dport 8545 -j ACCEPT 2>/dev/null || true
docker exec "${CONTAINER}" iptables -D INPUT -p tcp -j DROP 2>/dev/null || true
echo "Partition removed from ${CONTAINER}"
