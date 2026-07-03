use parking_lot::{Mutex, MutexGuard};
use std::{
    collections::{hash_map::DefaultHasher, HashMap},
    future::Future,
    hash::{Hash, Hasher},
    mem,
    pin::Pin,
    sync::atomic::{AtomicU64, AtomicUsize, Ordering},
    task::{Context, Poll},
};
use tokio::sync::oneshot;

type Registrations<V> = Vec<oneshot::Sender<V>>;

/// Rayls: Operations between cleanup attempts.
const CLEANUP_INTERVAL_OPS: u64 = 100;

/// A thread-safe pub/sub notification system for asynchronously waiting on key-value pairs.
#[derive(Debug)]
pub struct NotifyRead<K, V> {
    pending: Vec<Mutex<HashMap<K, Registrations<V>>>>,
    count_pending: AtomicUsize,
    /// Counter for operations since last cleanup
    ops_since_cleanup: AtomicU64,
}

impl<K: Eq + Hash + Clone, V: Clone> NotifyRead<K, V> {
    /// Create a new instance of `Self`.
    pub fn new() -> Self {
        let pending = (0..255).map(|_| Default::default()).collect();
        let count_pending = Default::default();
        let ops_since_cleanup = AtomicU64::new(0);
        Self { pending, count_pending, ops_since_cleanup }
    }

    /// Notify waiters and return remaining pending count.
    pub fn notify(&self, key: &K, value: &V) -> usize {
        // Increment operation counter and check if cleanup is needed
        let ops = self.ops_since_cleanup.fetch_add(1, Ordering::Relaxed);
        if ops >= CLEANUP_INTERVAL_OPS {
            // Reset counter and trigger cleanup
            self.ops_since_cleanup.store(0, Ordering::Relaxed);
            self.cleanup_all();
        }

        let registrations = self.pending(key).remove(key);
        let Some(registrations) = registrations else {
            return self.count_pending.load(Ordering::Relaxed);
        };
        let rem = self.count_pending.fetch_sub(registrations.len(), Ordering::Relaxed);
        for registration in registrations {
            registration.send(value.clone()).ok();
        }
        rem
    }

    pub fn register_one(&self, key: &K) -> Registration<'_, K, V> {
        self.count_pending.fetch_add(1, Ordering::Relaxed);
        let (sender, receiver) = oneshot::channel();
        self.register(key, sender);
        Registration { this: self, registration: Some((key.clone(), receiver)) }
    }

    pub fn register_all(&self, keys: Vec<K>) -> Vec<Registration<'_, K, V>> {
        self.count_pending.fetch_add(keys.len(), Ordering::Relaxed);
        let mut registrations = vec![];
        for key in keys.iter() {
            let (sender, receiver) = oneshot::channel();
            self.register(key, sender);
            let registration =
                Registration { this: self, registration: Some((key.clone(), receiver)) };
            registrations.push(registration);
        }
        registrations
    }

    fn register(&self, key: &K, sender: oneshot::Sender<V>) {
        self.pending(key).entry(key.clone()).or_default().push(sender);
    }

    fn pending(&self, key: &K) -> MutexGuard<'_, HashMap<K, Registrations<V>>> {
        let mut state = DefaultHasher::new();
        key.hash(&mut state);
        let hash = state.finish();
        let pending = self.pending.get((hash % self.pending.len() as u64) as usize).unwrap();
        pending.lock()
    }

    pub fn num_pending(&self) -> usize {
        self.count_pending.load(Ordering::Relaxed)
    }

    /// Remove stale registrations from all shards and return count cleaned.
    pub fn cleanup_all(&self) -> usize {
        let mut total_cleaned = 0usize;

        for shard in &self.pending {
            let mut pending = shard.lock();
            let mut empty_keys = Vec::new();

            for (key, registrations) in pending.iter_mut() {
                let old_len = registrations.len();
                registrations.retain(|s| !s.is_closed());
                let cleaned = old_len - registrations.len();
                total_cleaned += cleaned;

                if registrations.is_empty() {
                    empty_keys.push(key.clone());
                }
            }

            // Remove empty entries
            for key in empty_keys {
                pending.remove(&key);
            }
        }

        if total_cleaned > 0 {
            self.count_pending.fetch_sub(total_cleaned, Ordering::Relaxed);
        }

        total_cleaned
    }

    fn cleanup(&self, key: &K) {
        let mut pending = self.pending(key);
        // it is possible that registration was fulfilled before we get here
        let Some(registrations) = pending.get_mut(key) else {
            return;
        };
        let mut count_deleted = 0usize;
        registrations.retain(|s| {
            let delete = s.is_closed();
            if delete {
                count_deleted += 1;
            }
            !delete
        });
        self.count_pending.fetch_sub(count_deleted, Ordering::Relaxed);
        if registrations.is_empty() {
            pending.remove(key);
        }
    }
}

/// Registration resolves to the value but also provides safe cancellation
/// When Registration is dropped before it is resolved, we de-register from the pending list
#[derive(Debug)]
pub struct Registration<'a, K: Eq + Hash + Clone, V: Clone> {
    this: &'a NotifyRead<K, V>,
    registration: Option<(K, oneshot::Receiver<V>)>,
}

impl<K: Eq + Hash + Clone + Unpin, V: Clone + Unpin> Future for Registration<'_, K, V> {
    type Output = V;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let receiver = self
            .registration
            .as_mut()
            .map(|(_key, receiver)| receiver)
            .expect("poll can not be called after drop");
        let poll = Pin::new(receiver).poll(cx);
        if poll.is_ready() {
            // When polling complete we no longer need to cancel
            self.registration.take();
        }
        poll.map(|r| r.expect("Sender never drops when registration is pending"))
    }
}

impl<K: Eq + Hash + Clone, V: Clone> Drop for Registration<'_, K, V> {
    fn drop(&mut self) {
        if let Some((key, receiver)) = self.registration.take() {
            mem::drop(receiver);
            // Receiver is dropped before cleanup
            self.this.cleanup(&key)
        }
    }
}
impl<K: Eq + Hash + Clone, V: Clone> Default for NotifyRead<K, V> {
    fn default() -> Self {
        Self::new()
    }
}

// Note: cleanup_all is O(n) where n is the number of pending registrations.
// With CLEANUP_INTERVAL_OPS set high enough (1000), this amortizes the cost.

#[cfg(test)]
mod tests {
    use super::*;
    use futures::future::join_all;

    #[tokio::test]
    async fn test_notify_read() {
        let notify_read = NotifyRead::<u64, u64>::new();
        let mut registrations = notify_read.register_all(vec![1, 2, 3]);
        assert_eq!(3, notify_read.count_pending.load(Ordering::Relaxed));
        registrations.pop();
        assert_eq!(2, notify_read.count_pending.load(Ordering::Relaxed));
        notify_read.notify(&2, &2);
        notify_read.notify(&1, &1);
        let reads = join_all(registrations).await;
        assert_eq!(0, notify_read.count_pending.load(Ordering::Relaxed));
        assert_eq!(reads, vec![1, 2]);
        // ensure cleanup is done correctly
        for pending in &notify_read.pending {
            assert!(pending.lock().is_empty());
        }
    }
}
