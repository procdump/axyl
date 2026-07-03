//! ABI encoding and decoding utilities for ERC-20 precompile.
//!
//! This module provides utilities for encoding and decoding ERC-20 method calls
//! and return values according to the Ethereum ABI specification.

use crate::native_erc20::precompile::ERC20Error;
use alloy::{
    primitives::{Address, Bytes, Signature, B256, U256},
    sol_types::{SolCall, SolStruct},
};

// Define ERC-20 method selectors using Solidity function signatures
pub mod erc20 {
    use alloy::sol;

    sol! {
        // Read-only methods
        function name() external view returns (string);
        function symbol() external view returns (string);
        function decimals() external view returns (uint8);
        function totalSupply() external view returns (uint256);
        function balanceOf(address account) external view returns (uint256);
        function allowance(address owner, address spender) external view returns (uint256);

        // State-changing methods
        function transfer(address to, uint256 amount) external returns (bool);
        function approve(address spender, uint256 amount) external returns (bool);
        function transferFrom(address from, address to, uint256 amount) external returns (bool);

        // Minting/Burning methods
        function mint(address to, uint256 amount) external returns (bool);
        function burn(uint256 amount) external returns (bool);
        function burnFrom(address account, uint256 amount) external returns (bool);

        // Events
        event Transfer(address indexed from, address indexed to, uint256 value);
        event Approval(address indexed owner, address indexed spender, uint256 value);
        event Mint(address indexed to, uint256 value);
        event Burn(address indexed from, uint256 value);
    }
}

pub mod eip3009 {
    use alloy::sol;

    sol! {
        struct TransferWithAuthorizationStruct {
            address from;
            address to;
            uint256 value;
            uint256 validAfter;
            uint256 validBefore;
            bytes32 nonce;
        }

        struct ReceiveWithAuthorizationStruct {
            address from;
            address to;
            uint256 value;
            uint256 validAfter;
            uint256 validBefore;
            bytes32 nonce;
        }

        struct CancelAuthorizationStruct {
            address authorizer;
            bytes32 nonce;
        }

        function TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce, uint8 v, bytes32 r, bytes32 s);
        function ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce, uint8 v, bytes32 r, bytes32 s);
        function CancelAuthorization(address authorizer,bytes32 nonce, uint8 v, bytes32 r, bytes32 s);
        // Events
        event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);
        event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);
    }
}

/// ERC-20 method selectors (first 4 bytes of keccak256(signature)).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Erc20Selector {
    /// name() - 0x06fdde03
    Name,
    /// symbol() - 0x95d89b41
    Symbol,
    /// decimals() - 0x313ce567
    Decimals,
    /// totalSupply() - 0x18160ddd
    TotalSupply,
    /// balanceOf(address) - 0x70a08231
    BalanceOf,
    /// allowance(address,address) - 0xdd62ed3e
    Allowance,
    /// transfer(address,uint256) - 0xa9059cbb
    Transfer,
    /// approve(address,uint256) - 0x095ea7b3
    Approve,
    /// transferFrom(address,address,uint256) - 0x23b872dd
    TransferFrom,
    /// mint(address,uint256) - 0x40c10f19
    Mint,
    /// burn(uint256) - 0x42966c68
    Burn,
    /// burnFrom(address,uint256) - 0x79cc6790
    BurnFrom,

    /// TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256
    /// validBefore,bytes32 nonce)
    TransferWithAuthorization,
    /// ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256
    /// validBefore,bytes32 nonce)
    ReceiveWithAuthorization,
    /// CancelAuthorization(address authorizer,bytes32 nonce)
    CancelAuthorization,
}

/// Lookup table for selector to enum mapping.
const SELECTOR_TABLE: [([u8; 4], Erc20Selector); 15] = [
    (erc20::nameCall::SELECTOR, Erc20Selector::Name),
    (erc20::symbolCall::SELECTOR, Erc20Selector::Symbol),
    (erc20::decimalsCall::SELECTOR, Erc20Selector::Decimals),
    (erc20::totalSupplyCall::SELECTOR, Erc20Selector::TotalSupply),
    (erc20::balanceOfCall::SELECTOR, Erc20Selector::BalanceOf),
    (erc20::allowanceCall::SELECTOR, Erc20Selector::Allowance),
    (erc20::transferCall::SELECTOR, Erc20Selector::Transfer),
    (erc20::approveCall::SELECTOR, Erc20Selector::Approve),
    (erc20::transferFromCall::SELECTOR, Erc20Selector::TransferFrom),
    (erc20::mintCall::SELECTOR, Erc20Selector::Mint),
    (erc20::burnCall::SELECTOR, Erc20Selector::Burn),
    (erc20::burnFromCall::SELECTOR, Erc20Selector::BurnFrom),
    (eip3009::TransferWithAuthorizationCall::SELECTOR, Erc20Selector::TransferWithAuthorization),
    (eip3009::ReceiveWithAuthorizationCall::SELECTOR, Erc20Selector::ReceiveWithAuthorization),
    (eip3009::CancelAuthorizationCall::SELECTOR, Erc20Selector::CancelAuthorization),
];

/// Secp256k1 curve order divided by 2 (used for signature malleability check).
const SECP256K1N_HALF: U256 = U256::from_limbs([
    0xBFD25E8CD0364140,
    0xBAAEDCE6AF48A03B,
    0xFFFFFFFFFFFFFFFE,
    0x7FFFFFFFFFFFFFFF,
]);

// region: EIP-3009 "Transfer With Authorization"
pub fn verify_transfer_authorization(
    domain: &alloy::sol_types::Eip712Domain,
    from: Address,
    to: Address,
    value: U256,
    valid_after: U256,
    valid_before: U256,
    nonce: B256,
    v: u8,
    r: U256,
    s: U256,
) -> Result<Address, ERC20Error> {
    let hash_struct = eip3009::TransferWithAuthorizationStruct {
        from,
        to,
        value,
        validAfter: valid_after,
        validBefore: valid_before,
        nonce,
    };

    let hash = hash_struct.eip712_signing_hash(domain);
    let y_parity = match v {
        27 | 0 => false,
        28 | 1 => true,
        _ => return Err(ERC20Error::other("Invalid signature")),
    };

    if s > SECP256K1N_HALF {
        return Err(ERC20Error::SignatureMalleability);
    }
    let signature = Signature::from_scalars_and_parity(r.into(), s.into(), y_parity);
    let recovered = signature
        .recover_address_from_prehash(&hash)
        .map_err(|e| ERC20Error::other(e.to_string()))?;
    Ok(recovered)
}

pub fn verify_cancel_authorization(
    domain: &alloy::sol_types::Eip712Domain,
    authorizer: Address,
    nonce: B256,
    v: u8,
    r: U256,
    s: U256,
) -> Result<Address, ERC20Error> {
    let hash_struct = eip3009::CancelAuthorizationStruct { authorizer, nonce };

    let hash = hash_struct.eip712_signing_hash(domain);
    let y_parity = match v {
        27 | 0 => false,
        28 | 1 => true,
        _ => return Err(ERC20Error::other("Invalid signature")),
    };

    if s > SECP256K1N_HALF {
        return Err(ERC20Error::SignatureMalleability);
    }

    let signature = Signature::from_scalars_and_parity(r.into(), s.into(), y_parity);
    let recovered = signature
        .recover_address_from_prehash(&hash)
        .map_err(|e| ERC20Error::other(e.to_string()))?;
    Ok(recovered)
}

// endregion: EIP-3009 "Transfer With Authorization"

impl Erc20Selector {
    /// Parse selector from calldata.
    #[inline]
    pub fn from_calldata(data: &[u8]) -> Option<Self> {
        if data.len() < 4 {
            return None;
        }

        let selector: [u8; 4] = data[0..4].try_into().ok()?;
        SELECTOR_TABLE.iter().find(|(s, _)| *s == selector).map(|(_, variant)| *variant)
    }

    /// Get parameters from calldata (after selector).
    #[inline]
    pub fn get_params(data: &[u8]) -> &[u8] {
        if data.len() <= 4 {
            &[]
        } else {
            &data[4..]
        }
    }

    /// Return true if this selector mutates token state (balance, allowance, supply, or nonce).
    ///
    /// Exhaustive on purpose: adding a new selector to the enum forces an explicit
    /// classification here, preventing a silent fail-open in the static-call guard.
    pub const fn is_state_mutating(self) -> bool {
        match self {
            Self::Transfer
            | Self::Approve
            | Self::TransferFrom
            | Self::Mint
            | Self::Burn
            | Self::BurnFrom
            | Self::TransferWithAuthorization
            | Self::ReceiveWithAuthorization
            | Self::CancelAuthorization => true,
            Self::Name
            | Self::Symbol
            | Self::Decimals
            | Self::TotalSupply
            | Self::BalanceOf
            | Self::Allowance => false,
        }
    }
}

/// Encode uint256 as ABI return value.
#[inline]
pub fn encode_uint256(value: U256) -> Bytes {
    Bytes::copy_from_slice(&value.to_be_bytes::<32>())
}

/// Encode boolean as ABI return value.
#[inline]
pub fn encode_bool(value: bool) -> Bytes {
    let mut result = [0u8; 32];
    result[31] = value as u8;
    Bytes::copy_from_slice(&result)
}

/// Encode string as ABI return value.
#[inline]
pub fn encode_string(value: &str) -> Bytes {
    let bytes = value.as_bytes();
    let len = bytes.len();
    let padding = (32 - (len % 32)) % 32;
    let total = 64 + len + padding; // offset + length + data + padding

    let mut result = Vec::with_capacity(total);

    // Offset (0x20 = 32, data starts at byte 32)
    result.extend_from_slice(&[0u8; 31]);
    result.push(0x20);

    // Length
    result.extend_from_slice(&U256::from(len).to_be_bytes::<32>());

    // Data
    result.extend_from_slice(bytes);

    // Pad with zeros to 32-byte boundary
    result.resize(total, 0);

    Bytes::from(result)
}

/// Encode uint8 as ABI return value.
#[inline]
pub fn encode_uint8(value: u8) -> Bytes {
    let mut result = [0u8; 32];
    result[31] = value;
    Bytes::copy_from_slice(&result)
}

/// Encode revert reason like Solidity's Error(string).
#[inline]
pub fn encode_revert_reason(reason: &str) -> Bytes {
    // Error(string) selector: 0x08c379a0
    let string_data = encode_string(reason);
    let mut result = Vec::with_capacity(4 + string_data.len());
    result.extend_from_slice(&[0x08, 0xc3, 0x79, 0xa0]);
    result.extend_from_slice(&string_data);

    Bytes::from(result)
}

/// ABI encoding/decoding errors.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AbiError {
    /// Invalid input data.
    InvalidInput(String),
    /// Unknown method selector.
    UnknownSelector,
}

impl std::fmt::Display for AbiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidInput(msg) => write!(f, "Invalid ABI input: {}", msg),
            Self::UnknownSelector => write!(f, "Unknown method selector"),
        }
    }
}

impl std::error::Error for AbiError {}
