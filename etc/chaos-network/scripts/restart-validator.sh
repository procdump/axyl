#!/bin/bash
# Restart a previously killed validator container.
#
# Usage:
#   ./restart-validator.sh <container>
#   ./restart-validator.sh chaos-validator2

set -e

CONTAINER="${1:?Usage: restart-validator.sh <container>}"

echo "Restarting ${CONTAINER}..."
docker start "${CONTAINER}"
echo "${CONTAINER} restarted"
