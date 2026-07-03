//! Batch data prepared for EVM execution.

use std::sync::Arc;

use crate::{payload::RLPayload, Address, Batch, Epoch, SealedHeader, WorkerId, B256};
use serde::{Deserialize, Serialize};

/// Batch data prepared for EVM execution.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PreparedBatch {
    /// Shared reference to the batch (avoids cloning transaction bytes).
    pub batch: Arc<Batch>,
    /// Digest of the batch.
    pub batch_digest: B256,
    /// ECDSA address of the authority.
    pub beneficiary: Address,
    /// The ConsensusHeader digest.
    pub output_digest: B256,
    /// The output nonce (epoch << 32 | round).
    pub output_nonce: u64,
    /// Commit timestamp from the output.
    pub timestamp: u64,
    /// The epoch from the output (for gas limit calc).
    pub epoch: Epoch,
    /// Worker ID from the batch.
    pub worker_id: WorkerId,
    /// Original batch index in the subdag.
    pub batch_index: usize,
    /// True when this batch was drained from the parking area.
    pub drained: bool,
    /// Block gas limit.
    pub gas_limit: u64,
}

impl PreparedBatch {
    /// Build an [`RLPayload`] from this batch.
    pub fn build_payload(
        &self,
        parent: SealedHeader,
        close_epoch: Option<B256>,
        base_fee_per_gas: u64,
    ) -> RLPayload {
        let mix_hash = self.output_digest ^ self.batch_digest;
        let gas_limit = self.gas_limit;
        RLPayload {
            parent_header: parent,
            beneficiary: self.beneficiary,
            nonce: self.output_nonce,
            batch_index: self.batch_index,
            timestamp: self.timestamp,
            batch_digest: self.batch_digest,
            consensus_header_digest: self.output_digest,
            base_fee_per_gas,
            gas_limit,
            mix_hash,
            close_epoch,
            worker_id: self.worker_id,
        }
    }
}
