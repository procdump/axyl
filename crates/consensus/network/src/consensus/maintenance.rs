use crate::{
    codec::RLMessage,
    consensus::types::{
        MAX_PENDING_INBOUND_REQUESTS, MAX_PENDING_KAD_QUERIES, MAX_PENDING_OUTBOUND_REQUESTS,
    },
    error::NetworkError,
    types::NetworkEvent,
    ConsensusNetwork,
};
use rayls_infrastructure_types::{Database, RaylsSender};
use tracing::warn;

impl<Req, Res, DB, Events> ConsensusNetwork<Req, Res, DB, Events>
where
    Req: RLMessage,
    Res: RLMessage,
    DB: Database,
    Events: RaylsSender<NetworkEvent<Req, Res>> + Send + 'static,
{
    /// Rayls: Remove stale entries from request tracking maps to prevent unbounded growth.
    pub(super) fn cleanup_request_maps(&mut self) {
        // Clean up outbound requests if too many are pending
        let outbound_len = self.outbound_requests.len();
        if outbound_len > MAX_PENDING_OUTBOUND_REQUESTS {
            warn!(
                target: "network",
                count = outbound_len,
                "too many pending outbound requests, clearing oldest"
            );
            // Clear half and notify callers of error
            let to_remove = outbound_len / 2;
            let mut removed = 0;
            for (_, sender) in self.outbound_requests.extract_if(|_, _| {
                removed += 1;
                removed <= to_remove
            }) {
                let _ = sender.send(Err(NetworkError::RequestQueueOverflow));
            }
        }

        // Clean up inbound requests if too many are pending
        let inbound_len = self.inbound_requests.len();
        if inbound_len > MAX_PENDING_INBOUND_REQUESTS {
            warn!(
                target: "network",
                count = inbound_len,
                "too many pending inbound requests, clearing oldest"
            );
            // Clear half and notify handlers of cancellation
            let to_remove = inbound_len / 2;
            let mut removed = 0;
            for (_, sender) in self.inbound_requests.extract_if(|_, _| {
                removed += 1;
                removed <= to_remove
            }) {
                let _ = sender.send(());
            }
        }

        // Clean up kad queries if too many are pending
        let kad_len = self.kad_record_queries.len();
        if kad_len > MAX_PENDING_KAD_QUERIES {
            warn!(
                target: "network-kad",
                count = kad_len,
                "too many pending kad queries, clearing oldest"
            );
            // Just clear without notifying - these are internal queries
            let to_remove = kad_len - MAX_PENDING_KAD_QUERIES / 2;
            let keys: Vec<_> = self.kad_record_queries.keys().take(to_remove).copied().collect();
            for key in keys {
                self.kad_record_queries.remove(&key);
            }
        }
    }
}
