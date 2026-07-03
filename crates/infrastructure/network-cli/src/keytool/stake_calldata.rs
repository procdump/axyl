//! Generate stake calldata subcommand
use alloy::{hex, rlp::Bytes, sol_types::SolCall};
use clap::Args;
use rayls_execution_evm::system_calls::ConsensusRegistry;
use rayls_infrastructure_config::{Config, RaylsDirs};
use tracing::info;

#[derive(Debug, Clone, Args)]
pub struct GenerateStakeCalldata {}

impl GenerateStakeCalldata {
    /// Create all necessary information needed for validator and save to file.
    pub fn execute<RLD: RaylsDirs>(&self, rl_datadir: &RLD) -> eyre::Result<()> {
        info!(target: "rl::generate_stake_calldata", "generating calldata for stake transaction");

        let config: Config = Config::load_or_default(rl_datadir, false, "test")?;
        let node_info = config.node_info;

        let proof = ConsensusRegistry::ProofOfPossession {
            uncompressedPubkey: node_info.bls_public_key.serialize().into(),
            uncompressedSignature: node_info.proof_of_possession.serialize().into(),
        };
        let calldata: Bytes = ConsensusRegistry::stakeCall {
            blsPubkey: node_info.bls_public_key.to_bytes().into(),
            proofOfPossession: proof,
        }
        .abi_encode()
        .into();

        println!("Calldata: 0x{}", hex::encode(calldata));

        Ok(())
    }
}
