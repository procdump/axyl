// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {RLSAccumulator} from "src/fees/RLSAccumulator.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockRLS is ERC20 {
    constructor() ERC20("Mock RLS", "RLS") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RLSAccumulatorTest is Test {
    RLSAccumulator public accumulator;
    MockRLS public rls;

    address public admin = address(0xAD01);
    address public rewardDistributor = address(0xBD01);
    address public depositor = address(0xDE01);
    address public user = address(0x3001);

    function setUp() public {
        rls = new MockRLS();

        RLSAccumulator impl = new RLSAccumulator();
        bytes memory initData = abi.encodeCall(
            RLSAccumulator.initialize,
            (address(rls), rewardDistributor, admin)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        accumulator = RLSAccumulator(address(proxy));

        // Fund depositor
        rls.mint(depositor, 1_000_000e18);
    }

    function test_initialize() public view {
        assertEq(accumulator.rlsToken(), address(rls));
        assertEq(accumulator.rewardDistributor(), rewardDistributor);
        assertTrue(accumulator.hasRole(accumulator.DEFAULT_ADMIN_ROLE(), admin));
        // DEPOSITOR_ROLE was removed — deposit() is permissionless
        assertTrue(accumulator.hasRole(accumulator.UPGRADER_ROLE(), admin));
    }

    function test_initialize_approvesRewardDistributor() public view {
        uint256 allowance = rls.allowance(address(accumulator), rewardDistributor);
        assertEq(allowance, type(uint256).max);
    }

    function testRevert_initialize_zeroRls() public {
        RLSAccumulator impl = new RLSAccumulator();
        vm.expectRevert(RLSAccumulator.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(RLSAccumulator.initialize, (address(0), rewardDistributor, admin))
        );
    }

    function testRevert_initialize_zeroDistributor() public {
        RLSAccumulator impl = new RLSAccumulator();
        vm.expectRevert(RLSAccumulator.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(RLSAccumulator.initialize, (address(rls), address(0), admin))
        );
    }

    function testRevert_initialize_zeroAdmin() public {
        RLSAccumulator impl = new RLSAccumulator();
        vm.expectRevert(RLSAccumulator.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(RLSAccumulator.initialize, (address(rls), rewardDistributor, address(0)))
        );
    }

    function test_deposit() public {
        uint256 amount = 100_000e18;

        vm.startPrank(depositor);
        rls.approve(address(accumulator), amount);
        accumulator.deposit(amount);
        vm.stopPrank();

        assertEq(accumulator.balance(), amount);
        assertEq(rls.balanceOf(address(accumulator)), amount);
    }

    function test_deposit_permissionless() public {
        // Anyone can deposit (no role guard)
        rls.mint(user, 1000e18);

        vm.startPrank(user);
        rls.approve(address(accumulator), 1000e18);
        accumulator.deposit(1000e18);
        vm.stopPrank();

        assertEq(accumulator.balance(), 1000e18);
    }

    function testRevert_deposit_zeroAmount() public {
        vm.expectRevert(RLSAccumulator.ZeroAmount.selector);
        accumulator.deposit(0);
    }

    function test_rewardDistributorCanPull() public {
        // Fund accumulator
        rls.mint(address(accumulator), 100_000e18);

        // RewardDistributor pulls via transferFrom
        vm.prank(rewardDistributor);
        rls.transferFrom(address(accumulator), rewardDistributor, 50_000e18);

        assertEq(rls.balanceOf(rewardDistributor), 50_000e18);
        assertEq(accumulator.balance(), 50_000e18);
    }

    function test_nonDistributorCannotPull() public {
        rls.mint(address(accumulator), 100_000e18);

        vm.prank(user);
        vm.expectRevert();
        rls.transferFrom(address(accumulator), user, 1e18);
    }

    function test_setRewardDistributor() public {
        address newDistributor = address(0xBE01);

        vm.prank(admin);
        accumulator.setRewardDistributor(newDistributor);

        assertEq(accumulator.rewardDistributor(), newDistributor);

        // Old approval revoked
        assertEq(rls.allowance(address(accumulator), rewardDistributor), 0);
        // New approval set
        assertEq(rls.allowance(address(accumulator), newDistributor), type(uint256).max);
    }

    function testRevert_setRewardDistributor_notAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        accumulator.setRewardDistributor(address(0x9999));
    }

    function testRevert_setRewardDistributor_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(RLSAccumulator.ZeroAddress.selector);
        accumulator.setRewardDistributor(address(0));
    }

    function test_setRlsToken() public {
        MockRLS newRls = new MockRLS();

        vm.prank(admin);
        accumulator.setRlsToken(address(newRls));

        // Token updated
        assertEq(accumulator.rlsToken(), address(newRls));

        // Old token approval revoked
        assertEq(rls.allowance(address(accumulator), rewardDistributor), 0);

        // New token approved for RewardDistributor
        assertEq(newRls.allowance(address(accumulator), rewardDistributor), type(uint256).max);
    }

    function test_setRlsToken_depositAndPullWithNewToken() public {
        MockRLS newRls = new MockRLS();
        vm.prank(admin);
        accumulator.setRlsToken(address(newRls));

        // Deposit new token
        newRls.mint(depositor, 1_000e18);
        vm.startPrank(depositor);
        newRls.approve(address(accumulator), 1_000e18);
        accumulator.deposit(1_000e18);
        vm.stopPrank();

        assertEq(accumulator.balance(), 1_000e18);

        // RewardDistributor can pull new token
        vm.prank(rewardDistributor);
        newRls.transferFrom(address(accumulator), rewardDistributor, 500e18);
        assertEq(newRls.balanceOf(rewardDistributor), 500e18);
    }

    function testRevert_setRlsToken_notAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        accumulator.setRlsToken(address(0x1234));
    }

    function testRevert_setRlsToken_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(RLSAccumulator.ZeroAddress.selector);
        accumulator.setRlsToken(address(0));
    }

    function test_refreshApproval() public {
        vm.prank(admin);
        accumulator.refreshApproval();

        assertEq(rls.allowance(address(accumulator), rewardDistributor), type(uint256).max);
    }

    function test_revokeApproval() public {
        vm.prank(admin);
        accumulator.revokeApproval();

        // Approval is now zero
        assertEq(rls.allowance(address(accumulator), rewardDistributor), 0);

        // RewardDistributor can no longer pull
        rls.mint(address(accumulator), 100_000e18);
        vm.prank(rewardDistributor);
        vm.expectRevert();
        rls.transferFrom(address(accumulator), rewardDistributor, 1e18);
    }

    function test_revokeApproval_thenRefresh() public {
        // Revoke
        vm.prank(admin);
        accumulator.revokeApproval();
        assertEq(rls.allowance(address(accumulator), rewardDistributor), 0);

        // Refresh restores access
        vm.prank(admin);
        accumulator.refreshApproval();
        assertEq(rls.allowance(address(accumulator), rewardDistributor), type(uint256).max);

        // RewardDistributor can pull again
        rls.mint(address(accumulator), 100_000e18);
        vm.prank(rewardDistributor);
        rls.transferFrom(address(accumulator), rewardDistributor, 1e18);
        assertEq(rls.balanceOf(rewardDistributor), 1e18);
    }

    function testRevert_revokeApproval_notAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        accumulator.revokeApproval();
    }

    function test_recoverTokens() public {
        // Send a non-RLS token to accumulator
        MockRLS otherToken = new MockRLS();
        otherToken.mint(address(accumulator), 500e18);

        vm.prank(admin);
        accumulator.recoverTokens(address(otherToken), admin, 500e18);

        assertEq(otherToken.balanceOf(admin), 500e18);
    }

    function test_recoverTokens_canDrainRls() public {
        rls.mint(address(accumulator), 100_000e18);

        vm.prank(admin);
        accumulator.recoverTokens(address(rls), admin, 100_000e18);

        assertEq(rls.balanceOf(admin), 100_000e18);
        assertEq(accumulator.balance(), 0);
    }

    function testRevert_recoverTokens_notAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        accumulator.recoverTokens(address(rls), user, 1e18);
    }

    function testRevert_recoverTokens_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(RLSAccumulator.ZeroAddress.selector);
        accumulator.recoverTokens(address(rls), address(0), 1e18);
    }
}
