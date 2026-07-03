//! Integrity verifiers for post-chaos assertions.
//!
//! Each verifier checks a specific invariant that must hold after chaos injection
//! and (optionally) recovery.

pub mod block_consistency;
pub mod chain_advancing;
pub mod nonce_monotonicity;
