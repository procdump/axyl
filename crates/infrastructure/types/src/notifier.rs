//! Notify subscribers - useful for shutdown.

use parking_lot::Mutex;
use std::{
    future::Future,
    pin::Pin,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    task::{Context, Poll, Waker},
};

/// A Noticer is a future that will resolve when the Notifier it is subscribed to is notified.
/// Used for simple notification schemes (like shutdown signals).
/// Does not implement Clone on purpose- you will have race conditions with the Waker if it is
/// cloned.
#[derive(Debug)]
pub struct Noticer {
    lock: Arc<Mutex<(bool, Option<Waker>)>>,
}

/// Maximum number of subscriptions to prevent unbounded memory growth.
const MAX_SUBSCRIPTIONS: usize = 1000;

/// Simple notifier.
///
/// Will hand out a future on a subscribe() call that will resolve after
/// notify() if called.  Can manage any number of "subscribers".
/// Once notify() if called the resolved subscribers will be cleared.
#[derive(Clone, Debug)]
pub struct Notifier {
    noticers: Arc<Mutex<Vec<Noticer>>>,
    notified: Arc<AtomicBool>,
}

impl Notifier {
    /// Create a new empty Notifier.
    pub fn new() -> Self {
        Self {
            noticers: Arc::new(Mutex::new(Vec::new())),
            notified: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Return true if this Notifier has been notified at least once.
    pub fn was_notified(&self) -> bool {
        self.notified.load(Ordering::Acquire)
    }

    /// Get a Noticer that will resolve once this Notifier is notified.
    ///
    /// If the Notifier has already been notified the returned Noticer is
    /// pre-resolved so that `select!` and `.await` on it complete immediately.
    /// This guarantees that subscribing *after* `notify()` never produces a
    /// dead future — a requirement for shutdown signals to remain reliable
    /// regardless of call ordering.
    pub fn subscribe(&self) -> Noticer {
        let already = self.notified.load(Ordering::Acquire);
        let lock = Arc::new(Mutex::new((already, None)));
        let noticer = Noticer { lock: lock.clone() };

        // If already notified the Noticer is immediately resolved — no need to
        // track it for a future `notify()` call.
        if already {
            return noticer;
        }

        let mut noticers = self.noticers.lock();

        // Clean up dropped subscriptions (where Arc strong count is 1, meaning
        // subscriber dropped their Noticer) to prevent unbounded accumulation
        noticers.retain(|n| Arc::strong_count(&n.lock) > 1);

        // Enforce maximum subscriptions limit
        if noticers.len() >= MAX_SUBSCRIPTIONS {
            // Remove oldest subscriptions to make room
            let excess = noticers.len() - MAX_SUBSCRIPTIONS + 1;
            noticers.drain(0..excess);
        }

        noticers.push(Noticer { lock });
        noticer
    }

    /// Resolve all the subscribed Noticers.
    pub fn notify(&self) {
        self.notified.store(true, Ordering::Release);
        let mut wakers = vec![];
        let mut noticers = self.noticers.lock();
        for n in noticers.drain(..) {
            let mut guard = n.lock.lock();
            if let Some(wake) = guard.1.take() {
                wakers.push(wake);
            }
            guard.0 = true;
        }
        // Wake everyone up after all flags set to true to avoid races in noticiers.
        for wake in wakers {
            wake.wake();
        }
    }

    /// You have to re subscribe after invoking silence
    pub fn reset(&self) {
        self.notified.store(false, Ordering::Release);
        self.noticers.lock().drain(..);
    }
}

impl Default for Notifier {
    fn default() -> Self {
        Self::new()
    }
}

impl Noticer {
    /// Return true of this Noticer has been noticed.
    /// I.e. the future has or will resolve.
    pub fn noticed(&self) -> bool {
        let guard = self.lock.lock();
        guard.0
    }

    fn poll_int(&self, cx: &mut Context<'_>) -> Poll<()> {
        let mut guard = self.lock.lock();
        if guard.0 {
            guard.1 = None;
            Poll::Ready(())
        } else {
            guard.1 = Some(cx.waker().clone());
            Poll::Pending
        }
    }
}

impl Future for Noticer {
    type Output = ();

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let this = self.get_mut();
        this.poll_int(cx)
    }
}

impl Future for &Noticer {
    type Output = ();

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let this = self.get_mut();
        this.poll_int(cx)
    }
}

#[cfg(test)]
mod test {
    use crate::Notifier;
    use parking_lot::Mutex;
    use std::{sync::Arc, time::Duration};

    #[tokio::test]
    async fn test_notifier() {
        let b1 = Arc::new(Mutex::new(false));
        let b1_clone = b1.clone();
        let b2 = Arc::new(Mutex::new(false));
        let b2_clone = b2.clone();
        let b3 = Arc::new(Mutex::new(false));
        let b3_clone = b3.clone();
        let notifier = Notifier::new();
        let n1 = notifier.subscribe();
        let n2 = notifier.subscribe();
        let n3 = notifier.subscribe();
        tokio::spawn(async move {
            n1.await;
            *b1_clone.lock() = true;
        });
        tokio::spawn(async move {
            n2.await;
            *b2_clone.lock() = true;
        });
        tokio::spawn(async move {
            n3.await;
            *b3_clone.lock() = true;
        });
        assert!(!(*b1.lock()));
        assert!(!(*b2.lock()));
        assert!(!(*b3.lock()));
        tokio::time::sleep(Duration::from_secs(3)).await;
        assert!(!(*b1.lock()));
        assert!(!(*b2.lock()));
        assert!(!(*b3.lock()));
        notifier.notify();
        // Make sure the background tasks get a chance to run.
        for _ in 0..10 {
            tokio::task::yield_now().await;
        }
        assert!(*b1.lock());
        assert!(*b2.lock());
        assert!(*b3.lock());
    }

    /// Subscribing after notify() must produce an immediately-resolved Noticer.
    #[tokio::test]
    async fn test_subscribe_after_notify() {
        let notifier = Notifier::new();
        notifier.notify();

        // subscribe after notify — must resolve immediately
        let late = notifier.subscribe();
        assert!(late.noticed());

        let resolved = Arc::new(Mutex::new(false));
        let resolved_clone = resolved.clone();
        tokio::spawn(async move {
            late.await;
            *resolved_clone.lock() = true;
        });
        tokio::task::yield_now().await;
        assert!(*resolved.lock());
    }
}
