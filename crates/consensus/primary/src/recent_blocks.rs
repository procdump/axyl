//! Track the most recent execution blocks for the consensus layer.

use rayls_infrastructure_types::{BlockHash, BlockNumHash, SealedHeader};
use std::collections::VecDeque;

/// Tracks 'num_blocks' most recently executed block hashes and numbers.
#[derive(Clone, Debug)]
pub struct RecentBlocks {
    num_blocks: usize,
    blocks: VecDeque<SealedHeader>,
}

impl RecentBlocks {
    /// Create a RecentBlocks that will hold 'num_blocks' most recent blocks.
    pub fn new(num_blocks: usize) -> Self {
        Self { num_blocks, blocks: VecDeque::new() }
    }

    /// Max number of blocks that can be held in RecentBlocks.
    pub fn block_capacity(&self) -> u64 {
        self.num_blocks as u64
    }

    /// Push the latest block onto RecentBlocks, will remove the oldest if needed to make room.
    pub fn push_latest(&mut self, latest: SealedHeader) {
        if self.blocks.len() >= self.num_blocks {
            self.blocks.pop_front();
        }
        self.blocks.push_back(latest);
    }

    /// Return the hash and number of the last executed block.
    /// This will return a default BlockNumHash if recents blocks are empty.
    /// This should only happen on node startup before any execution has taken
    /// place.  Most callsites will be fine with this, call is_empty() if this
    /// matters to you.
    pub fn latest_block_num_hash(&self) -> BlockNumHash {
        self.blocks.back().cloned().unwrap_or_else(Default::default).num_hash()
    }

    /// Return the number of the oldest block, or 0 if empty.
    pub fn oldest_block_number(&self) -> u64 {
        self.blocks.front().map(|h| h.number).unwrap_or(0)
    }

    /// Return the most recently pushed (highest block-number) executed block.
    ///
    /// WARNING: the tip's block *number* is monotonic, but the nonce it carries
    /// (`epoch << 32 | round`) is NOT - neither half. Draining a parked (out-of-order seq) batch
    /// executes a block that belongs to an OLDER output yet lands here as the newest height, so the
    /// tip's nonce reflects that origin output, not the frontier: its round can sit far below the
    /// true frontier round, and - when the drained batch was carried over from a previous epoch -
    /// its epoch can sit below the current epoch too.
    ///
    /// Example: execution has genuinely reached round 498. A batch for an earlier seq, mapping to
    /// round 200, was parked; the gap then fills and it is drained and executed now. That fresh
    /// block gets the next (highest) block number and becomes this tip, but its nonce encodes round
    /// 200. A caller reading the round here sees 200, not 498. The proposer throttle did exactly
    /// this: with consensus at round 500 it computed lag `500 - 200 = 300 > threshold` and
    /// throttled forever, wedging proposals - when the real lag was `500 - 498 = 2`. The epoch half
    /// regresses the same way: a batch drained from the previous epoch tags this tip with the old
    /// epoch.
    ///
    /// So never derive the execution frontier's epoch or round from this tip. Use the monotonic
    /// `executed_anchor` channel for the frontier, or scan the window for the max-nonce block when
    /// you must work from recent blocks.
    pub fn latest_block(&self) -> SealedHeader {
        self.blocks.back().cloned().unwrap_or_else(Default::default)
    }

    /// Is hash a recent block we have executed?
    pub fn contains_hash(&self, hash: BlockHash) -> bool {
        self.blocks.iter().any(|block| block.hash() == hash)
    }

    /// Get the block at a specific block number, if it exists in recent blocks.
    pub fn block_at_number(&self, number: u64) -> Option<&SealedHeader> {
        self.blocks.iter().find(|block| block.number == number)
    }

    /// Number of blocks actually stored.
    pub fn len(&self) -> usize {
        self.blocks.len()
    }

    /// Do we have any blocks?
    pub fn is_empty(&self) -> bool {
        self.blocks.is_empty()
    }
}
