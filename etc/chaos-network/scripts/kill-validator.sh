#!/bin/bash
# Kill a validator container (simulates node crash).
#
# Usage:
#   ./kill-validator.sh <container> [--hard]
#   ./kill-validator.sh chaos-validator2         # SIGTERM (graceful)
#   ./kill-validator.sh chaos-validator2 --hard  # SIGKILL (crash)

set -e

CONTAINER="${1:?Usage: kill-validator.sh <container> [--hard]}"
MODE="${2:-}"

if [ "${MODE}" = "--hard" ]; then
    echo "Hard-killing ${CONTAINER} (SIGKILL)..."
    docker kill "${CONTAINER}"
else
    echo "Gracefully stopping ${CONTAINER} (SIGTERM)..."
    docker stop -t 5 "${CONTAINER}"
fi

echo "${CONTAINER} stopped"
