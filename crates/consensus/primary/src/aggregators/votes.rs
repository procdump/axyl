//! Aggregate votes after proposing a header.

use rayls_consensus_primary_metrics::PrimaryMetrics;
use rayls_infrastructure_types::{
    ensure,
    error::{DagError, DagResult},
    to_intent_message, AuthorityIdentifier, BlsSignature, Certificate, Committee, Header,
    ProtocolSignature, SignatureVerificationState, Votable, Vote, VotesAggregator,
};
use std::sync::Arc;
use tracing::trace;

/// Aggregates votes for a particular header to form a certificate.
pub(crate) struct HeaderVotesAggregator {
    inner: VotesAggregator<Vote>,
    /// (authority, signature) pairs for certificate construction.
    verified_votes: Vec<(AuthorityIdentifier, BlsSignature)>,
    metrics: Arc<PrimaryMetrics>,
}

impl HeaderVotesAggregator {
    pub(crate) fn new(metrics: Arc<PrimaryMetrics>, committee: &Committee) -> Self {
        metrics.votes_received_last_round.set(0);

        Self {
            inner: VotesAggregator::new(committee.quorum_threshold()),
            verified_votes: Vec::new(),
            metrics,
        }
    }

    /// Append the vote to the collection.
    pub(crate) fn append(
        &mut self,
        vote: Vote,
        committee: &Committee,
        header: &Header,
    ) -> DagResult<Option<Certificate>> {
        let author = vote.voter_id();

        // ensure digest matches the header
        ensure!(vote.header_digest == header.digest(), DagError::InvalidHeaderDigest);

        // ensure this came from a committee member and that the signature is valid
        if let Some(auth) = committee.authority(&author) {
            ensure!(
                vote.signature()
                    .verify_secure(&to_intent_message(vote.header_digest), auth.protocol_key()),
                DagError::InvalidSignature
            );
        } else {
            return Err(DagError::UnknownAuthority(author.to_string()));
        }

        // dedup + weight accumulation via generic aggregator
        let weight = committee.voting_power_by_id(&author);
        let sig = *vote.signature();
        let quorum = self
            .inner
            .append(vote, weight)
            .map_err(|_| DagError::AuthorityReuse(author.to_string()))?;

        self.verified_votes.push((author, sig));

        // update metrics
        self.metrics.votes_received_last_round.set(self.verified_votes.len() as i64);

        // check if this vote reaches quorum
        if quorum {
            let mut cert = Certificate::new_unverified(
                committee,
                header.clone(),
                self.verified_votes.clone(),
            )?;
            trace!(target: "primary::votes_aggregator", ?cert, "certificate verified");
            cert.set_signature_verification_state(SignatureVerificationState::VerifiedDirectly(
                cert.aggregated_signature().ok_or(DagError::InvalidSignature)?,
            ));

            return Ok(Some(cert));
        }
        Ok(None)
    }
}
