# `crates/consensus/primary`

The primary crate runs the core consensus logic. It proposes headers, collects votes, certifies blocks, and coordinates with workers to form the DAG.

## Responsibilities

- Propose and sign primary headers.
- Aggregate votes and form certificates.
- Drive consensus progress and commit ordering.
- Coordinate with workers for batch references.

## Mid-level overview

The primary orchestrates the consensus DAG by receiving batch digests from workers, proposing
headers, certifying them with votes, and triggering state sync when peers lag. It owns the
primary network handle and wires in certificate fetchers, certifiers, and proposers as
background tasks.

## Key structures

- `Primary<DB>`
	- `primary_network`: handle for primary network messaging.
	- `rayls_consensus_state_sync`: state synchronizer for headers/certificates.
- `StateSynchronizer<DB>`
	- `certificate_validator`: validates and manages certificates.
	- `header_validator`: validates headers and syncs batches.

## External dependencies

- `tokio`
- `futures`
- `tracing`
- `eyre`
- `backoff`
- `parking_lot`
- `rand`
- `thiserror`
- `serde`
- `async-trait`

## Related crates

- `crates/consensus/worker`
- `crates/consensus/network`
- `crates/consensus/state-sync`
- `crates/consensus/primary-metrics`
