# `crates/consensus/primary-metrics`

The primary metrics crate defines instrumentation specific to the primary node, supplementing shared consensus metrics with primary-only counters and timers.

## Responsibilities

- Record primary-specific latency and throughput metrics.
- Provide metric handles for primary services.

## Mid-level overview

This crate defines Prometheus metrics for primary-specific channels and execution timing. It
builds on the shared consensus metrics crate and exposes grouped metric sets for channel
occupancy, counters, and latency histograms.

## Key structures

- `Metrics`
	- `primary_channel_metrics`: channel occupancy gauges and counters.
	- `node_metrics`: primary node metric bundle.
- `PrimaryChannelMetrics` ([`primary-metrics/src/metrics.rs:58-116`](../../../crates/consensus/primary-metrics/src/metrics.rs))

  For each consensus channel the struct exposes **both** a current-occupancy `IntGauge` (e.g. `tx_others_digests`) and a cumulative `IntCounter` recording the number of messages ever sent on it (e.g. `tx_others_digests_total`). The counter is the primary signal during incident investigation since the gauge can hide bursty traffic.

  Gauges:
	- `tx_others_digests` — worker digest channel occupancy.
	- `tx_our_digests` — own digest channel occupancy.
	- `tx_system_messages` — system message channel occupancy.
	- `tx_parents` — parent certificate channel occupancy.
	- `tx_headers` — header channel occupancy.
	- `tx_certificate_fetcher` — certificate fetcher channel occupancy.
	- `tx_committed_certificates` — committed cert channel occupancy.
	- `tx_new_certificates` — new cert channel occupancy.
	- `tx_committed_own_headers` — own header channel occupancy.
	- `tx_certificate_acceptor` — internal cert acceptor channel occupancy.
	- `tx_new_epoch_certificates` — epoch certificate channel occupancy.

  Note: `tx_state_handler` and `tx_pending_cert_commands` are counter-only channels — their `_total` `IntCounter` siblings exist below but the corresponding `IntGauge` is intentionally not registered.

  Counters (`IntCounter`, suffixed `_total`):
	- `tx_others_digests_total`, `tx_our_digests_total`, `tx_system_messages_total`, `tx_parents_total`, `tx_headers_total`, `tx_certificate_fetcher_total`, `tx_state_handler_total`, `tx_committed_certificates_total`, `tx_new_certificates_total`, `tx_committed_own_headers_total`, `tx_certificate_acceptor_total`, `tx_pending_cert_commands_total`.

## External dependencies

- `prometheus`
- `tracing`

## Related crates

- `crates/consensus/primary`
- `crates/consensus/consensus-metrics`
