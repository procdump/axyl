//! Public errors for Rayls RPC endpoints.
//!
//! These errors are returned by the RPC for public requests to the `rayls` namespace.

use rayls_infrastructure_types::hex::encode_prefixed;
use thiserror::Error;

/// The result type for rayls RPC namespace.
pub(crate) type RaylsNetworkRpcResult<T> = Result<T, RaylsRpcError>;

/// Error type for public RPC endpoints in the `rayls` namespace.
#[derive(Debug, Error)]
pub enum RaylsRpcError {
    /// Handshake client provided an invalid signature for network key.
    #[error("Invalid proof of possession for provided network key or genesis.")]
    InvalidProofOfPossession,
    /// Requested item not found.
    #[error("Not Found.")]
    NotFound,
}

impl From<RaylsRpcError> for jsonrpsee_types::ErrorObject<'static> {
    fn from(error: RaylsRpcError) -> Self {
        match error {
            RaylsRpcError::InvalidProofOfPossession => rpc_error(401, error.to_string(), None),
            RaylsRpcError::NotFound => rpc_error(401, error.to_string(), None),
        }
    }
}

/// Constructs a JSON-RPC error for jsonrpsee compatibility.
pub(crate) fn rpc_error(
    code: i32,
    msg: impl Into<String>,
    data: Option<&[u8]>,
) -> jsonrpsee_types::ErrorObject<'static> {
    jsonrpsee_types::ErrorObject::owned(
        code,
        msg.into(),
        data.map(|data| {
            jsonrpsee::core::to_json_raw_value(&encode_prefixed(data))
                .expect("string is serializable")
        }),
    )
}
