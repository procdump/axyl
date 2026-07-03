use crate::{
    evm::RaylsEvmConfig,
    traits::{DefaultEthPayloadTypes, RaylsExecution, RaylsNode, RaylsPrimitives},
    FixedBytes,
};
use alloy::primitives::BlockHash;
use rayls_infrastructure_config::FEE_AGGREGATOR_ADDRESS;
use rayls_infrastructure_types::{
    Address, NonceRange, RecoveredBlock, SenderNonceRanges, TransactionSigned, B256,
};
use rayon::prelude::*;
use reth::rpc::{
    builder::TransportRpcModules,
    server_types::eth::utils::recover_raw_transaction as reth_recover_raw_transaction,
};
use reth_db::DatabaseEnv;
use reth_engine_tree::{
    engine::{EngineApiRequest, FromEngine},
    tree::{EngineApiTreeHandler, PayloadProcessor},
};
use reth_primitives::Recovered;
use reth_provider::providers::BlockchainProvider;
use reth_rpc_eth_types::EthResult;
use reth_trie::updates::TrieUpdates;
use std::sync::{Arc, OnceLock};
use tokio::sync::broadcast;
use tracing::error;

/// Type-erased closure that stops prewarming and blocks on the sparse trie
/// result. Returns `(state_root, trie_updates)` or an error string on failure.
pub type SparseRootFn = Box<dyn FnOnce() -> Result<(B256, TrieUpdates), String> + Send>;

/// Notification about transactions that failed during block execution.
///
/// These transactions were included in a batch that reached consensus quorum,
/// but failed validation during EVM execution. They will NOT appear in the
/// canonical notification, causing them to remain in the batch builder's
/// in-flight tracking map until stale cleanup.
///
/// Subscribers can use this notification to proactively remove these
/// transaction hashes from tracking structures.
#[derive(Debug, Clone)]
pub struct FailedTxNotification {
    /// Hashes of transactions that failed execution.
    pub failed_hashes: Vec<B256>,
    /// The batch digest where these failures occurred.
    pub batch_digest: B256,
}

/// Detail about a single nonce-too-high transaction for diagnostic tracing.
#[derive(Debug)]
pub struct NonceTooHighDetail {
    /// Transaction hash.
    pub tx_hash: B256,
    /// Sender address.
    pub sender: Address,
    /// Nonce on the transaction.
    pub tx_nonce: u64,
    /// Nonce expected by the state.
    pub state_nonce: u64,
}

/// Per-batch counts of transactions dropped during EVM execution, classified by reason.
#[derive(Debug, Default)]
pub struct TxValidationCounts {
    /// Transactions with nonce higher than account state (gap — tx is lost).
    pub nonce_too_high: u32,
    /// Transactions with nonce lower than account state (already executed — harmless).
    pub nonce_too_low: u32,
    /// Transactions dropped for other validation reasons.
    pub other: u32,
    /// Detailed info for nonce-too-high transactions.
    pub nonce_too_high_details: Vec<NonceTooHighDetail>,
    /// Per-sender nonce ranges across all executed+dropped txs in this batch.
    pub sender_nonce_ranges: SenderNonceRanges,
}

impl TxValidationCounts {
    /// Total number of dropped transactions.
    pub fn total(&self) -> u32 {
        self.nonce_too_high + self.nonce_too_low + self.other
    }

    /// Track per-sender nonce for range calculation.
    pub(super) fn observe_nonce(&mut self, sender: Address, nonce: u64) {
        self.sender_nonce_ranges
            .entry(sender)
            .and_modify(|range| {
                range.min = range.min.min(nonce);
                range.max = range.max.max(nonce);
            })
            .or_insert(NonceRange { min: nonce, max: nonce });
    }
}

/// Receiver for failed transaction notifications.
pub type ExecutedBatchDigestReceiver = broadcast::Receiver<BlockHash>;

/// This will contain the address to receive base fees.  It is set per chain and
/// will not change.  Implemented as a static OnceLock to work around the Reth lib interface.
static BASEFEE_ADDRESS: OnceLock<Address> = OnceLock::new();

/// Return the chains basefee address if set.
/// Note the basefee address is set once for the chain and will not change (outside of a hard fork).
/// Defaults to FEE_AGGREGATOR_ADDRESS so transaction base fees flow directly to fee distribution.
pub fn basefee_address() -> Address {
    *BASEFEE_ADDRESS.get().unwrap_or(&FEE_AGGREGATOR_ADDRESS)
}

/// Set the basefee address.  This will only work on the first call and should be during program
/// initialization. Calling more than once will do nothing, not calling early can lead to an unset
/// basefee address and a chain fork.
/// Defaults to FEE_AGGREGATOR_ADDRESS for direct fee collection.
pub(super) fn set_basefee_address(address: Option<Address>) {
    // Ignore the error. Should probably panic on error but this will break some test environments.
    let _ = BASEFEE_ADDRESS.set(address.unwrap_or(FEE_AGGREGATOR_ADDRESS));
}

/// Recover a batch of raw transactions, using parallelization for large batches.
pub fn reth_recover_raw_transactions(
    batch_digest: Option<FixedBytes<32>>,
    transactions: &[Vec<u8>],
) -> Vec<EthResult<Recovered<TransactionSigned>>> {
    let rec_fn = |tx_bytes: &Vec<u8>| {
        reth_recover_raw_transaction::<TransactionSigned>(tx_bytes).inspect_err(|e| {
            error!(
                target: "engine",
                batch=?batch_digest,
                ?tx_bytes,
                "failed to recover signer: {e}"
            )
        })
    };

    if transactions.len() > 100 {
        // use parallel iterator to speed up recovery of transactions
        transactions.par_iter().map(rec_fn).collect()
    } else {
        // use normal iterator for small number of transactions
        transactions.iter().map(rec_fn).collect()
    }
}

/// Rpc Server type, used for getting the node started.
pub type RpcServer = TransportRpcModules<()>;

/// The type to receive executed blocks from the engine and update canonical/finalized block state.
pub type RaylsEngineApiTreeHandler = EngineApiTreeHandler<
    RaylsPrimitives,
    BlockchainProvider<RaylsNode>,
    DefaultEthPayloadTypes,
    RaylsExecution,
    RaylsEvmConfig,
>;

/// The type to send to the blockchain tree (make blocks canonical/final).
pub type ToTree = std::sync::mpsc::Sender<
    FromEngine<
        EngineApiRequest<DefaultEthPayloadTypes, RaylsPrimitives>,
        alloy::consensus::Block<TransactionSigned>,
    >,
>;

// replace deprecated reth name with this type
/// Type alias to replace deprecated reth struct with new generic type:
/// A block with senders recovered from the block’s transactions.
///
/// This type is a SealedBlock with a list of senders that match the transactions in the block.
pub type BlockWithSenders = RecoveredBlock<reth_ethereum_primitives::Block>;

/// Shared handle to the payload processor for concurrent state root computation.
pub(crate) type SharedPayloadProcessor = Arc<parking_lot::Mutex<PayloadProcessor<RaylsEvmConfig>>>;

/// Type wrapper for a Reth DB.
/// Used primary as a opaque type to allow
/// the node launcher to create the DB upfront and reuse.
pub type RethDb = Arc<DatabaseEnv>;
