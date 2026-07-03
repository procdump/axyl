//! Trait and helpers for accessing epoch transition checkpoints in the consensus DB.

use crate::{tables::EpochTransitionCheckpoints, StoreResult};
use rayls_infrastructure_types::{Database, DbTxMut, Epoch, EpochTransitionCheckpoint};

/// Persistent storage for epoch transition checkpoints.
pub trait CheckpointStore {
    /// Persist a checkpoint for the given epoch.
    fn save_checkpoint(&self, checkpoint: &EpochTransitionCheckpoint) -> StoreResult<()>;

    /// Load the checkpoint for the given epoch, if one exists.
    fn load_checkpoint(&self, epoch: Epoch) -> StoreResult<Option<EpochTransitionCheckpoint>>;

    /// Remove the checkpoint for the given epoch after a successful transition.
    fn clear_checkpoint(&self, epoch: Epoch) -> StoreResult<()>;
}

impl<DB: Database> CheckpointStore for DB {
    fn save_checkpoint(&self, checkpoint: &EpochTransitionCheckpoint) -> StoreResult<()> {
        self.with_write_txn(|txn| {
            txn.insert::<EpochTransitionCheckpoints>(&checkpoint.epoch, checkpoint)?;
            Ok(())
        })
    }

    fn load_checkpoint(&self, epoch: Epoch) -> StoreResult<Option<EpochTransitionCheckpoint>> {
        self.get::<EpochTransitionCheckpoints>(&epoch)
    }

    fn clear_checkpoint(&self, epoch: Epoch) -> StoreResult<()> {
        self.with_write_txn(|txn| {
            txn.remove::<EpochTransitionCheckpoints>(&epoch)?;
            Ok(())
        })
    }
}
