//! Node kill fault injector.
//!
//! Kills validator processes (graceful SIGTERM or hard SIGKILL) and returns
//! a [`FaultGuard`] that restarts the node on recovery.

use crate::{cluster::TestCluster, fault::FaultGuard};
use rand::Rng;
use tracing::info;

/// Kill a specific validator by index.
///
/// Returns a guard that will restart the validator when recovered.
pub fn kill_validator(cluster: &mut TestCluster, index: usize) -> eyre::Result<FaultGuard> {
    eyre::ensure!(
        index < cluster.validators.len(),
        "validator index {index} out of range (cluster has {} validators)",
        cluster.validators.len()
    );

    info!(target: "chaos", index, "killing validator");
    cluster.kill_validator(index);

    Ok(FaultGuard::new(move |cluster: &mut TestCluster| {
        info!(target: "chaos", index, "recovering: restarting validator");
        cluster.restart_validator(index);
    }))
}

/// Hard-kill (SIGKILL) a specific validator by index.
///
/// Simulates a crash without graceful shutdown.
pub fn hard_kill_validator(cluster: &mut TestCluster, index: usize) -> eyre::Result<FaultGuard> {
    eyre::ensure!(
        index < cluster.validators.len(),
        "validator index {index} out of range (cluster has {} validators)",
        cluster.validators.len()
    );

    info!(target: "chaos", index, "hard-killing validator (SIGKILL)");
    cluster.hard_kill_validator(index);

    Ok(FaultGuard::new(move |cluster: &mut TestCluster| {
        info!(target: "chaos", index, "recovering: restarting hard-killed validator");
        cluster.restart_validator(index);
    }))
}

/// Kill a random validator from the cluster.
pub fn kill_random_validator(cluster: &mut TestCluster) -> eyre::Result<FaultGuard> {
    let count = cluster.validators.len();
    eyre::ensure!(count > 0, "cluster has no validators");

    let index = rand::rng().random_range(0..count);
    kill_validator(cluster, index)
}

/// Hard-kill a random validator from the cluster.
pub fn hard_kill_random_validator(cluster: &mut TestCluster) -> eyre::Result<FaultGuard> {
    let count = cluster.validators.len();
    eyre::ensure!(count > 0, "cluster has no validators");

    let index = rand::rng().random_range(0..count);
    hard_kill_validator(cluster, index)
}

/// Kill multiple validators at once (up to `count`).
///
/// Returns a single guard that restarts all of them on recovery.
pub fn kill_multiple_validators(
    cluster: &mut TestCluster,
    count: usize,
) -> eyre::Result<FaultGuard> {
    let total = cluster.validators.len();
    let kill_count = count.min(total);

    // Select random unique indices.
    let mut indices: Vec<usize> = (0..total).collect();
    let mut rng = rand::rng();
    // Fisher-Yates partial shuffle to pick `kill_count` random indices.
    for i in 0..kill_count {
        let j = rng.random_range(i..total);
        indices.swap(i, j);
    }
    let killed: Vec<usize> = indices[..kill_count].to_vec();

    for &idx in &killed {
        info!(target: "chaos", idx, "killing validator (multi-kill)");
        cluster.kill_validator(idx);
    }

    Ok(FaultGuard::new(move |cluster: &mut TestCluster| {
        for &idx in &killed {
            info!(target: "chaos", idx, "recovering: restarting validator (multi-kill)");
            cluster.restart_validator(idx);
        }
    }))
}
