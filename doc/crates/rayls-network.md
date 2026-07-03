# `bin/rayls-network`

The `rayls-network` crate provides the main binary for running Rayls Network nodes and tools. It wires together consensus, execution, and infrastructure crates and exposes them through a single CLI.

## What it does

- Boots the node runtime (Tokio + tracing + metrics setup).
- Loads configuration, keys, and chain parameters.
- Runs consensus (primary/worker), execution (EVM), and networking services.
- Exposes JSON-RPC and other operational endpoints when enabled.

## Key entrypoints

- Source: `bin/rayls-network/src/main.rs`
- Binary name: `rayls-network`

## Common CLI responsibilities

- **Key management**: generate or import validator/observer keys and configs.
- **Node startup**: start validator or observer nodes with the configured data directory.
- **Network options**: configure libp2p addresses and chain selection (testnet/mainnet/local).

## Related crates

- Consensus: `crates/consensus/primary`, `crates/consensus/worker`, `crates/consensus/state-sync`
- Execution: `crates/execution/evm`, `crates/execution/rpc`
- Infrastructure: `crates/infrastructure/config`, `crates/infrastructure/storage`, `crates/infrastructure/network-types`
- Middleware: `crates/middleware/orchestrator`

## Useful docs

- Root README: `README.md`
- Local testnet script: `etc/test-network/local-testnet.sh`
