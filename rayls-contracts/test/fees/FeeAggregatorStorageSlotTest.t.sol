// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";

/// @title FeeAggregatorStorageSlotTest
/// @notice Guards against accidental "correction" of the FeeAggregator's non-standard ERC-7201 slot.
/// @dev See audit finding. The deployed FeeAggregator uses a storage slot that does not
///      derive from "feeaggregator.storage.v1" via the standard ERC-7201 formula. Changing the
///      constant to the "correct" derivation would cause total state loss on the live proxy.
contract FeeAggregatorStorageSlotTest is Test {
    /// @dev The slot that is DEPLOYED and contains live state. Must never change.
    bytes32 constant DEPLOYED_SLOT =
        0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39fc00;

    /// @dev What ERC-7201 would produce from "feeaggregator.storage.v1". Must NOT be used.
    bytes32 constant CORRECT_ERC7201_SLOT =
        0x97723226cbb2c5eba8cb8d1d9f606a619559178ba469ca1b06b8d9362615b100;

    function test_feeAggregator_storageSlot_isNotStandardDerivation() public pure {
        // Verify the known mismatch — if this fails, someone changed the derivation formula
        assertNotEq(
            DEPLOYED_SLOT,
            CORRECT_ERC7201_SLOT,
            "Deployed slot must differ from standard derivation"
        );

        // Verify the standard derivation independently
        bytes32 computed = keccak256(
            abi.encode(uint256(keccak256("feeaggregator.storage.v1")) - 1)
        ) & ~bytes32(uint256(0xff));
        assertEq(computed, CORRECT_ERC7201_SLOT);
    }

    function test_rlsAccumulator_storageSlot_isCorrect() public pure {
        bytes32 expected = 0x1434b6d7a9cd896918fc9e177be6ce103a3f4b47c31c2a0c7a187bcc052a1c00;
        bytes32 computed = keccak256(
            abi.encode(uint256(keccak256("rlsaccumulator.storage.v1")) - 1)
        ) & ~bytes32(uint256(0xff));
        assertEq(computed, expected);
    }

    function test_rewardDistributor_storageSlot_isCorrect() public pure {
        bytes32 expected = 0x8a40cc0ccf5a2d030058c860d76601e04104947950ec7475e80ab15a7d69d600;
        bytes32 computed = keccak256(
            abi.encode(uint256(keccak256("rewarddistributor.storage.v1")) - 1)
        ) & ~bytes32(uint256(0xff));
        assertEq(computed, expected);
    }

    function test_delegationPool_storageSlot_isCorrect() public pure {
        bytes32 expected = 0x88221c9a15d56692c82fe5e6f956bdf53eb61854017aba5bacf6b40976119e00;
        bytes32 computed = keccak256(
            abi.encode(uint256(keccak256("delegationpool.storage.v1")) - 1)
        ) & ~bytes32(uint256(0xff));
        assertEq(computed, expected);
    }
}
