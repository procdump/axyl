use crate::{tables::BatchOrderingState as TableBatchOrderingState, StoreResult};
use rayls_infrastructure_types::{batch_ordering::BatchOrderingState, Database};

/// The ordering state key - always 0 since we store one epoch's worth at a time.
pub const ORDERING_KEY: u8 = 0;

/// Trait for persisting batch ordering state.
pub trait BatchOrderingStore {
    /// Write the entire batch ordering state for the current epoch.
    fn write_batch_ordering_state(&self, ordering: &BatchOrderingState) -> StoreResult<()>;

    /// Read the batch ordering state.
    fn read_batch_ordering_state(&self) -> StoreResult<Option<BatchOrderingState>>;
}

impl<DB: Database> BatchOrderingStore for DB {
    fn write_batch_ordering_state(&self, ordering: &BatchOrderingState) -> StoreResult<()> {
        self.insert::<TableBatchOrderingState>(&ORDERING_KEY, ordering)
    }

    fn read_batch_ordering_state(&self) -> StoreResult<Option<BatchOrderingState>> {
        self.get::<TableBatchOrderingState>(&ORDERING_KEY)
    }
}
