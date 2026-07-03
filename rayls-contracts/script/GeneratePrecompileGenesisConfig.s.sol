// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {LibString} from "solady/utils/LibString.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {Deployments} from "../deployments/Deployments.sol";
import {RlGenesis} from "../deployments/genesis/RlGenesis.sol";
import {Safe} from "safe-contracts/contracts/Safe.sol";
import {SafeProxyFactory} from "safe-contracts/contracts/proxies/SafeProxyFactory.sol";
import {SafeProxy} from "safe-contracts/contracts/proxies/SafeProxy.sol";
import {DelegationPool} from "../src/consensus/DelegationPool.sol";
import {IDelegationPool} from "../src/interfaces/IDelegationPool.sol";
import {RewardDistributor} from "../src/fees/RewardDistributor.sol";
import {FeeAggregator} from "../src/fees/FeeAggregator.sol";
import {IFeeAggregator} from "../src/interfaces/IFeeAggregator.sol";
import {NativeTokenController} from "../src/native/NativeTokenController.sol";
import {RLSAccumulator} from "../src/fees/RLSAccumulator.sol";

/// @title Genesis Precompile Config Generator
/// @author Rayls Core Ltd., Telcoin Association
/// @notice Generates a yaml file comprising the storage slots and their values
/// Used by rayls-network protocol to instantiate the contracts with required configuration at genesis

/// @dev Usage: `forge script script/GenerateGenesisPrecompileConfig.s.sol -vvvv`
contract GenerateGenesisPrecompileConfig is RlGenesis, Script {
    Deployments deployments;
    address admin;
    string root;
    string dest;
    uint64 sharedNonce = 0;
    uint256 sharedBalance = 0;
    function setUp() public {
        root = vm.projectRoot();
        string memory path = string.concat(
            root,
            "/deployments/deployments.json"
        );
        string memory json = vm.readFile(path);
        bytes memory data = vm.parseJson(json);
        deployments = abi.decode(data, (Deployments));

        // Output target — must match a path whitelisted in foundry.toml fs_permissions.
        dest = string.concat(root, "/deployments/genesis/precompile-config.yaml");

        admin = vm.envOr("ADMIN", deployments.admin);
        require(admin != address(0), "ADMIN env or deployments.admin must be non-zero");

        safeOwners = new address[](1);
        safeOwners[0] = admin;
        safeThreshold = 1;

        _setGenesisTargets(
            payable(deployments.SafeImpl),
            deployments.SafeProxyFactory,
            payable(deployments.Safe),
            deployments.DelegationPoolImpl,
            deployments.DelegationPool,
            payable(deployments.FeeAggregatorImpl),
            payable(deployments.FeeAggregator),
            payable(deployments.RewardDistributorImpl),
            payable(deployments.RewardDistributor),
            deployments.NativeTokenControllerImpl,
            deployments.NativeTokenController,
            deployments.RLSAccumulatorImpl,
            deployments.RLSAccumulator
        );
    }

    function run() public {
        vm.startBroadcast();

        // initialize clean yaml file
        if (vm.exists(dest)) vm.removeFile(dest);
        vm.writeLine(dest, "---"); // indicate yaml format

        // safe impl (has storage)
        address simulatedSafeImpl = address(instantiateSafeImpl());
        assertTrue(
            yamlAppendGenesisAccount(
                dest,
                simulatedSafeImpl,
                deployments.SafeImpl,
                sharedNonce,
                sharedBalance
            )
        );

        // safe proxy factory (no storage)
        address simulatedSafeFactory = address(instantiateSafeProxyFactory());
        assertFalse(
            yamlAppendGenesisAccount(
                dest,
                simulatedSafeFactory,
                deployments.SafeProxyFactory,
                sharedNonce,
                sharedBalance
            )
        );
        // governance safe (has storage)
        address simulatedSafe = address(instantiateGovernanceSafe());
        assertTrue(
            yamlAppendGenesisAccount(
                dest,
                simulatedSafe,
                deployments.Safe,
                sharedNonce,
                governanceInitialBalance
            )
        );

        // FeeAggregator implementation (no storage, only bytecode)
        address simulatedFeeAggregatorImpl = address(instantiateFeeAggregatorImpl());
        assertFalse(
            yamlAppendGenesisAccount(
                dest,
                simulatedFeeAggregatorImpl,
                deployments.FeeAggregatorImpl,
                sharedNonce,
                sharedBalance
            )
        );

        // FeeAggregator proxy (has storage via initialize)
        IFeeAggregator.DistributionConfig memory faConfig = IFeeAggregator.DistributionConfig({
            validatorPoolBps: 5000,   // 50% to validators
            ecosystemBps: 0,       // 30% to ecosystem treasury
            burnBps: 5000             // 20% burn
        });
        // USDr is the native ERC-20 precompile at 0x...0400
        address usdrPrecompile = address(0x0000000000000000000000000000000000000400);
        address simulatedFeeAggregator = address(
            instantiateFeeAggregator(
                deployments.FeeAggregatorImpl,  // Implementation address
                deployments.RLS,                // RLS token,
                address(0),                     // Algebra router (set post-genesis)
                deployments.RewardDistributor,  // RewardDistributor
                address(0),                     // Ecosystem treasury
                address(0xdead),                // Burn address
                usdrPrecompile,                 // USDr token (precompile)
                faConfig,
                admin                           // Admin
            )
        );
        assertTrue(
            yamlAppendGenesisAccount(
                dest,
                simulatedFeeAggregator,
                deployments.FeeAggregator,
                sharedNonce,
                sharedBalance
            )
        );

        // NativeTokenController implementation (no storage)
        address simulatedNativeTokenControllerImpl = address(
            instantiateNativeTokenControllerImpl()
        );
        assertFalse(
            yamlAppendGenesisAccount(
                dest,
                simulatedNativeTokenControllerImpl,
                deployments.NativeTokenControllerImpl,
                sharedNonce,
                sharedBalance
            )
        );

        // NativeTokenController proxy (has storage - AccessControl roles, ERC1967 impl slot)
        address simulatedNativeTokenController = address(
            instantiateNativeTokenController(
                deployments.NativeTokenControllerImpl,  // Use target genesis address so ERC1967 slot is correct
                admin                           // Admin (can grant MINTER/BURNER roles)
            )
        );
        assertTrue(
            yamlAppendGenesisAccount(
                dest,
                simulatedNativeTokenController,
                deployments.NativeTokenController,
                sharedNonce,
                sharedBalance
            )
        );

        // DelegationPool implementation (no storage, only bytecode)
        address simulatedDelegationPoolImpl = address(instantiateDelegationPoolImpl());
        assertFalse(
            yamlAppendGenesisAccount(
                dest,
                simulatedDelegationPoolImpl,
                deployments.DelegationPoolImpl,
                sharedNonce,
                sharedBalance
            )
        );

        // DelegationPool proxy (has storage via initialize)
        IDelegationPool.DelegationConfig memory dpConfig = IDelegationPool.DelegationConfig({
            minDelegation: 1e18,
            maxDelegation: 500_000_000e18,
            maxValidatorDelegation: 500_000_000e18,
            unbondingEpochs: 14,
            commissionDelayEpochs: 7
        });
        address simulatedDelegationPool = address(
            instantiateDelegationPool(
                deployments.DelegationPoolImpl,  // Impl address (for ERC1967 slot)
                deployments.RLS,                 // RLS token
                deployments.ConsensusRegistry,   // ConsensusRegistry
                admin,                           // Admin
                deployments.RewardDistributor,   // RewardDistributor (set via post-init setter)
                dpConfig
            )
        );
        assertTrue(
            yamlAppendGenesisAccount(
                dest,
                simulatedDelegationPool,
                deployments.DelegationPool,
                sharedNonce,
                sharedBalance
            )
        );

        // RewardDistributor implementation (no storage, only bytecode)
        address simulatedRewardDistributorImpl = address(instantiateRewardDistributorImpl());
        assertFalse(
            yamlAppendGenesisAccount(
                dest,
                simulatedRewardDistributorImpl,
                deployments.RewardDistributorImpl,
                sharedNonce,
                sharedBalance
            )
        );

        // RewardDistributor proxy (has storage via initialize)
        address simulatedRewardDistributor = address(
            instantiateRewardDistributor(
                deployments.RewardDistributorImpl,  // Impl address (for ERC1967 slot)
                deployments.RLS,                    // RLS token
                deployments.FeeAggregator,          // FeeAggregator
                deployments.ConsensusRegistry,      // ConsensusRegistry
                deployments.DelegationPool,         // DelegationPool
                admin,                              // Admin
                deployments.RLSAccumulator          // Accumulator (wired via post-init setter)
            )
        );
        assertTrue(
            yamlAppendGenesisAccount(
                dest,
                simulatedRewardDistributor,
                deployments.RewardDistributor,
                sharedNonce,
                sharedBalance
            )
        );

        // RLSAccumulator implementation (no storage, only bytecode)
        address simulatedRLSAccumulatorImpl = address(instantiateRLSAccumulatorImpl());
        assertFalse(
            yamlAppendGenesisAccount(
                dest,
                simulatedRLSAccumulatorImpl,
                deployments.RLSAccumulatorImpl,
                sharedNonce,
                sharedBalance
            )
        );

        // RLSAccumulator proxy (has storage via initialize).
        // Stub the RLS token with minimal "return true" bytecode so the `forceApprove` doesn't revert
        vm.etch(deployments.RLS, hex"600160005260206000f3");
        address simulatedRLSAccumulator = address(
            instantiateRLSAccumulator(
                deployments.RLSAccumulatorImpl,  // Impl address (for ERC1967 slot)
                deployments.RLS,                 // RLS token (stubbed above)
                deployments.RewardDistributor,   // RewardDistributor
                admin                            // Admin
            )
        );
        assertTrue(
            yamlAppendGenesisAccount(
                dest,
                simulatedRLSAccumulator,
                deployments.RLSAccumulator,
                sharedNonce,
                sharedBalance
            )
        );

        vm.stopBroadcast();
    }
}
