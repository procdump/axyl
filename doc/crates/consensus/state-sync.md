# `crates/consensus/state-sync`

The state sync crate handles catching up nodes that fall behind consensus. It fetches missing data (blocks, batches, and certificates) and verifies it before inserting into local storage so the node can rejoin the quorum.

## Responsibilities

- Request missing consensus data from peers.
- Validate and store fetched batches/certificates.
- Provide sync progress feedback to the primary node.

## Mid-level overview

State sync runs background tasks that watch for missing consensus headers, request them from peers,
and persist them into the consensus database. It also primes round bounds on startup and performs
cache cleanup for outdated consensus headers to keep storage bounded.

## Key structures

This crate is function-oriented and does not define public structs; the entrypoints are task
spawners and helper functions that operate on shared consensus types.

## External dependencies

- `tokio`
- `tracing`
- `eyre`
- `futures` — async combinators used by the background tasks

## Related crates

- `crates/consensus/primary`
- `crates/consensus/network`
- `crates/infrastructure/storage`
