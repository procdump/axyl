//! Hierarchical type to hold tasks spawned for a worker in the network.
use rayls_consensus_primary::{
    consensus::ConsensusMetrics, network::PrimaryNetworkHandle, ConsensusBus, Primary,
    StateSynchronizer,
};
use rayls_consensus_primary_metrics::Metrics;
use rayls_infrastructure_config::ConsensusConfig;
use rayls_infrastructure_types::{
    AuthorityIdentifier, CameFrom, Committee, ConsensusOutput, Database as ConsensusDatabase,
    Notifier, TaskManager,
};
use std::sync::Arc;
use tokio::sync::{mpsc, RwLock};

use crate::primary::primary_node_inner::PrimaryNodeInner;

#[derive(Clone, Debug)]
pub struct PrimaryNode<CDB> {
    internal: Arc<RwLock<PrimaryNodeInner<CDB>>>,
}

impl<CDB: ConsensusDatabase> PrimaryNode<CDB> {
    pub fn new(
        consensus_config: ConsensusConfig<CDB>,
        consensus_bus: ConsensusBus,
        network: PrimaryNetworkHandle,
        rayls_consensus_state_sync: StateSynchronizer<CDB>,
    ) -> PrimaryNode<CDB> {
        let primary = Primary::new(
            consensus_config.clone(),
            &consensus_bus,
            network,
            rayls_consensus_state_sync,
        );

        let inner = PrimaryNodeInner { consensus_config, consensus_bus, primary };

        Self { internal: Arc::new(RwLock::new(inner)) }
    }

    pub async fn start(
        &self,
        task_manager: &TaskManager,
        to_inner: mpsc::Sender<(CameFrom, ConsensusOutput)>,
        execution_replay_completed: tokio::sync::watch::Sender<()>,
    ) -> eyre::Result<()>
    where
        CDB: ConsensusDatabase,
    {
        let mut guard = self.internal.write().await;
        guard.start(task_manager, to_inner, execution_replay_completed).await
    }

    pub async fn shutdown(&self) {
        let guard = self.internal.write().await;
        guard.consensus_config.shutdown().notify();
    }

    /// Return the consensus metrics.
    pub async fn consensus_metrics(&self) -> Arc<ConsensusMetrics> {
        self.internal.read().await.consensus_bus.consensus_metrics()
    }

    /// Return the primary metrics.
    pub async fn primary_metrics(&self) -> Arc<Metrics> {
        self.internal.read().await.consensus_bus.primary_metrics()
    }

    /// Return a copy of the primaries consensus bus.
    pub async fn consensus_bus(&self) -> ConsensusBus {
        self.internal.read().await.consensus_bus.clone()
    }

    /// Return the WAN handle if the primary p2p is runnig.
    pub async fn network_handle(&self) -> PrimaryNetworkHandle {
        self.internal.read().await.primary.network_handle().clone()
    }

    /// Return the [StateSynchronizer]
    pub async fn rayls_consensus_state_sync(&self) -> StateSynchronizer<CDB> {
        self.internal.read().await.primary.rayls_consensus_state_sync()
    }

    /// Return the [Noticer] shutdown for consensus.
    pub async fn shutdown_signal(&self) -> Notifier {
        self.internal.read().await.consensus_config.shutdown().clone()
    }

    /// Returns the current committee.
    pub async fn current_committee(&self) -> Committee {
        self.internal.read().await.consensus_config.committee().clone()
    }

    /// Return the authority identifier for this node, if it is a committee member.
    pub async fn authority_id(&self) -> Option<AuthorityIdentifier> {
        self.internal.read().await.consensus_config.authority_id()
    }
}
