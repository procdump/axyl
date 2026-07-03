//! Per-authority batch sequence ordering with parking for out-of-order batches.

use std::collections::{BTreeMap, HashMap};

use crate::{Address, Epoch, PreparedBatch};
use serde::{Deserialize, Serialize};

/// Maximum number of parked batches per authority before forced out-of-order execution.
pub const MAX_PARKED_PER_AUTHORITY: usize = 32;

/// Result of attempting to accept a batch into the ordering state.
#[derive(Debug)]
pub enum AcceptResult {
    /// Batch is in-order or the first from this authority - execute immediately.
    InOrder(PreparedBatch),
    /// Batch was parked, waiting for its predecessor.
    Parked,
    /// Parking limit reached - forced out-of-order execution.
    OverflowForced(PreparedBatch),
}

/// Per-authority ordering state.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct AuthoritySeqState {
    /// The highest seq we've executed for this authority. None means first batch not yet seen.
    pub last_executed_seq: Option<u64>,
    /// Batches waiting for their predecessor, keyed by seq.
    pub parked: BTreeMap<u64, PreparedBatch>,
}

/// Batch ordering state with epoch tracking.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct BatchOrderingState {
    /// The epoch these ordering states belong to.
    pub epoch: Epoch,
    /// Per-authority ordering state, keyed by ECDSA address.
    pub authorities: HashMap<Address, AuthoritySeqState>,
}
