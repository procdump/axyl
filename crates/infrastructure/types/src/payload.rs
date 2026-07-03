//! The payload that contains all data from consensus to be executed.

use crate::{
    Address, BlockHeader as _, ConsensusOutput, ExecHeader, SealedHeader, WorkerId, B256,
    MIN_PROTOCOL_BASE_FEE,
};
use reth::rpc::api::eth::helpers::pending_block::BuildPendingEnv;
use serde::{Deserialize, Serialize};

/// The type used to build the next canonical block.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RLPayload {
    /// The previous canonical block's number and hash.
    pub parent_header: SealedHeader,
    /// The authority responsible for producing the batch.
    /// This is used for block's coinbase where priority fees are sent.
    pub beneficiary: Address,
    /// Used as the executed block header's `nonce`.
    ///
    /// The result of the leader's epoch and round:
    /// `((self.epoch as u64) << 32) | self.round as u64`
    ///
    /// See ConsensusOutput::nonce()
    pub nonce: u64,
    /// The index of the block within the entire output from consensus.
    ///
    /// Used as executed block header's `difficulty`.
    pub batch_index: usize,
    /// Value for the `timestamp` field of the new payload
    pub timestamp: u64,
    /// This is used as the ommers hash.
    /// The default is `B256::ZERO` (no batches to execute).
    pub batch_digest: B256,
    /// Hash value for [ConsensusHeader]. Used as the executed block's "parent_beacon_block_root".
    pub consensus_header_digest: B256,
    /// The base fee per gas used to construct this block.
    /// The value comes from the proposed batch.
    pub base_fee_per_gas: u64,
    /// The gas limit for the constructed block.
    ///
    /// The value comes from the worker's block.
    pub gas_limit: u64,
    /// The mix hash used for prev_randao.
    pub mix_hash: B256,
    /// Boolean indicating if the payload should use system calls to close the epoch during
    /// execution.
    ///
    /// This is the last batch for the `ConsensusOutput` if the epoch is closing.
    pub close_epoch: Option<B256>,
    /// Worker that created this payload.
    pub worker_id: WorkerId,
}

impl RLPayload {
    /// Create a new instance of [Self].
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        parent_header: SealedHeader,
        beneficiary: Address,
        batch_index: usize,
        batch_digest: B256,
        output: &ConsensusOutput,
        consensus_header_digest: B256,
        base_fee_per_gas: u64,
        gas_limit: u64,
        mix_hash: B256,
        worker_id: WorkerId,
    ) -> Self {
        // include leader's aggregate bls signature if this is the last payload for the epoch
        let close_epoch = output
            .close_epoch_for_last_batch()
            .is_some_and(|last_batch| last_batch)
            .then(|| output.keccak_leader_sigs());

        Self {
            parent_header,
            beneficiary,
            nonce: output.nonce(),
            batch_index,
            timestamp: output.committed_at(),
            batch_digest,
            consensus_header_digest,
            base_fee_per_gas,
            gas_limit,
            mix_hash,
            close_epoch,
            worker_id,
        }
    }

    /// PrevRandao is used by Rayls to provide a source for randomness on-chain.
    ///
    /// This is used as the executed block's "mix_hash".
    /// [EIP-4399]: https://eips.ethereum.org/EIPS/eip-4399
    pub fn prev_randao(&self) -> B256 {
        self.mix_hash
    }

    /// The Rayls parent "beacon" block root.
    pub fn parent_beacon_block_root(&self) -> Option<B256> {
        Some(self.consensus_header_digest)
    }

    /// Method to create an instance of Self useful for tests.
    ///
    /// WARNING: only use this for tests. Data is invalid.
    #[cfg(feature = "test-utils")]
    pub fn new_for_test(parent_header: SealedHeader, output: &ConsensusOutput) -> Self {
        use crate::Hash as _;

        let beneficiary = Address::random();
        let batch_index = 0;
        let batch_digest = B256::random();
        let consensus_header_digest = output.digest().into();
        let base_fee_per_gas = parent_header.base_fee_per_gas.unwrap_or(MIN_PROTOCOL_BASE_FEE);
        let gas_limit = parent_header.gas_limit;
        let mix_hash = B256::random();

        Self::new(
            parent_header,
            beneficiary,
            batch_index,
            batch_digest,
            output,
            consensus_header_digest,
            base_fee_per_gas,
            gas_limit,
            mix_hash,
            0,
        )
    }
}

impl BuildPendingEnv<ExecHeader> for RLPayload {
    fn build_pending_env(parent: &SealedHeader<ExecHeader>) -> Self {
        Self {
            parent_header: parent.clone(),
            beneficiary: parent.beneficiary(),
            nonce: parent.nonce.into(),
            batch_index: 0,
            timestamp: parent.timestamp().saturating_add(1),
            batch_digest: B256::ZERO,
            consensus_header_digest: parent.parent_beacon_block_root().unwrap_or_default(),
            base_fee_per_gas: MIN_PROTOCOL_BASE_FEE,
            gas_limit: parent.gas_limit(),
            mix_hash: B256::random(),
            close_epoch: None,
            worker_id: 0,
        }
    }
}
