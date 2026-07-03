# `crates/consensus/worker/src/batch-validator`

The batch validator crate verifies batches received from peers before they are stored or referenced by consensus. It enforces integrity and basic validity checks.

## Responsibilities

- Validate batch structure and signatures.
- Reject malformed or oversized batches.
- Feed validated batches into worker storage.

## Mid-level overview

The batch validator checks that incoming batches match their digest, belong to the correct
worker and epoch, and conform to gas/size constraints. It also caches recent batch digests to
avoid repeat work and can optionally submit transactions from validated batches into the local
transaction pool.

## Key structures

- `BatchValidator` ([`batch-validator/src/validator.rs`](../../../crates/consensus/worker/src/batch-validator/src/validator.rs))
	- `reth_env`: execution environment for decoding and pool access.
	- `tx_pool`: optional worker transaction pool.
	- `worker_id`: expected worker id for batches.
	- `base_fee`: base fee for validation checks.
	- `epoch`: epoch for validation checks.
	- `validated_batches`: cache of recently validated digests.
	- `gas_limit: u64`: block gas limit; an inbound batch whose gas usage exceeds this is rejected.
- `NoopBatchValidator` — unit struct (`pub struct NoopBatchValidator;`); the `BatchValidation` impl unconditionally returns `Ok(())` and is used in tests and observer mode.

## External dependencies

- `async-trait`
- `rayon`
- `dashmap`
- `tracing`

## Related crates

- `crates/consensus/worker`
- `crates/infrastructure/storage`
