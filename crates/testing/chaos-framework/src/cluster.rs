//! TestCluster: spawn and manage a local 4-validator testnet.

use crate::node::NodeHandle;
use escargot::CargoRun;
use std::{
    net::TcpListener,
    path::{Path, PathBuf},
    sync::OnceLock,
};
use tracing::info;

/// Default number of validators in a test cluster.
pub const DEFAULT_VALIDATOR_COUNT: usize = 4;

/// Default passphrase for test nodes.
pub const TEST_PASSPHRASE: &str = "chaos_test";

/// Only compile the main binary once across all tests.
static CHAOS_BINARY: OnceLock<CargoRun> = OnceLock::new();

/// Build or retrieve the cached `rayls-network` binary.
pub fn get_binary() -> &'static CargoRun {
    CHAOS_BINARY.get_or_init(|| {
        info!(target: "chaos", "building rayls-network binary for chaos tests");
        let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR not set");
        let path = PathBuf::from(manifest_dir);
        let workspace_root = path
            .ancestors()
            .find(|p| p.join("Cargo.toml").exists() && p.join("crates").exists())
            .expect("Cannot find workspace root");

        escargot::CargoBuild::new()
            .bin("rayls-network")
            .manifest_path(workspace_root.join("Cargo.toml"))
            .target_dir(workspace_root.join("target"))
            .current_target()
            .run()
            .expect("Failed to build rayls-network binary")
    })
}

/// A managed cluster of validator (and optionally observer) nodes.
pub struct TestCluster {
    /// The validator node handles.
    pub validators: Vec<NodeHandle>,
    /// Temp directory holding all node data (dropped = cleaned up).
    _tmp_dir: tempfile::TempDir,
    /// Base path for node data directories.
    base_dir: PathBuf,
    /// Reference to the compiled binary.
    bin: &'static CargoRun,
    /// Passphrase used for BLS keys.
    passphrase: String,
}

impl TestCluster {
    /// Spawn a new test cluster with `count` validators.
    ///
    /// This runs the genesis ceremony and starts all validator processes.
    pub fn spawn(count: usize) -> eyre::Result<Self> {
        // The genesis ceremony below is hardcoded to build exactly
        // DEFAULT_VALIDATOR_COUNT validator directories. A different count would
        // either point processes at non-existent datadirs (count > 4) or leave
        // genesis validators with no running process (count < 4), silently
        // invalidating the test. Fail fast instead.
        eyre::ensure!(
            count == DEFAULT_VALIDATOR_COUNT,
            "TestCluster::spawn supports exactly {DEFAULT_VALIDATOR_COUNT} validators (got {count})"
        );

        let tmp_dir = tempfile::TempDir::new()?;
        let base_dir = tmp_dir.path().to_path_buf();
        let passphrase = TEST_PASSPHRASE.to_string();

        // Run genesis ceremony.
        e2e_tests_config_local_testnet(&base_dir, passphrase.clone())?;

        let bin = get_binary();
        let mut validators = Vec::with_capacity(count);

        // Reserve distinct ports up front. Calling an ephemeral-port helper once
        // per validator hands back the SAME port each time (it binds then frees
        // immediately), so the second node failed with "address already in use".
        let rpc_ports = reserve_distinct_ports(count)?;
        for (i, &rpc_port) in rpc_ports.iter().enumerate() {
            let node = NodeHandle::spawn_validator(i, bin, &base_dir, rpc_port, &passphrase);
            validators.push(node);
        }

        info!(target: "chaos", count, "test cluster spawned");
        Ok(Self { validators, _tmp_dir: tmp_dir, base_dir, bin, passphrase })
    }

    /// Spawn a default 4-validator cluster.
    pub fn spawn_default() -> eyre::Result<Self> {
        Self::spawn(DEFAULT_VALIDATOR_COUNT)
    }

    /// Get the RPC URLs of all currently alive validators.
    pub fn live_rpc_urls(&mut self) -> Vec<&str> {
        let mut urls = Vec::new();
        for node in &mut self.validators {
            if node.is_alive() {
                urls.push(node.rpc_url());
            }
        }
        urls
    }

    /// Get the RPC URLs of all validators (alive or dead).
    pub fn all_rpc_urls(&self) -> Vec<&str> {
        self.validators.iter().map(|n| n.rpc_url()).collect()
    }

    /// Kill validator at the given index.
    pub fn kill_validator(&mut self, index: usize) {
        self.validators[index].kill();
    }

    /// Hard-kill (SIGKILL) validator at the given index.
    pub fn hard_kill_validator(&mut self, index: usize) {
        self.validators[index].hard_kill();
    }

    /// Restart a previously killed validator.
    pub fn restart_validator(&mut self, index: usize) {
        self.validators[index].restart(self.bin, &self.passphrase);
    }

    /// Get the compiled binary reference.
    pub fn bin(&self) -> &'static CargoRun {
        self.bin
    }

    /// Get the base directory for node data.
    pub fn base_dir(&self) -> &Path {
        &self.base_dir
    }

    /// Get the passphrase.
    pub fn passphrase(&self) -> &str {
        &self.passphrase
    }

    /// Shut down all validators gracefully.
    pub fn shutdown(&mut self) {
        // Send SIGTERM to all first for parallel shutdown.
        for node in &mut self.validators {
            node.graceful_stop();
        }
        // Then wait/kill each.
        for node in &mut self.validators {
            node.kill();
        }
    }
}

impl Drop for TestCluster {
    fn drop(&mut self) {
        self.shutdown();
    }
}

impl std::fmt::Debug for TestCluster {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TestCluster")
            .field("validators", &self.validators.len())
            .field("base_dir", &self.base_dir)
            .finish()
    }
}

/// Reserve `n` distinct ephemeral TCP ports on localhost.
///
/// Binds all listeners simultaneously so each gets a unique port, then releases
/// them so the spawned nodes can bind. There is a small TOCTOU window between
/// release and the node binding, which is acceptable for local tests and far
/// better than the guaranteed collision of requesting one port at a time.
fn reserve_distinct_ports(n: usize) -> eyre::Result<Vec<u16>> {
    let listeners: Vec<TcpListener> =
        (0..n).map(|_| TcpListener::bind("127.0.0.1:0")).collect::<Result<_, _>>()?;
    let ports =
        listeners.iter().map(|l| Ok(l.local_addr()?.port())).collect::<eyre::Result<Vec<u16>>>()?;
    drop(listeners);
    Ok(ports)
}

/// Run the genesis ceremony to configure a local testnet.
///
/// This replicates the logic from `e2e_tests::config_local_testnet` but is
/// self-contained to avoid a direct dependency on the e2e-tests crate.
fn e2e_tests_config_local_testnet(temp_path: &Path, passphrase: String) -> eyre::Result<()> {
    use clap::Parser as _;
    use rayls_infrastructure_types::test_utils::CommandParser;
    use rayls_network_cli::{genesis::GenesisArgs, keytool::KeyArgs};

    let validators = [
        ("validator-1", "0x1111111111111111111111111111111111111111"),
        ("validator-2", "0x2222222222222222222222222222222222222222"),
        ("validator-3", "0x3333333333333333333333333333333333333333"),
        ("validator-4", "0x4444444444444444444444444444444444444444"),
    ];

    // Create shared genesis directory.
    let shared_genesis_dir = temp_path.join("shared-genesis");
    let copy_path = shared_genesis_dir.join("genesis/validators");
    std::fs::create_dir_all(&copy_path)?;

    for (v, addr) in validators.iter() {
        let dir = temp_path.join(v);
        let keys_command = CommandParser::<KeyArgs>::parse_from([
            "rl",
            "generate",
            "validator",
            "--address",
            addr,
        ]);
        keys_command.args.execute(dir.clone(), passphrase.clone())?;
        std::fs::copy(dir.join("node-info.yaml"), copy_path.join(format!("{v}.yaml")))?;
    }

    // Create observer config.
    let dir = temp_path.join("observer");
    let keys_command = CommandParser::<KeyArgs>::parse_from([
        "rl",
        "generate",
        "observer",
        "--address",
        "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
    ]);
    keys_command.args.execute(dir, passphrase)?;

    // Create committee from shared genesis.
    let create_committee_command = CommandParser::<GenesisArgs>::parse_from([
        "rl",
        "--basefee-address",
        "0x9999999999999999999999999999999999999999",
        "--consensus-registry-owner",
        "0x00000000000000000000000000000000000007a0",
        "--dev-funded-account",
        "test-source",
        "--max-header-delay-ms",
        "1000",
        "--min-header-delay-ms",
        "500",
    ]);
    create_committee_command.args.execute(shared_genesis_dir.clone())?;

    // Copy genesis files to each validator and observer.
    for (v, _) in validators.iter() {
        let dir = temp_path.join(v);
        std::fs::create_dir_all(dir.join("genesis"))?;
        std::fs::copy(
            shared_genesis_dir.join("genesis/committee.yaml"),
            dir.join("genesis/committee.yaml"),
        )?;
        std::fs::copy(
            shared_genesis_dir.join("genesis/genesis.yaml"),
            dir.join("genesis/genesis.yaml"),
        )?;
        std::fs::copy(shared_genesis_dir.join("parameters.yaml"), dir.join("parameters.yaml"))?;
    }

    let dir = temp_path.join("observer");
    std::fs::create_dir_all(dir.join("genesis"))?;
    std::fs::copy(
        shared_genesis_dir.join("genesis/committee.yaml"),
        dir.join("genesis/committee.yaml"),
    )?;
    std::fs::copy(
        shared_genesis_dir.join("genesis/genesis.yaml"),
        dir.join("genesis/genesis.yaml"),
    )?;
    std::fs::copy(shared_genesis_dir.join("parameters.yaml"), dir.join("parameters.yaml"))?;

    Ok(())
}
