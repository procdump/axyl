//! Custom handler to override EVM basefees.

use crate::reth_env::types::basefee_address;
use rayls_infrastructure_types::Address;
use reth_revm::{
    context_interface::{
        journaled_state::account::JournaledAccountTr, result::HaltReason, Block, ContextTr,
        JournalTr, LocalContextTr, Transaction,
    },
    handler::{EvmTr, FrameResult, FrameTr, Handler},
    inspector::{InspectorEvmTr, InspectorHandler},
    interpreter::{interpreter::EthInterpreter, interpreter_action::FrameInit, InterpreterResult},
    primitives::U256,
    Database, Inspector,
};

/// The handler that executes Rayls evm types.
///
/// This is only intended to overwrite basefee logic for now.
pub(super) struct RaylsEvmHandler<EVM> {
    /// Address for basefees
    basefee_address: Address,
    _phantom: core::marker::PhantomData<EVM>,
}

impl<EVM> RaylsEvmHandler<EVM> {
    fn new(basefee_address: Address) -> Self {
        Self { basefee_address, _phantom: core::marker::PhantomData }
    }
}

impl<EVM> Default for RaylsEvmHandler<EVM> {
    fn default() -> Self {
        RaylsEvmHandler::new(basefee_address())
    }
}

impl<EVM> Handler for RaylsEvmHandler<EVM>
where
    EVM: EvmTr<
        Context: ContextTr<Journal: JournalTr, Local: LocalContextTr>,
        Precompiles: reth_revm::handler::PrecompileProvider<
            EVM::Context,
            Output = InterpreterResult,
        >,
        Frame: FrameTr<FrameResult = FrameResult, FrameInit = FrameInit>,
    >,
{
    type Evm = EVM;
    type Error = reth_revm::context_interface::result::EVMError<
        <<EVM::Context as ContextTr>::Db as Database>::Error,
        reth_revm::context_interface::result::InvalidTransaction,
    >;
    type HaltReason = HaltReason;

    // overwrite the default basefee logic
    fn reward_beneficiary(
        &self,
        evm: &mut Self::Evm,
        exec_result: &mut <<Self::Evm as EvmTr>::Frame as FrameTr>::FrameResult,
    ) -> Result<(), Self::Error> {
        let gas = exec_result.gas();
        let gas_used = gas.spent_sub_refunded() as u128;

        // read block and tx info through destructuring to avoid borrow issues
        let (block, tx, _, journal, _, _) = evm.ctx().all_mut();
        let beneficiary = block.beneficiary();
        let basefee = block.basefee() as u128;
        let effective_gas_price = tx.effective_gas_price(basefee);

        // transfer fee to coinbase/beneficiary.
        // Basefee amount of gas is redirected.
        let coinbase_gas_price = effective_gas_price.saturating_sub(basefee);

        // reward coinbase with priority fee
        journal
            .load_account_mut(beneficiary)?
            .incr_balance(U256::from(coinbase_gas_price * gas_used));

        // Send the base fee portion to a basefee account for later processing
        // (offchain).
        journal
            .load_account_mut(self.basefee_address)?
            .incr_balance(U256::from(basefee * gas_used));

        Ok(())
    }
}

impl<EVM> InspectorHandler for RaylsEvmHandler<EVM>
where
    EVM: InspectorEvmTr<
        Inspector: Inspector<<<Self as Handler>::Evm as EvmTr>::Context, EthInterpreter>,
        Context: ContextTr<Journal: JournalTr, Local: LocalContextTr>,
        Precompiles: reth_revm::handler::PrecompileProvider<
            EVM::Context,
            Output = InterpreterResult,
        >,
    >,
{
    type IT = EthInterpreter;
}
