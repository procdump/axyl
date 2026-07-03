# `crates/consensus/worker`

The worker crate handles batch creation and propagation for consensus. Workers collect transactions, build batches, and serve them to primaries and peers.

## Responsibilities

- Build and validate transaction batches.
- Share batches with other workers and primaries.
- Maintain worker-to-worker and worker-to-primary channels.

## Mid-level overview

Workers accept transaction batches from the execution layer, store them, and broadcast them to
peers. They coordinate with quorum waiters to ensure batches are acknowledged before being
considered sealed and ready for consensus.

## Key structures

- `Worker<DB, QW>`
	- `id`: worker identifier.
	- `quorum_waiter`: optional quorum waiter for attestations.
	- `node_metrics`: worker metrics handle.
	- `client`: local network client for primary communication.
	- `store`: batch storage backend.
	- `tx_batches`: sender for batch submission.
	- `rx_batches`: receiver for batch submission.
	- `timeout`: request timeout for peer interactions.
	- `network_handle`: worker network handle.
	- `batch_tracker`: optional batch lifecycle tracker.
- `WorkerNetworkHandle` ([`worker/src/network/mod.rs:38-45`](../../../crates/consensus/worker/src/network/mod.rs))
	- `handle: NetworkHandle<Req, Res>`: the underlying p2p handle for sending worker requests/responses.
	- `task_spawner: TaskSpawner`: handle used to spawn worker-side network tasks.
	- `max_rpc_message_size: usize`: per-message size limit enforced on inbound and outbound RPC payloads.

## External dependencies

- `tokio`
- `futures`
- `tracing`
- `async-trait`
- `thiserror`
- `prometheus`
- `serde`
- `eyre`

## Related crates

- `crates/consensus/worker/src/batch-builder`
- `crates/consensus/worker/src/batch-validator`
- `crates/consensus/network`
- `crates/consensus/consensus-metrics`
