//! Chaos engineering integration tests for Axyl.
//!
//! All tests are `#[ignore]` because they spawn a full 4-validator local testnet
//! and take significant time. Run with:
//!
//! ```sh
//! cargo test -p chaos-framework --test chaos_scenarios -- --ignored --test-threads 1
//! ```

// Suppress unused crate warnings — these dependencies are used by the library,
// not directly by the test binary.
#![allow(unused_crate_dependencies)]

use chaos_framework::{
    cluster::TestCluster,
    fault::{network_latency, network_partition, node_kill, tx_spam},
    rpc,
    scenario::ScenarioBuilder,
    verify::{block_consistency, chain_advancing, nonce_monotonicity},
};
use std::time::Duration;

/// Limit potential for port collisions across chaos tests.
static CHAOS_TEST_MUTEX: std::sync::Mutex<()> = std::sync::Mutex::new(());

// ---------------------------------------------------------------------------
// Scenario 1: Kill 1 validator → chain continues → restart → verify consistency
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet, run separately"]
fn test_single_validator_crash_and_recovery() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    let mut cluster = TestCluster::spawn_default()?;

    ScenarioBuilder::new("single-validator-crash")
        .wait_advancing(3)
        .kill_node(2)
        .sleep(Duration::from_secs(2))
        .wait_advancing(5)
        .recover()
        .wait_advancing(3)
        .verify_block_consistency()
        .verify_nonce_monotonicity()
        .run(&mut cluster)?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Scenario 2: Rolling failure — kill node A, wait, kill node B
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet, run separately"]
fn test_rolling_validator_failure() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    let mut cluster = TestCluster::spawn_default()?;

    // Wait for network to be healthy.
    chain_advancing::wait_network_advancing(cluster.live_rpc_urls())?;

    // Kill validator 1.
    let guard1 = node_kill::kill_validator(&mut cluster, 1)?;

    // Chain should continue with 3 out of 4 validators (BFT tolerance: f=1).
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 5, Duration::from_secs(45))?;

    // Restart validator 1 before killing validator 3.
    guard1.recover(&mut cluster);
    std::thread::sleep(Duration::from_secs(5));

    // Kill validator 3.
    let guard3 = node_kill::kill_validator(&mut cluster, 3)?;

    // Chain should still continue.
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 5, Duration::from_secs(45))?;

    // Recover and verify.
    guard3.recover(&mut cluster);
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 3, Duration::from_secs(45))?;

    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;

    // Verify nonce monotonicity on the node that was killed and restarted.
    let latest = rpc::get_block_number(cluster.validators[1].rpc_url())?;
    nonce_monotonicity::verify_nonce_monotonicity(cluster.validators[1].rpc_url(), latest)?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Scenario 3: Kill 1 validator during active transaction load
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet, run separately"]
fn test_validator_crash_under_tx_load() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    let mut cluster = TestCluster::spawn_default()?;

    chain_advancing::wait_network_advancing(cluster.live_rpc_urls())?;
    std::thread::sleep(Duration::from_secs(2));

    let key = rpc::get_key("test-source");
    let to_account = rpc::address_from_word("chaos-tx-load-test");

    // Send a transaction before the kill.
    rpc::send_and_confirm(
        cluster.validators[0].rpc_url(),
        cluster.validators[1].rpc_url(),
        &key,
        to_account,
    )?;

    // Kill validator 2.
    let guard = node_kill::kill_validator(&mut cluster, 2)?;

    // Send more transactions while validator 2 is down.
    rpc::send_and_confirm(
        cluster.validators[0].rpc_url(),
        cluster.validators[1].rpc_url(),
        &key,
        to_account,
    )?;

    // Recover.
    guard.recover(&mut cluster);
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 3, Duration::from_secs(60))?;

    // Verify the restarted node has the correct balance.
    let expected_balance = 20 * rpc::WEI_PER_RLS;
    let actual = rpc::get_balance_above_with_retry(
        cluster.validators[2].rpc_url(),
        &to_account.to_string(),
        expected_balance - 1,
    )?;
    assert_eq!(
        actual, expected_balance,
        "restarted node should have caught up with correct balance"
    );

    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Scenario 4: SIGTERM (graceful) vs SIGKILL (hard crash)
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet, run separately"]
fn test_sigterm_vs_sigkill_recovery() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    let mut cluster = TestCluster::spawn_default()?;

    chain_advancing::wait_network_advancing(cluster.live_rpc_urls())?;

    // --- Test graceful stop (SIGTERM) ---
    let guard = node_kill::kill_validator(&mut cluster, 1)?;
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 3, Duration::from_secs(45))?;
    guard.recover(&mut cluster);
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 3, Duration::from_secs(60))?;

    let latest = rpc::get_block_number(cluster.validators[1].rpc_url())?;
    nonce_monotonicity::verify_nonce_monotonicity(cluster.validators[1].rpc_url(), latest)?;

    // --- Test hard kill (SIGKILL) ---
    let guard = node_kill::hard_kill_validator(&mut cluster, 1)?;
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 3, Duration::from_secs(45))?;
    guard.recover(&mut cluster);
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 3, Duration::from_secs(60))?;

    let latest = rpc::get_block_number(cluster.validators[1].rpc_url())?;
    nonce_monotonicity::verify_nonce_monotonicity(cluster.validators[1].rpc_url(), latest)?;

    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Scenario 5: Kill multiple validators (up to f) simultaneously
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet, run separately"]
fn test_multi_validator_kill_within_bft_tolerance() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    let mut cluster = TestCluster::spawn_default()?;

    chain_advancing::wait_network_advancing(cluster.live_rpc_urls())?;

    // In a 4-validator BFT with f=1, killing 1 should be survivable.
    // Killing 2 would halt consensus (2f+1 = 3 needed, only 2 alive).
    let guard = node_kill::kill_multiple_validators(&mut cluster, 1)?;

    // Chain should still advance with 3/4 validators.
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 5, Duration::from_secs(45))?;

    guard.recover(&mut cluster);
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 3, Duration::from_secs(60))?;

    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Scenario 6: Kill validator with delayed restart (state sync test)
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet, run separately"]
fn test_delayed_restart_state_sync() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    let mut cluster = TestCluster::spawn_default()?;

    chain_advancing::wait_network_advancing(cluster.live_rpc_urls())?;

    // Kill validator and wait a long time so it falls behind.
    let guard = node_kill::kill_validator(&mut cluster, 2)?;

    // Let the network advance significantly.
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 20, Duration::from_secs(120))?;

    let height_before_restart = rpc::get_block_number(cluster.validators[0].rpc_url())?;

    // Restart the lagged validator — it must catch up via state sync.
    guard.recover(&mut cluster);

    // Wait for the restarted node to catch up.
    let mut caught_up = false;
    for _ in 0..60 {
        std::thread::sleep(Duration::from_secs(2));
        match rpc::get_block_number(cluster.validators[2].rpc_url()) {
            Ok(height) if height >= height_before_restart => {
                caught_up = true;
                break;
            }
            _ => continue,
        }
    }
    assert!(caught_up, "validator did not catch up within 120s");

    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;

    let latest = rpc::get_block_number(cluster.validators[2].rpc_url())?;
    nonce_monotonicity::verify_nonce_monotonicity(cluster.validators[2].rpc_url(), latest)?;

    Ok(())
}

// ===========================================================================
// Phase 2: Mempool Spam Scenarios
// ===========================================================================

// ---------------------------------------------------------------------------
// Scenario 7: Flood mempool with invalid-signature transactions
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet, run separately"]
fn test_spam_invalid_signatures() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    let mut cluster = TestCluster::spawn_default()?;

    chain_advancing::wait_network_advancing(cluster.live_rpc_urls())?;
    std::thread::sleep(Duration::from_secs(2));

    // Spam invalid signature transactions — all should be rejected.
    let result = tx_spam::spam_invalid_signatures(cluster.validators[0].rpc_url(), 100)?;
    assert_eq!(result.accepted, 0, "transactions with invalid signatures should not be accepted");

    // Chain should still be healthy and advancing.
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 3, Duration::from_secs(30))?;
    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Scenario 8: Flood mempool with wrong chain ID transactions
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet, run separately"]
fn test_spam_wrong_chain_id() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    let mut cluster = TestCluster::spawn_default()?;

    chain_advancing::wait_network_advancing(cluster.live_rpc_urls())?;
    std::thread::sleep(Duration::from_secs(2));

    let result = tx_spam::spam_wrong_chain_id(cluster.validators[0].rpc_url(), 100)?;
    // Wrong chain ID txns should be rejected by the tx pool.
    assert_eq!(result.accepted, 0, "transactions with wrong chain ID should not be accepted");

    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 3, Duration::from_secs(30))?;
    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Scenario 9: Flood mempool with oversized calldata
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet, run separately"]
fn test_spam_oversized_calldata() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    let mut cluster = TestCluster::spawn_default()?;

    chain_advancing::wait_network_advancing(cluster.live_rpc_urls())?;
    std::thread::sleep(Duration::from_secs(2));

    // Send transactions with calldata exceeding the 2MB batch size limit.
    tx_spam::spam_oversized_calldata(cluster.validators[0].rpc_url(), 5, 2_100_000)?;

    // These may or may not be accepted by the tx pool (depends on whether
    // the pool enforces batch limits). The key assertion is that the chain
    // remains healthy.
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 3, Duration::from_secs(45))?;
    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Scenario 10: Flood mempool with excessive gas transactions
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet, run separately"]
fn test_spam_excessive_gas() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    let mut cluster = TestCluster::spawn_default()?;

    chain_advancing::wait_network_advancing(cluster.live_rpc_urls())?;
    std::thread::sleep(Duration::from_secs(2));

    tx_spam::spam_excessive_gas(cluster.validators[0].rpc_url(), 50)?;

    // Chain should be healthy regardless of acceptance.
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 3, Duration::from_secs(30))?;
    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Scenario 11: High-volume valid transaction burst
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet, run separately"]
fn test_spam_valid_burst() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    let mut cluster = TestCluster::spawn_default()?;

    chain_advancing::wait_network_advancing(cluster.live_rpc_urls())?;
    std::thread::sleep(Duration::from_secs(2));

    // Burst 200 valid transactions to stress throughput and backpressure.
    let result = tx_spam::spam_valid_transfers(cluster.validators[0].rpc_url(), 200)?;
    assert!(result.accepted > 0, "some valid transactions should be accepted");

    // Wait for the chain to process the burst.
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 10, Duration::from_secs(60))?;
    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Scenario 12: Mixed malformed transaction spam
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet, run separately"]
fn test_spam_mixed_malformed() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    let mut cluster = TestCluster::spawn_default()?;

    chain_advancing::wait_network_advancing(cluster.live_rpc_urls())?;
    std::thread::sleep(Duration::from_secs(2));

    // Mix of all malformed types.
    tx_spam::spam_mixed(cluster.validators[0].rpc_url(), 200)?;

    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 5, Duration::from_secs(45))?;
    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;

    Ok(())
}

// ===========================================================================
// Phase 2: Network Latency Scenarios
// (Require root/CAP_NET_ADMIN — skip gracefully if unavailable)
// ===========================================================================

// ---------------------------------------------------------------------------
// Scenario 13: Inject 200-500ms latency on all links
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet + root for tc, run separately"]
fn test_network_latency_uniform() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());

    if network_latency::check_tc_capability().is_err() {
        eprintln!("SKIPPED: tc not available (need root or CAP_NET_ADMIN)");
        return Ok(());
    }

    let mut cluster = TestCluster::spawn_default()?;
    chain_advancing::wait_network_advancing(cluster.live_rpc_urls())?;

    // Inject 350ms ± 150ms latency.
    let guard = network_latency::add_latency(350, 150)?;

    // Consensus should slow but still advance.
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 5, Duration::from_secs(120))?;

    // Remove latency.
    guard.clean();

    // Verify chain is healthy after latency removal.
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 3, Duration::from_secs(30))?;
    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Scenario 14: Latency + valid transaction load
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet + root for tc, run separately"]
fn test_latency_under_tx_load() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());

    if network_latency::check_tc_capability().is_err() {
        eprintln!("SKIPPED: tc not available (need root or CAP_NET_ADMIN)");
        return Ok(());
    }

    let mut cluster = TestCluster::spawn_default()?;
    chain_advancing::wait_network_advancing(cluster.live_rpc_urls())?;

    // Inject latency.
    let latency_guard = network_latency::add_latency(200, 50)?;

    // Send valid transactions under latency.
    let key = rpc::get_key("test-source");
    let to_account = rpc::address_from_word("latency-tx-test");
    rpc::send_and_confirm(
        cluster.validators[0].rpc_url(),
        cluster.validators[1].rpc_url(),
        &key,
        to_account,
    )?;

    // Remove latency.
    latency_guard.clean();

    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 3, Duration::from_secs(30))?;
    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Scenario 15: Packet loss
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet + root for tc, run separately"]
fn test_network_packet_loss() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());

    if network_latency::check_tc_capability().is_err() {
        eprintln!("SKIPPED: tc not available (need root or CAP_NET_ADMIN)");
        return Ok(());
    }

    let mut cluster = TestCluster::spawn_default()?;
    chain_advancing::wait_network_advancing(cluster.live_rpc_urls())?;

    // 10% packet loss — should degrade but not halt.
    let guard = network_latency::add_packet_loss(10.0)?;

    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 5, Duration::from_secs(120))?;

    guard.clean();

    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 3, Duration::from_secs(30))?;
    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;

    Ok(())
}

// ===========================================================================
// Phase 3: Combined Fault Scenarios
// ===========================================================================

// ---------------------------------------------------------------------------
// Scenario 16: Kill node + inject latency on remaining
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet + root for tc, run separately"]
fn test_kill_plus_latency() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());

    if network_latency::check_tc_capability().is_err() {
        eprintln!("SKIPPED: tc not available (need root or CAP_NET_ADMIN)");
        return Ok(());
    }

    let mut cluster = TestCluster::spawn_default()?;
    chain_advancing::wait_network_advancing(cluster.live_rpc_urls())?;

    // Kill one validator.
    let kill_guard = node_kill::kill_validator(&mut cluster, 2)?;

    // Inject latency on remaining nodes.
    let latency_guard = network_latency::add_latency(200, 50)?;

    // Chain should still advance (3/4 validators, with latency).
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 5, Duration::from_secs(120))?;

    // Remove latency first, then restart validator.
    latency_guard.clean();
    kill_guard.recover(&mut cluster);

    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 3, Duration::from_secs(60))?;
    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Scenario 17: Latency + transaction spam
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet + root for tc, run separately"]
fn test_latency_plus_tx_spam() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());

    if network_latency::check_tc_capability().is_err() {
        eprintln!("SKIPPED: tc not available (need root or CAP_NET_ADMIN)");
        return Ok(());
    }

    let mut cluster = TestCluster::spawn_default()?;
    chain_advancing::wait_network_advancing(cluster.live_rpc_urls())?;

    // Inject latency.
    let latency_guard = network_latency::add_latency(150, 50)?;

    // Spam mixed malformed + valid transactions.
    tx_spam::spam_mixed(cluster.validators[0].rpc_url(), 100)?;
    tx_spam::spam_valid_transfers(cluster.validators[1].rpc_url(), 50)?;

    // Chain should survive.
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 5, Duration::from_secs(120))?;

    latency_guard.clean();

    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 3, Duration::from_secs(30))?;
    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Scenario 18: Network partition — isolate 1 node
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet + root for iptables, run separately"]
fn test_network_partition_single_node() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());

    if network_partition::check_iptables_capability().is_err() {
        eprintln!("SKIPPED: iptables not available (need root or CAP_NET_ADMIN)");
        return Ok(());
    }

    let mut cluster = TestCluster::spawn_default()?;
    chain_advancing::wait_network_advancing(cluster.live_rpc_urls())?;

    // Partition validator 2 by blocking its p2p port range.
    // In test config, each validator instance uses port offsets from the base.
    // The exact ports depend on --external-primary-addr / --external-worker-addr.
    // Here we block a broad range around the expected p2p ports for instance 3
    // (validator index 2 = instance 3). Adjust if test config changes.
    let guard = network_partition::partition_port_range("validator-2", 9300, 9400)?;

    // Remaining 3 validators should still advance.
    // Note: we check only non-partitioned nodes.
    let live_urls: Vec<&str> = cluster
        .validators
        .iter()
        .enumerate()
        .filter(|(i, _)| *i != 2)
        .map(|(_, n)| n.rpc_url())
        .collect();

    chain_advancing::wait_chain_advancing(live_urls, 10, Duration::from_secs(60))?;

    // Heal the partition.
    guard.clean();

    // Wait for partitioned node to catch up.
    std::thread::sleep(Duration::from_secs(10));
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 5, Duration::from_secs(120))?;
    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Scenario 19: Kill node during epoch transition
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet with short epochs, run separately"]
fn test_kill_during_epoch_transition() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    let mut cluster = TestCluster::spawn_default()?;

    chain_advancing::wait_network_advancing(cluster.live_rpc_urls())?;

    // Wait for the chain to produce a meaningful number of blocks.
    // Epoch transitions happen at configured intervals. With short epochs
    // (e.g., 5 seconds in test config), we can catch one.
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 20, Duration::from_secs(60))?;

    // Kill a validator — if we're lucky, this hits during an epoch transition.
    // Even if not, this tests the crash-recovery of epoch checkpoints.
    let guard = node_kill::hard_kill_validator(&mut cluster, 1)?;

    // Let chain advance further (potentially crossing an epoch boundary).
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 20, Duration::from_secs(120))?;

    // Restart and verify recovery.
    guard.recover(&mut cluster);

    // Wait for the killed node to recover and catch up.
    let mut caught_up = false;
    let target_height = rpc::get_block_number(cluster.validators[0].rpc_url())?;
    for _ in 0..60 {
        std::thread::sleep(Duration::from_secs(2));
        match rpc::get_block_number(cluster.validators[1].rpc_url()) {
            Ok(h) if h >= target_height => {
                caught_up = true;
                break;
            }
            _ => continue,
        }
    }
    assert!(caught_up, "validator did not recover after epoch transition kill");

    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;

    let latest = rpc::get_block_number(cluster.validators[1].rpc_url())?;
    nonce_monotonicity::verify_nonce_monotonicity(cluster.validators[1].rpc_url(), latest)?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Scenario 20: Combined chaos — kill + latency + spam
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet + root, run separately"]
fn test_combined_chaos() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    let mut cluster = TestCluster::spawn_default()?;

    chain_advancing::wait_network_advancing(cluster.live_rpc_urls())?;

    // Layer 1: Kill a validator.
    let kill_guard = node_kill::kill_validator(&mut cluster, 3)?;

    // Layer 2: Inject latency (if tc available).
    let latency_guard = if network_latency::check_tc_capability().is_ok() {
        Some(network_latency::add_latency(100, 30)?)
    } else {
        eprintln!("NOTE: tc not available, skipping latency injection in combined test");
        None
    };

    // Layer 3: Spam transactions.
    tx_spam::spam_mixed(cluster.validators[0].rpc_url(), 100)?;
    tx_spam::spam_valid_transfers(cluster.validators[1].rpc_url(), 50)?;

    // Chain should survive all three simultaneous faults.
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 10, Duration::from_secs(120))?;

    // Recover in order: latency → kill.
    if let Some(lg) = latency_guard {
        lg.clean();
    }
    kill_guard.recover(&mut cluster);

    // Full recovery verification.
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 5, Duration::from_secs(60))?;
    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;

    let latest = rpc::get_block_number(cluster.validators[3].rpc_url())?;
    nonce_monotonicity::verify_nonce_monotonicity(cluster.validators[3].rpc_url(), latest)?;

    Ok(())
}

// ===========================================================================
// Phase 3: Aggressive failure mode scenarios
// ===========================================================================

// ---------------------------------------------------------------------------
// Scenario 21: Rapid kill/restart cycling
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet, run separately"]
fn test_rapid_kill_restart_cycling() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    let mut cluster = TestCluster::spawn_default()?;

    chain_advancing::wait_network_advancing(cluster.live_rpc_urls())?;

    // Rapidly kill and restart the same validator 3 times.
    // This stresses crash recovery: the node may not finish shutting down
    // before the next restart, or may have partially-written state.
    for cycle in 0..3 {
        let guard = node_kill::hard_kill_validator(&mut cluster, 1)?;
        // Minimal delay — restart before node fully stops.
        std::thread::sleep(Duration::from_millis(500));
        guard.recover(&mut cluster);
        std::thread::sleep(Duration::from_secs(3));

        // Verify the node is responsive after each cycle.
        let mut responsive = false;
        for _ in 0..30 {
            if rpc::get_block_number(cluster.validators[1].rpc_url()).is_ok() {
                responsive = true;
                break;
            }
            std::thread::sleep(Duration::from_secs(1));
        }
        assert!(responsive, "validator not responsive after kill/restart cycle {cycle}");
    }

    // After all cycles, chain must be healthy.
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 5, Duration::from_secs(60))?;
    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;

    let latest = rpc::get_block_number(cluster.validators[1].rpc_url())?;
    nonce_monotonicity::verify_nonce_monotonicity(cluster.validators[1].rpc_url(), latest)?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Scenario 22: Full network restart (all validators killed simultaneously)
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet, run separately"]
fn test_full_network_restart() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    let mut cluster = TestCluster::spawn_default()?;

    chain_advancing::wait_network_advancing(cluster.live_rpc_urls())?;

    // Send a transaction so there's state to verify after restart.
    let key = rpc::get_key("test-source");
    let to_account = rpc::address_from_word("full-restart-test");
    rpc::send_and_confirm(
        cluster.validators[0].rpc_url(),
        cluster.validators[1].rpc_url(),
        &key,
        to_account,
    )?;

    let pre_restart_height = rpc::get_block_number(cluster.validators[0].rpc_url())?;

    // Kill ALL validators simultaneously.
    let guard = node_kill::kill_multiple_validators(&mut cluster, 4)?;

    // Verify all nodes are down.
    std::thread::sleep(Duration::from_secs(3));
    for v in &cluster.validators {
        assert!(
            rpc::get_block_number(v.rpc_url()).is_err(),
            "validator {} should be down",
            v.index
        );
    }

    // Restart all.
    guard.recover(&mut cluster);

    // Network must reconverge and advance.
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 5, Duration::from_secs(120))?;

    // All validators must have the pre-restart state.
    let balance = rpc::get_positive_balance_with_retry(
        cluster.validators[2].rpc_url(),
        &to_account.to_string(),
    )?;
    assert!(balance > 0, "state lost after full network restart");

    // Block height must be at least what it was before restart.
    for v in &cluster.validators {
        let height = rpc::get_block_number(v.rpc_url())?;
        assert!(
            height >= pre_restart_height,
            "validator {} at height {height}, expected >= {pre_restart_height}",
            v.index
        );
    }

    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Scenario 23: Kill a node that's mid-state-sync
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet, run separately"]
fn test_kill_during_state_sync() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    let mut cluster = TestCluster::spawn_default()?;

    chain_advancing::wait_network_advancing(cluster.live_rpc_urls())?;

    // Kill a validator and let the network advance far ahead.
    let guard = node_kill::kill_validator(&mut cluster, 2)?;
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 30, Duration::from_secs(180))?;

    let target_height = rpc::get_block_number(cluster.validators[0].rpc_url())?;

    // Restart the validator — it starts state sync to catch up.
    guard.recover(&mut cluster);

    // Wait briefly for state sync to begin, then kill again mid-sync.
    std::thread::sleep(Duration::from_secs(5));
    let mid_sync_height = rpc::get_block_number(cluster.validators[2].rpc_url()).unwrap_or(0);

    // Only kill mid-sync if the node hasn't fully caught up yet.
    if mid_sync_height < target_height {
        let guard2 = node_kill::hard_kill_validator(&mut cluster, 2)?;
        std::thread::sleep(Duration::from_secs(2));

        // Restart again — node must recover from interrupted state sync.
        guard2.recover(&mut cluster);
    }

    // Wait for the node to fully catch up.
    let mut caught_up = false;
    for _ in 0..90 {
        std::thread::sleep(Duration::from_secs(2));
        match rpc::get_block_number(cluster.validators[2].rpc_url()) {
            Ok(h) if h >= target_height => {
                caught_up = true;
                break;
            }
            _ => continue,
        }
    }
    assert!(caught_up, "validator did not recover from interrupted state sync");

    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;

    let latest = rpc::get_block_number(cluster.validators[2].rpc_url())?;
    nonce_monotonicity::verify_nonce_monotonicity(cluster.validators[2].rpc_url(), latest)?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Scenario 24: Transaction flood during node crash
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet, run separately"]
fn test_tx_flood_during_crash() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    let mut cluster = TestCluster::spawn_default()?;

    chain_advancing::wait_network_advancing(cluster.live_rpc_urls())?;

    // Start a transaction flood on validator 0.
    let key = rpc::get_key("test-source");
    let to_account = rpc::address_from_word("flood-crash-test");

    // Base nonces on the sender's current on-chain nonce — `test-source` starts at
    // a genesis nonce of 5+N, so a 0-based sequence would be rejected as too low.
    let sender = rpc::address_from_key(&key)?;
    let start_nonce =
        rpc::get_transaction_count(cluster.validators[0].rpc_url(), &sender.to_string())?;

    // Send initial transactions.
    for offset in 0..5 {
        let _ = rpc::send_rls(
            cluster.validators[0].rpc_url(),
            &key,
            to_account,
            rpc::WEI_PER_RLS,
            rpc::GAS_PRICE,
            21000,
            start_nonce + offset,
        );
    }

    // Kill a validator while transactions are still being processed.
    let guard = node_kill::hard_kill_validator(&mut cluster, 3)?;

    // Continue flooding transactions to remaining validators.
    for offset in 5..20 {
        let _ = rpc::send_rls(
            cluster.validators[0].rpc_url(),
            &key,
            to_account,
            rpc::WEI_PER_RLS,
            rpc::GAS_PRICE,
            21000,
            start_nonce + offset,
        );
    }

    // Chain must keep processing despite the crash + flood.
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 10, Duration::from_secs(60))?;

    // Restart the crashed validator.
    guard.recover(&mut cluster);
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 5, Duration::from_secs(60))?;

    // Verify the restarted node caught up with the correct balance.
    let balance = rpc::get_positive_balance_with_retry(
        cluster.validators[3].rpc_url(),
        &to_account.to_string(),
    )?;
    assert!(balance > 0, "restarted node has zero balance after tx flood");

    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Scenario 25: Progressive degradation and recovery
// ---------------------------------------------------------------------------

#[test]
#[ignore = "chaos test: requires full testnet + root for tc, run separately"]
fn test_progressive_degradation() -> eyre::Result<()> {
    let _guard = CHAOS_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());

    if network_latency::check_tc_capability().is_err() {
        eprintln!("SKIPPED: tc not available");
        return Ok(());
    }

    let mut cluster = TestCluster::spawn_default()?;
    chain_advancing::wait_network_advancing(cluster.live_rpc_urls())?;

    // Phase 1: Add light latency.
    let latency1 = network_latency::add_latency(50, 10)?;
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 3, Duration::from_secs(30))?;

    // Phase 2: Increase to heavy latency.
    latency1.clean();
    let latency2 = network_latency::add_latency(300, 100)?;
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 3, Duration::from_secs(120))?;

    // Phase 3: Add a node kill on top of latency.
    let kill_guard = node_kill::kill_validator(&mut cluster, 2)?;
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 5, Duration::from_secs(120))?;

    // Phase 4: Recovery — remove faults in reverse order.
    kill_guard.recover(&mut cluster);
    std::thread::sleep(Duration::from_secs(5));

    latency2.clean();

    // Network must fully recover.
    chain_advancing::wait_chain_advancing(cluster.live_rpc_urls(), 5, Duration::from_secs(60))?;
    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;

    let latest = rpc::get_block_number(cluster.validators[2].rpc_url())?;
    nonce_monotonicity::verify_nonce_monotonicity(cluster.validators[2].rpc_url(), latest)?;

    Ok(())
}
