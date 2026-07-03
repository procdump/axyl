//! The payload that contains all data from consensus to be executed.

use crate::reth_env::RethEnv;
use rayls_infrastructure_types::{ConsensusOutput, SealedHeader};

/// The type for building blocks that extend the canonical tip.
#[derive(Debug)]
pub struct BuildArguments {
    /// State provider.
    pub reth_env: RethEnv,
    /// Output from consensus that contains all the transactions to execute.
    pub output: ConsensusOutput,
    /// Last executed block from the previous consensus output.
    pub parent_header: SealedHeader,
}

impl BuildArguments {
    /// Initialize new instance of [Self].
    pub fn new(reth_env: RethEnv, output: ConsensusOutput, parent_header: SealedHeader) -> Self {
        Self { reth_env, output, parent_header }
    }
}
