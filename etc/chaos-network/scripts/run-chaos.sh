#!/bin/bash
# Chaos test runner for Docker-based Axyl testnet.
#
# Prerequisites:
#   docker compose -f etc/chaos-network/compose.yaml up --build -d
#
# Usage:
#   ./run-chaos.sh [scenario]
#
# Scenarios:
#   all           - Run all scenarios sequentially (default)
#   node-crash    - Kill and restart a validator
#   latency       - Inject latency on a validator
#   partition     - Network-partition a validator
#   packet-loss   - Inject packet loss
#   combined      - Kill + latency + packet-loss simultaneously

# No `set -e`: this harness deliberately injects faults and probes nodes that are
# expected to be down, so commands fail intermittently by design. Failures are
# tracked explicitly via the FAILURES counter and per-scenario pass/fail. A global
# `set -e` previously aborted the entire run (before the summary) on a single
# transient docker/curl hiccup — see review on #447. `pipefail` is kept for hygiene.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO="${1:-all}"

VALIDATORS=("chaos-validator1" "chaos-validator2" "chaos-validator3" "chaos-validator4")
RPC_URLS=("http://127.0.0.1:7545" "http://127.0.0.1:7544" "http://127.0.0.1:7543" "http://127.0.0.1:7542")

# --- Utility functions ---

get_block_number() {
    local url="$1"
    local result
    result=$(curl -s -X POST "${url}" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        2>/dev/null | grep -o '"result":"0x[0-9a-f]*"' | cut -d'"' -f4)
    if [ -z "$result" ]; then
        echo "0"
    else
        printf "%d" "$result"
    fi
}

# True only if the node's RPC actually answers with a result.
#
# NOTE: do not use get_block_number for liveness/down checks — it echoes "0" and
# returns exit 0 even when the node is unreachable, so `if get_block_number ...`
# is always true. This probe uses `curl -sf` (fails on connection-refused / non-2xx)
# and requires a `"result"` field in the body.
node_responsive() {
    local url="$1"
    curl -sf -m 3 -X POST "${url}" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        2>/dev/null | grep -q '"result"'
}

wait_advancing() {
    local url="$1"
    local min_blocks="${2:-1}"
    local timeout="${3:-60}"
    local start
    start=$(get_block_number "$url")
    local target=$((start + min_blocks))
    local elapsed=0

    echo "  Waiting for chain to advance from block $start to $target..."
    while [ "$elapsed" -lt "$timeout" ]; do
        sleep 2
        elapsed=$((elapsed + 2))
        local current
        current=$(get_block_number "$url")
        if [ "$current" -ge "$target" ]; then
            echo "  Chain advanced to block $current"
            return 0
        fi
    done
    echo "  TIMEOUT: chain stuck at block $(get_block_number "$url"), expected $target"
    return 1
}

check_consistency() {
    echo "  Checking block consistency across validators..."
    local ref_block
    ref_block=$(curl -s -X POST "${RPC_URLS[0]}" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}')
    local ref_hash
    ref_hash=$(echo "$ref_block" | grep -o '"hash":"0x[0-9a-f]*"' | head -1 | cut -d'"' -f4)
    local ref_number
    ref_number=$(echo "$ref_block" | grep -o '"number":"0x[0-9a-f]*"' | head -1 | cut -d'"' -f4)

    # Guard the reference node itself: an empty hash means the consistency check
    # has nothing to compare against and must not silently "pass".
    if [ -z "$ref_hash" ]; then
        echo "  FAIL: reference node ${RPC_URLS[0]} returned no latest block"
        return 1
    fi

    for i in 1 2 3; do
        local block
        block=$(curl -s -X POST "${RPC_URLS[$i]}" \
            -H "Content-Type: application/json" \
            -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"${ref_number}\",false],\"id\":1}")
        local hash
        hash=$(echo "$block" | grep -o '"hash":"0x[0-9a-f]*"' | head -1 | cut -d'"' -f4)
        # An empty hash means the node is down or still catching up at this height.
        # Treat that as a failure rather than skipping it (the previous
        # `&& [ -n "$hash" ]` guard silently counted such nodes as consistent).
        if [ -z "$hash" ]; then
            echo "  FAIL: validator$((i+1)) returned no block at $ref_number (down or lagging)"
            return 1
        fi
        if [ "$hash" != "$ref_hash" ]; then
            echo "  FAIL: validator$((i+1)) has different hash at $ref_number (fork)"
            return 1
        fi
    done
    echo "  Block consistency OK at $ref_number"
}

pass() { echo "  PASS: $1"; echo; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); echo; }

FAILURES=0

# --- Wait for network to be ready ---
echo "Waiting for network to be ready..."
sleep 5
wait_advancing "${RPC_URLS[0]}" 3 120 || { echo "Network not ready"; exit 1; }
echo "Network ready."
echo

# --- Scenarios ---

run_node_crash() {
    echo "=== Scenario: Node Crash ==="
    echo "  Killing validator2..."
    "$SCRIPT_DIR/kill-validator.sh" chaos-validator2

    sleep 2
    if wait_advancing "${RPC_URLS[0]}" 5 60; then
        pass "chain continued after killing 1 validator"
    else
        fail "chain stalled after killing 1 validator"
    fi

    echo "  Restarting validator2..."
    "$SCRIPT_DIR/restart-validator.sh" chaos-validator2
    sleep 10

    if wait_advancing "${RPC_URLS[1]}" 3 120; then
        pass "validator2 recovered and catching up"
    else
        fail "validator2 failed to recover"
    fi

    if check_consistency; then
        pass "block consistency after recovery"
    else
        fail "block consistency after recovery"
    fi
}

run_latency() {
    echo "=== Scenario: Network Latency ==="
    echo "  Injecting 300ms ± 100ms latency on validator3..."
    "$SCRIPT_DIR/inject-latency.sh" chaos-validator3 300 100

    if wait_advancing "${RPC_URLS[0]}" 5 120; then
        pass "chain advancing under latency"
    else
        fail "chain stalled under latency"
    fi

    echo "  Removing latency..."
    "$SCRIPT_DIR/remove-latency.sh" chaos-validator3
    sleep 5

    if check_consistency; then
        pass "block consistency after latency removal"
    else
        fail "block consistency after latency removal"
    fi
}

run_partition() {
    echo "=== Scenario: Network Partition ==="
    echo "  Partitioning validator4..."
    "$SCRIPT_DIR/inject-partition.sh" chaos-validator4

    if wait_advancing "${RPC_URLS[0]}" 10 60; then
        pass "chain advancing with 1 partitioned node"
    else
        fail "chain stalled with partitioned node"
    fi

    echo "  Healing partition..."
    "$SCRIPT_DIR/remove-partition.sh" chaos-validator4
    sleep 15

    if wait_advancing "${RPC_URLS[3]}" 3 120; then
        pass "partitioned node caught up"
    else
        fail "partitioned node failed to catch up"
    fi

    if check_consistency; then
        pass "block consistency after partition heal"
    else
        fail "block consistency after partition heal"
    fi
}

run_packet_loss() {
    echo "=== Scenario: Packet Loss ==="
    echo "  Injecting 15% packet loss on validator2..."
    "$SCRIPT_DIR/inject-packet-loss.sh" chaos-validator2 15

    if wait_advancing "${RPC_URLS[0]}" 5 120; then
        pass "chain advancing under packet loss"
    else
        fail "chain stalled under packet loss"
    fi

    echo "  Removing packet loss..."
    # remove-latency.sh runs `tc qdisc del ... root`, which clears the netem qdisc
    # regardless of whether it was configured for latency or packet loss — so it is
    # the correct cleanup for packet loss too (both use the same root netem qdisc).
    "$SCRIPT_DIR/remove-latency.sh" chaos-validator2
    sleep 5

    if check_consistency; then
        pass "block consistency after packet loss removal"
    else
        fail "block consistency after packet loss removal"
    fi
}

run_combined() {
    echo "=== Scenario: Combined Chaos ==="

    echo "  Injecting 200ms latency on validator1..."
    "$SCRIPT_DIR/inject-latency.sh" chaos-validator1 200 50

    echo "  Killing validator3..."
    "$SCRIPT_DIR/kill-validator.sh" chaos-validator3

    echo "  Injecting 10% packet loss on validator4..."
    "$SCRIPT_DIR/inject-packet-loss.sh" chaos-validator4 10

    sleep 5
    if wait_advancing "${RPC_URLS[1]}" 10 120; then
        pass "chain survived combined faults"
    else
        fail "chain stalled under combined faults"
    fi

    echo "  Recovering all faults..."
    "$SCRIPT_DIR/remove-latency.sh" chaos-validator1
    "$SCRIPT_DIR/remove-latency.sh" chaos-validator4
    "$SCRIPT_DIR/restart-validator.sh" chaos-validator3
    sleep 15

    if wait_advancing "${RPC_URLS[2]}" 3 120; then
        pass "all validators recovered"
    else
        fail "validator recovery failed"
    fi

    if check_consistency; then
        pass "block consistency after combined recovery"
    else
        fail "block consistency after combined recovery"
    fi
}

run_rapid_cycling() {
    echo "=== Scenario: Rapid Kill/Restart Cycling ==="

    for cycle in 1 2 3; do
        echo "  Cycle $cycle: hard-killing validator2..."
        docker kill chaos-validator2 >/dev/null 2>&1 || true
        sleep 1
        echo "  Cycle $cycle: restarting..."
        docker start chaos-validator2 >/dev/null 2>&1

        sleep 5
        if node_responsive "${RPC_URLS[1]}"; then
            echo "  Cycle $cycle: validator2 responsive"
        else
            echo "  Cycle $cycle: validator2 not yet responsive (may still be starting)"
        fi
    done

    sleep 10
    if wait_advancing "${RPC_URLS[0]}" 5 60; then
        pass "chain healthy after rapid kill/restart cycling"
    else
        fail "chain unhealthy after rapid kill/restart cycling"
    fi

    if check_consistency; then
        pass "block consistency after rapid cycling"
    else
        fail "block consistency after rapid cycling"
    fi
}

run_full_restart() {
    echo "=== Scenario: Full Network Restart ==="
    echo "  Recording pre-restart block height..."

    local pre_height
    pre_height=$(get_block_number "${RPC_URLS[0]}")
    echo "  Pre-restart height: $pre_height"

    echo "  Killing ALL validators..."
    for v in "${VALIDATORS[@]}"; do
        docker stop -t 3 "$v" >/dev/null 2>&1 &
    done
    wait
    sleep 3

    echo "  Verifying all nodes are down..."
    for url in "${RPC_URLS[@]}"; do
        # Must use node_responsive (real curl exit/HTTP check), NOT get_block_number,
        # which returns "0"/exit 0 for an unreachable node and made this branch fire
        # unconditionally — full-restart (and therefore `all`) could never pass.
        if node_responsive "$url"; then
            fail "validator still responsive after kill-all"
            return
        fi
    done
    pass "all validators stopped"

    echo "  Restarting ALL validators..."
    for v in "${VALIDATORS[@]}"; do
        docker start "$v" >/dev/null 2>&1
    done

    if wait_advancing "${RPC_URLS[0]}" 5 120; then
        pass "network reconverged after full restart"
    else
        fail "network failed to reconverge"
        return
    fi

    local post_height
    post_height=$(get_block_number "${RPC_URLS[0]}")
    if [ "$post_height" -ge "$pre_height" ]; then
        pass "no state loss: height $post_height >= pre-restart $pre_height"
    else
        fail "state loss: height $post_height < pre-restart $pre_height"
    fi

    if check_consistency; then
        pass "block consistency after full restart"
    else
        fail "block consistency after full restart"
    fi
}

run_kill_during_sync() {
    echo "=== Scenario: Kill During State Sync ==="

    echo "  Killing validator3 and letting network advance..."
    docker stop -t 3 chaos-validator3 >/dev/null 2>&1

    if ! wait_advancing "${RPC_URLS[0]}" 20 120; then
        fail "network didn't advance while validator3 was down"
        docker start chaos-validator3 >/dev/null 2>&1
        return
    fi

    local target_height
    target_height=$(get_block_number "${RPC_URLS[0]}")
    echo "  Network at height $target_height. Restarting validator3..."

    docker start chaos-validator3 >/dev/null 2>&1
    sleep 5

    echo "  Killing validator3 again mid-sync..."
    docker kill chaos-validator3 >/dev/null 2>&1
    sleep 2

    echo "  Restarting validator3 (must recover from interrupted sync)..."
    docker start chaos-validator3 >/dev/null 2>&1

    local caught_up=false
    for i in $(seq 1 60); do
        local h
        h=$(get_block_number "${RPC_URLS[2]}" 2>/dev/null) || continue
        if [ "$h" -ge "$target_height" ]; then
            caught_up=true
            break
        fi
        sleep 2
    done

    if $caught_up; then
        pass "validator3 recovered from interrupted state sync"
    else
        fail "validator3 did not recover from interrupted state sync"
    fi

    if check_consistency; then
        pass "block consistency after interrupted sync recovery"
    else
        fail "block consistency after interrupted sync recovery"
    fi
}

run_asymmetric_latency() {
    echo "=== Scenario: Asymmetric Latency ==="

    echo "  Adding 500ms latency to validator1 only..."
    "$SCRIPT_DIR/inject-latency.sh" chaos-validator1 500 100

    echo "  Adding 50ms latency to validator3..."
    "$SCRIPT_DIR/inject-latency.sh" chaos-validator3 50 10

    if wait_advancing "${RPC_URLS[1]}" 10 120; then
        pass "chain advancing under asymmetric latency"
    else
        fail "chain stalled under asymmetric latency"
    fi

    echo "  Removing all latency..."
    "$SCRIPT_DIR/remove-latency.sh" chaos-validator1
    "$SCRIPT_DIR/remove-latency.sh" chaos-validator3
    sleep 5

    if check_consistency; then
        pass "block consistency after asymmetric latency"
    else
        fail "block consistency after asymmetric latency"
    fi
}

# --- Run scenarios ---

case "$SCENARIO" in
    node-crash)          run_node_crash ;;
    latency)             run_latency ;;
    partition)           run_partition ;;
    packet-loss)         run_packet_loss ;;
    combined)            run_combined ;;
    rapid-cycling)       run_rapid_cycling ;;
    full-restart)        run_full_restart ;;
    kill-during-sync)    run_kill_during_sync ;;
    asymmetric-latency)  run_asymmetric_latency ;;
    all)
        run_node_crash
        run_latency
        run_partition
        run_packet_loss
        run_rapid_cycling
        run_full_restart
        run_kill_during_sync
        run_asymmetric_latency
        run_combined
        ;;
    *)
        echo "Unknown scenario: $SCENARIO"
        echo "Available: all, node-crash, latency, partition, packet-loss, combined,"
        echo "           rapid-cycling, full-restart, kill-during-sync, asymmetric-latency"
        exit 1
        ;;
esac

echo "==============================="
if [ "$FAILURES" -eq 0 ]; then
    echo "All scenarios PASSED"
    exit 0
else
    echo "$FAILURES scenario(s) FAILED"
    exit 1
fi
