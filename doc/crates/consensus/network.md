# `crates/consensus/network`

The consensus network crate provides the libp2p-based networking layer for consensus. It defines message types, peer connections, and request/response flows used by primaries and workers.

## Responsibilities

- Transport for consensus messages (headers, votes, batches).
- Peer discovery and connection management.
- Request/response utilities and timeouts for consensus traffic.

## Mid-level overview

This crate builds a libp2p swarm with gossipsub for broadcast traffic, request/response for
targeted RPCs, and Kademlia for peer discovery. It manages authorized publishers per topic,
tracks in-flight requests, and exposes a handle-based API so primaries and workers can send and
receive consensus messages without owning the swarm loop.

## Key structures

- `RLBehavior<C, DB>`
	- `gossipsub`: gossipsub behaviour for broadcast topics.
	- `req_res`: request/response behaviour for direct RPCs.
	- `peer_manager`: scoring and peer lifecycle state.
	- `kademlia`: DHT behaviour backed by `KadStore`.
- `RLCodec<Req, Res>`
	- `compressed_buffer`: reusable buffer for compressed payloads.
	- `decode_buffer`: reusable buffer for decoded payloads.
	- `max_chunk_size`: upper bound on message size.
	- `_phantom`: marker for request/response types.
- `ConsensusNetwork<Req, Res, DB, Events>` ([`network/src/consensus/mod.rs:51`](../../../crates/consensus/network/src/consensus/mod.rs))
	- `swarm`: libp2p swarm running the behaviours.
	- `event_stream`: channel for emitting network events.
	- `handle`: sender for issuing network commands.
	- `commands`: receiver for network commands.
	- `authorized_publishers`: per-topic publisher allowlist.
	- `pending_px_disconnects`: pending peer-exchange disconnects.
	- `outbound_requests`: in-flight outbound request map.
	- `inbound_requests`: in-flight inbound request map.
	- `kad_record_queries`: pending Kademlia queries.
	- `kad_expecting_to_fail_query_ids`: Kademlia queries known to lack peers; suppresses error reporting on expected failures.
	- `config`: libp2p network configuration.
	- `connected_peers`: tracked connected peers for round-robin.
	- `key_config`: local key configuration for signing records.
	- `task_spawner`: task spawner handle.
	- `node_record`: signed peer record advertised to the DHT.
	- `last_cleanup`: timestamp for periodic cleanup.
	- `network_metrics: Arc<NetworkMetrics>`: per-peer-manager Prometheus metrics handle.
	- `network_label: &'static str`: label distinguishing primary vs worker networks in metric output.

## External dependencies

- `libp2p`
- `tokio`
- `futures`
- `serde`
- `thiserror`
- `async-trait`
- `bcs`
- `snap`
- `rand`
- `serde_with`
- `bs58`

## Related crates

- `crates/consensus/primary`
- `crates/consensus/worker`
- `crates/infrastructure/network-types`
