//! Error types for Rayls Network Engine.

use rayls_execution_evm::error::RaylsRethError;
use rayls_infrastructure_types::{AuthorityIdentifier, Epoch, Round};
use tokio::sync::oneshot;

/// Result alias for [`RLEngineError`].
pub(crate) type EngineResult<T> = Result<T, RLEngineError>;

/// Core error variants when executing the output from consensus and extending the canonical block.
#[derive(Debug, thiserror::Error)]
pub enum RLEngineError {
    /// Error from Reth.
    #[error(transparent)]
    Reth(#[from] RaylsRethError),
    /// The oneshot channel sender dropped during output execution.
    #[error("The oneshot channel sender inside blocking task dropped during output execution.")]
    ChannelClosed,
    /// The queued output that triggered the engine build was not found.
    #[error("Engine trying to build from empty queue.")]
    EmptyQueue,
    /// The consensus stream has closed.
    #[error("Consensus output stream closed.")]
    ConsensusOutputStreamClosed,
    /// The output's leader is unknown.
    #[error("Unknown authority for block rewards {0}")]
    UnknownAuthority(AuthorityIdentifier),
    /// A panic occurred inside the blocking execution task.
    #[error("Panic in execution task: {0}")]
    ExecutionPanic(String),
    /// Divergent consensus content at an already-executed `(epoch, round)`.
    ///
    /// The engine keys dedup and ordering on the deterministic `(epoch, leader_round)`, so a
    /// different subdag at an executed position is a fork: halt and resync rather than silently
    /// extend a divergent chain.
    #[error("consensus fork detected at epoch {epoch} round {round}: divergent content at an already-executed position")]
    ConsensusFork {
        /// Leader epoch of the divergent output.
        epoch: Epoch,
        /// Leader round of the divergent output.
        round: Round,
    },
}

impl From<oneshot::error::RecvError> for RLEngineError {
    fn from(_: oneshot::error::RecvError) -> Self {
        Self::ChannelClosed
    }
}
