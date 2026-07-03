# `crates/consensus/worker/src/batch-builder`

The batch builder crate is a focused component for constructing batches from incoming transactions. It ensures batches meet size/format requirements before handoff.

## Responsibilities

- Accumulate transactions into batches.
- Enforce batch size and configuration limits.
- Provide batch-ready notifications to workers.

## Mid-level overview

The batch builder polls the worker transaction pool, filters transactions by gas and size
limits, and constructs sealed batches without executing them. It spawns a background task for
each batch build so the worker can await quorum acknowledgements before advancing sequence
counters and pruning the pool.

## Key structures

- `BatchBuilder` ([`batch-builder/src/lib.rs`](../../../crates/consensus/worker/src/batch-builder/src/lib.rs))
	- `pending_task`: current in-flight build task receiver.
	- `pool`: worker transaction pool handle.
	- `to_worker`: channel to the worker batch proposer.
	- `address`: beneficiary address for the batch.
	- `max_delay_interval`: periodic wake interval.
	- `state_changed`: canonical state update stream.
	- `last_canonical_update`: last sealed block for pool updates.
	- `task_spawner`: task spawner handle.
	- `worker_id`: worker identifier.
	- `base_fee`: base fee container for batch metadata.
	- `epoch`: epoch for batch validity.
	- `next_batch_seq`: next sequence number to assign.
	- `epoch_transitioning`: guard for epoch transitions.
	- `gas_limit: u64`: block gas limit applied when sealing batches; propagated into the resulting payload.
- `BatchBuilderOutput`
	- `batch`: built batch data.
	- `mined_transactions`: hashes of mined transactions.
	- `sender_nonce_ranges`: per-sender nonce ranges.

## External dependencies

- `tokio`
- `futures-util`
- `tracing`
- `thiserror`

## Related crates

- `crates/consensus/worker`
- `crates/infrastructure/types`
