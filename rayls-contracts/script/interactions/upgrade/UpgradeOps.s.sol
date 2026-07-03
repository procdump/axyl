// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {InteractionScript} from "../_base/InteractionScript.sol";
import {DelegationPool} from "../../../src/consensus/DelegationPool.sol";
import {FeeAggregator} from "../../../src/fees/FeeAggregator.sol";
import {RewardDistributor} from "../../../src/fees/RewardDistributor.sol";
import {RLSAccumulator} from "../../../src/fees/RLSAccumulator.sol";
import {NativeTokenController} from "../../../src/native/NativeTokenController.sol";
import {RLS} from "../../../src/token/RLS.sol";

/// @title UpgradeOps
/// @notice UUPS upgrade operations for all 6 proxy contracts. Pick the action with `--sig`.
///
/// All `upgrade<Contract>()` actions:
///   1. Deploy a fresh implementation contract (same source, fresh bytecode)
///   2. Call `upgradeToAndCall(newImpl, "")` on the proxy
///   3. Verify the ERC-1967 implementation slot updated
///
/// `verify()` is read-only: it reports who has UPGRADER_ROLE on each contract and
/// confirms ERC-1967 slots are consistent — useful pre-flight check.
///
/// Usage (read-only check):
///   forge script .../UpgradeOps.s.sol:UpgradeOps --sig "verify()" --rpc-url $RPC_URL -vvvv
///
/// Usage (perform upgrade — caller must hold UPGRADER_ROLE on the target contract):
///   forge script .../UpgradeOps.s.sol:UpgradeOps --sig "upgradeFeeAggregator()" \
///     --rpc-url $RPC_URL --broadcast --skip-simulation --private-key $UPGRADER_PK -vvvv
///
/// Note: `--skip-simulation` is recommended because each upgrade deploys a real implementation
///       contract and the local revm may not reproduce all chain state perfectly.
contract UpgradeOps is InteractionScript {
    bytes32 internal constant ERC1967_IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    function run() public {
        verify();
    }

    // ── READ ────────────────────────────────────────────────────────────

    /// @notice Read-only: report ERC-1967 slot + UPGRADER_ROLE membership for each contract.
    /// Optional env: UPGRADER (extra address to check membership for; defaults to deployments.admin).
    function verify() public {
        address upgraderToCheck = vm.envOr("UPGRADER", deployments.admin);
        console2.log("========== Upgradability Verification ==========");
        console2.log("Checking UPGRADER_ROLE for:", upgraderToCheck);

        _verifyOne("DelegationPool", deployments.DelegationPool, deployments.DelegationPoolImpl, upgraderToCheck);
        _verifyOne("FeeAggregator", deployments.FeeAggregator, deployments.FeeAggregatorImpl, upgraderToCheck);
        _verifyOne("RewardDistributor", deployments.RewardDistributor, deployments.RewardDistributorImpl, upgraderToCheck);
        _verifyOne("NativeTokenController", deployments.NativeTokenController, deployments.NativeTokenControllerImpl, upgraderToCheck);
        _verifyOne("RLS", deployments.RLS, deployments.RLSImpl, upgraderToCheck);
        _verifyOne("RLSAccumulator", deployments.RLSAccumulator, deployments.RLSAccumulatorImpl, upgraderToCheck);
    }

    function _verifyOne(string memory name, address proxy, address expectedImpl, address upgrader) internal view {
        logSection(name);
        console2.log("Proxy:        ", proxy);
        console2.log("Expected impl:", expectedImpl);

        bytes32 raw = vm.load(proxy, ERC1967_IMPL_SLOT);
        address currentImpl = address(uint160(uint256(raw)));
        console2.log("Current impl: ", currentImpl);

        if (currentImpl == expectedImpl) {
            console2.log("ERC-1967 slot:", "OK");
        } else {
            console2.log("ERC-1967 slot:", "MISMATCH");
        }

        // hasRole via low-level staticcall (works for any AccessControl-style contract)
        (bool ok, bytes memory ret) = proxy.staticcall(
            abi.encodeWithSignature("hasRole(bytes32,address)", UPGRADER_ROLE, upgrader)
        );
        bool hasUpgrader = ok && ret.length >= 32 && abi.decode(ret, (bool));
        console2.log("UPGRADER role:", hasUpgrader);
    }

    // ── UPGRADES ────────────────────────────────────────────────────────

    /// @notice Deploy a fresh DelegationPool impl and upgrade the proxy to it.
    function upgradeDelegationPool() public {
        vm.startBroadcast();
        address newImpl = address(new DelegationPool());
        UUPSUpgradeable(deployments.DelegationPool).upgradeToAndCall(newImpl, "");
        vm.stopBroadcast();
        _verifyUpgrade("DelegationPool", deployments.DelegationPool, newImpl);
    }

    /// @notice Deploy a fresh FeeAggregator impl and upgrade the proxy to it.
    function upgradeFeeAggregator() public {
        vm.startBroadcast();
        address newImpl = address(new FeeAggregator());
        UUPSUpgradeable(deployments.FeeAggregator).upgradeToAndCall(newImpl, "");
        vm.stopBroadcast();
        _verifyUpgrade("FeeAggregator", deployments.FeeAggregator, newImpl);
    }

    /// @notice Deploy a fresh RewardDistributor impl and upgrade the proxy to it.
    function upgradeRewardDistributor() public {
        vm.startBroadcast();
        address newImpl = address(new RewardDistributor());
        UUPSUpgradeable(deployments.RewardDistributor).upgradeToAndCall(newImpl, "");
        vm.stopBroadcast();
        _verifyUpgrade("RewardDistributor", deployments.RewardDistributor, newImpl);
    }

    /// @notice Deploy a fresh NativeTokenController impl and upgrade the proxy to it.
    function upgradeNativeTokenController() public {
        vm.startBroadcast();
        address newImpl = address(new NativeTokenController());
        UUPSUpgradeable(deployments.NativeTokenController).upgradeToAndCall(newImpl, "");
        vm.stopBroadcast();
        _verifyUpgrade("NativeTokenController", deployments.NativeTokenController, newImpl);
    }

    /// @notice Deploy a fresh RLS impl and upgrade the proxy to it.
    function upgradeRLS() public {
        vm.startBroadcast();
        address newImpl = address(new RLS());
        UUPSUpgradeable(deployments.RLS).upgradeToAndCall(newImpl, "");
        vm.stopBroadcast();
        _verifyUpgrade("RLS", deployments.RLS, newImpl);
    }

    /// @notice Deploy a fresh RLSAccumulator impl and upgrade the proxy to it.
    function upgradeRLSAccumulator() public {
        vm.startBroadcast();
        address newImpl = address(new RLSAccumulator());
        UUPSUpgradeable(deployments.RLSAccumulator).upgradeToAndCall(newImpl, "");
        vm.stopBroadcast();
        _verifyUpgrade("RLSAccumulator", deployments.RLSAccumulator, newImpl);
    }

    function _verifyUpgrade(string memory name, address proxy, address expectedImpl) internal view {
        bytes32 raw = vm.load(proxy, ERC1967_IMPL_SLOT);
        address currentImpl = address(uint160(uint256(raw)));
        console2.log("");
        console2.log(name, "upgraded:");
        console2.log("  Proxy:           ", proxy);
        console2.log("  New impl:        ", expectedImpl);
        console2.log("  ERC-1967 reads:  ", currentImpl);
        require(currentImpl == expectedImpl, "upgrade did not persist");
        console2.log("  Status:          ", "OK");
    }
}
