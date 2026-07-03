// SPDX-License-Identifier: BUSL-1.1
//! Process consensus output and execute every transaction.

mod errors;
pub mod subscriber;
use crate::subscriber::spawn_subscriber;
pub use errors::{SubscriberError, SubscriberResult};
use rayls_consensus_primary::{network::PrimaryNetworkHandle, ConsensusBus};
use rayls_infrastructure_config::ConsensusConfig;
use rayls_infrastructure_types::{CameFrom, ConsensusOutput, Database, Noticer, TaskManager};
use tokio::sync::mpsc;
use tracing::info;

/// A client subscribing to the consensus output and forwarding every transaction to be executed by
/// the engine.
#[derive(Debug)]
pub struct Executor;

impl Executor {
    /// Spawn a new client subscriber.
    pub fn spawn<DB: Database>(
        config: ConsensusConfig<DB>,
        rx_shutdown: Noticer,
        consensus_bus: ConsensusBus,
        task_manager: &TaskManager,
        network: PrimaryNetworkHandle,
        to_engine: mpsc::Sender<(CameFrom, ConsensusOutput)>,
        execution_replay_completed: tokio::sync::watch::Sender<()>,
    ) {
        // Spawn the subscriber.
        spawn_subscriber(
            config,
            rx_shutdown,
            consensus_bus,
            task_manager,
            network,
            to_engine,
            execution_replay_completed,
        );

        info!("Consensus subscriber successfully started");
    }
}

#[cfg(test)]
mod clippy {
    use eyre as _;
    use rayls_consensus_network as _;
    use rayls_execution_evm as _;
    use rayls_testing_test_utils as _;
}
