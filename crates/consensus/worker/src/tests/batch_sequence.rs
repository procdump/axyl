//! Tests for `walk_consensus_blocks_for_max_seq` - the recovery path that
//! reconstructs a worker's batch sequence from canonical consensus history.
//!
//! Regression coverage for the break-on-first-payload-entry bug: a single
//! header can carry multiple (author, worker) batches, and the walk must
//! return the MAX seq within the block, not the first one encountered.

use super::*;
use crate::{metrics::WorkerMetrics, test_utils::TestMakeBlockQuorumWaiter};
use indexmap::IndexMap;
use rayls_infrastructure_network_types::local::LocalNetwork;
use rayls_infrastructure_storage::{
    open_db,
    tables::{BatchSeqCounter, Batches, ConsensusBlocks},
};
use rayls_infrastructure_types::{
    AuthorityIdentifier, Batch, BlockHash, Certificate, CommittedSubDag, ConsensusHeader, Database,
    Epoch, Header, ReputationScores, TaskManager, WorkerId,
};
use std::{sync::Arc, time::Duration};
use tempfile::TempDir;

const WORKER_A: WorkerId = 0;
const WORKER_B: WorkerId = 1;

fn authority(byte: u8) -> AuthorityIdentifier {
    AuthorityIdentifier::dummy_for_test(byte)
}

fn batch_with_seq(seq: u64) -> Batch {
    Batch { seq, ..Default::default() }
}

fn header_with_payload(
    author: AuthorityIdentifier,
    epoch: Epoch,
    payload: IndexMap<BlockHash, WorkerId>,
) -> Header {
    Header { author, epoch, payload, ..Default::default() }
}

/// `Certificate` has private fields, so we can't use struct-update syntax from
/// outside the types crate. Mutate the public `header` on a Default instance.
fn cert_with_header(header: Header) -> Certificate {
    let mut cert = Certificate::default();
    cert.header = header;
    cert
}

fn subdag(certs: Vec<Certificate>, leader_epoch: Epoch) -> CommittedSubDag {
    // leader's epoch drives sub_dag.leader_epoch() which gates the walk.
    let leader = cert_with_header(Header { epoch: leader_epoch, ..Default::default() });
    CommittedSubDag::new(certs, leader, 0, ReputationScores::default(), None)
}

fn write_block<DB: Database>(store: &DB, number: u64, sub_dag: CommittedSubDag) {
    let header = ConsensusHeader { number, sub_dag, ..Default::default() };
    store.insert::<ConsensusBlocks>(&header.number, &header).unwrap();
}

/// Construct a minimal Worker for exercising the DB-backed methods. The
/// TaskManager is returned so the caller keeps it alive for the test - its
/// spawner is wired into WorkerNetworkHandle::new_for_test.
fn make_worker<DB: Database + Clone>(
    store: DB,
) -> (Worker<DB, TestMakeBlockQuorumWaiter>, TaskManager) {
    let task_manager = TaskManager::default();
    let worker = Worker::new(
        WORKER_A,
        None,
        Arc::new(WorkerMetrics::default()),
        LocalNetwork::new_with_empty_id(),
        store,
        Duration::from_secs(5),
        WorkerNetworkHandle::new_for_test(task_manager.get_spawner()),
    );
    (worker, task_manager)
}

/// Regression for the break-on-first-payload-entry bug:
/// a single header contains 3 batches from the same (author, worker)
/// with seqs [5, 6, 7]. The walk must return 7, not 5.
#[test]
fn walk_returns_max_when_header_carries_multiple_own_batches() {
    let temp_dir = TempDir::new().unwrap();
    let store = open_db(temp_dir.path());
    let me = authority(1);
    let epoch: Epoch = 2;

    let b5 = batch_with_seq(5);
    let b6 = batch_with_seq(6);
    let b7 = batch_with_seq(7);
    let d5 = b5.digest();
    let d6 = b6.digest();
    let d7 = b7.digest();

    store.insert::<Batches>(&d5, &b5).unwrap();
    store.insert::<Batches>(&d6, &b6).unwrap();
    store.insert::<Batches>(&d7, &b7).unwrap();

    // Insertion order (IndexMap preserves it): lowest seq first - the exact
    // shape that tripped the old `break 'outer` logic.
    let mut payload = IndexMap::new();
    payload.insert(d5, WORKER_A);
    payload.insert(d6, WORKER_A);
    payload.insert(d7, WORKER_A);

    let cert = cert_with_header(header_with_payload(me.clone(), epoch, payload));
    write_block(&store, 1, subdag(vec![cert], epoch));

    assert_eq!(walk_consensus_blocks_for_max_seq(&store, WORKER_A, me, epoch), Some(7));
}

/// Newer block holds the max. Walk must prefer it over earlier blocks.
#[test]
fn walk_prefers_newest_block_across_multiple_blocks() {
    let temp_dir = TempDir::new().unwrap();
    let store = open_db(temp_dir.path());
    let me = authority(1);
    let epoch: Epoch = 2;

    let older = batch_with_seq(3);
    let newer = batch_with_seq(9);
    let d_older = older.digest();
    let d_newer = newer.digest();
    store.insert::<Batches>(&d_older, &older).unwrap();
    store.insert::<Batches>(&d_newer, &newer).unwrap();

    let older_cert = cert_with_header(header_with_payload(
        me.clone(),
        epoch,
        IndexMap::from([(d_older, WORKER_A)]),
    ));
    let newer_cert = cert_with_header(header_with_payload(
        me.clone(),
        epoch,
        IndexMap::from([(d_newer, WORKER_A)]),
    ));
    write_block(&store, 1, subdag(vec![older_cert], epoch));
    write_block(&store, 2, subdag(vec![newer_cert], epoch));

    assert_eq!(walk_consensus_blocks_for_max_seq(&store, WORKER_A, me, epoch), Some(9));
}

/// Prior-epoch blocks must be excluded even when they contain our batches.
#[test]
fn walk_ignores_prior_epoch_blocks() {
    let temp_dir = TempDir::new().unwrap();
    let store = open_db(temp_dir.path());
    let me = authority(1);

    let prev_batch = batch_with_seq(100);
    let d_prev = prev_batch.digest();
    store.insert::<Batches>(&d_prev, &prev_batch).unwrap();

    let prev_cert =
        cert_with_header(header_with_payload(me.clone(), 1, IndexMap::from([(d_prev, WORKER_A)])));
    write_block(&store, 1, subdag(vec![prev_cert], 1));

    assert_eq!(walk_consensus_blocks_for_max_seq(&store, WORKER_A, me, 2), None);
}

/// Other authors / other workers must not contribute.
#[test]
fn walk_filters_by_author_and_worker() {
    let temp_dir = TempDir::new().unwrap();
    let store = open_db(temp_dir.path());
    let me = authority(1);
    let other = authority(2);
    let epoch: Epoch = 2;

    let mine = batch_with_seq(4);
    let theirs = batch_with_seq(42);
    let other_worker = batch_with_seq(99);
    let d_mine = mine.digest();
    let d_theirs = theirs.digest();
    let d_other_worker = other_worker.digest();
    store.insert::<Batches>(&d_mine, &mine).unwrap();
    store.insert::<Batches>(&d_theirs, &theirs).unwrap();
    store.insert::<Batches>(&d_other_worker, &other_worker).unwrap();

    let my_cert = cert_with_header(header_with_payload(
        me.clone(),
        epoch,
        IndexMap::from([(d_mine, WORKER_A), (d_other_worker, WORKER_B)]),
    ));
    let their_cert =
        cert_with_header(header_with_payload(other, epoch, IndexMap::from([(d_theirs, WORKER_A)])));
    write_block(&store, 1, subdag(vec![my_cert, their_cert], epoch));

    assert_eq!(walk_consensus_blocks_for_max_seq(&store, WORKER_A, me, epoch), Some(4));
}

/// Empty ConsensusBlocks - observer recovery / fresh start.
#[test]
fn walk_returns_none_on_empty_db() {
    let temp_dir = TempDir::new().unwrap();
    let store = open_db(temp_dir.path());
    let me = authority(1);

    assert_eq!(walk_consensus_blocks_for_max_seq(&store, WORKER_A, me, 1), None);
}

/// Distinguishing "observed seq=0" from "observed nothing" is the whole point
/// of the `Option<u64>` return. A first-ever committed batch at seq=0 must
/// yield `Some(0)` so the caller can advance to seq=1 for the next batch,
/// rather than getting the same seq=0 that was just consumed.
#[test]
fn walk_returns_some_zero_when_first_committed_batch_has_seq_zero() {
    let temp_dir = TempDir::new().unwrap();
    let store = open_db(temp_dir.path());
    let me = authority(1);
    let epoch: Epoch = 2;

    let first = batch_with_seq(0);
    let d_first = first.digest();
    store.insert::<Batches>(&d_first, &first).unwrap();

    let cert = cert_with_header(header_with_payload(
        me.clone(),
        epoch,
        IndexMap::from([(d_first, WORKER_A)]),
    ));
    write_block(&store, 1, subdag(vec![cert], epoch));

    assert_eq!(walk_consensus_blocks_for_max_seq(&store, WORKER_A, me, epoch), Some(0));
}

/// Missing Batches entry (digest referenced in payload but batch not stored
/// locally) must not panic and must not count toward max.
#[test]
fn walk_tolerates_missing_batches_entry() {
    let temp_dir = TempDir::new().unwrap();
    let store = open_db(temp_dir.path());
    let me = authority(1);
    let epoch: Epoch = 2;

    let stored = batch_with_seq(7);
    let d_stored = stored.digest();
    store.insert::<Batches>(&d_stored, &stored).unwrap();

    let missing = batch_with_seq(42);
    let d_missing = missing.digest();
    // d_missing deliberately NOT inserted into Batches.

    let cert = cert_with_header(header_with_payload(
        me.clone(),
        epoch,
        IndexMap::from([(d_missing, WORKER_A), (d_stored, WORKER_A)]),
    ));
    write_block(&store, 1, subdag(vec![cert], epoch));

    assert_eq!(walk_consensus_blocks_for_max_seq(&store, WORKER_A, me, epoch), Some(7));
}

// -----------------------------------------------------------------------------
// Tests for `Worker::get_persisted_batch_seq` and
// `Worker::recover_batch_seq_from_history` - the per-Worker wrappers around
// the persisted counter read and the walk fallback.
// -----------------------------------------------------------------------------

/// Missing counter row yields `None` so the caller falls back to the walk.
#[test]
fn persisted_returns_none_when_counter_absent() {
    let temp_dir = TempDir::new().unwrap();
    let store = open_db(temp_dir.path());
    let (worker, _tm) = make_worker(store);
    assert_eq!(worker.get_persisted_batch_seq(), None);
}

/// Present counter row yields `Some(n)` verbatim.
#[test]
fn persisted_returns_value_when_counter_present() {
    let temp_dir = TempDir::new().unwrap();
    let store = open_db(temp_dir.path());
    store.insert::<BatchSeqCounter>(&WORKER_A, &42u64).unwrap();
    let (worker, _tm) = make_worker(store);
    assert_eq!(worker.get_persisted_batch_seq(), Some(42));
}

/// Observer / non-committee members have no authority - recovery returns 0
/// without touching the store.
#[test]
fn recover_returns_zero_for_non_committee() {
    let temp_dir = TempDir::new().unwrap();
    let store = open_db(temp_dir.path());
    let (worker, _tm) = make_worker(store);
    assert_eq!(worker.recover_batch_seq_from_history(None, 1), 0);
}

/// Committee member with no committed certs yet - walk returns `None`, so
/// recovery yields seq=0 for the very first batch.
#[test]
fn recover_returns_zero_when_history_empty() {
    let temp_dir = TempDir::new().unwrap();
    let store = open_db(temp_dir.path());
    let me = authority(1);
    let (worker, _tm) = make_worker(store);
    assert_eq!(worker.recover_batch_seq_from_history(Some(me), 2), 0);
}

/// Walk observed max=9 - next seq must be 10.
#[test]
fn recover_returns_next_after_observed_max() {
    let temp_dir = TempDir::new().unwrap();
    let store = open_db(temp_dir.path());
    let me = authority(1);
    let epoch: Epoch = 2;

    let mine = batch_with_seq(9);
    let d = mine.digest();
    store.insert::<Batches>(&d, &mine).unwrap();
    let cert =
        cert_with_header(header_with_payload(me.clone(), epoch, IndexMap::from([(d, WORKER_A)])));
    write_block(&store, 1, subdag(vec![cert], epoch));

    let (worker, _tm) = make_worker(store);
    assert_eq!(worker.recover_batch_seq_from_history(Some(me), epoch), 10);
}

/// Walk observed u64::MAX - saturating_add keeps us at u64::MAX rather than
/// wrapping. Operationally unreachable but exercises the defense-in-depth.
#[test]
fn recover_saturates_at_u64_max() {
    let temp_dir = TempDir::new().unwrap();
    let store = open_db(temp_dir.path());
    let me = authority(1);
    let epoch: Epoch = 2;

    let mine = batch_with_seq(u64::MAX);
    let d = mine.digest();
    store.insert::<Batches>(&d, &mine).unwrap();
    let cert =
        cert_with_header(header_with_payload(me.clone(), epoch, IndexMap::from([(d, WORKER_A)])));
    write_block(&store, 1, subdag(vec![cert], epoch));

    let (worker, _tm) = make_worker(store);
    assert_eq!(worker.recover_batch_seq_from_history(Some(me), epoch), u64::MAX);
}
