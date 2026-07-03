//! Network latency injection using Linux `tc` (traffic control).
//!
//! Supports two modes:
//! - **Native**: runs `tc` directly on the host (Linux with CAP_NET_ADMIN)
//! - **Docker**: runs `tc` inside a container via `docker exec` (any platform)
//!
//! Docker mode is automatically used when a container name is provided.
//! For the Docker-based chaos testnet, use `etc/chaos-network/compose.yaml`.

use crate::fault::SelfCleaningGuard;
use std::{ops::Range, process::Command};
use tracing::{info, warn};

/// Check if native `tc` is available (Linux with CAP_NET_ADMIN).
pub fn check_tc_capability() -> eyre::Result<()> {
    let output = Command::new("tc").args(["qdisc", "show", "dev", "lo"]).output().map_err(|e| {
        eyre::eyre!(
            "tc not available natively: {e}. Use Docker mode \
             (etc/chaos-network/) for cross-platform support."
        )
    })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(eyre::eyre!("tc failed (need CAP_NET_ADMIN or root): {stderr}"));
    }
    Ok(())
}

/// Check if Docker is available for container-based fault injection.
pub fn check_docker_capability() -> eyre::Result<()> {
    let output = Command::new("docker")
        .args(["info"])
        .output()
        .map_err(|e| eyre::eyre!("docker not found: {e}"))?;

    if !output.status.success() {
        return Err(eyre::eyre!("docker daemon not running"));
    }
    Ok(())
}

/// Add latency on the host loopback interface (native Linux mode).
pub fn add_latency(delay_ms: u32, jitter_ms: u32) -> eyre::Result<SelfCleaningGuard> {
    check_tc_capability()?;
    info!(target: "chaos", delay_ms, jitter_ms, "injecting latency (native)");
    tc_add_or_replace("lo", &format!("delay {delay_ms}ms {jitter_ms}ms"))?;
    Ok(SelfCleaningGuard::new(|| tc_del("lo")))
}

/// Add latency inside a Docker container (cross-platform mode).
///
/// The container must have `iproute2` installed and `cap_add: [NET_ADMIN]`.
/// Use `etc/chaos-network/compose.yaml` which provides both.
pub fn add_latency_docker(
    container: &str,
    delay_ms: u32,
    jitter_ms: u32,
) -> eyre::Result<SelfCleaningGuard> {
    check_docker_capability()?;
    info!(target: "chaos", container, delay_ms, jitter_ms, "injecting latency (docker)");
    docker_tc_replace(container, &format!("delay {delay_ms}ms {jitter_ms}ms"))?;
    let c = container.to_string();
    Ok(SelfCleaningGuard::new(move || docker_tc_del(&c)))
}

/// Add latency using `tc netem`'s delay/jitter model.
///
/// Maps `range` to `netem delay <midpoint>ms <half-width>ms`, which produces
/// a uniform distribution around the midpoint.
pub fn add_latency_range(range: Range<u32>) -> eyre::Result<SelfCleaningGuard> {
    let delay_ms = (range.start + range.end) / 2;
    let jitter_ms = (range.end - range.start) / 2;
    add_latency(delay_ms, jitter_ms)
}

/// Add latency range inside a Docker container.
pub fn add_latency_range_docker(
    container: &str,
    range: Range<u32>,
) -> eyre::Result<SelfCleaningGuard> {
    let delay_ms = (range.start + range.end) / 2;
    let jitter_ms = (range.end - range.start) / 2;
    add_latency_docker(container, delay_ms, jitter_ms)
}

/// Add packet loss on the host loopback (native Linux mode).
pub fn add_packet_loss(percent: f32) -> eyre::Result<SelfCleaningGuard> {
    check_tc_capability()?;
    info!(target: "chaos", percent, "injecting packet loss (native)");
    tc_add_or_replace("lo", &format!("loss {percent}%"))?;
    Ok(SelfCleaningGuard::new(|| tc_del("lo")))
}

/// Add packet loss inside a Docker container.
pub fn add_packet_loss_docker(container: &str, percent: f32) -> eyre::Result<SelfCleaningGuard> {
    check_docker_capability()?;
    info!(target: "chaos", container, percent, "injecting packet loss (docker)");
    docker_tc_replace(container, &format!("loss {percent}%"))?;
    let c = container.to_string();
    Ok(SelfCleaningGuard::new(move || docker_tc_del(&c)))
}

/// Add combined latency and packet loss (native).
pub fn add_latency_and_loss(
    delay_ms: u32,
    jitter_ms: u32,
    loss_percent: f32,
) -> eyre::Result<SelfCleaningGuard> {
    check_tc_capability()?;
    info!(target: "chaos", delay_ms, jitter_ms, loss_percent, "injecting latency+loss (native)");
    tc_add_or_replace("lo", &format!("delay {delay_ms}ms {jitter_ms}ms loss {loss_percent}%"))?;
    Ok(SelfCleaningGuard::new(|| tc_del("lo")))
}

/// Add combined latency and packet loss inside a Docker container.
pub fn add_latency_and_loss_docker(
    container: &str,
    delay_ms: u32,
    jitter_ms: u32,
    loss_percent: f32,
) -> eyre::Result<SelfCleaningGuard> {
    check_docker_capability()?;
    info!(target: "chaos", container, delay_ms, jitter_ms, loss_percent, "injecting latency+loss (docker)");
    docker_tc_replace(
        container,
        &format!("delay {delay_ms}ms {jitter_ms}ms loss {loss_percent}%"),
    )?;
    let c = container.to_string();
    Ok(SelfCleaningGuard::new(move || docker_tc_del(&c)))
}

// --- Native tc helpers ---

fn tc_add_or_replace(dev: &str, netem_args: &str) -> eyre::Result<()> {
    let args_str = format!("qdisc replace dev {dev} root netem {netem_args}");
    let args: Vec<&str> = args_str.split_whitespace().collect();
    let output = Command::new("tc").args(&args).output()?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(eyre::eyre!("tc {args_str} failed: {stderr}"));
    }
    Ok(())
}

fn tc_del(dev: &str) {
    info!(target: "chaos", dev, "removing tc qdisc");
    let output = Command::new("tc").args(["qdisc", "del", "dev", dev, "root"]).output();
    match output {
        Ok(o) if !o.status.success() => {
            let stderr = String::from_utf8_lossy(&o.stderr);
            if !stderr.contains("No such file") {
                warn!(target: "chaos", stderr = %stderr, "tc del failed");
            }
        }
        Err(e) => warn!(target: "chaos", ?e, "tc del command failed"),
        _ => {}
    }
}

// --- Docker tc helpers ---

fn docker_tc_replace(container: &str, netem_args: &str) -> eyre::Result<()> {
    let cmd = format!("tc qdisc replace dev eth0 root netem {netem_args}");
    let output = Command::new("docker").args(["exec", container, "sh", "-c", &cmd]).output()?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(eyre::eyre!("docker exec tc in {container} failed: {stderr}"));
    }
    Ok(())
}

fn docker_tc_del(container: &str) {
    info!(target: "chaos", container, "removing tc qdisc (docker)");
    let output = Command::new("docker")
        .args(["exec", container, "tc", "qdisc", "del", "dev", "eth0", "root"])
        .output();
    match output {
        Ok(o) if !o.status.success() => {
            let stderr = String::from_utf8_lossy(&o.stderr);
            if !stderr.contains("No such file") {
                warn!(target: "chaos", container, stderr = %stderr, "docker tc del failed");
            }
        }
        Err(e) => warn!(target: "chaos", container, ?e, "docker tc del failed"),
        _ => {}
    }
}
