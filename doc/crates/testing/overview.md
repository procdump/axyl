# Testing Crates

The testing layer provides three levels of test infrastructure: committee-level fixtures
for unit tests, cross-crate helpers for integration tests, and full end-to-end tests that
spin up a local four-validator network.

| Crate | Name | Responsibility |
|---|---|---|
| `crates/testing/test-utils-committee` | `rayls-testing-test-utils-committee` | Committee and authority fixtures for low-level consensus unit tests |
| `crates/testing/test-utils` | `rayls-testing-test-utils` | Cross-crate helpers: consensus data builders, execution node factories, temp dirs |
| `crates/testing/e2e-tests` | `rayls-testing-e2e-tests` | Full-stack integration tests: genesis, epochs, restarts, faucet |

---

## `rayls-testing-test-utils-committee`

Provides deterministic in-memory committee fixtures used throughout the consensus
unit test suite.
Tests import these types directly rather than setting up real network stacks.

### Types

#### `CommitteeFixture<DB>`

Represents a complete committee ready to reach consensus.
Holds one `AuthorityFixture<DB>` per validator, all sharing the same `Committee`.

Key methods:

| Method | Description |
|---|---|
| `builder(new_db)` | Create a `Builder` that constructs the fixture with a custom DB factory |
| `authorities()` | Iterator over all `AuthorityFixture` references |
| `authority_by_id(id)` | Look up a specific authority |
| `first_authority()` / `last_authority()` | Convenience accessors |
| `committee()` | Return the production `Committee` struct |
| `certificate(header)` | Produce a quorum-signed `Certificate` for a given header |
| `genesis()` | Return genesis `CertificateDigest`s used as the initial set of parents |
| `header_builder_last_authority()` | `HeaderBuilder` pre-seeded with the last authority's identity |

#### `AuthorityFixture<DB>`

Represents a single validator with its key material, consensus DB, and worker
configuration.
Used to sign headers and produce votes without a live p2p stack.

Key methods:

| Method | Description |
|---|---|
| `id()` | Return `AuthorityIdentifier` |
| `keypair()` | Return the BLS keypair for signing |
| `header(committee)` | Build and return a valid signed header |
| `header_with_round(committee, round)` | Build a header pinned to a specific consensus round |
| `header_builder(committee)` | Return a `HeaderBuilder` for constructing custom headers |
| `vote(header)` | Produce a valid `Vote` on a header (signed with the fixture's keypair; the committee is held internally) |
| `consensus_config()` | Return the authority's `ConsensusConfig<DB>` (includes the consensus DB handle) |

#### `WorkerFixture`

Represents a single worker attached to an authority.
Provides the worker's network key and ID for tests that need to simulate
batch production.

#### `Builder<DB, F>`

Builder pattern for `CommitteeFixture`.
Accepts a `Fn() -> DB` factory so that each authority gets its own fresh
database instance.
Defaults to a four-authority committee; the size is configurable.

---

## `rayls-testing-test-utils`

Re-exports everything from `test-utils-committee` and adds higher-level helpers for
building consensus data and bootstrapping execution nodes.

### Re-exports

```
CommitteeFixture, AuthorityFixture, WorkerFixture, Builder
```

### `consensus.rs` — consensus data builders

| Function | Description |
|---|---|
| `create_signed_certificates_for_rounds(range, fixture)` | Creates a full `VecDeque<Certificate>` covering the given round range, with random batches attached. Returns certificates, parent digest set, and the batch map. |
| `random_batches(n)` (private) | Generates `n` random signed-transaction `Batch` values using the test chain spec. Used internally by `create_signed_certificates_for_rounds`. |

These helpers let unit tests construct realistic multi-round DAG histories without
running a primary or worker.

### `execution.rs` — execution node factories

| Function / Type | Description |
|---|---|
| `TestExecutionNode` | Type alias for `ExecutionNode` (orchestrator crate) |
| `default_test_execution_node(chain, address, tmp_dir, rewards)` | Creates a fully initialised `ExecutionNode` backed by a temp-dir Reth database. Accepts an optional chain spec and funded address; defaults to testnet + a deterministic address. |
| `execution_builder_no_args(...)` | Public helper that produces a `RaylsBuilder` with no CLI extensions, for tests that build `RethEnv` directly. The fully generic `execution_builder` (with a typed `CliExt`) is private and used only by `default_test_execution_node`. |

### `temp_dirs.rs` — temporary directory helpers

Wrappers around `tempfile::TempDir` that create the directory layout expected by a
running node (`node-keys.yaml`, `genesis/`, etc.) so that tests can call
`create_validator_info` without manually building the path hierarchy.

---

## `rayls-testing-e2e-tests`

Full integration tests that exercise the complete Axyl stack: key generation,
genesis ceremony, consensus, execution, epoch transitions, node restarts, and
the faucet.

### Architecture

Each test spawns a local four-validator network in a shared `TempDir` using the
in-process `launch_node` function.
Port conflicts are prevented by `IT_TEST_MUTEX`, a global `Mutex` that serialises
tests that bind to fixed ports.
The compiled `rayls-network` binary is built once via
[escargot](https://github.com/assert-rs/escargot) and cached in `RAYLS_BINARY` so
that recompilation does not happen between tests.

### Setup helpers

#### `config_local_testnet(temp_path, passphrase, accounts)`

End-to-end bootstrap helper:

1. Creates four validator data directories under `temp_path`
   (`validator-1` … `validator-4`) with deterministic addresses.
2. Runs `keytool generate validator` for each to produce BLS and network keys.
3. Runs the genesis ceremony to produce `genesis.yaml` and the initial committee.
4. Returns an `eyre::Result<()>` — the caller then spawns each validator.

#### `create_validator_info(dir, address, passphrase)`

Runs `keytool generate validator` inside an existing directory.
Used by `config_local_testnet` and by tests that manage their own directory layout.

### Test suites

#### `genesis_tests` — network initialisation

| Test | What it checks |
|---|---|
| `test_genesis_with_precompiles` | Full genesis + multi-thread node start; verifies block production, RPC connectivity, and that precompile accounts are present at block 0. |
| `test_precompile_genesis_accounts` | Verifies that genesis accounts for precompile contracts (ERC-20, etc.) are funded with the correct balances at block 0. |
| `test_genesis_with_consensus_registry` | Verifies that `ConsensusRegistry` is correctly deployed and its initial state matches the genesis committee. |

#### `epochs` — epoch boundary and sync

| Test | What it checks |
|---|---|
| `test_epoch_boundary` | Advances the network through at least one epoch transition; verifies that each validator produces matching canonical blocks on both sides of the boundary. |
| `test_epoch_sync` | Simulates a node that misses part of an epoch, then rejoins; verifies that it catches up to the current canonical tip and continues producing matching blocks. |

The `test_epoch_boundary_inner` and `test_epoch_sync_inner` helpers contain the
shared assertion logic (block hash equality across all four validators) and are
called from the public `#[tokio::test]` entrypoints.

#### `restarts` — node recovery

| Test | What it checks |
|---|---|
| `test_restartstt` | Stops and restarts one validator; verifies that it rejoins consensus and the four validators converge on the same chain tip. |
| `test_restarts_observer` | Stops and restarts an observer node; verifies that it re-syncs without affecting consensus. |
| `test_restarts_delayed` | Restarts a validator after a short delay; verifies catch-up to current round. |
| `test_restarts_lagged_delayed` | Restarts a validator that has fallen significantly behind; verifies full state-sync recovery. |
| `test_observer_late_start_catchup` | Starts an observer after validators have already produced blocks; verifies it catches up to the current canonical tip. |

`test_blocks_same(client_urls)` is a shared helper that queries all four RPC
endpoints and asserts identical block hashes at each height.

#### `faucet` — KMS-backed faucet (feature-gated)

| Test | What it checks |
|---|---|
| `test_faucet_transfers_rls_and_xyz_with_google_kms_e2e` | Sends transfer requests to the faucet endpoint using a real Google Cloud KMS key; verifies that RLS and XYZ token balances increase on-chain. |

This test suite is only compiled when the `faucet` feature flag is enabled, and
requires live GCP credentials. It is excluded from standard CI runs.
