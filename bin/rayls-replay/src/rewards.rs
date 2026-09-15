//! Snapshot-backed [`RewardsBackend`] for archive replay.
//!
//! Serves the close-epoch leader tally read from the snapshot block's
//! `withdrawals`, delegating committee and address resolution to
//! [`NoopRewardsBackend`]. Hybrid-reward epochs (post `HybridRewards` fork)
//! need per-validator participation rounds, which a block does not preserve;
//! those are recomputed by the live consensus-DB walk over the snapshot's
//! `ConsensusBlocks` and cross-checked against the withdrawals. Injected only
//! by `rayls-replay`.

use parking_lot::Mutex;
use rayls_infrastructure_types::{
    rewards::{HybridEpochTally, NoopRewardsBackend, RewardsBackend, RewardsCounter, RewardsError},
    Address, AuthorityIdentifier, Committee, Epoch,
};
use std::{
    collections::BTreeMap,
    sync::{Arc, OnceLock},
};

/// Shared epoch -> committed-tally store.
///
/// The replay consumer fills it from each close block's snapshot withdrawals
/// before that block executes; [`SnapshotRewardsBackend::tally`] reads it.
#[derive(Clone, Debug, Default)]
pub struct SnapshotTallyStore(Arc<Mutex<BTreeMap<Epoch, BTreeMap<Address, u32>>>>);

impl SnapshotTallyStore {
    /// Record the committed tally for a closing `epoch`.
    pub fn insert(&self, epoch: Epoch, tally: BTreeMap<Address, u32>) {
        self.0.lock().insert(epoch, tally);
    }

    /// Committed tally for `epoch`, empty if none was recorded.
    fn get(&self, epoch: Epoch) -> BTreeMap<Address, u32> {
        self.0.lock().get(&epoch).cloned().unwrap_or_default()
    }
}

/// Late-bound consensus-DB walker serving hybrid-reward tallies.
///
/// The archive env (and its [`RewardsCounter`]) is built before the consensus DB
/// is opened, so the walker is attached afterwards through this shared slot.
/// Attach before the first committee install: `set_committee` only forwards to
/// a walker that is already present.
#[derive(Clone, Debug, Default)]
pub struct HybridTallySource(Arc<OnceLock<RewardsCounter>>);

impl HybridTallySource {
    /// Install the consensus-DB walker. Returns `false` if one was already attached.
    pub fn attach(&self, walker: RewardsCounter) -> bool {
        self.0.set(walker).is_ok()
    }

    fn get(&self) -> Option<&RewardsCounter> {
        self.0.get()
    }
}

/// [`RewardsBackend`] that serves the snapshot's committed close-epoch tally.
#[derive(Debug, Default)]
pub struct SnapshotRewardsBackend {
    committee: NoopRewardsBackend,
    tallies: SnapshotTallyStore,
    hybrid: HybridTallySource,
}

impl SnapshotRewardsBackend {
    /// Build a backend reading committed tallies from `tallies` and hybrid
    /// tallies from the walker later attached to `hybrid`.
    pub fn new(tallies: SnapshotTallyStore, hybrid: HybridTallySource) -> Self {
        Self { committee: NoopRewardsBackend::default(), tallies, hybrid }
    }

    /// Wrap into the type-erased [`RewardsCounter`] handle for `RethEnv`.
    pub fn into_counter(self) -> RewardsCounter {
        RewardsCounter::from_impl(self)
    }
}

impl RewardsBackend for SnapshotRewardsBackend {
    fn tally(
        &self,
        epoch: Epoch,
        _last_executed_round: u32,
    ) -> Result<BTreeMap<Address, u32>, RewardsError> {
        Ok(self.tallies.get(epoch))
    }

    fn tally_hybrid(
        &self,
        epoch: Epoch,
        last_executed_round: u32,
    ) -> Result<HybridEpochTally, RewardsError> {
        // A `Withdrawal` carries one `u32` per validator (its leader rounds), so the
        // snapshot block alone cannot recover `participation_rounds`. Walk the
        // snapshot's consensus DB exactly as the live node did, then hold the
        // walk to the block's committed leader counts so the snapshot stays the
        // oracle: a disagreement means its consensus and execution DBs diverged.
        let walker = self.hybrid.get().ok_or_else(|| {
            RewardsError::Unsupported(format!(
                "hybrid-reward replay of epoch {epoch} needs the snapshot consensus DB, \
                 but no walker is attached"
            ))
        })?;
        let tally = walker.tally_hybrid(epoch, last_executed_round)?;

        // Exact map equality is intended, zero entries included. The live close block
        // writes one withdrawal per `per_address` entry with `amount = leader_rounds`
        // and no filtering (`CloseEpochTally::withdrawal_counts` -> `build_withdrawals`
        // in `crates/execution/evm/src/evm/block.rs`), and `snapshot_close_epoch_tally`
        // reads them back unfiltered. A validator that participated but never led is
        // therefore present on both sides with 0. Do NOT drop zeros here: that would
        // hide a walk crediting a leader the block never recorded.
        let committed = self.tallies.get(epoch);
        let walked: BTreeMap<Address, u32> =
            tally.per_address.iter().map(|(addr, t)| (*addr, t.leader_rounds)).collect();
        if walked != committed {
            return Err(RewardsError::Unsupported(format!(
                "hybrid tally for epoch {epoch} disagrees with the snapshot's committed \
                 withdrawals: consensus-DB leader rounds {walked:?} != withdrawals {committed:?}"
            )));
        }
        Ok(tally)
    }

    fn get_authority_address(&self, id: &AuthorityIdentifier) -> Option<Address> {
        self.committee.get_authority_address(id)
    }

    fn set_committee(&self, committee: Committee) {
        if let Some(walker) = self.hybrid.get() {
            walker.set_committee(committee.clone());
        }
        self.committee.set_committee(committee);
    }

    fn get_address_counts(&self) -> BTreeMap<Address, u32> {
        self.committee.get_address_counts()
    }

    fn set_leader_counts(&self, leader_counts: BTreeMap<AuthorityIdentifier, u32>) {
        self.committee.set_leader_counts(leader_counts);
    }

    fn inc_leader_count(&self, leader: &AuthorityIdentifier) {
        self.committee.inc_leader_count(leader);
    }

    fn clear(&self) {
        self.committee.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rayls_infrastructure_types::rewards::ValidatorRoundTally;

    fn addr(n: u8) -> Address {
        Address::with_last_byte(n)
    }

    /// Stand-in for the consensus-DB walk: serves a fixed hybrid tally.
    #[derive(Debug)]
    struct FixedWalker(HybridEpochTally);

    impl RewardsBackend for FixedWalker {
        fn tally(&self, _: Epoch, _: u32) -> Result<BTreeMap<Address, u32>, RewardsError> {
            unreachable!("legacy tally is withdrawal-backed")
        }
        fn tally_hybrid(&self, _: Epoch, _: u32) -> Result<HybridEpochTally, RewardsError> {
            Ok(self.0.clone())
        }
        fn get_authority_address(&self, _: &AuthorityIdentifier) -> Option<Address> {
            None
        }
        fn set_committee(&self, _: Committee) {}
        fn get_address_counts(&self) -> BTreeMap<Address, u32> {
            BTreeMap::new()
        }
        fn set_leader_counts(&self, _: BTreeMap<AuthorityIdentifier, u32>) {}
        fn inc_leader_count(&self, _: &AuthorityIdentifier) {}
        fn clear(&self) {}
    }

    fn hybrid(rows: &[(u8, u32, u32)]) -> HybridEpochTally {
        HybridEpochTally {
            per_address: rows
                .iter()
                .map(|(a, participation_rounds, leader_rounds)| {
                    (
                        addr(*a),
                        ValidatorRoundTally {
                            participation_rounds: *participation_rounds,
                            leader_rounds: *leader_rounds,
                        },
                    )
                })
                .collect(),
            total_rounds: rows.iter().map(|(_, _, l)| l).sum(),
        }
    }

    fn backend_with(
        walker: Option<HybridEpochTally>,
    ) -> (SnapshotTallyStore, SnapshotRewardsBackend) {
        let store = SnapshotTallyStore::default();
        let source = HybridTallySource::default();
        if let Some(tally) = walker {
            assert!(source.attach(RewardsCounter::from_impl(FixedWalker(tally))));
        }
        (store.clone(), SnapshotRewardsBackend::new(store, source))
    }

    #[test]
    fn tally_serves_stored_epoch() {
        let (store, backend) = backend_with(None);
        let expected: BTreeMap<Address, u32> = [(addr(1), 3), (addr(2), 1)].into_iter().collect();
        store.insert(7, expected.clone());
        assert_eq!(backend.tally(7, 0).unwrap(), expected);
    }

    #[test]
    fn tally_hybrid_without_walker_errors_loudly() {
        let (_, backend) = backend_with(None);
        let err = backend.tally_hybrid(7, 0).expect_err("must not silently succeed");
        assert!(!err.is_transient(), "a missing walker is not a retryable DB error");
    }

    #[test]
    fn tally_hybrid_serves_walk_matching_withdrawals() {
        // addr(3) participated but never led. The walk creates its `per_address` entry
        // with `leader_rounds == 0`, and the live block writes a zero-amount withdrawal
        // for it (no filtering on either side), so the maps must compare equal.
        let walked = hybrid(&[(1, 5, 3), (2, 4, 2), (3, 5, 0)]);
        let (store, backend) = backend_with(Some(walked.clone()));
        store.insert(7, [(addr(1), 3), (addr(2), 2), (addr(3), 0)].into_iter().collect());
        assert_eq!(backend.tally_hybrid(7, 0).unwrap(), walked);
    }

    #[test]
    fn tally_hybrid_rejects_walk_disagreeing_with_withdrawals() {
        let (store, backend) = backend_with(Some(hybrid(&[(1, 5, 3), (2, 4, 2)])));
        store.insert(7, [(addr(1), 3), (addr(2), 1)].into_iter().collect());
        let err = backend.tally_hybrid(7, 0).expect_err("leader rounds differ from withdrawals");
        assert!(!err.is_transient());
        assert!(err.to_string().contains("disagrees"), "{err}");
    }

    #[test]
    fn attach_is_once() {
        let source = HybridTallySource::default();
        assert!(source.attach(RewardsCounter::default()));
        assert!(!source.attach(RewardsCounter::default()));
    }

    #[test]
    fn tally_empty_for_unknown_epoch() {
        let (_, backend) = backend_with(None);
        assert!(backend.tally(99, 0).unwrap().is_empty());
    }

    #[test]
    fn store_insert_overwrites() {
        let (store, backend) = backend_with(None);
        store.insert(1, [(addr(1), 1)].into_iter().collect());
        store.insert(1, [(addr(1), 5)].into_iter().collect());
        assert_eq!(backend.tally(1, 0).unwrap().get(&addr(1)), Some(&5));
    }
}
