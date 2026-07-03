//! Scenario composition and execution.
//!
//! Scenarios combine fault injectors, wait conditions, and verifiers into
//! repeatable chaos test sequences.

use crate::{
    cluster::TestCluster,
    fault::FaultGuard,
    verify::{block_consistency, chain_advancing, nonce_monotonicity},
};
use std::time::Duration;
use tracing::info;

/// A single step in a chaos scenario.
enum Step {
    /// Inject a fault via a closure that returns a guard.
    Inject {
        name: String,
        inject_fn: Box<dyn FnOnce(&mut TestCluster) -> eyre::Result<FaultGuard> + Send>,
    },
    /// Wait for the chain to advance by at least N blocks.
    WaitAdvancing { min_blocks: u64, timeout: Duration },
    /// Sleep for a fixed duration.
    Sleep(Duration),
    /// Recover all outstanding fault guards.
    Recover,
    /// Verify block consistency across all live nodes.
    VerifyBlockConsistency,
    /// Verify nonce monotonicity (no forks).
    VerifyNonceMonotonicity,
}

/// Builder for composing chaos scenarios.
pub struct ScenarioBuilder {
    name: String,
    steps: Vec<Step>,
}

impl ScenarioBuilder {
    /// Start building a new scenario.
    pub fn new(name: impl Into<String>) -> Self {
        Self { name: name.into(), steps: Vec::new() }
    }

    /// Inject a node kill fault targeting a specific validator index.
    pub fn kill_node(mut self, index: usize) -> Self {
        let name = format!("kill_node_{index}");
        self.steps.push(Step::Inject {
            name,
            inject_fn: Box::new(move |cluster| {
                crate::fault::node_kill::kill_validator(cluster, index)
            }),
        });
        self
    }

    /// Inject a random node kill fault.
    pub fn kill_random_node(mut self) -> Self {
        self.steps.push(Step::Inject {
            name: "kill_random_node".to_string(),
            inject_fn: Box::new(crate::fault::node_kill::kill_random_validator),
        });
        self
    }

    /// Wait for the chain to advance by at least `min_blocks`.
    pub fn wait_advancing(mut self, min_blocks: u64) -> Self {
        self.steps.push(Step::WaitAdvancing { min_blocks, timeout: Duration::from_secs(60) });
        self
    }

    /// Wait for the chain to advance with a custom timeout.
    pub fn wait_advancing_with_timeout(mut self, min_blocks: u64, timeout: Duration) -> Self {
        self.steps.push(Step::WaitAdvancing { min_blocks, timeout });
        self
    }

    /// Sleep for a fixed duration.
    pub fn sleep(mut self, duration: Duration) -> Self {
        self.steps.push(Step::Sleep(duration));
        self
    }

    /// Recover all killed/faulted nodes.
    pub fn recover(mut self) -> Self {
        self.steps.push(Step::Recover);
        self
    }

    /// Verify that all live nodes have identical blocks.
    pub fn verify_block_consistency(mut self) -> Self {
        self.steps.push(Step::VerifyBlockConsistency);
        self
    }

    /// Verify nonce monotonicity (no forks detected).
    pub fn verify_nonce_monotonicity(mut self) -> Self {
        self.steps.push(Step::VerifyNonceMonotonicity);
        self
    }
}

impl std::fmt::Debug for ScenarioBuilder {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ScenarioBuilder")
            .field("name", &self.name)
            .field("steps", &self.steps.len())
            .finish()
    }
}

impl ScenarioBuilder {
    /// Build and immediately run the scenario against the given cluster.
    pub fn run(self, cluster: &mut TestCluster) -> eyre::Result<()> {
        info!(scenario = %self.name, "starting chaos scenario");

        let mut guards: Vec<FaultGuard> = Vec::new();

        for step in self.steps {
            match step {
                Step::Inject { name, inject_fn } => {
                    info!(fault = %name, "injecting fault");
                    let guard = inject_fn(cluster)?;
                    guards.push(guard);
                }
                Step::WaitAdvancing { min_blocks, timeout } => {
                    info!(min_blocks, ?timeout, "waiting for chain to advance");
                    chain_advancing::wait_chain_advancing(
                        cluster.live_rpc_urls(),
                        min_blocks,
                        timeout,
                    )?;
                }
                Step::Sleep(duration) => {
                    info!(?duration, "sleeping");
                    std::thread::sleep(duration);
                }
                Step::Recover => {
                    info!(guards = guards.len(), "recovering all faults");
                    for guard in guards.drain(..) {
                        guard.recover(cluster);
                    }
                }
                Step::VerifyBlockConsistency => {
                    info!("verifying block consistency");
                    block_consistency::verify_block_consistency(cluster.live_rpc_urls())?;
                }
                Step::VerifyNonceMonotonicity => {
                    info!("verifying nonce monotonicity");
                    let urls = cluster.live_rpc_urls();
                    if let Some(url) = urls.first() {
                        let latest = crate::rpc::get_block_number(url)?;
                        nonce_monotonicity::verify_nonce_monotonicity(url, latest)?;
                    }
                }
            }
        }

        // Clean up any remaining guards.
        for guard in guards {
            guard.recover(cluster);
        }

        info!(scenario = %self.name, "chaos scenario completed successfully");
        Ok(())
    }
}
