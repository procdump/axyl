// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {Safe} from "safe-contracts/contracts/Safe.sol";
import {SafeProxyFactory} from "safe-contracts/contracts/proxies/SafeProxyFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DelegationPool} from "../../src/consensus/DelegationPool.sol";
import {IDelegationPool} from "../../src/interfaces/IDelegationPool.sol";
import {RewardDistributor} from "../../src/fees/RewardDistributor.sol";
import {FeeAggregator} from "../../src/fees/FeeAggregator.sol";
import {IFeeAggregator} from "../../src/interfaces/IFeeAggregator.sol";
import {NativeTokenController} from "../../src/native/NativeTokenController.sol";
import {RLSAccumulator} from "../../src/fees/RLSAccumulator.sol";
import {GenesisPrecompiler} from "./GenesisPrecompiler.sol";

/// @title RlGenesis utility providing genesis-specific contract instantiation functions
/// @notice Genesis target addresses must first be stored via `_setGenesisTargets()`
/// @dev All genesis fns return simulated deployments, copying state changes to genesis targets in storage
abstract contract RlGenesis is GenesisPrecompiler {
    // ── State variables ──────────────────────────────────────────────────
    Safe safeImpl;
    SafeProxyFactory safeProxyFactory;
    Safe governanceSafe;
    address[] safeOwners;
    uint256 safeThreshold;
    DelegationPool delegationPoolImplContract;
    DelegationPool delegationPoolContract;
    FeeAggregator feeAggregatorImplContract;
    FeeAggregator feeAggregatorContract;
    RewardDistributor rewardDistributorImplContract;
    RewardDistributor rewardDistributorContract;
    NativeTokenController nativeTokenControllerImplContract;
    NativeTokenController nativeTokenControllerContract;
    RLSAccumulator rlsAccumulatorImplContract;
    RLSAccumulator rlsAccumulatorContract;

    uint256 public constant rlsTotalSupply = 100_000_000_000e18;
    uint256 public constant governanceInitialBalance = 10e18;

    /// @dev Sets this contract's state from a `deployments.json` file
    function _setGenesisTargets(
        address payable safeSingleton,
        address safeFactory,
        address payable safe,
        address delegationPoolImpl_,
        address delegationPool_,
        address payable feeAggregatorImpl_,
        address payable feeAggregator_,
        address payable rewardDistributorImpl_,
        address payable rewardDistributor_,
        address nativeTokenControllerImpl_,
        address nativeTokenController_,
        address rlsAccumulatorImpl_,
        address rlsAccumulator_
    ) internal {
        safeImpl = Safe(safeSingleton);
        safeProxyFactory = SafeProxyFactory(safeFactory);
        governanceSafe = Safe(safe);

        // Staking and Fee Distribution contracts
        delegationPoolImplContract = DelegationPool(delegationPoolImpl_);
        delegationPoolContract = DelegationPool(delegationPool_);
        feeAggregatorImplContract = FeeAggregator(feeAggregatorImpl_);
        feeAggregatorContract = FeeAggregator(feeAggregator_);
        rewardDistributorImplContract = RewardDistributor(rewardDistributorImpl_);
        rewardDistributorContract = RewardDistributor(rewardDistributor_);
        nativeTokenControllerImplContract = NativeTokenController(nativeTokenControllerImpl_);
        nativeTokenControllerContract = NativeTokenController(nativeTokenController_);
        rlsAccumulatorImplContract = RLSAccumulator(rlsAccumulatorImpl_);
        rlsAccumulatorContract = RLSAccumulator(rlsAccumulator_);
    }

    /// @notice Governance Safe infrastructure
    /// @dev Used as genesis precompiles for base fees and system contract ownership

    function instantiateSafeImpl()
        public
        virtual
        returns (Safe simulatedDeployment)
    {
        vm.startStateDiffRecording();
        simulatedDeployment = new Safe();
        Vm.AccountAccess[] memory safeImplRecords = vm.stopAndReturnStateDiff();

        bytes32[] memory slots = saveWrittenSlots(
            address(simulatedDeployment),
            safeImplRecords
        );
        copyContractState(
            address(simulatedDeployment),
            address(safeImpl),
            slots
        );
    }

    function instantiateSafeProxyFactory()
        public
        virtual
        returns (SafeProxyFactory simulatedDeployment)
    {
        simulatedDeployment = new SafeProxyFactory();

        copyContractState(
            address(simulatedDeployment),
            address(safeProxyFactory),
            new bytes32[](0)
        );
    }

    function instantiateGovernanceSafe()
        public
        virtual
        returns (Safe simulatedDeployment)
    {
        vm.startStateDiffRecording();

        address to;
        bytes memory data;
        address fallbackHandler;
        address paymentToken;
        uint256 payment;
        address paymentReceiver;
        bytes memory setupData = abi.encodeWithSelector(
            Safe.setup.selector,
            safeOwners,
            safeThreshold,
            to,
            data,
            fallbackHandler,
            paymentToken,
            payment,
            paymentReceiver
        );
        simulatedDeployment = Safe(
            payable(
                address(
                    safeProxyFactory.createProxyWithNonce(
                        address(safeImpl),
                        setupData,
                        0x0
                    )
                )
            )
        );

        Vm.AccountAccess[] memory safeRecords = vm.stopAndReturnStateDiff();
        bytes32[] memory slots = saveWrittenSlots(
            address(simulatedDeployment),
            safeRecords
        );
        copyContractState(
            address(simulatedDeployment),
            address(governanceSafe),
            slots
        );
    }

    /// @notice Staking and Fee Distribution infrastructure
    /// @dev DelegationPool, FeeAggregator, and RewardDistributor for validator staking and reward distribution

    function instantiateDelegationPoolImpl()
        public
        virtual
        returns (DelegationPool simulatedDeployment)
    {
        simulatedDeployment = new DelegationPool();

        copyContractState(
            address(simulatedDeployment),
            address(delegationPoolImplContract),
            new bytes32[](0)
        );
    }

    function instantiateDelegationPool(
        address impl,
        address rls_,
        address consensusRegistry_,
        address admin_,
        address rewardDistributor_,
        IDelegationPool.DelegationConfig memory config_
    )
        public
        virtual
        returns (DelegationPool simulatedDeployment)
    {
        vm.startStateDiffRecording();

        bytes memory initData = abi.encodeCall(
            DelegationPool.initialize,
            (
                rls_,
                consensusRegistry_,
                admin_,
                config_
            )
        );

        ERC1967Proxy proxy = new ERC1967Proxy(impl, initData);
        simulatedDeployment = DelegationPool(address(proxy));

        // Wire DelegationPool.rewardDistributor at genesis (admin-only post-init setter).
        vm.stopBroadcast();
        vm.prank(admin_);
        simulatedDeployment.setRewardDistributor(rewardDistributor_);
        vm.startBroadcast();

        Vm.AccountAccess[] memory dpRecords = vm.stopAndReturnStateDiff();

        bytes32[] memory slots = saveWrittenSlots(
            address(simulatedDeployment),
            dpRecords
        );
        copyContractState(
            address(simulatedDeployment),
            address(delegationPoolContract),
            slots
        );
    }

    function instantiateFeeAggregatorImpl()
        public
        virtual
        returns (FeeAggregator simulatedDeployment)
    {
        simulatedDeployment = new FeeAggregator();

        copyContractState(
            address(simulatedDeployment),
            address(feeAggregatorImplContract),
            new bytes32[](0)
        );
    }

    function instantiateFeeAggregator(
        address impl,
        address rlsToken_,
        address algebraRouter_,
        address rewardDistributor_,
        address ecosystemTreasury_,
        address burnAddress_,
        address usdrToken_,
        IFeeAggregator.DistributionConfig memory config_,
        address admin_
    )
        public
        virtual
        returns (FeeAggregator simulatedDeployment)
    {
        vm.startStateDiffRecording();

        bytes memory initData = abi.encodeCall(
            FeeAggregator.initialize,
            (
                rlsToken_,
                algebraRouter_,
                rewardDistributor_,
                ecosystemTreasury_,
                burnAddress_,
                usdrToken_,
                config_,
                admin_
            )
        );

        ERC1967Proxy proxy = new ERC1967Proxy(impl, initData);
        simulatedDeployment = FeeAggregator(payable(address(proxy)));

        Vm.AccountAccess[] memory faRecords = vm.stopAndReturnStateDiff();

        bytes32[] memory slots = saveWrittenSlots(
            address(simulatedDeployment),
            faRecords
        );
        copyContractState(
            address(simulatedDeployment),
            address(feeAggregatorContract),
            slots
        );
    }

    function instantiateRewardDistributorImpl()
        public
        virtual
        returns (RewardDistributor simulatedDeployment)
    {
        simulatedDeployment = new RewardDistributor();

        copyContractState(
            address(simulatedDeployment),
            address(rewardDistributorImplContract),
            new bytes32[](0)
        );
    }

    function instantiateRewardDistributor(
        address impl,
        address rls_,
        address feeAggregator_,
        address consensusRegistry_,
        address delegationPool_,
        address admin_,
        address accumulator_
    )
        public
        virtual
        returns (RewardDistributor simulatedDeployment)
    {
        vm.startStateDiffRecording();

        bytes memory initData = abi.encodeCall(
            RewardDistributor.initialize,
            (
                rls_,
                feeAggregator_,
                consensusRegistry_,
                delegationPool_,
                admin_
            )
        );

        ERC1967Proxy proxy = new ERC1967Proxy(impl, initData);
        simulatedDeployment = RewardDistributor(address(proxy));

        // Wire RewardDistributor.accumulator at genesis (admin-only post-init setter).
        vm.stopBroadcast();
        vm.prank(admin_);
        simulatedDeployment.setAccumulator(accumulator_);
        vm.startBroadcast();

        Vm.AccountAccess[] memory rdRecords = vm.stopAndReturnStateDiff();

        bytes32[] memory slots = saveWrittenSlots(
            address(simulatedDeployment),
            rdRecords
        );
        copyContractState(
            address(simulatedDeployment),
            address(rewardDistributorContract),
            slots
        );
    }

    function instantiateNativeTokenControllerImpl()
        public
        virtual
        returns (NativeTokenController simulatedDeployment)
    {
        simulatedDeployment = new NativeTokenController();

        copyContractState(
            address(simulatedDeployment),
            address(nativeTokenControllerImplContract),
            new bytes32[](0)
        );
    }

    function instantiateNativeTokenController(
        address impl,
        address admin_
    )
        public
        virtual
        returns (NativeTokenController simulatedDeployment)
    {
        vm.startStateDiffRecording();

        bytes memory initData = abi.encodeCall(
            NativeTokenController.initialize,
            (admin_)
        );

        ERC1967Proxy proxy = new ERC1967Proxy(impl, initData);
        simulatedDeployment = NativeTokenController(address(proxy));

        Vm.AccountAccess[] memory ntcRecords = vm.stopAndReturnStateDiff();

        bytes32[] memory slots = saveWrittenSlots(
            address(simulatedDeployment),
            ntcRecords
        );
        copyContractState(
            address(simulatedDeployment),
            address(nativeTokenControllerContract),
            slots
        );
    }

    function instantiateRLSAccumulatorImpl()
        public
        virtual
        returns (RLSAccumulator simulatedDeployment)
    {
        simulatedDeployment = new RLSAccumulator();

        copyContractState(
            address(simulatedDeployment),
            address(rlsAccumulatorImplContract),
            new bytes32[](0)
        );
    }

    /// @notice Simulate RLSAccumulator proxy deployment.
    /// @dev Operators must call `RLSAccumulator.refreshApproval()` as admin after chain launch to 
    /// set the real allowance on the genesis RLS token.
    function instantiateRLSAccumulator(
        address impl,
        address rls_,
        address rewardDistributor_,
        address admin_
    )
        public
        virtual
        returns (RLSAccumulator simulatedDeployment)
    {
        vm.startStateDiffRecording();

        bytes memory initData = abi.encodeCall(
            RLSAccumulator.initialize,
            (rls_, rewardDistributor_, admin_)
        );

        ERC1967Proxy proxy = new ERC1967Proxy(impl, initData);
        simulatedDeployment = RLSAccumulator(address(proxy));

        Vm.AccountAccess[] memory accRecords = vm.stopAndReturnStateDiff();

        bytes32[] memory slots = saveWrittenSlots(
            address(simulatedDeployment),
            accRecords
        );
        copyContractState(
            address(simulatedDeployment),
            address(rlsAccumulatorContract),
            slots
        );
    }
}
