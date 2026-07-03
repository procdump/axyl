//! Network partition simulation using `iptables`.
//!
//! Supports two modes:
//! - **Native**: runs `iptables` directly on the host (Linux with CAP_NET_ADMIN)
//! - **Docker**: runs `iptables` inside a container via `docker exec` (any platform)
//!
//! Docker mode is automatically used when a container name is provided.
//! For the Docker-based chaos testnet, use `etc/chaos-network/compose.yaml`.
//!
//! Consensus p2p ports are configured via `--external-primary-addr` and
//! `--external-worker-addr`. They are NOT related to the RPC port.

use crate::fault::SelfCleaningGuard;
use std::process::Command;
use tracing::{info, warn};

/// Check if native `iptables` is available.
pub fn check_iptables_capability() -> eyre::Result<()> {
    let output = Command::new("iptables").args(["--list", "-n"]).output().map_err(|e| {
        eyre::eyre!(
            "iptables not available natively: {e}. Use Docker mode \
             (etc/chaos-network/) for cross-platform support."
        )
    })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(eyre::eyre!("iptables failed (need CAP_NET_ADMIN or root): {stderr}"));
    }
    Ok(())
}

/// Partition by blocking specific ports on the host (native Linux mode).
pub fn partition_ports(label: &str, ports: &[u16]) -> eyre::Result<SelfCleaningGuard> {
    check_iptables_capability()?;

    let chain_name = format!("CHAOS-{label}");
    info!(target: "chaos", label, chain = %chain_name, ?ports, "partitioning (native)");

    run_iptables(&["-N", &chain_name])?;

    for &port in ports {
        let port_str = port.to_string();
        run_iptables(&["-A", &chain_name, "-p", "tcp", "--dport", &port_str, "-j", "DROP"])?;
        run_iptables(&["-A", &chain_name, "-p", "tcp", "--sport", &port_str, "-j", "DROP"])?;
        run_iptables(&["-A", &chain_name, "-p", "udp", "--dport", &port_str, "-j", "DROP"])?;
        run_iptables(&["-A", &chain_name, "-p", "udp", "--sport", &port_str, "-j", "DROP"])?;
    }

    run_iptables(&["-I", "INPUT", "-j", &chain_name])?;
    run_iptables(&["-I", "OUTPUT", "-j", &chain_name])?;

    let chain_clone = chain_name.clone();
    Ok(SelfCleaningGuard::new(move || remove_chain(&chain_clone)))
}

/// Partition by blocking a port range on the host (native Linux mode).
pub fn partition_port_range(label: &str, start: u16, end: u16) -> eyre::Result<SelfCleaningGuard> {
    check_iptables_capability()?;

    let chain_name = format!("CHAOS-{label}");
    let range = format!("{start}:{end}");
    info!(target: "chaos", label, chain = %chain_name, %range, "partitioning port range (native)");

    run_iptables(&["-N", &chain_name])?;
    run_iptables(&["-A", &chain_name, "-p", "tcp", "--dport", &range, "-j", "DROP"])?;
    run_iptables(&["-A", &chain_name, "-p", "tcp", "--sport", &range, "-j", "DROP"])?;
    run_iptables(&["-A", &chain_name, "-p", "udp", "--dport", &range, "-j", "DROP"])?;
    run_iptables(&["-A", &chain_name, "-p", "udp", "--sport", &range, "-j", "DROP"])?;
    run_iptables(&["-I", "INPUT", "-j", &chain_name])?;
    run_iptables(&["-I", "OUTPUT", "-j", &chain_name])?;

    let chain_clone = chain_name.clone();
    Ok(SelfCleaningGuard::new(move || remove_chain(&chain_clone)))
}

/// Partition a Docker container by dropping all consensus (UDP) traffic.
///
/// Keeps TCP port 8545 (RPC) open so the test can still query the node.
/// The container must have `iptables` installed and `cap_add: [NET_ADMIN]`.
/// Use `etc/chaos-network/compose.yaml` which provides both.
pub fn partition_container(container: &str) -> eyre::Result<SelfCleaningGuard> {
    super::network_latency::check_docker_capability()?;

    info!(target: "chaos", container, "partitioning container (docker)");

    // Drop all UDP (QUIC consensus traffic).
    docker_iptables(container, &["-A", "INPUT", "-p", "udp", "-j", "DROP"])?;
    docker_iptables(container, &["-A", "OUTPUT", "-p", "udp", "-j", "DROP"])?;

    // Allow RPC (TCP 8545) but drop other TCP.
    docker_iptables(container, &["-A", "INPUT", "-p", "tcp", "--dport", "8545", "-j", "ACCEPT"])?;
    docker_iptables(container, &["-A", "INPUT", "-p", "tcp", "-j", "DROP"])?;

    let c = container.to_string();
    Ok(SelfCleaningGuard::new(move || {
        info!(target: "chaos", container = %c, "healing partition (docker)");
        let _ = docker_iptables_quiet(&c, &["-F", "INPUT"]);
        let _ = docker_iptables_quiet(&c, &["-F", "OUTPUT"]);
    }))
}

// --- Native iptables helpers ---

fn run_iptables(args: &[&str]) -> eyre::Result<()> {
    let output = Command::new("iptables").args(args).output()?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(eyre::eyre!("iptables {:?} failed: {stderr}", args));
    }
    Ok(())
}

fn remove_chain(chain_name: &str) {
    info!(target: "chaos", chain = %chain_name, "removing iptables chain");
    let _ = run_iptables_quiet(&["-D", "INPUT", "-j", chain_name]);
    let _ = run_iptables_quiet(&["-D", "OUTPUT", "-j", chain_name]);
    let _ = run_iptables_quiet(&["-F", chain_name]);
    let _ = run_iptables_quiet(&["-X", chain_name]);
}

fn run_iptables_quiet(args: &[&str]) -> eyre::Result<()> {
    let output = Command::new("iptables").args(args).output()?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        warn!(target: "chaos", args = ?args, stderr = %stderr, "iptables cleanup failed");
    }
    Ok(())
}

// --- Docker iptables helpers ---

fn docker_iptables(container: &str, args: &[&str]) -> eyre::Result<()> {
    let mut cmd_args = vec!["exec", container, "iptables"];
    cmd_args.extend_from_slice(args);
    let output = Command::new("docker").args(&cmd_args).output()?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(eyre::eyre!("docker exec iptables in {container} failed: {stderr}"));
    }
    Ok(())
}

fn docker_iptables_quiet(container: &str, args: &[&str]) -> eyre::Result<()> {
    let mut cmd_args = vec!["exec", container, "iptables"];
    cmd_args.extend_from_slice(args);
    let output = Command::new("docker").args(&cmd_args).output()?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        warn!(target: "chaos", container, stderr = %stderr, "docker iptables cleanup failed");
    }
    Ok(())
}
