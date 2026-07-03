//! Block execution, epoch transitions, and output orchestration.

pub(crate) mod block;
mod orchestrator;

pub use orchestrator::{execute_consensus_output, Processor};
