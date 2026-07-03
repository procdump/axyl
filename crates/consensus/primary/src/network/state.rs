use crate::network::{AuthEquivocationMap, PrimaryResponse};
use parking_lot::Mutex;
use rayls_infrastructure_types::{AuthorityIdentifier, Epoch, HeaderDigest, Round};
use std::{sync::Arc, time::Duration};
use tokio::time::Instant;
use tracing::warn;

/// TTL for InFlight entries if Drop doesn't fire (above 10s req-resp timeout).
pub(super) const IN_FLIGHT_TTL: Duration = Duration::from_secs(15);

/// Per-authority vote state for equivocation detection and response caching.
#[derive(Clone, Debug)]
#[allow(clippy::large_enum_variant)]
pub(crate) enum AuthVoteState {
    InFlight {
        #[allow(dead_code)]
        epoch: Epoch,
        round: Round,
        #[allow(dead_code)]
        digest: HeaderDigest,
        created_at: Instant,
    },
    Completed {
        epoch: Epoch,
        round: Round,
        digest: HeaderDigest,
        response: Option<PrimaryResponse>,
    },
}

impl AuthVoteState {
    pub(crate) fn round(&self) -> Round {
        match self {
            Self::InFlight { round, .. } | Self::Completed { round, .. } => *round,
        }
    }
}

/// RAII guard that transitions InFlight -> Completed on all exit paths.
pub(crate) struct InFlightGuard {
    cache: Arc<Mutex<AuthEquivocationMap>>,
    author: AuthorityIdentifier,
    epoch: Epoch,
    round: Round,
    digest: HeaderDigest,
    completed: bool,
}

impl InFlightGuard {
    pub(crate) fn new(
        cache: Arc<Mutex<AuthEquivocationMap>>,
        author: AuthorityIdentifier,
        epoch: Epoch,
        round: Round,
        digest: HeaderDigest,
    ) -> Self {
        Self { cache, author, epoch, round, digest, completed: false }
    }

    /// Store the vote result and mark as completed.
    pub(crate) fn complete(mut self, response: PrimaryResponse) {
        {
            let mut cache = self.cache.lock();
            // only write if we haven't been superseded by a newer round
            let superseded = cache.get(&self.author).is_some_and(|s| s.round() > self.round);
            if !superseded {
                cache.insert(
                    self.author.clone(),
                    AuthVoteState::Completed {
                        epoch: self.epoch,
                        round: self.round,
                        digest: self.digest,
                        response: Some(response),
                    },
                );
            }
        }
        self.completed = true;
    }
}

impl Drop for InFlightGuard {
    fn drop(&mut self) {
        if self.completed {
            return;
        }
        let mut cache = self.cache.lock();
        // evict only if still our InFlight; removing (not rewriting as Completed { None })
        // lets the next request re-enter vote_inner cleanly instead of being re-processed
        if let Some(AuthVoteState::InFlight { round, .. }) = cache.get(&self.author) {
            if *round == self.round {
                cache.remove(&self.author);
                warn!(
                    target: "primary::handler",
                    author = %self.author,
                    round = self.round,
                    "InFlight guard dropped without completion, entry evicted"
                );
            }
        }
    }
}
