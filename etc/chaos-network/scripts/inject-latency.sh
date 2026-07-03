#!/bin/bash
# Inject network latency into a validator container using tc/netem.
#
# Usage:
#   ./inject-latency.sh <container> <delay_ms> [jitter_ms]
#   ./inject-latency.sh chaos-validator2 200 50
#
# To remove:
#   ./remove-latency.sh <container>

set -e

CONTAINER="${1:?Usage: inject-latency.sh <container> <delay_ms> [jitter_ms]}"
DELAY="${2:?Usage: inject-latency.sh <container> <delay_ms> [jitter_ms]}"
JITTER="${3:-0}"

echo "Injecting ${DELAY}ms ± ${JITTER}ms latency into ${CONTAINER}..."

docker exec "${CONTAINER}" tc qdisc replace dev eth0 root netem delay "${DELAY}ms" "${JITTER}ms"

echo "Latency injected into ${CONTAINER}"
