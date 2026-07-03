//! Aggregate certificates for the round.

use crate::{error::CertManagerResult, ConsensusBus};
use rayls_infrastructure_types::{
    AuthorityIdentifier, Certificate, Committee, RaylsSender as _, Round, VotingPower,
};
use std::collections::{BTreeMap, HashSet};
use tracing::trace;

/// Manage certificates as they aggregate through rounds.
#[derive(Debug, Clone)]
pub(crate) struct CertificatesAggregatorManager {
    /// Collection of [CertificatesAggregator]s.
    aggregators: BTreeMap<Round, Box<CertificatesAggregator>>,
    /// Consensus bus to forward parents for a round to the proposer.
    consensus_bus: ConsensusBus,
    /// Round window for proactive eviction; mirrors the consensus `gc_depth`.
    gc_depth: Round,
}

impl CertificatesAggregatorManager {
    /// Create a new manager that evicts aggregators more than `gc_depth` rounds stale.
    pub(crate) fn new(consensus_bus: ConsensusBus, gc_depth: Round) -> Self {
        Self { aggregators: BTreeMap::new(), consensus_bus, gc_depth }
    }

    /// Append a certificate by round and alert proposer if quorum is reached (2f+1).
    pub(crate) async fn append_certificate(
        &mut self,
        certificate: Certificate,
        committee: &Committee,
    ) -> CertManagerResult<()> {
        let round = certificate.round();

        self.proactive_gc(round);

        // append certificate
        let quorum = self
            .aggregators
            .entry(round)
            .or_insert_with(|| Box::new(CertificatesAggregator::new()))
            .append(certificate, committee);

        // forward to proposer if enough parents to advance the round (2f+1)
        if let Some(parents) = quorum {
            self.consensus_bus.parents().send((parents, round)).await?;
        }

        Ok(())
    }

    /// Evicts aggregators more than `gc_depth` rounds below `latest_round`.
    ///
    /// Backstops [`Self::garbage_collect`] (which only advances on a commit) so a commit stall
    /// cannot grow this map without bound. Bounds by round, so eviction stays deterministic.
    fn proactive_gc(&mut self, latest_round: Round) {
        // no-op when the frontier is within `gc_depth` of round 0.
        if let Some(floor) = latest_round.checked_sub(self.gc_depth) {
            self.garbage_collect(&floor);
        }
    }

    /// Process the next gc round and remove old parents that can never be accepted in the DAG.
    pub(crate) fn garbage_collect(&mut self, gc_round: &Round) {
        // Pop the stale prefix (rounds <= gc_round); the map is round-sorted, so this is O(evicted)
        // instead of the O(n) scan `retain` does on every append.
        while let Some((&round, _)) = self.aggregators.first_key_value() {
            if round > *gc_round {
                break;
            }
            self.aggregators.pop_first();
        }
    }
}

/// Aggregate certificates until quorum is reached
#[derive(Debug, Clone)]
struct CertificatesAggregator {
    /// The accumulated amount of voting power in favor of a proposed header.
    ///
    /// This amount is used to verify enough voting power to reach quorum within the committee.
    weight: VotingPower,
    /// The certificates aggregated for this round.
    certificates: Vec<Certificate>,
    /// The collection of authority ids that have already voted.
    authorities_seen: HashSet<AuthorityIdentifier>,
}

impl CertificatesAggregator {
    /// Create a new instance of `Self`.
    fn new() -> Self {
        Self { weight: 0, certificates: Vec::new(), authorities_seen: HashSet::new() }
    }

    /// Append the certificate to the collection.
    ///
    /// This method protects against equivocation by keeping track of peers that have already issued
    /// certificates.
    fn append(
        &mut self,
        certificate: Certificate,
        committee: &Committee,
    ) -> Option<Vec<Certificate>> {
        let origin = certificate.origin().clone();

        // ensure authority hasn't issued certificate already
        if !self.authorities_seen.insert(origin.clone()) {
            return None;
        }

        // accumulate certificates and voting power
        self.certificates.push(certificate);
        self.weight += committee.voting_power_by_id(&origin);

        // check for quorum
        if self.weight >= committee.quorum_threshold() {
            trace!(target: "primary::certificate_aggregator", "quorum reached");
            // NOTE: do not reset the weight here
            //
            // this method could be called again if the proposer doesn't
            // advance the round
            return Some(self.certificates.drain(..).collect());
        }

        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rayls_consensus_primary::test_utils::make_optimal_signed_certificates;
    use rayls_infrastructure_storage::mem_db::MemDatabase;
    use rayls_infrastructure_types::Hash as _;
    use rayls_testing_test_utils_committee::CommitteeFixture;
    use std::collections::BTreeSet;

    /// A frozen GC round (commits stalled) must not let the aggregator map grow past the trailing
    /// `gc_depth` round window.
    #[tokio::test]
    async fn proactive_gc_bounds_aggregators_when_commits_stall() {
        const GC_DEPTH: Round = 4;
        const LAST_ROUND: Round = 50;

        let fixture = CommitteeFixture::builder(MemDatabase::default).randomize_ports(true).build();
        let committee = fixture.committee();
        let mut manager = CertificatesAggregatorManager::new(ConsensusBus::new(), GC_DEPTH);

        let genesis =
            Certificate::genesis(&committee).iter().map(|c| c.digest()).collect::<BTreeSet<_>>();
        let keys: Vec<_> = fixture.authorities().map(|a| (a.id(), a.keypair().copy())).collect();
        let (certs, _) =
            make_optimal_signed_certificates(1..=LAST_ROUND, &genesis, &committee, &keys);

        // A single author per round stays below quorum, so `garbage_collect` is never invoked:
        // only proactive eviction can bound the map, modelling a commit stall.
        let author = fixture.authorities().next().unwrap().id();
        let by_round: BTreeMap<Round, Certificate> =
            certs.into_iter().filter(|c| c.origin() == &author).map(|c| (c.round(), c)).collect();
        for (_, cert) in by_round {
            manager.append_certificate(cert, &committee).await.unwrap();
        }

        assert!(
            manager.aggregators.len() <= GC_DEPTH as usize + 1,
            "expected <= {} aggregators, got {}",
            GC_DEPTH as usize + 1,
            manager.aggregators.len()
        );
        // Stale low rounds evicted; only the trailing window survives.
        assert!(manager.aggregators.keys().all(|&r| r > LAST_ROUND - GC_DEPTH));
        assert!(!manager.aggregators.contains_key(&1));
    }
}
