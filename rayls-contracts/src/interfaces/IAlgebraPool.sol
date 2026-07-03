// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @notice Minimal read/write interface for an Algebra Integral pool, derived from the pool ABI.
/// @dev Only the selectors required by FeeAggregator are declared here.
///      The 6-field `globalState` layout is specific to Algebra Integral (Algebra v2+);
///      V1 pools return a different tuple and are not supported.
interface IAlgebraPool {
    /// @notice Returns the current packed state of the pool.
    /// @return price   Current sqrt price as a Q64.96 fixed-point value (sqrt(token1/token0)).
    /// @return tick    Current tick derived from `price`.
    /// @return lastFee Most recently observed fee in hundredths of a basis point (1 = 0.0001 %).
    /// @return pluginConfig Active plugin flags as a bitmap.
    /// @return communityFee Community fee share in basis points (0–1000).
    /// @return unlocked False while a reentrancy lock is held.
    function globalState()
        external
        view
        returns (
            uint160 price,
            int24 tick,
            uint16 lastFee,
            uint8 pluginConfig,
            uint16 communityFee,
            bool unlocked
        );

    /// @notice The dynamic swap fee currently charged by the pool, in hundredths of a basis point.
    function fee() external view returns (uint16);

    /// @notice The lower-address token of the pair.
    function token0() external view returns (address);

    /// @notice The higher-address token of the pair.
    function token1() external view returns (address);

    /// @notice Total active liquidity currently in range.
    function liquidity() external view returns (uint128);

    /// @notice Minimum tick distance between initialised ticks.
    function tickSpacing() external view returns (int24);

    /// @notice Execute a swap against the pool's liquidity.
    /// @param recipient   Address that receives the output tokens.
    /// @param zeroToOne   Direction: `true` sells token0 for token1, `false` sells token1 for token0.
    /// @param amountRequired Positive = exact-input amount; negative = exact-output amount.
    /// @param limitSqrtPrice Q64.96 price bound — the swap halts if the price crosses this value.
    /// @param data        Arbitrary bytes forwarded to `IAlgebraSwapCallback.algebraSwapCallback`.
    /// @return amount0 Token0 delta from the pool's perspective (negative = sent out).
    /// @return amount1 Token1 delta from the pool's perspective (negative = sent out).
    function swap(
        address recipient,
        bool zeroToOne,
        int256 amountRequired,
        uint160 limitSqrtPrice,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}
