//! Storage utilities for the Native ERC-20 precompile.
//!
//! This module provides storage management for:
//! - Total supply storage slot calculation
//! - Allowance slot calculation
//! - Authorization nonce slot calculation (EIP-3009)
//!
//! Uses alloy primitives for type-safe, idiomatic storage slot calculation
//! following standard Solidity storage layout patterns.
//!
//! Note: Total supply is initialized directly in EVM storage at genesis,
//! not cached in memory. This ensures the value is part of the state root
//! and can be proven via eth_getProof.

use std::sync::LazyLock;

use alloy::primitives::{keccak256, Address, B256, U256};

/// Storage slot calculation utilities using alloy primitives.
mod slot_utils {
    use alloy::primitives::{keccak256, Address, B256, U256};

    /// Calculate storage slot for a Solidity mapping(address => T).
    ///
    /// Formula: keccak256(abi.encodePacked(key, slot))
    /// This matches Solidity's standard storage layout for mappings.
    #[inline]
    pub fn mapping_slot_address(key: Address, base_slot: U256) -> U256 {
        let mut buffer = [0u8; 64];
        // Left-pad address to 32 bytes (addresses are 20 bytes)
        buffer[12..32].copy_from_slice(key.as_slice());
        buffer[32..64].copy_from_slice(&base_slot.to_be_bytes::<32>());

        U256::from_be_bytes(keccak256(&buffer).0)
    }

    /// Calculate storage slot for a Solidity mapping(bytes32 => T).
    ///
    /// Formula: keccak256(abi.encodePacked(key, slot))
    #[inline]
    pub fn mapping_slot_bytes32(key: B256, base_slot: U256) -> U256 {
        let mut buffer = [0u8; 64];
        buffer[..32].copy_from_slice(key.as_slice());
        buffer[32..].copy_from_slice(&base_slot.to_be_bytes::<32>());

        U256::from_be_bytes(keccak256(&buffer).0)
    }

    /// Calculate storage slot for nested mapping(address => mapping(bytes32 => T)).
    ///
    /// Implements two-level mapping slot calculation:
    /// 1. inner_slot = keccak256(abi.encodePacked(outer_key, base_slot))
    /// 2. final_slot = keccak256(abi.encodePacked(inner_key, inner_slot))
    #[inline]
    pub fn nested_mapping_slot(outer_key: Address, inner_key: B256, base_slot: U256) -> U256 {
        let inner_slot = mapping_slot_address(outer_key, base_slot);
        mapping_slot_bytes32(inner_key, inner_slot)
    }

    /// Calculate storage slot for nested mapping(address => mapping(address => T)).
    ///
    /// Used for standard ERC-20 allowances: mapping(owner => mapping(spender => uint256))
    #[inline]
    pub fn allowance_mapping_slot(owner: Address, spender: Address, base_slot: U256) -> U256 {
        let inner_slot = mapping_slot_address(owner, base_slot);
        mapping_slot_address(spender, inner_slot)
    }
}

pub use slot_utils::*;

/// Storage slot for total supply, computed once at runtime.
///
/// The total supply is stored in the precompile's storage at this fixed slot.
/// This allows the total supply to be persisted and updated dynamically through
/// mint/burn operations, rather than being a constant from genesis.
///
/// Uses a dedicated namespace slot to avoid collisions with mapping storage.
/// Formula: keccak256("TOTAL_SUPPLY_V1__________STORAGE")
static TOTAL_SUPPLY_SLOT: LazyLock<U256> = LazyLock::new(|| {
    const TOTAL_SUPPLY_PREFIX: [u8; 32] = *b"TOTAL_SUPPLY_V1__________STORAGE";
    U256::from_be_bytes(keccak256(TOTAL_SUPPLY_PREFIX).0)
});

/// Returns the storage slot for total supply.
#[inline]
pub fn total_supply_slot() -> U256 {
    *TOTAL_SUPPLY_SLOT
}

/// Base storage slot for allowances mapping.
///
/// Simulates Solidity storage slot: `mapping(address => mapping(address => uint256)) allowances;`
/// placed at this base slot to avoid collisions with other storage.
pub const ALLOWANCES_BASE_SLOT: U256 = U256::from_limbs([
    0x0000000000000001, // Least significant limb - Slot 1
    0x0000000000000000,
    0x0000000000000000,
    0x0000000000000000,
]);

/// Calculate storage slot for allowance using standard Solidity mapping layout.
///
/// Follows EVM storage layout for nested mappings:
/// `mapping(address owner => mapping(address spender => uint256 amount))`
///
/// Formula (matches Solidity exactly):
/// 1. inner_slot = keccak256(owner || ALLOWANCES_BASE_SLOT)
/// 2. final_slot = keccak256(spender || inner_slot)
///
/// This ensures compatibility with standard ERC-20 storage layouts
/// and tooling that expects Solidity-style storage.
#[inline]
pub fn allowance_slot(owner: Address, spender: Address) -> U256 {
    allowance_mapping_slot(owner, spender, ALLOWANCES_BASE_SLOT)
}

// region: EIP-3009: "Transfer With Authorization"

/// Base storage slot for EIP-3009 authorization nonces.
///
/// Simulates Solidity storage:
/// `mapping(address authorizer => mapping(bytes32 nonce => bool used)) authorizationNonces;`
const AUTHORIZATION_NONCES_BASE_SLOT: U256 = U256::from_limbs([
    0x0000000000000005, // Least significant limb - Slot 5
    0x0000000000000000,
    0x0000000000000000,
    0x0000000000000000,
]);

/// Calculate storage slot for EIP-3009 authorization nonce.
///
/// Implements nested mapping: `mapping(address => mapping(bytes32 => bool))`
/// using standard Solidity storage layout.
///
/// Formula (matches Solidity):
/// 1. inner_slot = keccak256(authorizer || AUTHORIZATION_NONCES_BASE_SLOT)
/// 2. final_slot = keccak256(nonce || inner_slot)
#[inline]
pub fn authorization_nonce_slot(authorizer: Address, nonce: B256) -> U256 {
    nested_mapping_slot(authorizer, nonce, AUTHORIZATION_NONCES_BASE_SLOT)
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::address;

    #[test]
    fn test_total_supply_slot_consistency() {
        // Total supply slot should be consistent across calls
        let slot1 = total_supply_slot();
        let slot2 = total_supply_slot();
        assert_eq!(slot1, slot2);

        // Should be different from any allowance slot
        let owner = address!("7E5F4552091A69125d5DfCb7b8C2659029395Bdf");
        let spender = address!("2B5AD5c4795c026514f8317c7a215E218DcCD6cF");
        let allowance = allowance_slot(owner, spender);
        assert_ne!(slot1, allowance);
    }

    #[test]
    fn test_allowance_slot_uniqueness() {
        let owner1 = address!("7E5F4552091A69125d5DfCb7b8C2659029395Bdf");
        let owner2 = address!("2B5AD5c4795c026514f8317c7a215E218DcCD6cF");
        let spender1 = address!("6813Eb9362372EEF6200f3b1dbC3f819671cBA69");
        let spender2 = address!("0000000000000000000000000000000000000004");

        // Different owner-spender pairs should have different slots
        let slot1 = allowance_slot(owner1, spender1);
        let slot2 = allowance_slot(owner1, spender2);
        let slot3 = allowance_slot(owner2, spender1);

        assert_ne!(slot1, slot2);
        assert_ne!(slot1, slot3);
        assert_ne!(slot2, slot3);

        // Same owner-spender pair should have same slot
        let slot1_again = allowance_slot(owner1, spender1);
        assert_eq!(slot1, slot1_again);
    }

    #[test]
    fn test_total_supply_slot_hash() {
        // Verify that total_supply_slot() matches keccak256("TOTAL_SUPPLY_V1__________STORAGE")
        const TOTAL_SUPPLY_PREFIX: [u8; 32] = *b"TOTAL_SUPPLY_V1__________STORAGE";
        let expected_hash = keccak256(&TOTAL_SUPPLY_PREFIX);
        let expected_slot = U256::from_be_bytes(expected_hash.0);

        assert_eq!(
            total_supply_slot(),
            expected_slot,
            "total_supply_slot() const value doesn't match keccak256 hash"
        );
    }

    #[test]
    fn test_storage_slot_layout() {
        // Verify storage layout follows expected pattern:
        // - Slot 0: Reserved (or used by implementation-specific data)
        // - Slot 1: Allowances mapping base
        // - Slot 5: Authorization nonces mapping base
        // - Hash-based: Total supply (keccak256 of prefix)

        assert_eq!(ALLOWANCES_BASE_SLOT, U256::from(1));

        // Total supply should be a hash-derived slot (much larger than simple integers)
        assert!(total_supply_slot() > U256::from(100));

        // Ensure no collision between base slots and hash-derived slots
        assert_ne!(total_supply_slot(), ALLOWANCES_BASE_SLOT);
        assert_ne!(total_supply_slot(), U256::from(5)); // Authorization nonces base
    }
}
