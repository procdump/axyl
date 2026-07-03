//! Verify that all live nodes have identical blocks at the same height.

use crate::rpc;
use tracing::info;

/// Verify that all provided nodes have the same block hash at the latest
/// common block number.
///
/// Queries the latest block from the first node, then checks that all other
/// nodes have the same hash at that block number.
pub fn verify_block_consistency(rpc_urls: Vec<&str>) -> eyre::Result<()> {
    eyre::ensure!(rpc_urls.len() >= 2, "need at least 2 live nodes for block consistency check");

    let reference_block = rpc::get_block(rpc_urls[0], None)?;
    let number =
        u64::from_str_radix(&reference_block["number"].as_str().unwrap_or("0x0")[2..], 16)?;
    let reference_hash = &reference_block["hash"];

    info!(
        target: "chaos",
        number,
        hash = ?reference_hash,
        "checking block consistency at height {number}"
    );

    for url in &rpc_urls[1..] {
        let block = rpc::get_block(url, Some(number))?;
        if &block["hash"] != reference_hash {
            return Err(eyre::eyre!(
                "block mismatch at height {number}: node {} has hash {:?}, \
                 reference has {:?}",
                url,
                block["hash"],
                reference_hash
            ));
        }
    }

    info!(
        target: "chaos",
        number,
        nodes = rpc_urls.len(),
        "block consistency verified"
    );
    Ok(())
}
