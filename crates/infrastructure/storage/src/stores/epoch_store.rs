//! Trait and helpers for accessing Epoch data in the consensus DB.
use rayls_infrastructure_types::{
    BlockHash, BlsPublicKey, Database, DbTx, DbTxMut, Epoch, EpochCertificate, EpochRecord,
};

use crate::{
    tables::{EpochCerts, EpochRecords, EpochRecordsIndex},
    StoreResult,
};

/// Helpers for Epoch DB access.
pub trait EpochStore {
    /// Retrieve the committee keys for epoch if available in the DB.
    fn get_committee_keys(&self, epoch: Epoch) -> Option<Vec<BlsPublicKey>>;

    /// Save an epoch record *without* a certificate.
    ///
    /// Only for the epoch-0 unsigned dummy record written at startup. Every real
    /// record must be written together with its cert via
    /// [`EpochStore::save_epoch_record_with_cert`] to avoid an unrecoverable
    /// record-without-cert half-state on disk.
    fn save_epoch_record(&self, epoch_rec: &EpochRecord) -> StoreResult<()>;

    /// Save an epoch record with its certificate.
    fn save_epoch_record_with_cert(
        &self,
        epoch_rec: &EpochRecord,
        cert: &EpochCertificate,
    ) -> StoreResult<()>;

    /// Retrieve the epoch record and certificate (if available) by number.
    fn get_epoch_by_number(&self, epoch: Epoch) -> Option<(EpochRecord, Option<EpochCertificate>)>;

    /// Retrieve the epoch record and certificate (if available) by hash.
    fn get_epoch_by_hash(&self, hash: BlockHash)
        -> Option<(EpochRecord, Option<EpochCertificate>)>;
}

impl<DB: Database> EpochStore for DB {
    fn get_committee_keys(&self, epoch: Epoch) -> Option<Vec<BlsPublicKey>> {
        if let Ok(Some(rec)) = self.get::<EpochRecords>(&epoch) {
            Some(rec.committee)
        } else if let Ok(Some(rec)) = self.get::<EpochRecords>(&(epoch.saturating_sub(1))) {
            Some(rec.next_committee)
        } else {
            None
        }
    }

    fn save_epoch_record(&self, epoch_rec: &EpochRecord) -> StoreResult<()> {
        let epoch_hash = epoch_rec.digest();
        let epoch = epoch_rec.epoch;

        self.with_write_txn(|tx| {
            if epoch_rec.epoch == 0 {
                // Should have a "dummy" epoch 0 record, remove just in case the backend has a
                // dumb insert or something.
                tx.remove::<EpochRecords>(&epoch)?;
            }
            tx.insert::<EpochRecordsIndex>(&epoch_hash, &epoch)?;
            tx.insert::<EpochRecords>(&epoch, epoch_rec)?;
            Ok(())
        })
    }

    fn save_epoch_record_with_cert(
        &self,
        epoch_rec: &EpochRecord,
        cert: &EpochCertificate,
    ) -> StoreResult<()> {
        let epoch_hash = epoch_rec.digest();
        let epoch = epoch_rec.epoch;

        self.with_write_txn(|tx| {
            tx.insert::<EpochRecordsIndex>(&epoch_hash, &epoch)?;
            tx.insert::<EpochRecords>(&epoch, epoch_rec)?;
            tx.insert::<EpochCerts>(&epoch_hash, cert)?;
            Ok(())
        })
    }

    fn get_epoch_by_number(&self, epoch: Epoch) -> Option<(EpochRecord, Option<EpochCertificate>)> {
        self.with_read_txn(|txn| {
            let record = txn.get::<EpochRecords>(&epoch)?;
            if let Some(record) = record {
                let digest = record.digest();
                let epoch_cert = txn.get::<EpochCerts>(&digest)?;
                return Ok((record, epoch_cert));
            }

            Err(eyre::eyre!("No epoch record found"))
        })
        .ok()
    }

    fn get_epoch_by_hash(
        &self,
        hash: BlockHash,
    ) -> Option<(EpochRecord, Option<EpochCertificate>)> {
        self.with_read_txn(|txn| {
            let epoch = txn.get::<EpochRecordsIndex>(&hash)?;
            if let Some(epoch) = epoch {
                if let Some(record) = txn.get::<EpochRecords>(&epoch)? {
                    let digest = record.digest();
                    let epoch_cert = txn.get::<EpochCerts>(&digest)?;

                    return Ok((record, epoch_cert));
                }
            }

            Err(eyre::eyre!("No epoch record found"))
        })
        .ok()
    }
}
