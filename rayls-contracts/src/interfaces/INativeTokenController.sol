// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title INativeTokenController
/// @notice Interface matching the mint/burn methods exposed by the Reth native ERC-20 precompile at 0x0400.
/// @dev Selectors must match the Rust precompile exactly:
///      - mint(address,uint256)     → 0x40c10f19
///      - burn(uint256)             → 0x42966c68  (burns from msg.sender)
///      - burnFrom(address,uint256) → 0x79cc6790  (burns from account, requires allowance)

interface INativeTokenController {
        // ========== ERRORS ==========

    error ZeroAddress();
    error ZeroAmount();
    error PrecompileCallFailed(bytes returnData);

    // ========== EVENTS ==========

    event Minted(address indexed caller, address indexed to, uint256 amount);
    event Burned(address indexed caller, uint256 amount);
    event BurnedFrom(address indexed caller, address indexed account, uint256 amount);

    // ========== FUNCTIONS ==========

    /// @notice Mint native tokens to a recipient
    /// @param to The address to mint tokens to
    /// @param amount The amount of tokens to mint
    function mint(address to, uint256 amount) external returns (bool);

    /// @notice Burn native tokens from this contract's balance
    /// @param amount The amount of tokens to burn
    function burn(uint256 amount) external;

    /// @notice Burn native tokens from another account (requires precompile allowance)
    /// @param account The account to burn tokens from
    /// @param amount The amount of tokens to burn
    function burnFrom(address account, uint256 amount) external returns (bool);
}
