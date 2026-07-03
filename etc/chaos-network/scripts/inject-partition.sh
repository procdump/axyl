#!/bin/bash
# Partition a validator by dropping all traffic to/from its peers.
#
# Usage:
#   ./inject-partition.sh <container>
#   ./inject-partition.sh chaos-validator2
#
# To remove:
#   ./remove-partition.sh <container>

set -e

CONTAINER="${1:?Usage: inject-partition.sh <container>}"

echo "Partitioning ${CONTAINER} (dropping all peer traffic)..."

# Drop all incoming and outgoing UDP (QUIC consensus traffic).
docker exec "${CONTAINER}" iptables -A INPUT -p udp -j DROP
docker exec "${CONTAINER}" iptables -A OUTPUT -p udp -j DROP

# Drop incoming TCP except the RPC port (8545) so we can still query the node.
docker exec "${CONTAINER}" iptables -A INPUT -p tcp --dport 8545 -j ACCEPT
docker exec "${CONTAINER}" iptables -A INPUT -p tcp -j DROP

echo "Partition active on ${CONTAINER} (UDP blocked, TCP blocked except RPC 8545)"
