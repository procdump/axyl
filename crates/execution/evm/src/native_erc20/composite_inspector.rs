//! Composite inspector that chains NativeErc20Inspector with another inspector.
//!
//! This allows combining the Native ERC-20 inspector with other inspectors (e.g., tracers)
//! while ensuring ERC-20 operations at 0x0400 are always handled first.

use crate::{evm::RaylsEvmContext, native_erc20::inspector::NativeErc20Inspector};
use alloy::primitives::{Address, Log, U256};
use reth_revm::{
    inspector::Inspector,
    interpreter::{
        interpreter::EthInterpreter, CallInputs, CallOutcome, CreateInputs, CreateOutcome,
        Interpreter,
    },
    Database,
};

/// Composite inspector that chains NativeErc20Inspector with another inspector.
///
/// This inspector first tries NativeErc20Inspector for ERC-20 operations at 0x0400,
/// and if NativeErc20Inspector doesn't handle it (returns None), delegates to the inner inspector.
#[derive(Debug, Clone)]
pub struct CompositeInspector<I> {
    native_erc20: NativeErc20Inspector,
    inner: I,
}

impl<I> CompositeInspector<I> {
    /// Create a new CompositeInspector.
    pub fn new(native_erc20: NativeErc20Inspector, inner: I) -> Self {
        Self { native_erc20, inner }
    }

    /// Get a reference to the inner inspector.
    pub fn inner(&self) -> &I {
        &self.inner
    }

    /// Get a mutable reference to the inner inspector.
    pub fn inner_mut(&mut self) -> &mut I {
        &mut self.inner
    }
}

impl<DB, I> Inspector<RaylsEvmContext<DB>, EthInterpreter> for CompositeInspector<I>
where
    DB: Database,
    DB::Error: 'static,
    I: Inspector<RaylsEvmContext<DB>, EthInterpreter>,
{
    fn call(
        &mut self,
        context: &mut RaylsEvmContext<DB>,
        inputs: &mut CallInputs,
    ) -> Option<CallOutcome> {
        // First try NativeErc20Inspector for ERC-20 operations
        if let Some(outcome) = self.native_erc20.call(context, inputs) {
            return Some(outcome);
        }

        // If NativeErc20Inspector didn't handle it, delegate to inner inspector
        self.inner.call(context, inputs)
    }

    fn create(
        &mut self,
        context: &mut RaylsEvmContext<DB>,
        inputs: &mut CreateInputs,
    ) -> Option<CreateOutcome> {
        // First try NativeErc20Inspector (though it currently returns None for creates)
        if let Some(outcome) = self.native_erc20.create(context, inputs) {
            return Some(outcome);
        }
        // Then delegate to inner inspector
        self.inner.create(context, inputs)
    }

    fn log(&mut self, context: &mut RaylsEvmContext<DB>, log: Log) {
        // Chain both inspectors
        self.native_erc20.log(context, log.clone());
        self.inner.log(context, log);
    }

    fn selfdestruct(&mut self, contract: Address, target: Address, value: U256) {
        // Delegate to inner inspector only
        // NativeErc20Inspector doesn't need to track selfdestructs for ERC-20 operations
        self.inner.selfdestruct(contract, target, value);
    }

    fn call_end(
        &mut self,
        context: &mut RaylsEvmContext<DB>,
        inputs: &CallInputs,
        outcome: &mut CallOutcome,
    ) {
        // Chain both inspectors
        self.native_erc20.call_end(context, inputs, outcome);
        self.inner.call_end(context, inputs, outcome);
    }

    fn create_end(
        &mut self,
        context: &mut RaylsEvmContext<DB>,
        inputs: &CreateInputs,
        outcome: &mut CreateOutcome,
    ) {
        // Chain both inspectors
        self.native_erc20.create_end(context, inputs, outcome);
        self.inner.create_end(context, inputs, outcome);
    }

    fn initialize_interp(
        &mut self,
        interp: &mut Interpreter<EthInterpreter>,
        context: &mut RaylsEvmContext<DB>,
    ) {
        // Chain both inspectors
        self.native_erc20.initialize_interp(interp, context);
        self.inner.initialize_interp(interp, context);
    }

    fn step(
        &mut self,
        interp: &mut Interpreter<EthInterpreter>,
        context: &mut RaylsEvmContext<DB>,
    ) {
        // Chain both inspectors
        self.native_erc20.step(interp, context);
        self.inner.step(interp, context);
    }

    fn step_end(
        &mut self,
        interp: &mut Interpreter<EthInterpreter>,
        context: &mut RaylsEvmContext<DB>,
    ) {
        // Chain both inspectors
        self.native_erc20.step_end(interp, context);
        self.inner.step_end(interp, context);
    }
}
