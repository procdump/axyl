// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {InteractionScript} from "../_base/InteractionScript.sol";
import {ConsensusRegistry} from "../../../src/consensus/ConsensusRegistry.sol";
import {IConsensusRegistry} from "../../../src/interfaces/IConsensusRegistry.sol";
import {IStakeManager} from "../../../src/interfaces/IStakeManager.sol";

/// @title ConsensusRegistryOps
/// @notice Read-only diagnostics for ConsensusRegistry. Pick the action with `--sig`.
///
/// Usage:
///   forge script .../ConsensusRegistryOps.s.sol:ConsensusRegistryOps --sig "status()" \
///     --rpc-url $RPC_URL -vvvv
///
///   VALIDATOR=0x... \
///     forge script .../ConsensusRegistryOps.s.sol:ConsensusRegistryOps --sig "validatorDetail()" \
///     --rpc-url $RPC_URL -vvvv
///
///   EPOCH=42 \
///     forge script .../ConsensusRegistryOps.s.sol:ConsensusRegistryOps --sig "epochDetail()" \
///     --rpc-url $RPC_URL -vvvv
contract ConsensusRegistryOps is InteractionScript {
    ConsensusRegistry registry;

    function _setUp() internal override {
        registry = ConsensusRegistry(deployments.ConsensusRegistry);
    }

    function run() public {
        status();
    }

    /// @notice Full configuration dump. Optional env: VALIDATOR, EPOCH.
    function status() public {
        console2.log("========== ConsensusRegistry Status ==========");
        console2.log("Contract:", address(registry));

        logSection("Wiring");
        console2.log("RLS Token:     ", registry.rlsToken());
        console2.log("DelegationPool:", registry.delegationPool());

        logSection("Roles");
        console2.log("Owner:", registry.owner());

        logSection("State");
        console2.log("Paused:        ", registry.paused());
        console2.log("Current epoch: ", uint256(registry.getCurrentEpoch()));
        console2.log("Stake version: ", uint256(registry.getCurrentStakeVersion()));

        logSection("Current StakeConfig");
        IStakeManager.StakeConfig memory sc = registry.getCurrentStakeConfig();
        console2.log("Stake amount:        ", sc.stakeAmount);
        console2.log("Min withdraw amount: ", sc.minWithdrawAmount);
        console2.log("Epoch duration:      ", uint256(sc.epochDuration));

        logSection("Current EpochInfo");
        IConsensusRegistry.EpochInfo memory ei = registry.getCurrentEpochInfo();
        console2.log("Committee size: ", ei.committee.length);
        console2.log("Block height:   ", uint256(ei.blockHeight));
        console2.log("Epoch duration: ", uint256(ei.epochDuration));
        console2.log("Stake version:  ", uint256(ei.stakeVersion));

        logSection("Balances");
        console2.log("Registry RLS:  ", balanceOf(rls, address(registry)));
        console2.log("Slashed funds: ", registry.slashedFunds());

        logSection("Validator counts");
        console2.log("Total (unretired):       ", registry.getValidators(IConsensusRegistry.ValidatorStatus.Any).length);
        console2.log("Staked:                  ", registry.getValidators(IConsensusRegistry.ValidatorStatus.Staked).length);
        console2.log("Active (incl. pending):  ", registry.getValidators(IConsensusRegistry.ValidatorStatus.Active).length);
        console2.log("PendingActivation:       ", registry.getValidators(IConsensusRegistry.ValidatorStatus.PendingActivation).length);
        console2.log("PendingExit:             ", registry.getValidators(IConsensusRegistry.ValidatorStatus.PendingExit).length);
        console2.log("Exited:                  ", registry.getValidators(IConsensusRegistry.ValidatorStatus.Exited).length);

        logSection("Performance Weights (last applyIncentives)");
        IConsensusRegistry.PerformanceWeights memory pw = registry.getEpochPerformanceWeights();
        console2.log("Validators counted:", pw.validators.length);
        console2.log("Total weight:      ", pw.totalWeight);

        address validator = vm.envOr("VALIDATOR", address(0));
        if (validator != address(0)) _printValidator(validator);

        uint32 epoch = uint32(vm.envOr("EPOCH", uint256(type(uint32).max)));
        if (epoch != type(uint32).max) _printEpoch(epoch);
    }

    /// @notice Per-validator detail. Env: VALIDATOR (required).
    function validatorDetail() public {
        address validator = vm.envAddress("VALIDATOR");
        console2.log("========== Validator Detail ==========");
        console2.log("Registry:", address(registry));
        _printValidator(validator);
    }

    /// @notice Per-epoch detail. Env: EPOCH (required).
    function epochDetail() public {
        uint32 epoch = uint32(vm.envUint("EPOCH"));
        console2.log("========== Epoch Detail ==========");
        console2.log("Registry:", address(registry));
        _printEpoch(epoch);
    }

    function _printValidator(address validator) internal view {
        logSection("Validator");
        console2.log("Address:    ", validator);
        console2.log("Allowlisted:", registry.isAllowlisted(validator));
        console2.log("Retired:    ", registry.isRetired(validator));

        IConsensusRegistry.ValidatorInfo memory v = registry.getValidator(validator);
        console2.log("Status:           ", uint256(v.currentStatus));
        console2.log("Activation epoch: ", uint256(v.activationEpoch));
        console2.log("Exit epoch:       ", uint256(v.exitEpoch));
        console2.log("Is delegated:     ", v.isDelegated);
        console2.log("Stake version:    ", uint256(v.stakeVersion));

        if (v.currentStatus != IConsensusRegistry.ValidatorStatus.Undefined) {
            (uint256 outstanding, uint256 initial, uint256 rewards) = registry.getBalanceBreakdown(validator);
            console2.log("Outstanding balance:", outstanding);
            console2.log("Initial stake:      ", initial);
            console2.log("Rewards:            ", rewards);
            console2.log("Pool rewards owed:  ", registry.poolRewardBalances(validator));
        }
    }

    function _printEpoch(uint32 epoch) internal view {
        logSection("Epoch");
        console2.log("Epoch:", uint256(epoch));
        IConsensusRegistry.EpochInfo memory ei = registry.getEpochInfo(epoch);
        console2.log("Committee size: ", ei.committee.length);
        console2.log("Block height:   ", uint256(ei.blockHeight));
        console2.log("Epoch duration: ", uint256(ei.epochDuration));
        console2.log("Stake version:  ", uint256(ei.stakeVersion));
        for (uint256 i; i < ei.committee.length; ++i) {
            console2.log("  [%d]", i, ei.committee[i]);
        }
    }
}
