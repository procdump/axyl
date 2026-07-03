use crate::{epoch_manager::WORKER_TASK_BASE, worker::worker_node_inner::WorkerNodeInner};
use rayls_consensus_worker::{quorum_waiter::QuorumWaiter, Worker, WorkerNetworkHandle};
use rayls_infrastructure_config::ConsensusConfig;
use rayls_infrastructure_types::{BatchValidation, Database as ConsensusDatabase, WorkerId};
use std::sync::Arc;
use tokio::sync::RwLock;

#[derive(Clone, Debug)]
pub struct WorkerNode<CDB> {
    internal: Arc<RwLock<WorkerNodeInner<CDB>>>,
}

impl<CDB: ConsensusDatabase> WorkerNode<CDB> {
    pub fn new(
        id: WorkerId,
        consensus_config: ConsensusConfig<CDB>,
        network_handle: WorkerNetworkHandle,
        validator: Arc<dyn BatchValidation>,
    ) -> WorkerNode<CDB> {
        let inner = WorkerNodeInner { id, consensus_config, network_handle, validator };

        Self { internal: Arc::new(RwLock::new(inner)) }
    }

    pub async fn new_worker(&self) -> eyre::Result<Worker<CDB, QuorumWaiter>> {
        let mut guard = self.internal.write().await;
        guard.new_worker().await
    }

    /// Return the workers network handle.
    pub async fn network_handle(&self) -> WorkerNetworkHandle {
        let guard = self.internal.read().await;
        guard.network_handle.clone()
    }

    /// Return the worker id.
    pub async fn id(&self) -> WorkerId {
        let guard = self.internal.read().await;
        guard.id
    }
}

/// Helper method to create a worker's task manager name by id.
pub fn worker_task_manager_name(id: WorkerId) -> String {
    format!("{WORKER_TASK_BASE} - {id}")
}
