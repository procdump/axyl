// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IAlgebraSwapCallback} from "./callback/IAlgebraSwapCallback.sol";

/// @notice Algebra periphery swap-router interface, derived from the router contract ABI.
/// @dev Algebra's router adds a `deployer` field to single-hop param structs (absent in Uniswap V3)
///      to support custom pool deployers. Multi-hop path encoding is otherwise identical to V3.
interface ISwapRouter is IAlgebraSwapCallback {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        address deployer;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 limitSqrtPrice;
    }

    /// @notice Sell an exact amount of `tokenIn` for as much `tokenOut` as possible.
    /// @param params Swap configuration.
    /// @return amountOut Actual amount of `tokenOut` received.
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /// @notice Sell an exact amount of the first token in `path` for as much of the last token as possible.
    /// @param params Multi-hop swap configuration including the encoded path.
    /// @return amountOut Actual amount of the final token received.
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        address deployer;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 limitSqrtPrice;
    }

    /// @notice Buy an exact amount of `tokenOut` using as little `tokenIn` as possible.
    /// @dev When paying with a native token, pair this with `refundNativeToken` in a multicall.
    /// @param params Swap configuration.
    /// @return amountIn Actual amount of `tokenIn` consumed.
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);

    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    /// @notice Buy an exact amount of the last token in `path` using as little of the first token as possible.
    /// @dev When paying with a native token, pair this with `refundNativeToken` in a multicall.
    /// @param params Multi-hop swap configuration including the encoded path (reversed).
    /// @return amountIn Actual amount of the input token consumed.
    function exactOutput(ExactOutputParams calldata params) external payable returns (uint256 amountIn);

    /// @notice Variant of `exactInputSingle` that pulls tokens from the caller before the swap,
    ///         required for tokens that charge a fee on transfer.
    /// @param params Swap configuration (same layout as `exactInputSingle`).
    /// @return amountOut Actual amount of `tokenOut` received.
    function exactInputSingleSupportingFeeOnTransferTokens(
        ExactInputSingleParams calldata params
    ) external payable returns (uint256 amountOut);
}
