// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IMintableBurnable
/// @notice LayerZero OFT-compatible mint/burn interface
/// @dev Matches layerzerolabs/oft-evm/contracts/interfaces/IMintableBurnable.sol exactly.
///      When the oft-evm package is installed, this file can be replaced with the
///      package import.
interface IMintableBurnable {
    /// @dev Mints `_amount` tokens to address `_to`.
    /// @param _to The address that will receive the minted tokens.
    /// @param _amount The amount of tokens to mint.
    /// @return bool indicating success
    function mint(address _to, uint256 _amount) external returns (bool);

    /// @dev Burns `_amount` tokens from address `_from`.
    /// @param _from The address that the tokens will be burned from.
    /// @param _amount The amount of tokens to burn.
    /// @return bool indicating success
    function burn(address _from, uint256 _amount) external returns (bool);
}
