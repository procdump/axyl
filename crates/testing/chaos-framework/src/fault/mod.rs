//! Fault injection primitives.
//!
//! Each fault injector returns a [`FaultGuard`] or [`SelfCleaningGuard`].
//! - [`FaultGuard`]: requires explicit `.recover(&mut cluster)` (for node faults that need the
//!   cluster to restart processes).
//! - [`SelfCleaningGuard`]: cleans up automatically on drop (for network faults that only need to
//!   run a shell command).

pub mod network_latency;
pub mod network_partition;
pub mod node_kill;
pub mod tx_spam;

use crate::cluster::TestCluster;

/// A guard that reverts an injected fault when `.recover()` is called.
///
/// Used for faults that need the cluster reference to recover (e.g., restarting
/// killed nodes). If dropped without calling `.recover()`, a warning is logged.
pub struct FaultGuard {
    cleanup: Option<Box<dyn FnOnce(&mut TestCluster) + Send>>,
}

impl FaultGuard {
    /// Create a new guard with the given cleanup closure.
    pub fn new(cleanup: impl FnOnce(&mut TestCluster) + Send + 'static) -> Self {
        Self { cleanup: Some(Box::new(cleanup)) }
    }

    /// Create a no-op guard that does nothing on drop.
    pub fn noop() -> Self {
        Self { cleanup: None }
    }

    /// Explicitly recover the fault, consuming the guard.
    pub fn recover(mut self, cluster: &mut TestCluster) {
        if let Some(cleanup) = self.cleanup.take() {
            cleanup(cluster);
        }
    }

    /// Disarm the guard, extracting the cleanup closure without running it.
    ///
    /// Use this when composing multiple guards into a single combined guard
    /// (instead of `std::mem::forget` which silently leaks).
    pub fn disarm(mut self) -> Option<Box<dyn FnOnce(&mut TestCluster) + Send>> {
        self.cleanup.take()
    }
}

impl std::fmt::Debug for FaultGuard {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FaultGuard").field("has_cleanup", &self.cleanup.is_some()).finish()
    }
}

impl Drop for FaultGuard {
    fn drop(&mut self) {
        if self.cleanup.is_some() {
            tracing::warn!(
                "FaultGuard dropped without explicit recover(). \
                 Call guard.recover(&mut cluster) before dropping."
            );
        }
    }
}

/// A self-cleaning guard for network faults (`tc`, `iptables`).
///
/// Unlike [`FaultGuard`], this guard does NOT need the cluster to clean up.
/// It runs its cleanup closure automatically on drop, ensuring network rules
/// are always removed even if the test panics.
pub struct SelfCleaningGuard {
    cleanup: Option<Box<dyn FnOnce() + Send>>,
}

impl SelfCleaningGuard {
    /// Create a new self-cleaning guard.
    pub fn new(cleanup: impl FnOnce() + Send + 'static) -> Self {
        Self { cleanup: Some(Box::new(cleanup)) }
    }

    /// Explicitly clean up, consuming the guard.
    pub fn clean(mut self) {
        if let Some(cleanup) = self.cleanup.take() {
            cleanup();
        }
    }
}

impl std::fmt::Debug for SelfCleaningGuard {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SelfCleaningGuard").field("has_cleanup", &self.cleanup.is_some()).finish()
    }
}

impl Drop for SelfCleaningGuard {
    fn drop(&mut self) {
        if let Some(cleanup) = self.cleanup.take() {
            cleanup();
        }
    }
}
