//! Verify nonce monotonicity — no forks detected.
//!
//! The EVM block header nonce encodes `(epoch << 32) | round`. Nonces must
//! never decrease; a decrease indicates a fork where duplicate consensus
//! outputs produced blocks out of order.

use crate::rpc;
use eyre::Report;
use tracing::info;

/// Maximum number of blocks to check in a full scan. For deeper chains,
/// the verifier samples evenly-spaced blocks instead of checking every one.
const MAX_FULL_SCAN_BLOCKS: u64 = 200;

/// Verify that block nonces are monotonically non-decreasing for a node,
/// from block 1 up to `latest_block`.
///
/// For chains deeper than [`MAX_FULL_SCAN_BLOCKS`], samples evenly-spaced
/// blocks to keep RPC calls bounded.
pub fn verify_nonce_monotonicity(node: &str, latest_block: u64) -> eyre::Result<()> {
    let block_numbers: Vec<u64> = if latest_block <= MAX_FULL_SCAN_BLOCKS {
        (1..=latest_block).collect()
    } else {
        // Sample MAX_FULL_SCAN_BLOCKS evenly-spaced blocks, always including
        // block 1 and latest_block.
        let step = latest_block / MAX_FULL_SCAN_BLOCKS;
        let mut nums: Vec<u64> = (1..=latest_block).step_by(step as usize).collect();
        if nums.last() != Some(&latest_block) {
            nums.push(latest_block);
        }
        nums
    };

    let mut prev_nonce: u64 = 0;
    for &block_num in &block_numbers {
        let block = rpc::get_block(node, Some(block_num))?;
        let nonce_str = block["nonce"]
            .as_str()
            .ok_or_else(|| Report::msg(format!("missing nonce at block {block_num}")))?;
        let nonce = u64::from_str_radix(nonce_str.strip_prefix("0x").unwrap_or(nonce_str), 16)?;
        if nonce < prev_nonce {
            return Err(Report::msg(format!(
                "Fork detected: nonce went backwards at block {block_num}: \
                 {nonce:#x} < {prev_nonce:#x}"
            )));
        }
        prev_nonce = nonce;
    }
    info!(
        target: "chaos",
        node,
        latest_block,
        checked = block_numbers.len(),
        "nonce monotonicity OK"
    );
    Ok(())
}
