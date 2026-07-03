//! Committee loader for replay.
//!
//! Reads the committee from the on-chain `ConsensusRegistry` at the archive's
//! canonical tip and installs it on `rewards_counter`, mirroring how the live
//! epoch manager configures each epoch.

use crate::error::{ReplayError, ReplayResult};
use rayls_execution_evm::{
    reth_env::RethEnv,
    system_calls::{ConsensusRegistry, EpochState},
};
use rayls_infrastructure_types::{
    rewards::RewardsCounter, BlsPublicKey, Committee, CommitteeBuilder, Epoch,
};
use tracing::info;

/// Build a [`Committee`] for `epoch` from on-chain `ValidatorInfo` entries and
/// build its secondary indexes.
///
/// Bootstrap servers are intentionally not populated: replay never opens a
/// network, so only the authority-address mapping is consumed.
///
/// # Errors
///
/// Returns [`ReplayError::Committee`] when a BLS key fails to decode or fewer
/// than two validators are supplied (`Committee::load` panics below that size,
/// so a broken registry read is surfaced as an error instead).
pub fn committee_from_validators(
    epoch: Epoch,
    validators: &[ConsensusRegistry::ValidatorInfo],
) -> ReplayResult<Committee> {
    if validators.len() < 2 {
        return Err(ReplayError::Committee(format!(
            "registry returned {} validators for epoch {epoch}; a committee needs at least 2",
            validators.len()
        )));
    }
    let mut builder = CommitteeBuilder::new(epoch);
    for validator in validators {
        let bls = BlsPublicKey::from_literal_bytes(validator.blsPubkey.as_ref())
            .map_err(|e| ReplayError::Committee(format!("decode on-chain BLS key: {e:?}")))?;
        builder.add_authority(bls, 1, validator.validatorAddress);
    }
    let committee = builder.build();
    committee.load();
    Ok(committee)
}

/// Build a [`Committee`] from the on-chain `ConsensusRegistry` at `evm`'s
/// canonical tip.
///
/// The registry is read from persisted state (`LatestStateProvider`); callers
/// must flush deferred persistence first or the read trails the in-memory tip.
pub fn committee_from_contract(evm: &RethEnv) -> ReplayResult<Committee> {
    let EpochState { epoch, validators, .. } = evm
        .epoch_state_from_canonical_tip()
        .map_err(|e| ReplayError::Committee(format!("read ConsensusRegistry: {e}")))?;
    committee_from_validators(epoch, &validators)
}

/// Install the canonical-tip committee on `rewards_counter`.
///
/// Call once at replay start and again after each close-epoch block persists:
/// `concludeEpoch` rotates the registry's committee, so the tip state always
/// carries the membership for the epoch being replayed.
pub fn install_committee_from_contract(
    evm: &RethEnv,
    rewards_counter: &RewardsCounter,
) -> ReplayResult<()> {
    let committee = committee_from_contract(evm)?;
    info!(
        target: "rayls_replay::epoch",
        epoch = committee.epoch(),
        authorities = committee.size(),
        "installed committee from on-chain ConsensusRegistry"
    );
    rewards_counter.set_committee(committee);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::{rngs::StdRng, SeedableRng};
    use rayls_execution_evm::system_calls::ConsensusRegistry::{ValidatorInfo, ValidatorStatus};
    use rayls_infrastructure_types::{Address, BlsKeypair};

    fn validator(rng: &mut StdRng, last_byte: u8) -> ValidatorInfo {
        ValidatorInfo {
            blsPubkey: BlsKeypair::generate(rng).public().as_ref().to_vec().into(),
            validatorAddress: Address::with_last_byte(last_byte),
            activationEpoch: 0,
            exitEpoch: 0,
            currentStatus: ValidatorStatus::Active,
            isRetired: false,
            isDelegated: false,
            stakeVersion: 0,
        }
    }

    #[test]
    fn builds_committee_from_on_chain_validator_infos() {
        let mut rng = StdRng::seed_from_u64(7);
        let validators: Vec<_> = (1..=4).map(|n| validator(&mut rng, n)).collect();
        let committee = committee_from_validators(7, &validators).expect("4-validator committee");
        assert_eq!(committee.size(), 4);
        assert_eq!(committee.epoch(), 7);
    }

    #[test]
    fn sub_quorum_registry_read_is_an_error_not_a_panic() {
        let mut rng = StdRng::seed_from_u64(7);
        for validators in [vec![], vec![validator(&mut rng, 1)]] {
            let err = committee_from_validators(0, &validators).unwrap_err();
            assert!(matches!(err, ReplayError::Committee(_)), "got {err:?}");
        }
    }
}
