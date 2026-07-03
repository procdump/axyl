//! Error types for primary's Proposer task.

use rayls_infrastructure_types::Header;
use tokio::sync::{oneshot, watch};

/// Result alias for [`ProposerError`].
pub(crate) type ProposerResult<T> = Result<T, ProposerError>;

/// Core error variants when executing the output from consensus and extending the canonical block.
#[derive(Debug, thiserror::Error)]
pub(crate) enum ProposerError {
    /// The watch channel that receives the result from executing output on a blocking thread.
    #[error(
        "The watch channel sender for primary's proposer dropped while building the next header."
    )]
    WatchChannelClosed,
    /// The oneshot channel that receives the result from executing output on a blocking thread.
    #[error(
        "The oneshot channel sender inside new header task dropped while builing the next header."
    )]
    OneshotChannelClosed,
    /// Sending error for the proposer to certifier.
    #[error("Proposer failed to send header to certifier.")]
    CertifierSender(#[from] Box<rayls_infrastructure_types::SendError<Header>>),
    /// Error writing to the proposer store.
    #[error("Failed to write new header to proposer store: {0}")]
    StoreError(String),
    /// Error when proposing a header in the past.
    #[error("Failed to propose a header because current timestamp {0} is before last proposed's header timestamp {1}. This is likely due to system clock adjustments.")]
    OldTimestamp(u64, u64),
}

impl From<watch::error::RecvError> for ProposerError {
    fn from(_: watch::error::RecvError) -> Self {
        Self::WatchChannelClosed
    }
}

impl From<oneshot::error::RecvError> for ProposerError {
    fn from(_: oneshot::error::RecvError) -> Self {
        Self::OneshotChannelClosed
    }
}
