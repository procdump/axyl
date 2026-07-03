#!/bin/bash
# Inject packet loss into a validator container using tc/netem.
#
# Usage:
#   ./inject-packet-loss.sh <container> <percent>
#   ./inject-packet-loss.sh chaos-validator3 10

set -e

CONTAINER="${1:?Usage: inject-packet-loss.sh <container> <percent>}"
PERCENT="${2:?Usage: inject-packet-loss.sh <container> <percent>}"

echo "Injecting ${PERCENT}% packet loss into ${CONTAINER}..."

docker exec "${CONTAINER}" tc qdisc replace dev eth0 root netem loss "${PERCENT}%"

echo "Packet loss injected into ${CONTAINER}"
