// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title IRLS
/// @notice Interface for the RLS ERC-20 token (v2)
interface IRLS is IERC20, IERC20Metadata, IERC20Permit {
    error InvalidAddress();
    error ZeroAmount();
    error MaxSupplyExceeded();

    event TokensMinted(address indexed receiver, uint256 amount);

    /// @notice The hard cap on total token supply (10 billion RLS)
    function MAX_SUPPLY() external view returns (uint256);

    /// @notice Mint tokens to the receiver (MINTER_ROLE only)
    function mint(address receiver, uint256 amount) external;

    /// @notice Pause all token transfers
    function pause() external;

    /// @notice Unpause the contract
    function unpause() external;

    /// @notice Returns the contract version
    function version() external pure returns (string memory);
}
