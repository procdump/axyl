//! Generic vote aggregation with double-vote protection.

use crate::{AuthorityIdentifier, VotingPower};
use std::collections::HashSet;

/// A vote that can be attributed to a unique authority.
///
/// Callers are responsible for verifying signatures and committee membership
/// before appending votes to the aggregator.
pub trait Votable {
    /// Extract the voter's authority identity for dedup.
    fn voter_id(&self) -> AuthorityIdentifier;
}

/// Aggregation error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AggregatorError {
    /// Authority already voted.
    DuplicateVote(String),
}

impl std::fmt::Display for AggregatorError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::DuplicateVote(id) => write!(f, "duplicate vote from {id}"),
        }
    }
}

impl std::error::Error for AggregatorError {}

/// Generic vote aggregator with built-in double-vote protection.
#[derive(Debug)]
pub struct VotesAggregator<V> {
    seen: HashSet<AuthorityIdentifier>,
    votes: Vec<V>,
    weight: VotingPower,
    threshold: VotingPower,
}

impl<V: Votable> VotesAggregator<V> {
    /// Create a new aggregator with the given quorum threshold.
    pub fn new(threshold: VotingPower) -> Self {
        Self { seen: HashSet::new(), votes: Vec::new(), weight: 0, threshold }
    }

    /// Append a pre-verified vote with the given weight.
    ///
    /// Returns `Ok(true)` when quorum is reached. Returns
    /// `Err(AggregatorError::DuplicateVote)` if this authority already voted.
    pub fn append(&mut self, vote: V, weight: VotingPower) -> Result<bool, AggregatorError> {
        let voter = vote.voter_id();
        if !self.seen.insert(voter.clone()) {
            return Err(AggregatorError::DuplicateVote(voter.to_string()));
        }
        self.weight += weight;
        self.votes.push(vote);
        Ok(self.weight >= self.threshold)
    }

    pub fn count(&self) -> usize {
        self.seen.len()
    }

    pub fn weight(&self) -> VotingPower {
        self.weight
    }

    pub fn into_votes(self) -> Vec<V> {
        self.votes
    }

    pub fn votes(&self) -> &[V] {
        &self.votes
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Minimal vote type for testing.
    #[derive(Clone, Debug)]
    struct TestVote {
        voter: AuthorityIdentifier,
    }

    impl TestVote {
        fn new(id: u8) -> Self {
            Self { voter: AuthorityIdentifier::dummy_for_test(id) }
        }
    }

    impl Votable for TestVote {
        fn voter_id(&self) -> AuthorityIdentifier {
            self.voter.clone()
        }
    }

    #[test]
    fn single_validator_cannot_vote_twice() {
        let mut agg = VotesAggregator::new(3);
        let vote = TestVote::new(1);

        assert!(agg.append(vote.clone(), 1).is_ok());
        assert!(agg.append(vote, 1).is_err());
        assert_eq!(agg.count(), 1);
        assert_eq!(agg.weight(), 1);
    }

    #[test]
    fn single_validator_cannot_reach_quorum_alone() {
        // 4-node committee, threshold = (4/3)+1 = 2
        let mut agg = VotesAggregator::new(2);
        let vote = TestVote::new(1);

        assert_eq!(agg.append(vote.clone(), 1), Ok(false));
        // second vote from same validator is rejected
        assert!(agg.append(vote, 1).is_err());
        // weight stays at 1, never reaches threshold of 2
        assert_eq!(agg.weight(), 1);
        assert_eq!(agg.count(), 1);
    }

    #[test]
    fn quorum_reached_with_unique_voters() {
        let mut agg = VotesAggregator::new(3);

        assert_eq!(agg.append(TestVote::new(1), 1), Ok(false));
        assert_eq!(agg.append(TestVote::new(2), 1), Ok(false));
        assert_eq!(agg.append(TestVote::new(3), 1), Ok(true));
        assert_eq!(agg.count(), 3);
    }

    #[test]
    fn weighted_quorum_respects_voting_power() {
        // threshold of 7, one voter has weight 5, another has weight 3
        let mut agg = VotesAggregator::new(7);

        assert_eq!(agg.append(TestVote::new(1), 5), Ok(false));
        assert_eq!(agg.append(TestVote::new(2), 3), Ok(true));
        assert_eq!(agg.weight(), 8);
        assert_eq!(agg.count(), 2);
    }

    #[test]
    fn duplicate_does_not_advance_weight() {
        let mut agg = VotesAggregator::new(3);

        assert_eq!(agg.append(TestVote::new(1), 1), Ok(false));
        // spam 10 duplicates from same voter
        for _ in 0..10 {
            assert!(agg.append(TestVote::new(1), 1).is_err());
        }
        // weight unchanged
        assert_eq!(agg.weight(), 1);
        assert_eq!(agg.count(), 1);
    }

    #[test]
    fn into_votes_returns_only_accepted() {
        let mut agg = VotesAggregator::new(10);

        agg.append(TestVote::new(1), 1).unwrap();
        agg.append(TestVote::new(2), 1).unwrap();
        let _ = agg.append(TestVote::new(1), 1); // duplicate, rejected

        let votes = agg.into_votes();
        assert_eq!(votes.len(), 2);
    }
}
