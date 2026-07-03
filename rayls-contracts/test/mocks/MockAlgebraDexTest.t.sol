// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { MockAlgebraPool, MockAlgebraRouter } from "../../src/mocks/MockAlgebraDex.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ISwapRouter } from "../../src/interfaces/ISwapRouter.sol";

contract MintableERC20 is ERC20 {
    uint8 private _dec;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _dec = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }
}

contract MockAlgebraDexTest is Test {
    MockAlgebraRouter router;
    MockAlgebraPool pool;
    MintableERC20 rls;
    MintableERC20 usdt;

    address admin = address(this);
    address swapper = makeAddr("swapper");

    function setUp() public {
        // Deploy tokens — ensure usdt < rls for pool ordering
        usdt = new MintableERC20("USDT", "USDT", 6);
        rls = new MintableERC20("RLS", "RLS", 18);
        if (address(usdt) > address(rls)) {
            (usdt, rls) = (
                new MintableERC20("USDT", "USDT", 6),
                new MintableERC20("RLS", "RLS", 18)
            );
            // If still wrong order, just skip the pool token-order assertion
        }

        // Deploy mock DEX
        // sqrtPriceX96 for 1:1 price = 2^96 ≈ 79228162514264337593543950336
        uint160 oneToOne = 79228162514264337593543950336;
        address t0 = address(usdt) < address(rls) ? address(usdt) : address(rls);
        address t1 = address(usdt) < address(rls) ? address(rls) : address(usdt);
        pool = new MockAlgebraPool(t0, t1, oneToOne);
        router = new MockAlgebraRouter(address(rls));

        // Configure rate: 1 USDT → 0.1 RLS (RLS price = $10)
        router.setRate(address(usdt), 0.1e18, 6);

        // Fund router with RLS liquidity
        rls.mint(address(router), 1_000_000e18);
    }

    // ── Pool tests ────────────────────────────────────────────────────

    function test_pool_globalState_returns_configured_price() public view {
        (uint160 price,,,,,) = pool.globalState();
        assertEq(price, 79228162514264337593543950336);
    }

    function test_pool_setPriceFromRatio() public {
        // Set price: 1 token1 per 10 token0 → sqrtPrice = sqrt(0.1) * 2^96
        pool.setPriceFromRatio(1, 10);
        (uint160 price,,,,,) = pool.globalState();
        assertTrue(price > 0);
        // sqrt(0.1) ≈ 0.3162, * 2^96 ≈ 25_054_144_837_504_793_118_641_380_156
        // Allow 1% tolerance for integer sqrt
        uint256 expected = 25_054_144_837_504_793_118_641_380_156;
        assertApproxEqRel(price, expected, 0.01e18);
    }

    function test_pool_admin_only() public {
        vm.prank(swapper);
        vm.expectRevert();
        pool.setSqrtPriceX96(123);
    }

    // ── Router tests ──────────────────────────────────────────────────

    function test_swap_basic() public {
        uint256 amountIn = 10_000e6; // 10,000 USDT
        usdt.mint(swapper, amountIn);

        vm.startPrank(swapper);
        usdt.approve(address(router), amountIn);

        uint256 amountOut = router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(usdt),
                tokenOut: address(rls),
                deployer: address(0),
                recipient: swapper,
                deadline: block.timestamp + 300,
                amountIn: amountIn,
                amountOutMinimum: 0,
                limitSqrtPrice: 0
            })
        );
        vm.stopPrank();

        // 10,000 USDT * 0.1 RLS/USDT = 1,000 RLS
        assertEq(amountOut, 1_000e18);
        assertEq(rls.balanceOf(swapper), 1_000e18);
        assertEq(usdt.balanceOf(address(router)), amountIn);
    }

    function test_swap_respects_minOut() public {
        uint256 amountIn = 100e6;
        usdt.mint(swapper, amountIn);

        vm.startPrank(swapper);
        usdt.approve(address(router), amountIn);

        // 100 USDT → 10 RLS, but demand 11 RLS minimum
        vm.expectRevert();
        router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(usdt),
                tokenOut: address(rls),
                deployer: address(0),
                recipient: swapper,
                deadline: block.timestamp + 300,
                amountIn: amountIn,
                amountOutMinimum: 11e18,
                limitSqrtPrice: 0
            })
        );
        vm.stopPrank();
    }

    function test_swap_reverts_on_expired_deadline() public {
        usdt.mint(swapper, 100e6);
        vm.startPrank(swapper);
        usdt.approve(address(router), 100e6);

        vm.expectRevert();
        router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(usdt),
                tokenOut: address(rls),
                deployer: address(0),
                recipient: swapper,
                deadline: block.timestamp - 1,
                amountIn: 100e6,
                amountOutMinimum: 0,
                limitSqrtPrice: 0
            })
        );
        vm.stopPrank();
    }

    function test_swap_reverts_when_insufficient_rls() public {
        // Set rate so output would exceed router balance
        router.setRate(address(usdt), 2_000_000e18, 6); // absurd rate
        usdt.mint(swapper, 1e6);

        vm.startPrank(swapper);
        usdt.approve(address(router), 1e6);

        vm.expectRevert();
        router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(usdt),
                tokenOut: address(rls),
                deployer: address(0),
                recipient: swapper,
                deadline: block.timestamp + 300,
                amountIn: 1e6,
                amountOutMinimum: 0,
                limitSqrtPrice: 0
            })
        );
        vm.stopPrank();
    }

    function test_swap_rate_change() public {
        // Change rate to 1:1 (RLS = $1)
        router.setRate(address(usdt), 1e18, 6);

        uint256 amountIn = 5_000e6;
        usdt.mint(swapper, amountIn);

        vm.startPrank(swapper);
        usdt.approve(address(router), amountIn);

        uint256 amountOut = router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(usdt),
                tokenOut: address(rls),
                deployer: address(0),
                recipient: swapper,
                deadline: block.timestamp + 300,
                amountIn: amountIn,
                amountOutMinimum: 0,
                limitSqrtPrice: 0
            })
        );
        vm.stopPrank();

        assertEq(amountOut, 5_000e18);
    }

    function test_withdraw() public {
        uint256 before = rls.balanceOf(admin);
        router.withdraw(address(rls), 100e18);
        assertEq(rls.balanceOf(admin), before + 100e18);
    }

    function test_availableRls() public view {
        assertEq(router.availableRls(), 1_000_000e18);
    }

    function test_router_admin_only() public {
        vm.prank(swapper);
        vm.expectRevert();
        router.setRate(address(usdt), 1e18, 6);
    }
}
