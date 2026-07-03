# EVM crate (`rayls-execution-evm`)

[`crates/execution/evm/`](../../../crates/execution/evm/)

The EVM crate is the execution engine of the Rayls node. It wraps
[reth](https://github.com/paradigmxyz/reth) as a library, driving block production directly from
consensus output rather than through reth's own engine loop.

---

## Architectural diagram

```
                    ConsensusOutput  (CommittedSubDag + batches)
                           │
                           ▼
          ┌────────────────────────────────────┐
          │  execute_consensus_output          │  (middleware/processor)
          │  (per batch → RLPayload)           │
          └──────────────┬─────────────────────┘
                         │ RLPayload + raw tx bytes
                         ▼
          ┌────────────────────────────────────┐
          │  RethEnv::build_block_from_batch_payload  │
          │                                    │
          │  1. recover transactions           │
          │  2. spawn_sparse_trie_task ───────►│ PayloadProcessor
          │  3. build state (CIM + MDBX)       │   (parallel trie)
          │  4. create RaylsEvm                │
          │     ├─ NativeErc20Inspector        │
          │     ├─ RaylsEvmHandler             │
          │     └─ Precompiles (Pectra)        │
          │  5. apply_pre_execution_changes    │
          │     ├─ EIP-4788 beacon root        │
          │     └─ EIP-2935 blockhashes        │
          │  6. execute transactions (loop)     │
          │  7. executor.finish()              │
          │     └─ epoch-close system calls    │ ─► ConsensusRegistry.applyIncentives()
          │        (if close_epoch is Some)    │ ─► ConsensusRegistry.concludeEpoch()
          │                                    │ ─► RewardDistributor.distributeRewards()
          │  8. compute state root             │
          │  9. RaylsBlockAssembler            │
          │ 10. insert into CanonicalInMemory  │
          └──────────────┬─────────────────────┘
                         │ ExecutedBlock
                         ▼
          ┌────────────────────────────────────┐
          │  finish_executing_output           │
          │  (canonical head + notifications)  │
          └──────────────┬─────────────────────┘
                         │
                         ▼
          ┌────────────────────────────────────┐
          │  finalize_block                    │
          │  (deferred MDBX persistence)       │
          └────────────────────────────────────┘
```

---

## Dataflow through the EVM

One `ConsensusOutput` produces one or more EVM blocks (one per batch) or exactly one empty block
if the output carries no batches.

**Batch → block mapping**

`execute_consensus_output` (in `middleware/processor`) calls `output.flatten_batches()` to get an
ordered list of `(cert_idx, batch_idx_in_cert)` pairs. For each pair it builds an `RLPayload` and
calls `RethEnv::build_block_from_batch_payload`. Out-of-order batches (by per-authority sequence
number) are parked and re-tried once their predecessors arrive.

**Inside `build_block_from_batch_payload`**

1. Raw transaction bytes from the batch are signature-recovered via
   `reth_recover_raw_transactions`.
2. A parallel sparse trie task is spawned with the recovered transactions as pre-warming hints
   (see [persistence section](#how-canonical-blocks-are-persisted-and-state-stored)).
3. A layered read-only state view is built: `CanonicalInMemoryState` (in-memory blocks from this
   round) stacked on top of the MDBX `BlockchainProvider` (persisted history).
4. A revm `State` with bundle tracking is wrapped around that view.
5. The EVM is created (see [EVM construction](#how-the-revm-evm-is-constructed)).
6. Pre-execution system calls run (EIP-4788 beacon root, EIP-2935 blockhashes).
7. Each recovered transaction is executed. Nonce and gas errors are skipped; fatal errors abort
   the batch.
8. `executor.finish()` runs post-execution epoch-closing system calls when the payload's
   `close_epoch` flag is set.
9. The state root is computed (sparse trie or serial fallback).
10. `RaylsBlockAssembler` seals the block.
11. The completed `ExecutedBlock` is inserted into `CanonicalInMemoryState` immediately, making
    it available as the parent for the next batch in the same round.

After all batches for a round are built, `finish_executing_output` updates the canonical head and
broadcasts `CanonStateNotification` to subscribers. `finalize_block` then triggers deferred MDBX
persistence.

---

## How the revm EVM is constructed

The entry point is `RaylsEvmConfig`
([`src/evm/config.rs`](../../../crates/execution/evm/src/evm/config.rs)), created once at node
startup and passed to `RethEnv`. It owns three components:

| Component | Type | Role |
|-----------|------|------|
| `executor_factory` | `RaylsBlockExecutorFactory` | Creates per-block executors |
| `evm_factory` | `RaylsEvmFactory` | Creates individual EVM instances |
| `block_assembler` | `RaylsBlockAssembler` | Seals the completed block |

**Creating an EVM instance**

`RaylsEvmFactory::create_evm_with_native_erc20_only`
([`src/evm/factory.rs`](../../../crates/execution/evm/src/evm/factory.rs)):

1. Fetches the global `ERC20_PRECOMPILE_INSTANCE` (`Arc<RwLock<Erc20Precompile>>`).
2. Builds the active `Precompiles` set dynamically from the current `SpecId` and registers the
   native ERC-20 as a `DynPrecompile` at `0x0400` (for `eth_call` and gas estimation).
3. Wraps `NativeErc20Inspector` in a `CompositeInspector` for real transaction execution.
4. Builds a `RevmEvm` with:
   - `RaylsEvmContext<DB>` — the journal + database wrapper.
   - `EthInstructions` — standard Ethereum bytecode interpreter.
   - `RaylsEvmHandler` — overrides base fee accounting (see
     [mining reward section](#how-the-mining-reward-is-handled)).

**`RaylsChainSpec`**
([`src/chainspec.rs`](../../../crates/execution/evm/src/chainspec.rs)) wraps reth's `ChainSpec`
and overrides `next_block_base_fee`. When EIP-1559 is active for the next block, it computes a
standard EIP-1559 base-fee adjustment (`compute_next_base_fee`, `chainspec.rs:418`) and clamps
the result to a configurable `min_base_fee` floor (defaulting to `MIN_RAYLS_PROTOCOL_BASE_FEE`).
Only when EIP-1559 is not yet active does it return the static `MIN_PROTOCOL_BASE_FEE`. See
[`gasless-mode.md`](../../gasless-mode.md) for how the `min_base_fee` floor is configured to
zero on gasless chains.

---

## How the ERC-20 precompile works

The native token is exposed as a full ERC-20 at address `0x0400`
([`src/native_erc20/`](../../../crates/execution/evm/src/native_erc20/)).

**Two execution paths**

| Context | Path | State persistence |
|---------|------|------------------|
| Real transactions (block execution) | `NativeErc20Inspector` | Writes to revm journal — same atomicity as any EVM state change |
| `eth_call` / `eth_estimateGas` | `DynPrecompile` at `0x0400` | Temporary; not committed |

**Inspector path (real transactions)**

`NativeErc20Inspector`
([`src/native_erc20/inspector.rs`](../../../crates/execution/evm/src/native_erc20/inspector.rs))
implements the revm `Inspector` trait. In `call` it intercepts any call whose target address is
`0x0400` and routes it to the matching handler on `Erc20Precompile` before the EVM would
normally process it. `RaylsEvmHandler` implements `InspectorHandler` so the EVM dispatches calls
through the active inspector — that is the mechanism that guarantees inspector-path state
changes for `0x0400` take precedence over the standard precompile table entry registered for
`eth_call` support.

`NativeErc20Inspector` also fires in `call_end` to intercept every internal ETH value transfer
(not just explicit `0x0400` calls) and emits an ERC-20 `Transfer` event into the journal, keeping
on-chain logs consistent with ERC-20 tooling.

**Supported methods**

| Category | Methods |
|----------|---------|
| Metadata | `name`, `symbol`, `decimals` |
| Queries | `totalSupply`, `balanceOf`, `allowance` |
| Mutations | `transfer`, `approve`, `transferFrom` |
| Mint / burn | `mint`, `burn`, `burnFrom` (access-controlled to `MINTING_MODULE_ADDRESS`) |
| EIP-3009 gasless | `transferWithAuthorization`, `receiveWithAuthorization`, `cancelAuthorization` |

**Storage layout**

ERC-20 storage is held in deterministic EVM storage slots of the precompile contract account at
`0x0400`. Slot helpers are in
[`src/native_erc20/storage.rs`](../../../crates/execution/evm/src/native_erc20/storage.rs):

| Data | Slot computation |
|------|-----------------|
| Allowance `(owner, spender)` | `keccak256(spender ‖ keccak256(owner ‖ slot_0))` |
| Authorization nonce `(from, nonce)` | `keccak256(nonce ‖ keccak256(from ‖ slot_1))` |
| Total supply | `slot_2` |

Balances are the native ETH balances of the accounts, read directly from the journal — no
separate storage slot.

---

## How payloads are built and consumed

**`RLPayload`**
([`crates/infrastructure/types/src/payload.rs`](../../../crates/infrastructure/types/src/payload.rs))
is the single struct that carries all data from a consensus batch to the EVM. It is constructed
by `PreparedBatch::build_payload`
([`crates/infrastructure/types/src/processor/prepared_batch.rs:37`](../../../crates/infrastructure/types/src/processor/prepared_batch.rs))
inside `execute_consensus_output` and consumed entirely by `build_block_from_batch_payload`.
The `src/payload.rs` file inside the `evm` crate only declares `BuildArguments`.

| Field | Source | Maps to header field |
|-------|--------|----------------------|
| `parent_header` | Previous canonical block | — (used to derive parent hash / state root lookup) |
| `beneficiary` | Batch authority (ECDSA address) | `coinbase` |
| `nonce` | `(epoch << 32) \| round` | `nonce` |
| `batch_index` | Position within sub-dag | Part of `difficulty` (upper bits) |
| `worker_id` | Worker that created the batch | Part of `difficulty` (lower 16 bits) |
| `timestamp` | Consensus `committed_at()` | `timestamp` |
| `batch_digest` | Keccak of raw batch | `ommers_hash` |
| `consensus_header_digest` | Keccak of `ConsensusHeader` | `parent_beacon_block_root` |
| `base_fee_per_gas` | Set by worker at batch creation | `base_fee_per_gas` |
| `gas_limit` | `max_batch_gas(epoch)` | `gas_limit` |
| `mix_hash` | `output_digest XOR batch_digest` | `mix_hash` / `prev_randao` |
| `close_epoch` | `Some(keccak(leader_bls_sigs))` if last batch of epoch, else `None` | `extra_data` |

**`BuildArguments`** combines `RethEnv` + `ConsensusOutput` + `parent_header` and is passed into
`execute_consensus_output` as the outer container for a full round.

`close_epoch: Option<B256>` being `Some` is the signal for the executor's `finish()` method to
run epoch-closing system calls before sealing the block. The 32-byte value (hashed BLS aggregate
signature) is used as randomness for the new committee shuffle and is stored in `extra_data` so
external clients can identify epoch-boundary blocks.

**Withdrawals**

When `close_epoch` is `Some`, `RaylsBlockAssembler` generates EIP-4895 withdrawal records from
the `RewardsCounter`, providing an audit trail of which validators were rewarded. Empty blocks
and non-epoch-closing blocks carry a default empty withdrawals list.

---

## How the mining reward is handled

Priority fees and base fees are handled differently from standard Ethereum.

**Priority fee → coinbase**

`RaylsEvmHandler` ([`src/evm/handler.rs`](../../../crates/execution/evm/src/evm/handler.rs))
overrides `reward_beneficiary`. For each transaction:

```
effective_tip = effective_gas_price - basefee
priority_fee_amount = effective_tip * gas_used
```

`priority_fee_amount` is credited directly to the block's `coinbase` (the batch authority /
beneficiary) in the revm journal.

**Base fee → `BASEFEE_ADDRESS`**

Instead of burning the base fee (as in standard Ethereum), the base fee portion
(`basefee * gas_used`) is sent to `BASEFEE_ADDRESS`, a chain-level constant set at node startup
via `BASEFEE_ADDRESS: OnceLock<Address>`. This allows off-chain fee processing and redistribution.

**Epoch rewards → `ConsensusRegistry`**

At epoch boundaries (when `close_epoch` is `Some`), the executor calls
`apply_consensus_block_rewards` before `concludeEpoch`. This calls
`ConsensusRegistry.applyIncentives(rewardInfos)` as a system call, passing each validator's
address and the number of consensus headers (leader blocks) they produced during the epoch. The
contract handles the on-chain reward accounting.

Rewards metadata is also written to the block's withdrawal list by `RewardsCounter`, providing
off-chain visibility.

---

## RPC component

The EVM crate does not implement any JSON-RPC methods itself. Instead it:

1. **Exposes the standard `eth_*` API** via reth's built-in `EthApi`, configured and started
   through `RpcServerArgs`
   ([`src/rpc_server_args.rs`](../../../crates/execution/evm/src/rpc_server_args.rs)). This is a
   subset of reth's full RPC args, with unsupported options removed. It supports HTTP, WebSocket,
   and IPC transports with configurable per-connection subscription and request size limits.

2. **Exposes `WorkerComponents`**
   ([`src/worker.rs`](../../../crates/execution/evm/src/worker.rs)) — each worker has its own
   `RpcServerHandle` and `WorkerTxPool`. This is the attachment point where the `rayls_*` (from
   `rayls-execution-rpc`) and `faucet_*` (from `rayls-execution-faucet`) namespaces are merged in
   by the middleware layer.

3. **Provides `RethEnv::canonical_block_stream()`**
   ([`src/reth_env/accessors.rs:27`](../../../crates/execution/evm/src/reth_env/accessors.rs))
   — a `CanonStateNotificationStream` that the worker and the `rayls_*` RPC use to respond to
   newly committed blocks.

---

## How the system calls work

System calls are implemented in `RaylsBlockExecutor`
([`src/evm/block.rs`](../../../crates/execution/evm/src/evm/block.rs)) using Alloy's `sol!`
macro-generated ABI bindings from
[`src/system_calls.rs`](../../../crates/execution/evm/src/system_calls.rs).

**Mechanism**

All system calls use `evm.transact_system_call(SYSTEM_ADDRESS, contract, calldata)`. The system
address (`0xffff...fffe`) bypasses normal transaction validation (no signature, no balance check,
no nonce). The result is committed directly to the revm `State` and forwarded to the `state_hook`
(for the parallel trie task).

**Pre-execution calls (every block)**

| System call | Contract | Condition | Purpose |
|------------|----------|-----------|---------|
| EIP-4788 beacon root | `BEACON_ROOTS_ADDRESS` | First batch in output only | Stores `consensus_header_digest` in the beacon roots ring buffer |
| EIP-2935 blockhashes | `HISTORY_STORAGE_ADDRESS` | Every block | Stores parent block hash in the history storage contract |

The beacon root call fires only on the first batch (`ctx.first_batch()`) to write the consensus
header exactly once per consensus round rather than once per EVM block.

**Post-execution calls (epoch boundary only)**

These run inside `executor.finish()` when `ctx.close_epoch` is `Some`
(see `evm/block.rs:804-832`).

| Step | System call | Contract | Purpose |
|------|------------|----------|---------|
| 1 | `applyIncentives(rewardInfos[])` | `ConsensusRegistry` | Records how many leader blocks each validator produced; triggers on-chain reward accounting |
| 2 | `concludeEpoch(newCommittee[])` | `ConsensusRegistry` | Closes the current epoch and installs the new committee |
| 3 | `distributeRewards()` | `RewardDistributor` | Reads the performance weights set by `applyIncentives` and distributes accumulated RLS (`apply_reward_distribution`, `evm/block.rs:277`) |

Before step 2, the executor reads active validators on-chain via
`ConsensusRegistry.getValidators(Active)` and shuffles them deterministically using a
Fisher-Yates shuffle seeded with the hashed BLS aggregate signature from `ctx.close_epoch`. This
provides verifiable randomness for committee selection without an external randomness beacon. The
new committee size is determined by reading `ConsensusRegistry.getCommitteeValidators(epoch)`.

**Smart contract addresses**

| Constant | Address | Contract |
|----------|---------|----------|
| `SYSTEM_ADDRESS` | `0xffff…fffe` | Synthetic caller for all system calls |
| `CONSENSUS_REGISTRY_ADDRESS` | `0x07E1…7e1` | Validator registry, committee management, rewards |
| `DELEGATION_POOL_ADDRESS` | `0x07E1…7e2` | Multi-delegator staking pools |
| `FEE_AGGREGATOR_ADDRESS` | `0x07E1…7e3` | USDr fee collection, swap to RLS, epoch distribution |
| `REWARD_DISTRIBUTOR_ADDRESS` | `0x07E1…7e5` | RLS staking reward distribution |

ABI definitions live in `system_calls.rs` and are compiled by the `sol!` macro at build time.
The crate currently binds `ConsensusRegistry`, `FeeAggregator`, `RewardDistributor`, `RLS`,
`RLSAccumulator`, and `DelegationPool`. The primary post-execution system calls target
`ConsensusRegistry` and `RewardDistributor`; the others are defined so the EVM crate can call
their views and emitters when needed (e.g. fee aggregation and delegation accounting).
