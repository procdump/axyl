// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {DelegationPool} from "src/consensus/DelegationPool.sol";
import {IDelegationPool} from "src/interfaces/IDelegationPool.sol";
import {IConsensusRegistry} from "src/interfaces/IConsensusRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Mock RLS token (ERC-20 staking token) for testing
contract MockRLSExtended is ERC20 {
    constructor() ERC20("Mock RLS", "RLS") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Mock ConsensusRegistry that returns configurable validator status and epoch
contract MockConsensusRegistryExtended {
    mapping(address => IConsensusRegistry.ValidatorStatus) public validatorStatuses;
    mapping(address => bool) public validatorAllowlist;
    uint32 public currentEpoch;
    mapping(address => uint256) public balances;
    IERC20 public rlsToken;

    function setRlsToken(address rls_) external {
        rlsToken = IERC20(rls_);
    }

    function setValidatorStatus(address validator, IConsensusRegistry.ValidatorStatus status) external {
        validatorStatuses[validator] = status;
    }

    function setAllowlisted(address validator, bool allowed) external {
        validatorAllowlist[validator] = allowed;
    }

    function setCurrentEpoch(uint32 epoch) external {
        currentEpoch = epoch;
    }

    function setBalance(address validator, uint256 balance) external {
        balances[validator] = balance;
    }

    function getValidator(address validatorAddress) external view returns (IConsensusRegistry.ValidatorInfo memory) {
        return IConsensusRegistry.ValidatorInfo({
            blsPubkey: "",
            validatorAddress: validatorAddress,
            activationEpoch: 0,
            exitEpoch: 0,
            currentStatus: validatorStatuses[validatorAddress],
            isRetired: false,
            isDelegated: false,
            stakeVersion: 0
        });
    }

    function getCurrentEpoch() external view returns (uint32) {
        return currentEpoch;
    }

    function isAllowlisted(address validator) external view returns (bool) {
        return validatorAllowlist[validator];
    }

    function getBalance(address validator) external view returns (uint256) {
        return balances[validator];
    }

    function getValidators(uint8) external view returns (IConsensusRegistry.ValidatorInfo[] memory) {
        return new IConsensusRegistry.ValidatorInfo[](0);
    }

    // Receive slashed RLS tokens
    receive() external payable {}
}

contract DelegationPoolExtendedTest is Test {
    DelegationPool public pool;
    MockConsensusRegistryExtended public registry;
    MockRLSExtended public rls;

    address public owner = address(0xABCD);
    address public validator1 = address(0x1001);
    address public validator2 = address(0x1002);
    address public delegator1 = address(0x2001);
    address public delegator2 = address(0x2002);
    address public delegator3 = address(0x2003);
    address public rewardDistributor = address(0x3001);

    uint256 public constant MIN_DELEGATION = 1e18;
    uint256 public constant MAX_DELEGATION = 1_000_000e18;
    uint256 public constant MAX_VALIDATOR_DELEGATION = 10_000_000e18;
    uint32 public constant UNBONDING_EPOCHS = 3;
    uint32 public constant COMMISSION_DELAY_EPOCHS = 7;

    IDelegationPool.DelegationConfig defaultConfig;

    function setUp() public {
        rls = new MockRLSExtended();
        registry = new MockConsensusRegistryExtended();
        registry.setRlsToken(address(rls));

        defaultConfig = IDelegationPool.DelegationConfig({
            minDelegation: MIN_DELEGATION,
            maxDelegation: MAX_DELEGATION,
            maxValidatorDelegation: MAX_VALIDATOR_DELEGATION,
            unbondingEpochs: UNBONDING_EPOCHS,
            commissionDelayEpochs: COMMISSION_DELAY_EPOCHS
        });

        DelegationPool impl = new DelegationPool();
        bytes memory initData = abi.encodeCall(
            DelegationPool.initialize,
            (address(rls), address(registry), owner, defaultConfig)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        pool = DelegationPool(address(proxy));

        // Set reward distributor
        vm.prank(owner);
        pool.setRewardDistributor(rewardDistributor);

        // set validators as Active and allowlisted
        registry.setValidatorStatus(validator1, IConsensusRegistry.ValidatorStatus.Active);
        registry.setValidatorStatus(validator2, IConsensusRegistry.ValidatorStatus.Active);
        registry.setAllowlisted(validator1, true);
        registry.setAllowlisted(validator2, true);

        // mint RLS to delegators
        rls.mint(delegator1, 10_000_000e18);
        rls.mint(delegator2, 10_000_000e18);
        rls.mint(delegator3, 10_000_000e18);

        // approve pool to spend delegators' RLS
        vm.prank(delegator1);
        rls.approve(address(pool), type(uint256).max);
        vm.prank(delegator2);
        rls.approve(address(pool), type(uint256).max);
        vm.prank(delegator3);
        rls.approve(address(pool), type(uint256).max);
    }

    // Helper: distribute rewards to a validator's pool.
    // Advances epoch by 1 to ensure prior delegations are eligible (DP-NEW-002).
    function _distributeRewards(address validator, uint256 amount) internal {
        registry.setCurrentEpoch(registry.getCurrentEpoch() + 1);
        rls.mint(address(pool), amount);
        vm.prank(rewardDistributor);
        pool.distributePoolRewards(validator, amount);
    }

    // =========================================================================
    //  1. Late delegator gets no retroactive rewards (rewardDebt)
    // =========================================================================

    function test_lateDelegator_noRetroactiveRewards() public {
        vm.prank(validator1);
        pool.registerPool(0); // 0% commission for simpler math

        registry.setCurrentEpoch(1);

        // Delegator1 delegates 100e18 at epoch 1
        vm.prank(delegator1);
        pool.delegate(validator1, 100e18);

        // Distribute 100e18 rewards (all go to delegator1 since 0% commission)
        _distributeRewards(validator1, 100e18);

        registry.setCurrentEpoch(2);

        // Delegator2 delegates 100e18 at epoch 2 (after rewards distributed)
        vm.prank(delegator2);
        pool.delegate(validator1, 100e18);

        // Delegator1 should have 100e18 rewards from epoch 1
        uint256 d1Rewards = pool.getPendingRewards(validator1, delegator1);
        assertEq(d1Rewards, 100e18, "delegator1 should have full epoch-1 rewards");

        // Delegator2 should have 0 rewards (rewardDebt prevents retroactive rewards)
        uint256 d2Rewards = pool.getPendingRewards(validator1, delegator2);
        assertEq(d2Rewards, 0, "delegator2 must not receive retroactive rewards");
    }

    // =========================================================================
    //  2. Early exiter earns no rewards after undelegation
    // =========================================================================

    function test_earlyExiter_noNewRewards() public {
        vm.prank(validator1);
        pool.registerPool(0); // 0% commission

        registry.setCurrentEpoch(1);

        // Delegator1 delegates 100e18
        vm.prank(delegator1);
        pool.delegate(validator1, 100e18);

        // Delegator2 delegates 100e18 (so pool isn't empty after d1 exits)
        vm.prank(delegator2);
        pool.delegate(validator1, 100e18);

        // Distribute first round of rewards: 100e18 split 50/50
        _distributeRewards(validator1, 100e18);

        uint256 d1RewardsBefore = pool.getPendingRewards(validator1, delegator1);
        assertEq(d1RewardsBefore, 50e18, "delegator1 should have 50e18 after first distribution");

        registry.setCurrentEpoch(2);

        // Delegator1 fully undelegates
        vm.prank(delegator1);
        pool.requestUndelegation(validator1, 100e18);

        // Distribute second round of rewards: 200e18 all to delegator2 (only active delegator)
        _distributeRewards(validator1, 200e18);

        // Delegator1's rewards should still be 50e18 (only from before undelegation)
        // Their pendingRewards were settled at undelegation time
        uint256 d1RewardsAfter = pool.getPendingRewards(validator1, delegator1);
        assertEq(d1RewardsAfter, 50e18, "delegator1 must not earn rewards after undelegation");

        // Delegator2 gets all second-round rewards: 50 (first round) + 200 (second round) = 250
        uint256 d2Rewards = pool.getPendingRewards(validator1, delegator2);
        assertEq(d2Rewards, 250e18, "delegator2 should get all post-exit rewards");
    }

    // =========================================================================
    //  3. Partial undelegation — remaining stake earns rewards
    // =========================================================================

    function test_partialUndelegation_remainingEarnsRewards() public {
        vm.prank(validator1);
        pool.registerPool(0); // 0% commission

        registry.setCurrentEpoch(1);

        // Delegate 100e18
        vm.prank(delegator1);
        pool.delegate(validator1, 100e18);

        registry.setCurrentEpoch(2);

        // Undelegate 50e18 (partial)
        vm.prank(delegator1);
        pool.requestUndelegation(validator1, 50e18);

        // Verify pool state
        assertEq(pool.getTotalDelegatedStake(validator1), 50e18, "totalDelegated should be 50e18");

        // Distribute 100e18 rewards — only 50e18 active, so all delegator rewards go to that
        _distributeRewards(validator1, 100e18);

        // Remaining 50e18 should earn 100e18 in rewards
        uint256 rewards = pool.getPendingRewards(validator1, delegator1);
        assertEq(rewards, 100e18, "remaining 50e18 should earn full reward on reduced pool");
    }

    // =========================================================================
    //  4. Three delegators get proportional rewards
    // =========================================================================

    function test_multipleDelegators_proportionalRewards() public {
        vm.prank(validator1);
        pool.registerPool(0); // 0% commission for clean proportional math

        // 3 delegators: 100, 200, 300 = total 600
        vm.prank(delegator1);
        pool.delegate(validator1, 100e18);

        vm.prank(delegator2);
        pool.delegate(validator1, 200e18);

        vm.prank(delegator3);
        pool.delegate(validator1, 300e18);

        assertEq(pool.getTotalDelegatedStake(validator1), 600e18);

        // Distribute 600e18 rewards (0% commission, so all 600 to delegators)
        _distributeRewards(validator1, 600e18);

        // Proportional shares: 100/600 * 600 = 100, 200/600 * 600 = 200, 300/600 * 600 = 300
        uint256 d1Rewards = pool.getPendingRewards(validator1, delegator1);
        uint256 d2Rewards = pool.getPendingRewards(validator1, delegator2);
        uint256 d3Rewards = pool.getPendingRewards(validator1, delegator3);

        assertEq(d1Rewards, 100e18, "delegator1 (100/600) should get 100e18");
        assertEq(d2Rewards, 200e18, "delegator2 (200/600) should get 200e18");
        assertEq(d3Rewards, 300e18, "delegator3 (300/600) should get 300e18");
    }

    // =========================================================================
    //  5. Commission increase requires delay before activation
    // =========================================================================

    function test_commissionIncrease_delayedActivation() public {
        vm.prank(validator1);
        pool.registerPool(1000); // 10%

        registry.setCurrentEpoch(1);

        // Delegator delegates so we can test reward splits
        vm.prank(delegator1);
        pool.delegate(validator1, 100e18);

        // Update commission to 15% (increase)
        vm.prank(validator1);
        pool.updateCommission(1500);

        // Commission should still be 10%
        IDelegationPool.ValidatorPool memory vp = pool.getValidatorPool(validator1);
        assertEq(vp.commissionBps, 1000, "commission must not change immediately on increase");

        // Pending commission should be set
        IDelegationPool.PendingCommission memory pc = pool.getPendingCommission(validator1);
        assertEq(pc.newBps, 1500);
        assertEq(pc.effectiveEpoch, 1 + COMMISSION_DELAY_EPOCHS);

        // Distribute rewards while old commission is active — 10% commission
        _distributeRewards(validator1, 1000e18);

        vp = pool.getValidatorPool(validator1);
        assertEq(vp.pendingValidatorRewards, 100e18, "validator should get 10% = 100e18 commission");

        uint256 d1Rewards = pool.getPendingRewards(validator1, delegator1);
        assertEq(d1Rewards, 900e18, "delegator should get 90% = 900e18");

        // Trying to activate before delay should revert
        registry.setCurrentEpoch(1 + COMMISSION_DELAY_EPOCHS - 1);
        vm.prank(validator1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDelegationPool.CommissionNotYetEffective.selector,
                uint32(1 + COMMISSION_DELAY_EPOCHS - 1),
                uint32(1 + COMMISSION_DELAY_EPOCHS)
            )
        );
        pool.activatePendingCommission();

        // Advance past delay and activate
        registry.setCurrentEpoch(1 + COMMISSION_DELAY_EPOCHS);
        vm.prank(validator1);
        pool.activatePendingCommission();

        vp = pool.getValidatorPool(validator1);
        assertEq(vp.commissionBps, 1500, "commission should now be 15%");

        // Pending should be cleared
        pc = pool.getPendingCommission(validator1);
        assertEq(pc.newBps, 0);
        assertEq(pc.effectiveEpoch, 0);

        // Distribute rewards under new commission — 15% commission
        _distributeRewards(validator1, 1000e18);

        // Validator had 100e18, now gets additional 150e18 = 250 total
        vp = pool.getValidatorPool(validator1);
        assertEq(vp.pendingValidatorRewards, 250e18, "validator should get 10% + 15% across two distributions");
    }

    // =========================================================================
    //  6. Commission decrease applies immediately
    // =========================================================================

    function test_commissionDecrease_immediateEffect() public {
        vm.prank(validator1);
        pool.registerPool(1000); // 10%

        // Delegator delegates
        vm.prank(delegator1);
        pool.delegate(validator1, 100e18);

        // Decrease commission to 5%
        vm.prank(validator1);
        pool.updateCommission(500);

        // Verify it's applied immediately
        IDelegationPool.ValidatorPool memory vp = pool.getValidatorPool(validator1);
        assertEq(vp.commissionBps, 500, "decrease should apply immediately");

        // Distribute 1000e18 rewards — 5% commission = 50e18 to validator
        _distributeRewards(validator1, 1000e18);

        vp = pool.getValidatorPool(validator1);
        assertEq(vp.pendingValidatorRewards, 50e18, "validator should get 5% = 50e18");

        uint256 d1Rewards = pool.getPendingRewards(validator1, delegator1);
        assertEq(d1Rewards, 950e18, "delegator should get 95% = 950e18");
    }

    // =========================================================================
    //  7. Slash during active delegation — position settled before rewards
    // =========================================================================

    function test_slashDuringActiveDelegation_positionSettled() public {
        vm.prank(validator1);
        pool.registerPool(0); // 0% commission

        // Delegator delegates 100e18
        vm.prank(delegator1);
        pool.delegate(validator1, 100e18);

        // Slash 20e18 (20% of pool)
        vm.prank(address(registry));
        pool.applyPoolSlash(validator1, 20e18);

        // Effective position should be reduced
        (uint256 effectiveAmount, uint256 pendingRewards) = pool.getEffectivePosition(validator1, delegator1);
        assertEq(effectiveAmount, 80e18, "effective position should be 80e18 after 20% slash");
        assertEq(pendingRewards, 0, "no rewards distributed yet");

        // Pool total reduced
        assertEq(pool.getTotalDelegatedStake(validator1), 80e18);

        // Distribute 80e18 rewards on reduced pool
        _distributeRewards(validator1, 80e18);

        // Delegator claims rewards — settlement happens: slash applied first, then rewards
        (effectiveAmount, pendingRewards) = pool.getEffectivePosition(validator1, delegator1);
        assertEq(effectiveAmount, 80e18, "effective amount should still be 80e18");
        assertEq(pendingRewards, 80e18, "rewards calculated on post-slash amount");

        // Actually claim and verify token transfer
        uint256 balanceBefore = rls.balanceOf(delegator1);
        vm.prank(delegator1);
        pool.claimDelegationRewards(validator1);
        assertEq(rls.balanceOf(delegator1) - balanceBefore, 80e18, "claimed rewards should match");
    }

    // =========================================================================
    //  8. Unbonding delegator protected from post-exit slash
    // =========================================================================

    function test_unbondingDelegator_protectedFromSlash() public {
        vm.prank(validator1);
        pool.registerPool(0);

        // Two delegators so pool isn't empty after d1 exits
        vm.prank(delegator1);
        pool.delegate(validator1, 100e18);

        vm.prank(delegator2);
        pool.delegate(validator1, 100e18);

        registry.setCurrentEpoch(5);

        // Delegator1 requests full undelegation
        vm.prank(delegator1);
        pool.requestUndelegation(validator1, 100e18);

        // Verify undelegateAmount is set
        IDelegationPool.DelegatorPosition memory pos = pool.getDelegatorPosition(validator1, delegator1);
        assertEq(pos.undelegateAmount, 100e18);

        // totalDelegated reduced to 100e18 (only d2 remains)
        assertEq(pool.getTotalDelegatedStake(validator1), 100e18);

        // Slash happens AFTER d1's exit request — 50e18 on remaining 100e18
        vm.prank(address(registry));
        pool.applyPoolSlash(validator1, 50e18);

        // Pool total reduced to 50e18 (only d2 is affected)
        assertEq(pool.getTotalDelegatedStake(validator1), 50e18);

        // Delegator1's undelegateAmount is NOT affected by slash
        pos = pool.getDelegatorPosition(validator1, delegator1);
        assertEq(pos.undelegateAmount, 100e18, "unbonding amount must be protected from post-exit slash");

        // Delegator2's effective position is slashed
        (uint256 d2Effective, ) = pool.getEffectivePosition(validator1, delegator2);
        assertEq(d2Effective, 50e18, "active delegator should bear the slash");

        // Complete d1's undelegation — they get the full 100e18 back
        registry.setCurrentEpoch(5 + UNBONDING_EPOCHS);
        uint256 balanceBefore = rls.balanceOf(delegator1);
        vm.prank(delegator1);
        pool.completeUndelegation(validator1);
        assertEq(rls.balanceOf(delegator1) - balanceBefore, 100e18, "unbonding delegator gets full amount");
    }

    // =========================================================================
    //  9. Fuzz: delegate/undelegate invariant on totalDelegated
    // =========================================================================

    function testFuzz_delegateUndelegate_totalDelegatedInvariant(
        uint256 amount1,
        uint256 amount2,
        uint256 amount3,
        uint256 undelegateAmount1
    ) public {
        // Bound amounts to valid range
        amount1 = bound(amount1, MIN_DELEGATION, MAX_DELEGATION);
        amount2 = bound(amount2, MIN_DELEGATION, MAX_DELEGATION);
        amount3 = bound(amount3, MIN_DELEGATION, MAX_DELEGATION);

        // Cap total to maxValidatorDelegation
        vm.assume(amount1 + amount2 + amount3 <= MAX_VALIDATOR_DELEGATION);

        vm.prank(validator1);
        pool.registerPool(0);

        // Delegate
        vm.prank(delegator1);
        pool.delegate(validator1, amount1);

        vm.prank(delegator2);
        pool.delegate(validator1, amount2);

        vm.prank(delegator3);
        pool.delegate(validator1, amount3);

        uint256 expectedTotal = amount1 + amount2 + amount3;
        assertEq(
            pool.getTotalDelegatedStake(validator1),
            expectedTotal,
            "totalDelegated should equal sum of delegations"
        );

        // Verify sum of positions matches
        IDelegationPool.DelegatorPosition memory pos1 = pool.getDelegatorPosition(validator1, delegator1);
        IDelegationPool.DelegatorPosition memory pos2 = pool.getDelegatorPosition(validator1, delegator2);
        IDelegationPool.DelegatorPosition memory pos3 = pool.getDelegatorPosition(validator1, delegator3);

        assertEq(
            pos1.amount + pos2.amount + pos3.amount,
            pool.getTotalDelegatedStake(validator1),
            "sum(position.amount) must equal totalDelegated"
        );

        // Partial undelegate from delegator1
        undelegateAmount1 = bound(undelegateAmount1, 1, amount1);

        registry.setCurrentEpoch(1);

        vm.prank(delegator1);
        pool.requestUndelegation(validator1, undelegateAmount1);

        expectedTotal -= undelegateAmount1;
        assertEq(
            pool.getTotalDelegatedStake(validator1),
            expectedTotal,
            "totalDelegated should decrease by undelegated amount"
        );

        // Verify invariant still holds
        pos1 = pool.getDelegatorPosition(validator1, delegator1);
        pos2 = pool.getDelegatorPosition(validator1, delegator2);
        pos3 = pool.getDelegatorPosition(validator1, delegator3);

        assertEq(
            pos1.amount + pos2.amount + pos3.amount,
            pool.getTotalDelegatedStake(validator1),
            "sum(position.amount) must equal totalDelegated after undelegation"
        );
    }

    // =========================================================================
    //  10. Rounding: minimum delegation with tiny reward
    // =========================================================================

    function test_rounding_minimumDelegation_smallReward() public {
        vm.prank(validator1);
        pool.registerPool(0); // 0% commission

        // Delegate exactly minDelegation (1e18)
        vm.prank(delegator1);
        pool.delegate(validator1, MIN_DELEGATION);

        // Distribute 1 wei of reward — should not revert
        _distributeRewards(validator1, 1);

        // Reward is 0 due to rounding: 1 * 1e18 / 1e18 = 1 for accum
        // pendingReward = (1e18 * 1) / 1e18 - 0 = 1 wei
        // With rounding, it could be 0 or 1 — both acceptable
        uint256 rewards = pool.getPendingRewards(validator1, delegator1);
        assertTrue(rewards <= 1, "reward should be 0 or 1 wei due to rounding");

        // If there are rewards, claiming should not revert
        if (rewards > 0) {
            uint256 balanceBefore = rls.balanceOf(delegator1);
            vm.prank(delegator1);
            pool.claimDelegationRewards(validator1);
            assertEq(rls.balanceOf(delegator1) - balanceBefore, rewards);
        }
    }
}
