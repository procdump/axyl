// SPDX-License-Identifier: MIT or Apache-2.0
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {FeeAggregator} from "src/fees/FeeAggregator.sol";
import {RewardDistributor} from "src/fees/RewardDistributor.sol";
import {DelegationPool} from "src/consensus/DelegationPool.sol";
import {IFeeAggregator} from "src/interfaces/IFeeAggregator.sol";
import {IDelegationPool} from "src/interfaces/IDelegationPool.sol";
import {IConsensusRegistry} from "src/interfaces/IConsensusRegistry.sol";
import {ISwapRouter} from "src/interfaces/ISwapRouter.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockRLS is ERC20 {
    constructor() ERC20("Mock RLS", "RLS") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockStable is ERC20 {
    constructor() ERC20("Mock USDT", "USDT") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockAlgebraRouter {
    MockRLS public rlsToken;
    uint256 public swapRate; // RLS out per unit in, scaled by 1e18
    constructor(address _rls) { rlsToken = MockRLS(_rls); swapRate = 1e30; }
    function setSwapRate(uint256 r) external { swapRate = r; }
    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata p) external returns (uint256 amountOut) {
        amountOut = (p.amountIn * swapRate) / 1e18;
        require(amountOut >= p.amountOutMinimum, "Too little received");
        ERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn); // pull tokenIn (FA approved)
        rlsToken.mint(p.recipient, amountOut);
    }
}

contract MockAlgebraPool {
    uint160 public sqrtPriceX96 = 79228162514264337593543950336;
    function globalState() external view returns (uint160, int24, uint16, uint8, uint8, uint8) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0);
    }
}

contract MockCR {
    mapping(address => IConsensusRegistry.ValidatorStatus) public status;
    mapping(address => bool) public allowed;
    uint32 public currentEpoch;
    IConsensusRegistry.PerformanceWeights private perf;

    function setStatus(address v, IConsensusRegistry.ValidatorStatus s) external { status[v] = s; }
    function setAllowlisted(address v, bool a) external { allowed[v] = a; }
    function setCurrentEpoch(uint32 e) external { currentEpoch = e; }
    function setPerformanceWeights(address[] memory v, uint256[] memory w, uint256 t) external {
        perf = IConsensusRegistry.PerformanceWeights({validators: v, weights: w, totalWeight: t});
    }
    function getEpochPerformanceWeights() external view returns (IConsensusRegistry.PerformanceWeights memory) {
        return perf;
    }
    function getBalanceBreakdown(address) external pure returns (uint256, uint256, uint256) {
        return (0, 0, 0); // ownStake=0 → all reward to delegation pool; split path covered by RewardDistributor{,Extended}Test
    }
    function isAllowlisted(address v) external view returns (bool) { return allowed[v]; }
    function getCurrentEpoch() external view returns (uint32) { return currentEpoch; }
    function getValidator(address v) external view returns (IConsensusRegistry.ValidatorInfo memory) {
        return IConsensusRegistry.ValidatorInfo({
            blsPubkey: "", validatorAddress: v, activationEpoch: 0, exitEpoch: 0,
            currentStatus: status[v], isRetired: false, isDelegated: false, stakeVersion: 0
        });
    }
}

/// @dev Drives the full fee→reward pipeline and tracks every RLS crossing the
///      {FA,RD,DP} boundary so the invariant can check conservation exactly.
contract PipelineHandler is Test {
    address internal constant SYSTEM = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;

    FeeAggregator public fa;
    RewardDistributor public rd;
    DelegationPool public dp;
    MockRLS public rls;
    MockStable public stable;
    MockCR public registry;
    address public keeper;
    address public validator;
    address[] public delegators;

    uint256 public rlsIn;  // RLS entering the pipeline (swap mints + delegations)
    uint256 public rlsOut; // RLS leaving the pipeline (claims + completed undelegations)

    constructor(
        FeeAggregator _fa, RewardDistributor _rd, DelegationPool _dp,
        MockRLS _rls, MockStable _stable, MockCR _registry,
        address _keeper, address _validator, address[] memory _delegators
    ) {
        fa = _fa; rd = _rd; dp = _dp; rls = _rls; stable = _stable; registry = _registry;
        keeper = _keeper; validator = _validator; delegators = _delegators;
    }

    function _actor(uint256 s) internal view returns (address) { return delegators[s % delegators.length]; }

    function receiveFee(uint256 amount) external {
        amount = bound(amount, 2_000e6, 80_000e6);
        stable.mint(address(this), amount);
        stable.approve(address(fa), amount);
        fa.receiveFee(address(stable), amount);
    }

    function swap(uint256 amount) external {
        uint256 pending = fa.pendingBalance(address(stable));
        if (pending < 2_000e6) return;
        amount = bound(amount, 2_000e6, pending > 80_000e6 ? 80_000e6 : pending);
        uint256 got;
        vm.prank(keeper);
        try fa.swapToRls(IFeeAggregator.SwapParams({stablecoin: address(stable), stablecoinAmount: amount, minRlsOut: 0})) returns (uint256 r) {
            got = r;
        } catch { return; }
        rlsIn += got; // router minted `got` RLS into FA
    }

    function distributeFees() external {
        vm.prank(keeper);
        try fa.distributeEpochFees() {} catch {}
    }

    function distributeRewards() external {
        registry.setCurrentEpoch(registry.getCurrentEpoch() + 1);
        vm.prank(SYSTEM);
        try rd.distributeRewards() {} catch {}
    }

    function delegate(uint256 seed, uint256 amount) external {
        address d = _actor(seed);
        IDelegationPool.DelegatorPosition memory pos = dp.getDelegatorPosition(validator, d);
        IDelegationPool.ValidatorPool memory vp = dp.getValidatorPool(validator);
        uint256 room = 10_000_000e18 - vp.totalDelegated;
        uint256 actorRoom = 1_000_000e18 - pos.amount;
        uint256 cap = room < actorRoom ? room : actorRoom;
        if (cap < 1e18) return;
        amount = bound(amount, 1e18, cap);
        vm.prank(d);
        dp.delegate(validator, amount);
        rlsIn += amount; // delegator RLS entered DP
    }

    function requestUndelegation(uint256 seed, uint256 amount) external {
        address d = _actor(seed);
        IDelegationPool.DelegatorPosition memory pos = dp.getDelegatorPosition(validator, d);
        if (pos.amount == 0 || pos.undelegateEpoch != 0) return;
        amount = bound(amount, 1, pos.amount);
        vm.prank(d);
        dp.requestUndelegation(validator, amount);
    }

    function completeUndelegation(uint256 seed) external {
        address d = _actor(seed);
        IDelegationPool.DelegatorPosition memory pos = dp.getDelegatorPosition(validator, d);
        if (pos.undelegateEpoch == 0 || registry.getCurrentEpoch() < pos.undelegateEpoch) return;
        uint256 before = rls.balanceOf(d);
        vm.prank(d);
        dp.completeUndelegation(validator);
        rlsOut += rls.balanceOf(d) - before;
    }

    function claimRewards(uint256 seed) external {
        address d = _actor(seed);
        (, uint256 rewards) = dp.getEffectivePosition(validator, d);
        if (rewards == 0) return;
        uint256 before = rls.balanceOf(d);
        vm.prank(d);
        dp.claimDelegationRewards(validator);
        rlsOut += rls.balanceOf(d) - before;
    }

    function claimCommission() external {
        if (dp.getValidatorPool(validator).pendingValidatorRewards == 0) return;
        uint256 before = rls.balanceOf(validator);
        vm.prank(validator);
        dp.claimCommission();
        rlsOut += rls.balanceOf(validator) - before;
    }

    function advanceEpoch(uint256 n) external {
        registry.setCurrentEpoch(registry.getCurrentEpoch() + uint32(bound(n, 1, 5)));
    }

    function slash(uint256 amount) external {
        uint256 total = dp.getValidatorPool(validator).totalDelegated;
        if (total == 0) return;
        amount = bound(amount, 1, total);
        vm.prank(address(registry)); // applyPoolSlash is onlyConsensusRegistry
        uint256 slashed = dp.applyPoolSlash(validator, amount);
        rlsOut += slashed; // slashed RLS leaves DP → ConsensusRegistry (outside the pipeline set)
    }
}

/// @notice Conservation invariant for the fee→reward pipeline (FeeAggregator →
///         RewardDistributor → DelegationPool): RLS is only moved, never created
///         or destroyed inside the pipeline. The RLS held across the three
///         contracts must always equal everything that entered (swap mints +
///         delegations) minus everything that left (claims + completed
///         undelegations). A reward-inflation or fund-loss bug breaks this.
contract RewardPipelineConservationInvariant is Test {
    FeeAggregator internal fa;
    RewardDistributor internal rd;
    DelegationPool internal dp;
    MockRLS internal rls;
    MockStable internal stable;
    MockAlgebraRouter internal router;
    MockAlgebraPool internal pool;
    MockCR internal registry;
    PipelineHandler internal handler;

    address internal owner = address(0xABCD);
    address internal admin = address(0xA11CE);
    address internal keeper = address(0x1EEE);
    address internal validator = address(0x1001);
    address[] internal delegators;

    function setUp() public {
        rls = new MockRLS();
        stable = new MockStable();
        router = new MockAlgebraRouter(address(rls));
        pool = new MockAlgebraPool();
        registry = new MockCR();

        // DelegationPool
        IDelegationPool.DelegationConfig memory cfg = IDelegationPool.DelegationConfig({
            minDelegation: 1e18, maxDelegation: 1_000_000e18, maxValidatorDelegation: 10_000_000e18,
            unbondingEpochs: 3, commissionDelayEpochs: 7
        });
        dp = DelegationPool(address(new ERC1967Proxy(
            address(new DelegationPool()),
            abi.encodeCall(DelegationPool.initialize, (address(rls), address(registry), owner, cfg))
        )));

        // FeeAggregator — 100% of swapped RLS routes to the RewardDistributor (no ecosystem/burn outflow)
        IFeeAggregator.DistributionConfig memory dcfg = IFeeAggregator.DistributionConfig({
            validatorPoolBps: 10000, ecosystemBps: 0, burnBps: 0
        });
        fa = FeeAggregator(payable(address(new ERC1967Proxy(
            address(new FeeAggregator()),
            abi.encodeCall(FeeAggregator.initialize, (
                address(rls), address(router), owner /*temp RD*/, address(0xECCC), address(0xDEAD),
                address(0xD5D5), dcfg, admin
            ))
        ))));

        // RewardDistributor
        rd = RewardDistributor(address(new ERC1967Proxy(
            address(new RewardDistributor()),
            abi.encodeCall(RewardDistributor.initialize, (address(rls), address(fa), address(registry), address(dp), owner))
        )));

        // Wire the cross-references + roles
        vm.prank(admin);
        fa.setRewardDistributor(address(rd));
        vm.startPrank(owner);
        dp.setRewardDistributor(address(rd)); // RD is DP's authorized reward source
        vm.stopPrank();

        // CR: one active, allowlisted validator with full performance weight
        registry.setStatus(validator, IConsensusRegistry.ValidatorStatus.Active);
        registry.setAllowlisted(validator, true);
        registry.setCurrentEpoch(1);
        address[] memory vs = new address[](1);
        uint256[] memory ws = new uint256[](1);
        vs[0] = validator; ws[0] = 1;
        registry.setPerformanceWeights(vs, ws, 1);

        vm.prank(validator);
        dp.registerPool(1000); // 10% commission

        for (uint256 i = 0; i < 4; i++) {
            address d = address(uint160(0x2000 + i));
            delegators.push(d);
            rls.mint(d, 5_000_000e18);
            vm.prank(d);
            rls.approve(address(dp), type(uint256).max);
        }

        // Keeper role on FA (swap + distribute). Resolve the role id BEFORE pranking —
        // a nested external call in the args would otherwise consume the prank.
        bytes32 keeperRole = fa.KEEPER_ROLE();
        vm.prank(admin);
        fa.grantRole(keeperRole, keeper);

        handler = new PipelineHandler(fa, rd, dp, rls, stable, registry, keeper, validator, delegators);

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.receiveFee.selector;
        selectors[1] = handler.swap.selector;
        selectors[2] = handler.distributeFees.selector;
        selectors[3] = handler.distributeRewards.selector;
        selectors[4] = handler.delegate.selector;
        selectors[5] = handler.requestUndelegation.selector;
        selectors[6] = handler.completeUndelegation.selector;
        selectors[7] = handler.claimRewards.selector;
        selectors[8] = handler.claimCommission.selector;
        selectors[9] = handler.advanceEpoch.selector;
        selectors[10] = handler.slash.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
        // only the handler is fuzzed; exclude the rest (defensive vs Forge target-selection changes)
        excludeContract(address(fa));
        excludeContract(address(rd));
        excludeContract(address(dp));
        excludeContract(address(rls));
        excludeContract(address(stable));
        excludeContract(address(router));
        excludeContract(address(pool));
        excludeContract(address(registry));
    }

    function invariant_pipelineConservesRls() public view {
        uint256 held = rls.balanceOf(address(fa)) + rls.balanceOf(address(rd)) + rls.balanceOf(address(dp));
        assertEq(held, handler.rlsIn() - handler.rlsOut(), "pipeline created or lost RLS");
    }

    /// @notice FA holds exactly the stablecoin it accounts as pending — fees are neither
    ///         stranded nor lost across receiveFee/swap. (Enabled by the mock router pulling
    ///         tokenIn, mirroring production; a wrong pendingBalance decrement would break this.)
    function invariant_faStablecoinMatchesPending() public view {
        assertEq(
            stable.balanceOf(address(fa)),
            fa.pendingBalance(address(stable)),
            "FA stablecoin balance diverged from pendingBalance"
        );
    }
}
