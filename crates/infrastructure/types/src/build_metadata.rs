// SPDX-License-Identifier: BUSL-1.1
//! Compile-time build metadata shared across crates.

/// Compile-time build metadata populated once at binary startup.
#[derive(Debug, Clone, Default)]
pub struct BuildMetadata {
    pub version: &'static str,
    pub build_timestamp: &'static str,
    pub cargo_features: &'static str,
    pub git_sha: &'static str,
    pub target_triple: &'static str,
    pub build_profile: &'static str,
}
