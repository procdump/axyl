use crate::{
    codec::RLMessage,
    consensus::types::{RecordInvalidReason, SECONDS_IN_FUTURE_RECORD_ALLOWANCE},
    peers::Penalty,
    types::{NetworkEvent, NetworkResult, NodeRecord},
    ConsensusNetwork,
};
use libp2p::{
    kad::{
        self,
        store::{Error, RecordStore},
        ProviderRecord, QueryId, RecordKey,
    },
    PeerId,
};
use rayls_infrastructure_types::{encode, now, try_decode, BlsPublicKey, Database, RaylsSender};
use tracing::{debug, error, info, trace, warn};

impl<Req, Res, DB, Events> ConsensusNetwork<Req, Res, DB, Events>
where
    Req: RLMessage,
    Res: RLMessage,
    DB: Database,
    Events: RaylsSender<NetworkEvent<Req, Res>> + Send + 'static,
{
    /// Verify the record was signed by the key and the publisher matches the network key in the
    /// record.
    fn peer_record_valid_decoded(
        &self,
        key: &BlsPublicKey,
        publisher: Option<PeerId>,
        node_record: &NodeRecord,
    ) -> Result<(), String> {
        // verify bls signature
        if node_record.verify(key).is_err() {
            return Err(format!(
                "NodeRecord validation failed: invalid signature for record with key {:?}",
                key
            ));
        }

        // verify publisher matches the network public key in the record
        // this prevents replay attacks where malicious nodes republish outdated records
        let expected_peer_id: PeerId = node_record.info.pubkey.clone().into();
        if publisher.is_none_or(|p| p != expected_peer_id) {
            return Err(format!("NodeRecord validation failed: publisher {:?} doesn't match network key (expected {:?})", publisher, expected_peer_id));
        }

        Ok(())
    }

    /// Verify the record was signed by the key and the publisher matches the network key in the
    /// record.
    pub(super) fn peer_record_valid(
        &self,
        record: &kad::Record,
    ) -> Option<(BlsPublicKey, NodeRecord)> {
        let key = BlsPublicKey::from_literal_bytes(record.key.as_ref()).ok()?;
        let node_record = try_decode::<NodeRecord>(record.value.as_ref()).ok()?;

        // verify bls signature
        if let Err(e) = self.peer_record_valid_decoded(&key, record.publisher, &node_record) {
            warn!(target: "network-kad", ?e, "peer record failed validation");
            return None;
        }

        Some((key, node_record))
    }

    /// Process event from kademlia behavior.
    pub(super) fn process_kad_event(&mut self, event: kad::Event) -> NetworkResult<()> {
        match event {
            kad::Event::InboundRequest { request } => {
                trace!(target: "network-kad", "inbound {request:?}");
                match request {
                    kad::InboundRequest::FindNode { num_closer_peers: _ } => {}
                    kad::InboundRequest::GetProvider {
                        num_closer_peers: _,
                        num_provider_peers: _,
                    } => {}
                    kad::InboundRequest::AddProvider { record } => {
                        self.process_add_provider_request(record)
                    }
                    kad::InboundRequest::GetRecord { num_closer_peers: _, present_locally: _ } => {}
                    kad::InboundRequest::PutRecord { source, connection: _, record } => {
                        if let Some(record) = record {
                            self.process_kad_put_request(source, record);
                        }
                    }
                }
            }
            kad::Event::OutboundQueryProgressed { id: query_id, result, stats: _, step } => {
                match result {
                    kad::QueryResult::GetProviders(Ok(kad::GetProvidersOk::FoundProviders {
                        key,
                        providers,
                        ..
                    })) => {
                        debug!(
                            target: "network-kad",
                            key = ?BlsPublicKey::from_literal_bytes(key.as_ref()),
                            ?providers,
                            "kad::GetProviders::Ok"
                        );
                    }
                    kad::QueryResult::GetProviders(Err(err)) => {
                        error!(target: "network-kad", "Failed to get providers: {err:?}");
                    }
                    kad::QueryResult::GetRecord(Ok(kad::GetRecordOk::FoundRecord(
                        kad::PeerRecord { record, peer },
                    ))) => {
                        if let Some((key, value)) = self.peer_record_valid(&record) {
                            trace!(target: "network-kad", "Got record {key} {value:?}");
                            self.process_kad_query_result(&query_id, record, peer, step.last);
                        } else {
                            trace!(target: "network-kad", "Received invalid peer record!");

                            // assess penalty for invalid peer record
                            if let Some(peer_id) = peer {
                                self.swarm
                                    .behaviour_mut()
                                    .peer_manager
                                    .process_penalty(peer_id, Penalty::Fatal);
                            }

                            // ensure query cleaned up
                            if step.last {
                                self.close_kad_query(&query_id);
                            }
                        }
                    }
                    kad::QueryResult::GetRecord(Ok(
                        kad::GetRecordOk::FinishedWithNoAdditionalRecord { cache_candidates },
                    )) => {
                        // TODO: configure caching and see issue #301
                        // self.swarm.behaviour_mut().kademlia.put_record_to(record, peers, quorum);

                        debug!(target: "network-kad", ?cache_candidates, "FinishedWithNoAdditionalRecord - failed to find record");
                        self.close_kad_query(&query_id);
                    }
                    kad::QueryResult::GetRecord(Err(err)) => {
                        debug!(
                            target: "network-kad",
                            key = ?BlsPublicKey::from_literal_bytes(err.key().as_ref()),
                            ?err,
                            "kad::GetRecord::Err"
                        );
                        self.close_kad_query(&query_id);
                    }
                    kad::QueryResult::PutRecord(Ok(kad::PutRecordOk { key })) => {
                        debug!(
                            target: "network-kad",
                            key = ?BlsPublicKey::from_literal_bytes(key.as_ref()),
                            "kad::PutRecordOk"
                        );
                    }
                    kad::QueryResult::PutRecord(Err(err)) => {
                        if !self.kad_expecting_to_fail_query_ids.contains(&query_id) {
                            error!(target: "network-kad", "Failed to put record: {err:?}, {query_id:?}");
                        }
                    }
                    kad::QueryResult::StartProviding(Ok(kad::AddProviderOk { key })) => {
                        debug!(
                            target: "network-kad",
                            key = ?BlsPublicKey::from_literal_bytes(key.as_ref()),
                            "kad::StartProviding::Ok"
                        );
                    }
                    kad::QueryResult::StartProviding(Err(err)) => {
                        warn!(
                            target: "network-kad",
                            key = ?BlsPublicKey::from_literal_bytes(err.key().as_ref()),
                            ?err,
                            "kad::StartProviding::Err"
                        );
                    }
                    kad::QueryResult::GetClosestPeers(Ok(result)) => {
                        // process peers for potential discovery attempts
                        debug!(target: "network-kad", ?result, "GetClosestPeers for discovery");
                        self.swarm
                            .behaviour_mut()
                            .peer_manager
                            .process_peers_for_discovery(result.peers);
                    }
                    _ => {}
                }
                self.kad_expecting_to_fail_query_ids.remove(&query_id);
            }
            kad::Event::RoutingUpdated { peer, is_new_peer, addresses, bucket_range, old_peer } => {
                debug!(target: "network-kad", "routing updated peer {peer:?} new {is_new_peer} addrs {addresses:?} bucketr {bucket_range:?} old {old_peer:?}");

                // update newly added peer
                if is_new_peer {
                    self.swarm.behaviour_mut().peer_manager.update_routing_for_peer(&peer, true);

                    // update old peer if evicted from routing table
                    if let Some(old) = old_peer {
                        self.swarm
                            .behaviour_mut()
                            .peer_manager
                            .update_routing_for_peer(&old, false);
                    }
                }
            }
            kad::Event::UnroutablePeer { peer } => {
                // unknown peer queried a record - noop
                trace!(target: "network-kad", "unroutable peer {peer:?}")
            }
            kad::Event::RoutablePeer { peer, address } => {
                // kad discovered a new peer - peer is added to table on `PeerEvent::Connected`
                trace!(target: "network-kad", "routable peer {peer:?}/{address:?}");
            }
            kad::Event::PendingRoutablePeer { peer, address } => {
                trace!(target: "network-kad", "pending routable peer {peer:?}/{address:?}")
            }
            kad::Event::ModeChanged { new_mode } => {
                trace!(target: "network-kad", "mode changed {new_mode:?}")
            }
        }
        Ok(())
    }

    /// Process an inbound kad put request.
    pub(super) fn process_kad_put_request(&mut self, source: PeerId, record: kad::Record) {
        trace!(
            target: "network-kad",
            ?source,
            publisher = ?record.publisher,
            value_len = record.value.len(),
            "received inbound kad PutRecord",
        );
        let Ok(decoded_record) = try_decode::<NodeRecord>(&record.value) else {
            error!(target: "network-kad", ?source, "failed to decode record value - rejecting put request");
            self.apply_invalid_kad_request_penalty(
                &source,
                &RecordInvalidReason::InvalidPeerRecord("decoding failed".to_string()),
            );
            return;
        };

        let Ok(key) = BlsPublicKey::from_literal_bytes(record.key.as_ref()) else {
            error!(target: "network-kad", ?source, "invalid record key format - rejecting put request");
            self.apply_invalid_kad_request_penalty(&source, &RecordInvalidReason::InvalidKeyFormat);
            return;
        };

        if let Err(reason) =
            self.verify_kad_put_authenticity(&key, &source, &record, &decoded_record)
        {
            if matches!(
                reason,
                RecordInvalidReason::PublisherBanned
                    | RecordInvalidReason::SourceBanned
                    | RecordInvalidReason::MissingPublisher
            ) {
                error!(target: "network-kad", ?reason, ?source, publisher=?record.publisher, "rejecting put request for record");
                // handle race condition with PM
                self.swarm.behaviour_mut().kademlia.remove_record(&record.key);
            }
            self.apply_invalid_kad_request_penalty(&source, &reason);
            error!(target: "network-kad", ?source, ?reason, "failed to process kad put request");
            return;
        }

        // OldRecord branch: record already lives in our store from a prior PUT,
        // so refreshing the in-memory BLS mapping (wiped on restart) is safe.
        if !self.is_newer_record(&record.key, &decoded_record) {
            trace!(target: "network-kad", ?source, "duplicate record, refreshing known_peers");
            self.swarm.behaviour_mut().peer_manager.add_known_peer(key, decoded_record.info);
            return;
        }

        // Fresh record: store it first. add_known_peer only on success so a full
        // store cannot be used as a side-channel to populate known_peers (PR #280).
        if let Err(err) = self.swarm.behaviour_mut().kademlia.store_mut().put(record) {
            self.handle_kad_store_error(&source, err);
            return;
        }

        trace!(target: "network-kad", %key, "stored fresh kad record");
        self.swarm.behaviour_mut().peer_manager.add_known_peer(key, decoded_record.info);
    }

    /// Process on inbound add provider request.
    fn process_add_provider_request(&mut self, record: Option<ProviderRecord>) {
        if let Some(record) = record {
            let peer_id = record.provider;

            if self.swarm.behaviour().peer_manager.peer_banned(&peer_id) {
                warn!(target: "network-kad", ?peer_id, "rejecting add provider from banned peer");
                self.apply_invalid_kad_request_penalty(
                    &peer_id,
                    &RecordInvalidReason::SourceBanned,
                );
                return;
            }

            if let Err(err) = self.swarm.behaviour_mut().kademlia.store_mut().add_provider(record) {
                self.handle_kad_store_error(&peer_id, err);
            }
        }
    }

    fn verify_kad_put_authenticity(
        &mut self,
        key: &BlsPublicKey,
        source: &PeerId,
        record: &kad::Record,
        decoded_record: &NodeRecord,
    ) -> Result<(), RecordInvalidReason> {
        let publisher = record.publisher.ok_or(RecordInvalidReason::MissingPublisher)?;

        let pm = &self.swarm.behaviour().peer_manager;
        if pm.peer_banned(&publisher) {
            return Err(RecordInvalidReason::PublisherBanned);
        }
        if pm.peer_banned(source) {
            return Err(RecordInvalidReason::SourceBanned);
        }

        if decoded_record.info.timestamp > now() + SECONDS_IN_FUTURE_RECORD_ALLOWANCE {
            return Err(RecordInvalidReason::TimestampTooFarInFuture);
        }

        // verify record signature and ensure publisher matches record's network
        self.peer_record_valid_decoded(key, record.publisher, decoded_record)
            .map_err(RecordInvalidReason::InvalidPeerRecord)
    }

    /// Handle a store error from `add_provider()` or `put()`.
    ///
    /// Map the store error to a penalty reason and penalize the source peer.
    fn handle_kad_store_error(&mut self, peer_id: &PeerId, err: Error) {
        let reason = match err {
            Error::MaxRecords => {
                warn!(target: "network-kad", ?peer_id, "kad store at record capacity");
                RecordInvalidReason::MaxRecordSizeExceeded
            }
            Error::MaxProvidedKeys => {
                warn!(target: "network-kad", ?peer_id, "kad store at provider key capacity");
                RecordInvalidReason::MaxProvidedKeysExceeded
            }
            Error::ValueTooLarge => {
                warn!(target: "network-kad", ?peer_id, "kad record value too large");
                RecordInvalidReason::InvalidPeerRecord("value too large".to_string())
            }
        };
        self.apply_invalid_kad_request_penalty(peer_id, &reason);
    }

    fn apply_invalid_kad_request_penalty(
        &mut self,
        peer_id: &PeerId,
        reason: &RecordInvalidReason,
    ) {
        match reason {
            RecordInvalidReason::MissingPublisher
            | RecordInvalidReason::PublisherBanned
            | RecordInvalidReason::SourceBanned
            | RecordInvalidReason::InvalidKeyFormat
            | RecordInvalidReason::InvalidPeerRecord(_) => {
                self.process_fatal_penalty(peer_id, reason);
            }
            RecordInvalidReason::TimestampTooFarInFuture
            | RecordInvalidReason::MaxRecordSizeExceeded
            | RecordInvalidReason::MaxProvidedKeysExceeded => {
                self.process_mild_penalty(peer_id, reason);
            }
        }
    }

    fn process_mild_penalty(&mut self, peer_id: &PeerId, reason: &RecordInvalidReason) {
        trace!(target: "network-kad", ?peer_id, "processing mild penalty for {:?}", reason);
        self.swarm.behaviour_mut().peer_manager.process_penalty(*peer_id, Penalty::Mild);
    }

    fn process_fatal_penalty(&mut self, peer_id: &PeerId, reason: &RecordInvalidReason) {
        trace!(target: "network-kad", ?peer_id, "processing fatal penalty for {:?}", reason);
        self.swarm.behaviour_mut().peer_manager.process_penalty(*peer_id, Penalty::Fatal);
    }

    /// Check the local kad store to compare record timestamps.
    ///
    /// This method compares timestamps for verified records to ensure the latest record
    /// is stored (prevents replay attacks). Also returns `true` if the record is not found.
    /// It is the caller's responsibility to ensure records are verified and valid.
    fn is_newer_record(&mut self, key: &RecordKey, node_record: &NodeRecord) -> bool {
        let store = self.swarm.behaviour_mut().kademlia.store_mut();

        if let Some(existing) = store.get(key) {
            match try_decode::<NodeRecord>(&existing.value) {
                Ok(existing_record) => {
                    // return true if the new record is newer
                    existing_record.info.timestamp < node_record.info.timestamp
                }
                _ => false,
            }
        } else {
            // return true if record is not in local store
            true
        }
    }

    /// Logic to process a kad record request.
    ///
    /// This method checks:
    /// - the peer record is signed
    /// - the returned key matches the request
    /// - the latest node record is used
    fn process_kad_query_result(
        &mut self,
        query_id: &QueryId,
        record: kad::Record,
        peer: Option<PeerId>,
        is_last_step: bool,
    ) {
        // ensure returned record is valid, otherwise assess penalty
        if let Some((key, new_record)) = self.peer_record_valid(&record) {
            trace!(target: "network-kad", "Got record {key} {new_record:?}");
            // return if query id unknown - should not happen
            let Some(query) = self.kad_record_queries.get_mut(query_id) else { return };

            // ensure returned value matches request
            if query.request == key {
                match &mut query.result {
                    None => query.result = Some(new_record),
                    Some(tracked) if tracked.info.timestamp < new_record.info.timestamp => {
                        *tracked = new_record
                    }
                    Some(_) => {} // keep existing record
                }
            } else {
                // assess penalty for returning record that doesn't match key
                if let Some(peer_id) = peer {
                    trace!(target: "network-kad", ?peer_id, "processing fatal penalty for query record key mismatch");
                    self.swarm
                        .behaviour_mut()
                        .peer_manager
                        .process_penalty(peer_id, Penalty::Fatal);
                }
            }
        } else {
            // record signature invalid
            warn!(target: "network-kad", "Received invalid peer record!");

            // assess penalty for invalid peer record
            if let Some(peer_id) = peer {
                self.swarm.behaviour_mut().peer_manager.process_penalty(peer_id, Penalty::Fatal);
            }
        }

        // handle last step
        if is_last_step {
            self.close_kad_query(query_id);
        }
    }

    /// Cleanup kad record queries (called on last step).
    fn close_kad_query(&mut self, query_id: &QueryId) {
        if let Some(query) = self.kad_record_queries.remove(query_id) {
            if let Some(node_record) = query.result {
                self.swarm
                    .behaviour_mut()
                    .peer_manager
                    .add_known_peer(query.request, node_record.info);
            }
        }
    }

    /// Load known peers from the persistent KAD store into the in-memory cache at startup.
    ///
    /// `KadStore` is persisted across restarts, but `known_peerids` lives only in memory
    /// and is wiped on every boot. Without this preload, a restarted node rejects
    /// subsequent re-PUTs from peers as `OldRecord` and never repopulates the BLS mapping
    /// until those peers themselves restart with a fresh timestamp.
    pub(super) fn load_known_peers_from_kad_store(&mut self) {
        let local_peer_id = *self.swarm.local_peer_id();
        let records: Vec<kad::Record> = self
            .swarm
            .behaviour_mut()
            .kademlia
            .store_mut()
            .records()
            .map(|r| r.into_owned())
            .collect();
        let total = records.len();
        let mut loaded = 0_usize;

        for record in &records {
            let Some((bls_key, node_record)) = self.peer_record_valid(record) else {
                continue;
            };
            let peer_id = PeerId::from_public_key(&node_record.info.pubkey);
            if peer_id == local_peer_id {
                continue;
            }
            if self.swarm.behaviour().peer_manager.peer_banned(&peer_id) {
                continue;
            }
            self.swarm.behaviour_mut().peer_manager.add_known_peer(bls_key, node_record.info);
            loaded += 1;
        }
        info!(
            target: "network-kad",
            total,
            loaded,
            "loaded known peers from persistent kad store",
        );
    }

    /// Return a kademlia record keyed on our BlsPublicKey with our peer_id and network addresses.
    /// Return None if we don't have any confirmed external addresses yet.
    pub(super) fn get_peer_record(&self) -> kad::Record {
        let key = kad::RecordKey::new(&self.key_config.primary_public_key());
        kad::Record {
            key,
            value: encode(&self.node_record),
            publisher: Some(*self.swarm.local_peer_id()),
            expires: None, // never expire
        }
    }

    /// Publish and provide our network addresses and peer id under our BLS public key for
    /// discovery.
    pub(super) fn provide_our_data(&mut self) {
        let record = self.get_peer_record();
        info!(target: "network-kad", ?record, "Providing our record to kademlia for peer {:?}", self.swarm.local_peer_id());
        let key = record.key.clone();

        let put_record_result =
            self.swarm.behaviour_mut().kademlia.put_record(record, kad::Quorum::One);
        match put_record_result {
            Err(err) => {
                error!(target: "network-kad", "Failed to store record locally: {err}");
            }
            Ok(query_id) => {
                // if there are no peers then the PUT REQUEST to DHT is expected to fail. It will be
                // handled later on in publish_our_data_to_peer which is invoked when a peer
                // connects.
                let has_peers =
                    self.swarm.behaviour_mut().kademlia.kbuckets().any(|b| b.num_entries() > 0);
                if !has_peers {
                    self.kad_expecting_to_fail_query_ids.insert(query_id);
                }
            }
        }

        if let Err(err) = self.swarm.behaviour_mut().kademlia.start_providing(key) {
            error!(target: "network-kad", "Failed to start providing key: {err}");
        }
    }

    /// Publish our network addresses and peer id AND to the network under our BLS public key for
    /// discovery.
    pub(super) fn publish_our_data_to_peer(&mut self, peer: PeerId) {
        let record = self.get_peer_record();
        info!(target: "network-kad", "Publishing our record to kademlia. Peer: {:?}", peer);

        // Publish to the specified peer.
        let _ = self.swarm.behaviour_mut().kademlia.put_record_to(
            record.clone(),
            vec![peer].into_iter(),
            kad::Quorum::One,
        );

        // Also publish our record locally and to the network.
        if let Err(err) = self.swarm.behaviour_mut().kademlia.put_record(record, kad::Quorum::One) {
            error!(target: "network-kad", "Failed to publish record: {err}");
        }
    }
}
