//! Reputation scores for validation nodes participating in consensus.

use crate::{
    bcs_layout::{BcsCursor, BcsLayout, BcsLayoutError},
    AuthorityIdentifier, Committee,
};
use serde::{Deserialize, Serialize};
use std::{cmp::Ordering, collections::HashMap};

/// The reputation scores for authorities participating in consensus.
#[derive(Serialize, Deserialize, Clone, Debug, Default, Eq, PartialEq)]
pub struct ReputationScores {
    /// Holds the score for every authority. If an authority is not amongst
    /// the records of the map then we assume that its score is zero.
    pub scores_per_authority: HashMap<AuthorityIdentifier, u64>,
    /// When true it notifies us that those scores will be the last updated scores of the
    /// current schedule before they get reset for the next schedule and start
    /// scoring from the beginning. In practice we can leverage this information to
    /// use the scores during the next schedule until the next final ones are calculated.
    pub final_of_schedule: bool,
}

impl ReputationScores {
    /// Creating a new ReputationScores instance pre-populating the authorities entries with
    /// zero score value.
    pub fn new(committee: &Committee) -> Self {
        let scores_per_authority =
            committee.authorities().iter().map(|a| (a.id(), 0_u64)).collect();

        Self { scores_per_authority, final_of_schedule: false }
    }
    /// Adds the provided `score` to the existing score for the provided `authority`
    pub fn add_score(&mut self, authority: &AuthorityIdentifier, score: u64) {
        if let Some(val) = self.scores_per_authority.get_mut(authority) {
            *val += score;
        } else {
            self.scores_per_authority.insert(authority.clone(), score);
        }
    }

    /// The total number of authorities.
    pub fn total_authorities(&self) -> u64 {
        self.scores_per_authority.len() as u64
    }

    /// Boolean if any authority reputations are above 0.
    pub fn all_zero(&self) -> bool {
        !self.scores_per_authority.values().any(|e| *e > 0)
    }

    /// Returns the authorities by score in descending order.
    pub fn authorities_by_score_desc(&self) -> Vec<(AuthorityIdentifier, u64)> {
        let mut authorities: Vec<_> = self
            .scores_per_authority
            .iter()
            .map(|(authority, score)| (authority.clone(), *score))
            .collect();

        authorities.sort_by(|a1, a2| {
            match a2.1.cmp(&a1.1) {
                Ordering::Equal => {
                    // we resolve the score equality deterministically by ordering in authority
                    // identifier order descending.
                    a2.0.cmp(&a1.0)
                }
                result => result,
            }
        });

        authorities
    }
}

/// BCS layout: `scores_per_authority: HashMap<AuthorityIdentifier, u64>` then
/// `final_of_schedule: bool`. Keep in lockstep with the struct.
impl BcsLayout for ReputationScores {
    fn skip(c: &mut BcsCursor<'_>) -> Result<(), BcsLayoutError> {
        c.skip::<HashMap<AuthorityIdentifier, u64>>()?.skip::<bool>()?;
        Ok(())
    }
}
