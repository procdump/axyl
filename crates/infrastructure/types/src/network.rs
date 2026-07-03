//! Rayls network profiles with baked-in hardfork schedules.

pub const MIN_RAYLS_PROTOCOL_BASE_FEE: u64 = 48000000000;
/// Rayls network profiles with baked-in hardfork schedules.
///
/// Each variant selects a different set of activation blocks, following the
/// same pattern as [`EthereumHardfork::mainnet()`] / [`EthereumHardfork::sepolia()`].
#[derive(
    Debug, Default, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize,
)]
#[cfg_attr(feature = "cli", derive(clap::ValueEnum))]
#[serde(rename_all = "lowercase")]
pub enum RaylsNetwork {
    /// All forks active from genesis (block 0).
    Devnet,
    /// Forks at predetermined test network blocks.
    #[default]
    Testnet,
    /// Production fork schedule.
    Mainnet,
    /// Local development network with all mainnet forks activated
    Local,
}

impl std::fmt::Display for RaylsNetwork {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Devnet => write!(f, "devnet"),
            Self::Testnet => write!(f, "testnet"),
            Self::Mainnet => write!(f, "mainnet"),
            Self::Local => write!(f, "local"),
        }
    }
}
