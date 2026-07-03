//! Origin of a consensus output on its way to execution.

/// Where a [`ConsensusOutput`](crate::ConsensusOutput) was delivered from before it reached the
/// execution engine. Threaded through the engine input channel purely for tracing: it lets the
/// "output executed" / "dropping output" logs say which path fed the output, which is invaluable
/// for diagnosing dual-delivery races (live relay vs. catch-up replay vs. epoch close).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CameFrom {
    /// Live relay: `detect_epoch_boundary` forwarding non-boundary outputs to the engine.
    DetectEpochBoundary,
    /// Startup catch-up: replay of committed-but-unexecuted outputs (`get_missing_consensus`).
    GetMissingConsensus,
    /// Epoch close: the boundary output sent during the sequential transition.
    AwaitEpochExecution,
    /// Backward-compatible free-function entry point (batch-builder tests, etc.).
    FreeFn,
    /// Tests.
    Test,
}

impl std::fmt::Display for CameFrom {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            CameFrom::DetectEpochBoundary => "detect_epoch_boundary",
            CameFrom::GetMissingConsensus => "get_missing_consensus",
            CameFrom::AwaitEpochExecution => "await_epoch_execution",
            CameFrom::FreeFn => "free_fn",
            CameFrom::Test => "test",
        })
    }
}
