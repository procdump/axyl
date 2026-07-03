# `crates/consensus/consensus-metrics`

The consensus metrics crate exposes Prometheus/metrics helpers for the consensus stack. It centralizes metric definitions for primaries, workers, and state sync.

## Responsibilities

- Define shared counters, gauges, and histograms.
- Provide consistent metric labels across consensus components.
- Export instrumentation hooks used by consensus services.

## Mid-level overview

The crate wraps Prometheus registries and provides helpers like the `monitored_future!`
declarative macro (and a `monitored_scope` companion) to track task lifetimes, channel
occupancy, and scoped work durations. `monitored_future!` wraps any future expression and is
expanded at call sites — that is why it is a macro rather than a function. The metrics it
emits are shared across primary, worker, and state-sync components to keep instrumentation
consistent.

## Key structures

- `Metrics`
	- `tasks`: gauge vector for monitored tasks.
	- `futures`: gauge vector for monitored futures.
	- `channels`: gauge vector for channel sizes.
	- `scope_iterations`: gauge vector for scope iteration counts.
	- `scope_duration_ns`: gauge vector for scope duration.
	- `scope_entrance`: gauge vector for scope entrance counts.
- `MonitoredScopeGuard`
	- `metrics`: reference to shared metrics.
	- `name`: scope name label.
	- `timer`: elapsed time tracker.

## External dependencies

- `prometheus`
- `axum`
- `once_cell`
- `tokio`
- `parking_lot`
- `futures`
- `scopeguard`

## Related crates

- `crates/consensus/primary`
- `crates/consensus/worker`
- `crates/consensus/state-sync`
