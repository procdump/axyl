//! Tasks and helpers for collecting epoch records trustlessly.

use eyre::OptionExt;
use rayls_consensus_primary::{network::PrimaryNetworkHandle, ConsensusBus};
use rayls_infrastructure_storage::{tables::EpochRecords, EpochStore as _};
use rayls_infrastructure_types::{
    BlsPublicKey, Database as ReDatabase, Epoch, EpochRecord, Noticer, TaskSpawner, B256,
};
use tracing::info;

/// Return true if committee is compatable with epoch_rec_committee.
/// These will usually be equal but it is possible for a validator to be
/// booted and still in committee but not in epoch_rec.committee.
/// This is very unlikely, but check for it just in case.
pub fn epoch_committee_valid(epoch_rec: &EpochRecord, committee: &[BlsPublicKey]) -> bool {
    let epoch_committee_len = epoch_rec.committee.len();
    let committee_len = committee.len();
    match committee_len.cmp(&epoch_committee_len) {
        std::cmp::Ordering::Less => false,
        std::cmp::Ordering::Equal => committee == epoch_rec.committee,
        std::cmp::Ordering::Greater => {
            let required = (committee_len * 2).div_ceil(3);
            if epoch_committee_len < 4 || epoch_committee_len < required {
                // Make sure we have a reasonable committe size, i.e. don't let
                // a bogus record with one signer through, etc.
                false
            } else {
                for k in &epoch_rec.committee {
                    if !committee.contains(k) {
                        return false;
                    }
                }
                true
            }
        }
    }
}

/// get committee from the database for the given epoch. Will return an error if it can't be found.
fn get_committee(
    db: &impl ReDatabase,
    epoch: u32,
) -> Result<(B256, Vec<BlsPublicKey>), eyre::Error> {
    // Try to recover by downloading the epoch record and cert from a peer.
    if epoch == 0 {
        // If we can't find the genesis committee something is very wrong.
        let committee =
            db.get_committee_keys(0).ok_or_eyre("always can retreive epoch 0 committee")?;
        return Ok((B256::default(), committee));
    }

    db.get::<EpochRecords>(&(epoch - 1))
        .ok()
        .flatten()
        .map(|prev| (prev.digest(), prev.next_committee.clone()))
        .ok_or_else(|| eyre::eyre!("Failed to retrieve committee for epoch {epoch}"))
}

/// Asks peers for records from last_epoch to requested_epoch.
/// Returns the Epoch that was last retrieved.
async fn collect_epoch_records<DB>(
    last_epoch: Epoch,
    db: &DB,
    primary_handle: &PrimaryNetworkHandle,
) -> Epoch
where
    DB: ReDatabase,
{
    let mut result_epoch = last_epoch;
    for epoch in last_epoch.. {
        // If we already have epoch record AND it's certificate then continue.
        if let Some((_, Some(_))) = db.get_epoch_by_number(epoch) {
            continue;
        }
        // Try to recover by downloading the epoch record and cert from a peer.
        match primary_handle.request_epoch_cert(Some(epoch), None).await {
            Ok((epoch_rec, cert)) => {
                let (parent_hash, committee) =
                    if let Ok((parent_hash, committee)) = get_committee(db, epoch) {
                        (parent_hash, committee)
                    } else {
                        // We are missing epoch records.
                        // Should not be here but if so just skipping won't really help...
                        // Reduce last_epoch by one and once this loop finishes skipping we can
                        // try to get the missing epoch again.
                        return epoch - 1;
                    };
                // Verify the epoch has the expected parent and committee and is signed by
                // that committee.
                if parent_hash == epoch_rec.parent_hash
                    && epoch_committee_valid(&epoch_rec, &committee)
                    && epoch_rec.verify_with_cert(&cert)
                {
                    let epoch_hash = epoch_rec.digest();
                    if let Err(e) = db.save_epoch_record_with_cert(&epoch_rec, &cert) {
                        tracing::error!(
                            target: "epoch-manager",
                            "failed to save epoch record with cert for epoch {epoch}: {e}",
                        );
                        continue;
                    }
                    result_epoch = epoch;
                    info!(
                        target: "epoch-manager",
                        "retrieved cert for epoch {epoch}: {epoch_hash} from a peer",
                    );
                }
            }
            Err(err) => {
                // We delibrately go past the latest epoch so this is expected to happen.
                info!(
                    target: "epoch-manager",
                    "failed to retrieve epoch from a peer {epoch}: {err}",
                );
            }
        }
        if result_epoch != epoch {
            break;
        }
    }
    result_epoch
}

/// Spawn a long running task to collect missing epoch records.
///
/// Most likely because a node is syncing.
pub async fn spawn_epoch_record_collector<DB>(
    db: DB,
    primary_handle: PrimaryNetworkHandle,
    consensus_bus: ConsensusBus,
    node_task_spawner: TaskSpawner,
    node_shutdown: Noticer,
) -> eyre::Result<()>
where
    DB: ReDatabase,
{
    let mut epoch_rx = consensus_bus.requested_missing_epoch().subscribe();
    node_task_spawner.spawn_critical_task("Epoch Record Collector", async move {
        let mut last_epoch = if let Some((last_epoch, _)) = db.last_record::<EpochRecords>() {
            last_epoch
        } else {
            0
        };
        if last_epoch == 0 {
            while get_committee(&db, last_epoch).is_err() {
                tokio::select! {
                    _ = &node_shutdown => {
                        return;
                    },
                    _ = tokio::time::sleep(std::time::Duration::from_millis(100)) => { }
                }
            }
        }
        loop {
            let requested_epoch = *epoch_rx.borrow();
            if requested_epoch > last_epoch {
                last_epoch = collect_epoch_records(last_epoch, &db, &primary_handle).await;
                if last_epoch < requested_epoch {
                    // Small sanity check in case someone sends a malicious large epoch restore to
                    // sanity.
                    consensus_bus.requested_missing_epoch().send_replace(last_epoch);
                }
            }
            // Wait until the watch is updated to indicate we have more work to do.
            tokio::select!(
                _ = &node_shutdown => {
                    break;  // Break the outer loop.
                },
                _ = epoch_rx.changed() => { }
            );
        }
    });
    Ok(())
}
