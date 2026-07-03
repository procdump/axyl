//! Base fee resolution and gas accumulator updates.

use rayls_execution_evm::{chainspec::RaylsHardforks, reth_env::RethEnv};
use rayls_infrastructure_types::{gas_accumulator::GasAccumulator, SealedHeader};

/// Resolve the base fee for the next block.
pub(crate) fn resolve_base_fee(
    reth_env: &RethEnv,
    parent: &SealedHeader,
    batch_base_fee: u64,
) -> u64 {
    let chain_spec = reth_env.rayls_chain_spec();
    let next_block = parent.number + 1;
    if chain_spec.is_eip1559_active_at_block(next_block) {
        chain_spec.compute_next_base_fee(
            parent.gas_used,
            parent.gas_limit,
            parent.base_fee_per_gas,
            next_block,
        )
    } else {
        batch_base_fee
    }
}

/// After executing a block, update the gas accumulator's base fee container
/// so that downstream consumers (tx pool, batch builder) see the correct pending base fee.
pub(crate) fn update_base_fee_after_block(
    reth_env: &RethEnv,
    gas_accumulator: &GasAccumulator,
    header: &SealedHeader,
) {
    let chain_spec = reth_env.rayls_chain_spec();
    let next_block = header.number + 1;
    if chain_spec.is_eip1559_active_at_block(next_block) {
        let next_base_fee = chain_spec.compute_next_base_fee(
            header.gas_used,
            header.gas_limit,
            header.base_fee_per_gas,
            next_block,
        );
        for w in 0..gas_accumulator.num_workers() {
            gas_accumulator.base_fee(w as u16).set_base_fee(next_base_fee);
        }
    }
}
