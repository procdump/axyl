// SPDX-License-Identifier: BUSL-1.1
// Library for managing all components used by a full-node in a single process.

use rayls_infrastructure_config::RaylsDirs;
use tokio::runtime::Builder;
use tracing::instrument;
pub mod engine;
pub mod epoch_manager;
pub mod primary;
pub mod types;
pub mod worker;

use crate::{
    engine::RaylsBuilder,
    epoch_manager::{open_consensus_db, EpochManager},
};

/// Launch all components for the node.
///
/// Worker, Primary, and Execution.
/// This will possibly "loop" to launch multiple times in response to
/// a nodes mode changes.  This ensures a clean state and fresh tasks
/// when switching modes.
#[instrument(level = "info", skip_all)]
pub fn launch_node<P>(
    builder: RaylsBuilder,
    rayls_datadir: P,
    passphrase: String,
) -> eyre::Result<()>
where
    P: RaylsDirs + Clone + 'static,
{
    let runtime = Builder::new_multi_thread()
        .thread_name("rayls-network")
        .enable_io()
        .enable_time()
        .build()?;

    let res = runtime.block_on(async move {
        let consensus_db = open_consensus_db(&rayls_datadir, &builder.consensus_db_config)?;
        let mut epoch_manager =
            EpochManager::new(builder, rayls_datadir, passphrase, consensus_db)?;
        epoch_manager.run().await
    });

    // return result after shutdown
    res
}

#[cfg(test)]
#[path = "tests/epoch_transition_tests.rs"]
mod epoch_transition_tests;

#[cfg(test)]
#[path = "tests/batch_seq_gate_tests.rs"]
mod batch_seq_gate_tests;

#[cfg(test)]
mod clippy {
    use rand as _;
    use rayls_infrastructure_network_types as _;
    use rayls_testing_test_utils as _;
}
