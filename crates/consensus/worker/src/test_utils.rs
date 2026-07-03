//! Test utilities.

use crate::{
    quorum_waiter::{QuorumWaiterError, QuorumWaiterTrait},
    WorkerNetworkHandle, WorkerRequest, WorkerResponse,
};
use rand::rngs::StdRng;
use rayls_consensus_network::types::{NetworkCommand, NetworkHandle};
use rayls_infrastructure_types::{
    Batch, BlockHash, BlsKeypair, BlsPublicKey, SealedBatch, TaskManager, TaskSpawner,
};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::sync::{mpsc, oneshot, Mutex as TokioMutex};

#[derive(Clone, Debug)]
/// Test quorum waiter.
pub struct TestMakeBlockQuorumWaiter(pub Arc<Mutex<Option<SealedBatch>>>);
impl TestMakeBlockQuorumWaiter {
    /// New `Self` for test.
    pub fn new_test() -> Self {
        Self(Arc::new(Mutex::new(None)))
    }
}
impl QuorumWaiterTrait for TestMakeBlockQuorumWaiter {
    fn verify_batch(
        &self,
        batch: SealedBatch,
        _timeout: Duration,
        task_spawner: &TaskSpawner,
    ) -> oneshot::Receiver<Result<(), QuorumWaiterError>> {
        let data = self.0.clone();
        let (tx, rx) = oneshot::channel();
        let task_name = format!("qw-test-{}", batch.digest());
        task_spawner.spawn_task(task_name, async move {
            *data.lock().unwrap() = Some(batch);
            tx.send(Ok(()))
        });
        rx
    }
}

#[derive(Clone, Debug)]
pub struct TestRequestBatchesNetwork {
    // Worker name -> batch digests it has -> batches.
    data: Arc<TokioMutex<HashMap<BlsPublicKey, HashMap<BlockHash, Batch>>>>,
    // Per-peer artificial response delay, modeling a congested peer under load.
    delays: Arc<TokioMutex<HashMap<BlsPublicKey, Duration>>>,
    handle: WorkerNetworkHandle,
}

impl Default for TestRequestBatchesNetwork {
    fn default() -> Self {
        Self::new()
    }
}

impl TestRequestBatchesNetwork {
    pub fn new() -> Self {
        let data: Arc<TokioMutex<HashMap<BlsPublicKey, HashMap<BlockHash, Batch>>>> =
            Arc::new(TokioMutex::new(HashMap::new()));
        let delays: Arc<TokioMutex<HashMap<BlsPublicKey, Duration>>> =
            Arc::new(TokioMutex::new(HashMap::new()));
        let data_clone = data.clone();
        let delays_clone = delays.clone();
        let (tx, mut rx) = mpsc::channel(100);
        let task_manager = TaskManager::default();
        let handle = WorkerNetworkHandle::new(
            NetworkHandle::new(tx),
            task_manager.get_spawner(),
            1024 * 1024,
        );
        tokio::spawn(async move {
            let _owned = task_manager;
            while let Some(r) = rx.recv().await {
                match r {
                    NetworkCommand::ConnectedPeers { reply } => {
                        reply.send(data_clone.lock().await.keys().copied().collect()).unwrap();
                    }
                    NetworkCommand::SendRequest {
                        peer,
                        request:
                            WorkerRequest::RequestBatches { batch_digests: digests, max_response_size },
                        reply,
                    } => {
                        // Serve each request on its own task so a delayed (congested) peer
                        // does not stall replies to the others.
                        let data_task = data_clone.clone();
                        let delays_task = delays_clone.clone();
                        tokio::spawn(async move {
                            let delay =
                                delays_task.lock().await.get(&peer).copied().unwrap_or_default();
                            if !delay.is_zero() {
                                tokio::time::sleep(delay).await;
                            }

                            // Simulate the server-side response size limit in RequestBatches.
                            const MAX_READ_BLOCK_DIGESTS: usize = 5;
                            let mut batches = Vec::new();
                            let mut total_size = 0;
                            let guard = data_task.lock().await;
                            for digests_chunk in digests.chunks(MAX_READ_BLOCK_DIGESTS) {
                                for digest in digests_chunk {
                                    if let Some(batch) =
                                        guard.get(&peer).and_then(|b| b.get(digest))
                                    {
                                        let batch_size = batch.size();
                                        if total_size + batch_size <= max_response_size {
                                            batches.push(batch.clone());
                                            total_size += batch_size;
                                        } else {
                                            break;
                                        }
                                    }
                                }
                            }
                            drop(guard);

                            let _ = reply.send(Ok(WorkerResponse::RequestBatches(batches)));
                        });
                    }
                    _ => {}
                }
            }
        });
        Self { data, delays, handle }
    }

    pub async fn put(&mut self, keys: &[u8], batch: Batch) {
        for key in keys {
            let key = test_pk(*key);
            let mut guard = self.data.lock().await;
            let entry = guard.entry(key).or_default();
            entry.insert(batch.digest(), batch.clone());
        }
    }

    pub fn handle(&self) -> WorkerNetworkHandle {
        self.handle.clone()
    }

    /// Set an artificial response delay for the peer `key`. A delay beyond the per-peer request
    /// timeout makes the peer behave as unresponsive.
    pub async fn set_delay(&self, key: u8, delay: Duration) {
        self.delays.lock().await.insert(test_pk(key), delay);
    }
}

fn test_pk(i: u8) -> BlsPublicKey {
    use rand::SeedableRng;
    let mut rng = StdRng::from_seed([i; 32]);
    *BlsKeypair::generate(&mut rng).public()
}
