//! Rayls-specific context for evm.
//!
//! Source code in revm.
use reth_revm::{
    context::{BlockEnv, CfgEnv, TxEnv},
    Context,
};

/// The Rayls Network EVM context.
pub(crate) type RaylsEvmContext<DB> = Context<BlockEnv, TxEnv, CfgEnv, DB>;
