//! Verify that the chain is producing new blocks.

use crate::rpc;
use std::time::Duration;
use tracing::info;

/// Wait until any live node advances by at least `min_blocks` beyond the
/// current maximum block number, or timeout.
pub fn wait_chain_advancing(
    rpc_urls: Vec<&str>,
    min_blocks: u64,
    timeout: Duration,
) -> eyre::Result<()> {
    eyre::ensure!(!rpc_urls.is_empty(), "no live nodes to check");

    let start_max = max_block_number(&rpc_urls)?;
    let target = start_max + min_blocks;
    let deadline = std::time::Instant::now() + timeout;

    info!(target: "chaos", start_max, target, "waiting for chain to advance");

    loop {
        std::thread::sleep(Duration::from_secs(1));
        let current = max_block_number(&rpc_urls)?;
        if current >= target {
            info!(target: "chaos", current, target, "chain advanced");
            return Ok(());
        }
        if std::time::Instant::now() >= deadline {
            return Err(eyre::eyre!(
                "chain did not advance from {start_max} to {target} within {timeout:?} \
                 (current max: {current})"
            ));
        }
    }
}

/// Wait for the chain to advance by at least 1 block within 45 seconds.
///
/// This is the equivalent of the `network_advancing` helper from restart tests.
pub fn wait_network_advancing(rpc_urls: Vec<&str>) -> eyre::Result<()> {
    wait_chain_advancing(rpc_urls, 1, Duration::from_secs(45))
}

/// Get the maximum block number across all provided nodes.
fn max_block_number(rpc_urls: &[&str]) -> eyre::Result<u64> {
    let mut max_num = 0u64;
    for url in rpc_urls {
        match rpc::get_block_number(url) {
            Ok(num) => max_num = max_num.max(num),
            Err(_) => continue, // Node might be down; skip.
        }
    }
    Ok(max_num)
}
