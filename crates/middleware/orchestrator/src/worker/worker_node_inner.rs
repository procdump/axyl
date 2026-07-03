use rayls_consensus_worker::{
    metrics::Metrics, new_worker, quorum_waiter::QuorumWaiter, Worker, WorkerNetworkHandle,
};
use rayls_infrastructure_config::ConsensusConfig;
use rayls_infrastructure_types::{BatchValidation, Database as ConsensusDatabase, WorkerId};
use std::sync::Arc;

#[derive(Debug)]
/// The inner-worker type.
pub(super) struct WorkerNodeInner<CDB> {
    /// The worker's id
    pub(super) id: WorkerId,
    /// The consensus configuration.
    pub(super) consensus_config: ConsensusConfig<CDB>,
    /// The handle to the network.
    pub(super) network_handle: WorkerNetworkHandle,
    /// The batch validator.
    pub(super) validator: Arc<dyn BatchValidation>,
}

impl<CDB: ConsensusDatabase> WorkerNodeInner<CDB> {
    /// Starts the worker node with the provided info.
    ///
    /// If the node is already running then this method will return an error instead.
    ///
    /// Return the task manager for the worker and the [Worker] struct for spawning execution tasks.
    pub(super) async fn new_worker(&mut self) -> eyre::Result<Worker<CDB, QuorumWaiter>> {
        let metrics = Metrics::default();

        let batch_provider = new_worker(
            self.id,
            self.validator.clone(),
            metrics,
            self.consensus_config.clone(),
            self.network_handle.clone(),
        );

        Ok(batch_provider)
    }
}
