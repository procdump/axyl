//! Engine mod for Rayls Node
//!
//! This module contains all execution layer implementations for worker and primary nodes.
//!
//! The worker's execution components track the canonical tip to construct blocks for the worker to
//! propose. The execution state is also used to validate proposed blocks from other peers.
//!
//! The engine for the primary executes consensus output, extends the canonical tip, and updates the
//! final state of the chain.
//!
//! The methods in this module are thread-safe wrappers for the inner type that contains logic.

mod node;
mod node_builder;
mod node_inner;
mod rayls_builder;

pub use node::*;
pub use rayls_builder::*;
pub use rayls_execution_evm::worker::*;
