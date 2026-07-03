//! Implement an accumulator to total gas and blocks for an epoch.
//! This can be used to adjust per worker base fees on the next epoch.

use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc,
};

use alloy::{eips::eip1559::MIN_PROTOCOL_BASE_FEE, primitives::Address};
use parking_lot::Mutex;

use crate::{rewards::RewardsCounter, AuthorityIdentifier, WorkerId};

/// An interior mutable container for a worker's base fee.
#[derive(Clone, Debug)]
pub struct BaseFeeContainer {
    base_fee: Arc<AtomicU64>,
}

impl BaseFeeContainer {
    /// Create a new base fee container with base_fee.
    pub fn new(base_fee: u64) -> Self {
        Self { base_fee: Arc::new(AtomicU64::new(base_fee)) }
    }

    /// Return the contained base fee.
    pub fn base_fee(&self) -> u64 {
        self.base_fee.load(Ordering::Acquire)
    }

    /// Set the contained base fee.
    pub fn set_base_fee(&self, base_fee: u64) {
        self.base_fee.store(base_fee, Ordering::Release);
    }
}

impl Default for BaseFeeContainer {
    fn default() -> Self {
        Self::new(MIN_PROTOCOL_BASE_FEE)
    }
}

#[derive(Debug, Default)]
struct GasTotals {
    /// Total blocks executed so far this epoch.
    blocks: u64,
    /// Total gas used so far this epoch.
    gas_used: u64,
}

#[derive(Clone, Debug)]
struct Accumulated {
    gas: Arc<Mutex<GasTotals>>,
    base_fee: BaseFeeContainer,
}

impl Default for Accumulated {
    fn default() -> Self {
        Self {
            gas: Arc::new(Mutex::new(GasTotals::default())),
            base_fee: BaseFeeContainer::default(),
        }
    }
}

/// Shared accumulator for gas/block info as an epoch is built.
/// Can be used to calculate base fees at epoch boundaries.
#[derive(Clone, Debug)]
pub struct GasAccumulator {
    // Outer Arc for fast cloning.
    inner: Arc<Vec<Accumulated>>,
    /// Per-epoch rewards calculator (composed in for empty-block beneficiary
    /// resolution and committee distribution; tally happens at the EVM layer).
    rewards_counter: RewardsCounter,
}

impl GasAccumulator {
    /// Create a new empty ['GasAccumulator'] with a default Noop calculator.
    pub fn new(workers: usize) -> Self {
        Self::with_rewards(workers, RewardsCounter::default())
    }

    /// Create a new ['GasAccumulator'] threaded with a production-backed
    /// rewards calculator.
    pub fn with_rewards(workers: usize, rewards_counter: RewardsCounter) -> Self {
        let mut inner = Vec::with_capacity(workers);
        for _ in 0..workers {
            inner.push(Accumulated::default());
        }
        Self { inner: Arc::new(inner), rewards_counter }
    }

    /// Increment the counts for a block.
    /// Note: will panic if given an invalid worker_id.
    /// Any batch that makes it to execution will have a valid worker id.
    pub fn inc_block(&self, worker_id: WorkerId, gas_used: u64, _gas_limit: u64) {
        // skip empty blocks to keep restart-replay deterministic
        if gas_used == 0 {
            return;
        }
        let mut guard = self.inner.get(worker_id as usize).expect("valid worker id").gas.lock();
        guard.blocks += 1;
        guard.gas_used += gas_used;
    }

    /// Reset per-worker gas/block totals and wipe the in-memory leader mirror
    /// at epoch start. The authoritative close-epoch tally is recomputed from
    /// the consensus DB on demand.
    pub fn clear(&self) {
        for acc in self.inner.iter() {
            let mut guard = acc.gas.lock();
            guard.blocks = 0;
            guard.gas_used = 0;
        }
        self.rewards_counter.clear();
    }

    /// Return the accumulated blocks and gas.
    /// Note: will panic if given an invalid worker_id.
    pub fn get_values(&self, worker_id: WorkerId) -> (u64, u64) {
        let guard = self.inner.get(worker_id as usize).expect("valid worker id").gas.lock();
        (guard.blocks, guard.gas_used)
    }

    /// Return the base fee (can be changed in place) for a worker.
    pub fn base_fee(&self, worker_id: WorkerId) -> BaseFeeContainer {
        self.inner.get(worker_id as usize).expect("valid worker id").base_fee.clone()
    }

    /// Return the number of workers in the accumulator.
    /// Worker ids will be 0 to one less that this value.
    pub fn num_workers(&self) -> usize {
        self.inner.len()
    }

    /// Return a copy of the rewards calculator handle.
    pub fn rewards_counter(&self) -> RewardsCounter {
        self.rewards_counter.clone()
    }

    /// Use the authority's identifier to return an execution address for beneficiary address.
    pub fn get_authority_address(&self, authority_id: &AuthorityIdentifier) -> Option<Address> {
        self.rewards_counter.get_authority_address(authority_id)
    }
}

impl Default for GasAccumulator {
    fn default() -> Self {
        Self::new(1)
    }
}
