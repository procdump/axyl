// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ISwapRouter } from "../interfaces/ISwapRouter.sol";
import { IAlgebraPool } from "../interfaces/IAlgebraPool.sol";

/**
 * @title MockAlgebraPool
 * @notice Testnet-deployable mock of an Algebra pool.
 *         Returns a configurable sqrtPriceX96 so FeeAggregator can compute
 *         slippage limits and price impact.
 */
contract MockAlgebraPool is IAlgebraPool, Ownable {
    address public override token0;
    address public override token1;

    uint160 public sqrtPriceX96;
    int24 public currentTick;
    uint128 public override liquidity;

    constructor(address token0_, address token1_, uint160 initialSqrtPrice) Ownable(msg.sender) {
        require(token0_ < token1_, "token0 >= token1");
        token0 = token0_;
        token1 = token1_;
        sqrtPriceX96 = initialSqrtPrice;
        liquidity = type(uint128).max; // "infinite" liquidity
    }

    // ── IAlgebraPool – read functions ──────────────────────────────────

    function globalState()
        external
        view
        override
        returns (uint160 price, int24 tick, uint16 lastFee, uint8 pluginConfig, uint16 communityFee, bool unlocked)
    {
        return (sqrtPriceX96, currentTick, 100, 0, 0, true);
    }

    function fee() external pure override returns (uint16) {
        return 100; // 0.01%
    }

    function tickSpacing() external pure override returns (int24) {
        return 60;
    }

    function swap(address, bool, int256, uint160, bytes calldata)
        external
        pure
        override
        returns (int256, int256)
    {
        revert("use router");
    }

    // ── Admin setters ─────────────────────────────────────────────────

    function setSqrtPriceX96(uint160 newPrice) external onlyOwner {
        sqrtPriceX96 = newPrice;
    }

    function setTick(int24 newTick) external onlyOwner {
        currentTick = newTick;
    }

    /// @notice Convenience: set price from a human-readable ratio.
    /// @param priceNum   Numerator   (e.g. 1 for "1 token1 per 10 token0")
    /// @param priceDenom Denominator (e.g. 10)
    /// @dev   sqrtPriceX96 ≈ sqrt(priceNum/priceDenom) * 2^96.
    ///        Uses an integer Newton's-method sqrt — accurate enough for testnet.
    function setPriceFromRatio(uint256 priceNum, uint256 priceDenom) external onlyOwner {
        require(priceDenom > 0, "zero denom");
        // scaled = priceNum * 2^192 / priceDenom
        uint256 scaled = (priceNum << 192) / priceDenom;
        sqrtPriceX96 = uint160(_sqrt(scaled));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = x / 2 + 1;
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        }
    }
}

/**
 * @title MockAlgebraRouter
 * @notice Testnet-deployable mock of the Algebra SwapRouter.
 *
 *         Pre-fund this contract with RLS tokens. When FeeAggregator calls
 *         `exactInputSingle`, the router pulls the stablecoin and sends RLS
 *         back at a configurable rate.
 *
 *         Rate semantics:
 *           amountOut = amountIn × rate / 10^(tokenIn decimals)
 *         where `rate` is the RLS (18-dec) output per 1 whole unit of stablecoin.
 *
 *         Example – RLS at $10, USDT 6 decimals:
 *           rate = 0.1e18 → 10 000 USDT in → 1 000 RLS out
 */
contract MockAlgebraRouter is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable rls;

    struct RateConfig {
        uint256 rate; // RLS-wei per 1 whole stablecoin unit
        uint8 decimals; // stablecoin decimals
    }

    mapping(address stablecoin => RateConfig) public rates;

    event SwapExecuted(address indexed tokenIn, address indexed recipient, uint256 amountIn, uint256 amountOut);

    error NoRateConfigured(address token);
    error OutputBelowMinimum(uint256 got, uint256 min);
    error DeadlineExpired();
    error OutputMustBeRLS();
    error InsufficientLiquidity(uint256 needed, uint256 available);

    constructor(address rls_) Ownable(msg.sender) {
        rls = IERC20(rls_);
    }

    // ── ISwapRouter.exactInputSingle ───────────────────────────

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        if (block.timestamp > params.deadline) revert DeadlineExpired();
        if (params.tokenOut != address(rls)) revert OutputMustBeRLS();

        RateConfig memory rc = rates[params.tokenIn];
        if (rc.rate == 0) revert NoRateConfigured(params.tokenIn);

        // Pull stablecoin from caller (FeeAggregator)
        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);

        // amountOut = amountIn * rate / 10^decimals
        amountOut = (params.amountIn * rc.rate) / (10 ** rc.decimals);

        if (amountOut < params.amountOutMinimum) revert OutputBelowMinimum(amountOut, params.amountOutMinimum);

        uint256 available = rls.balanceOf(address(this));
        if (amountOut > available) revert InsufficientLiquidity(amountOut, available);

        // Send RLS to recipient
        rls.safeTransfer(params.recipient, amountOut);

        emit SwapExecuted(params.tokenIn, params.recipient, params.amountIn, amountOut);
    }

    // ── Admin ─────────────────────────────────────────────────────────

    /// @notice Configure swap rate for a stablecoin.
    /// @param stablecoin The stablecoin address.
    /// @param rate       RLS-wei returned per 1 whole stablecoin (e.g. 0.1e18 means RLS=$10).
    /// @param decimals   The stablecoin's decimals (6 for USDT/USDC, 18 for USDr).
    function setRate(address stablecoin, uint256 rate, uint8 decimals) external onlyOwner {
        rates[stablecoin] = RateConfig(rate, decimals);
    }

    /// @notice Withdraw any token held by this contract.
    function withdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /// @notice Check RLS balance available for swaps.
    function availableRls() external view returns (uint256) {
        return rls.balanceOf(address(this));
    }
}
