// SPDX-License-Identifier: BUSL-1.1
//! Batch validation

// FxHasher constants vary by target_pointer_width; 32-bit validators would compute
// different post-fork slot digests and silently disagree on transaction ownership.
#[cfg(not(target_pointer_width = "64"))]
compile_error!("Rayls Network requires a 64-bit target");

mod validator;
pub use validator::BatchValidator;

#[cfg(any(test, feature = "test-utils"))]
pub use validator::NoopBatchValidator;
