use alloy::primitives::B256;
use parking_lot::Mutex;
use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
};
use tracing::{info, warn};

/// Maximum number of nonce_too_high retries before a digest is kept permanently.
const MAX_NONCE_TOO_HIGH_RETRIES: u8 = 3;

/// Deduplication registry for executed batch digests.
#[derive(Clone, Debug, Default)]
pub struct ExecutedBatchRegistry {
    digests: Arc<Mutex<HashSet<B256>>>,
    retry_counts: Arc<Mutex<HashMap<B256, u8>>>,
}

impl ExecutedBatchRegistry {
    /// Create from a pre-populated set of digests.
    pub fn from_digests(digests: HashSet<B256>) -> Self {
        Self {
            digests: Arc::new(Mutex::new(digests)),
            retry_counts: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Register a batch digest. Return false if already present.
    pub fn try_register(&self, batch_digest: B256, output_digest: B256) -> bool {
        let result = self.digests.lock().insert(batch_digest);
        if !result {
            info!(
                target: "executed_batch_registry",
                batch_digest = ?batch_digest,
                output_digest = ?output_digest,
                "skipping duplicate batch digest"
            );
        }
        result
    }

    /// Check if a batch digest has already been registered without inserting it.
    pub fn contains(&self, batch_digest: &B256) -> bool {
        self.digests.lock().contains(batch_digest)
    }

    /// Remove a digest so the batch can be retried (bounded).
    ///
    /// Return false when the retry cap is reached, keeping the digest permanently.
    pub fn drop_digest(&self, batch_digest: B256) -> bool {
        let mut retries = self.retry_counts.lock();
        let count = retries.entry(batch_digest).or_insert(0);
        if *count >= MAX_NONCE_TOO_HIGH_RETRIES {
            warn!(
                target: "executed_batch_registry",
                ?batch_digest,
                "max retries reached, keeping digest"
            );
            return false;
        }
        *count += 1;
        self.digests.lock().remove(&batch_digest);
        true
    }
}
