// SPDX-License-Identifier: BUSL-1.1
//! Reth execution-layer metrics server.

use rayls_infrastructure_types::BuildMetadata;
use reth_db_api::database_metrics::DatabaseMetrics;
use reth_node_metrics::{
    chain::ChainSpecInfo,
    hooks::Hooks,
    recorder::install_prometheus_recorder,
    server::{MetricServer, MetricServerConfig},
    version::VersionInfo,
};
use reth_node_types::NodeTypesWithDB;
use reth_provider::{ProviderFactory, RocksDBProviderFactory, StaticFileProviderFactory};
use reth_tasks::TaskExecutor;
use reth_tracing::throttle;
use std::{net::SocketAddr, path::PathBuf, time::Duration};
use tracing::error;

/// Spawn a Prometheus metrics server on `GET /metrics`.
pub async fn start_reth_metrics_server<N: NodeTypesWithDB>(
    addr: SocketAddr,
    task_executor: TaskExecutor,
    provider_factory: &ProviderFactory<N>,
    pprof_dumps: PathBuf,
    chain_name: &str,
    build: &BuildMetadata,
) -> eyre::Result<()> {
    // ensure recorder runs upkeep periodically
    install_prometheus_recorder().spawn_upkeep();

    let config = MetricServerConfig::new(
        addr,
        VersionInfo {
            version: build.version,
            build_timestamp: build.build_timestamp,
            cargo_features: build.cargo_features,
            git_sha: build.git_sha,
            target_triple: build.target_triple,
            build_profile: build.build_profile,
        },
        ChainSpecInfo { name: chain_name.to_string() },
        task_executor,
        metrics_hooks(provider_factory),
        pprof_dumps,
    );
    MetricServer::new(config).serve().await?;

    Ok(())
}

fn metrics_hooks<N: NodeTypesWithDB>(provider_factory: &ProviderFactory<N>) -> Hooks {
    Hooks::builder()
        .with_hook({
            let db = provider_factory.db_ref().clone();
            move || throttle!(Duration::from_secs(5 * 60), || db.report_metrics())
        })
        .with_hook({
            let sfp = provider_factory.static_file_provider();
            move || {
                throttle!(Duration::from_secs(5 * 60), || {
                    if let Err(error) = sfp.report_metrics() {
                        error!(%error, "Failed to report metrics from static file provider");
                    }
                })
            }
        })
        .with_hook({
            let rocksdb = provider_factory.rocksdb_provider();
            move || throttle!(Duration::from_secs(5 * 60), || rocksdb.report_metrics())
        })
        .build()
}
