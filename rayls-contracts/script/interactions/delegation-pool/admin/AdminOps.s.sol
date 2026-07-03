// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {InteractionScript} from "../../_base/InteractionScript.sol";
import {DelegationPool} from "../../../../src/consensus/DelegationPool.sol";
import {IDelegationPool} from "../../../../src/interfaces/IDelegationPool.sol";

/// @title AdminOps
/// @notice DelegationPool admin operations. Pick the action with `--sig`.
/// @dev Requires DEFAULT_ADMIN_ROLE.
///
/// Usage:
///   REWARD_DISTRIBUTOR=0x... \
///     forge script .../AdminOps.s.sol:AdminOps --sig "setConfig()" \
///     --rpc-url $RPC_URL --broadcast --private-key $ADMIN_PK -vvvv
contract AdminOps is InteractionScript {
    DelegationPool pool;

    struct ConfigInputs {
        address rewardDistributor;
        uint256 minDelegation;
        uint256 maxDelegation;
        uint256 maxValidatorDelegation;
        uint32 unbondingEpochs;
        uint32 commissionDelayEpochs;
        bool updateRewardDist;
        bool updateConfig;
    }

    function _setUp() internal override {
        pool = DelegationPool(deployments.DelegationPool);
    }

    function run() public {
        setConfig();
    }

    /// @notice Update wiring + delegation config. Pass any subset of env vars.
    /// Env vars:
    ///   REWARD_DISTRIBUTOR
    ///   MIN_DELEGATION + MAX_DELEGATION + MAX_VALIDATOR_DELEGATION + UNBONDING_EPOCHS + COMMISSION_DELAY_EPOCHS
    ///   (config update requires ALL five)
    function setConfig() public {
        ConfigInputs memory inp = _readConfigInputs();
        require(
            inp.updateRewardDist || inp.updateConfig,
            "Set REWARD_DISTRIBUTOR or full delegation config (5 vars)"
        );

        logSection("Current");
        console2.log("RewardDistributor:", pool.rewardDistributor());
        IDelegationPool.DelegationConfig memory cfg = pool.getDelegationConfig();
        console2.log("Min delegation:           ", cfg.minDelegation);
        console2.log("Max delegation:           ", cfg.maxDelegation);
        console2.log("Max validator delegation: ", cfg.maxValidatorDelegation);
        console2.log("Unbonding epochs:         ", uint256(cfg.unbondingEpochs));
        console2.log("Commission delay epochs:  ", uint256(cfg.commissionDelayEpochs));

        if (inp.updateRewardDist) {
            logSection("New RewardDistributor");
            console2.log(inp.rewardDistributor);
        }
        if (inp.updateConfig) {
            logSection("New config");
            console2.log("Min delegation:           ", inp.minDelegation);
            console2.log("Max delegation:           ", inp.maxDelegation);
            console2.log("Max validator delegation: ", inp.maxValidatorDelegation);
            console2.log("Unbonding epochs:         ", uint256(inp.unbondingEpochs));
            console2.log("Commission delay epochs:  ", uint256(inp.commissionDelayEpochs));
        }

        vm.startBroadcast();
        if (inp.updateRewardDist) pool.setRewardDistributor(inp.rewardDistributor);
        if (inp.updateConfig) {
            pool.updateConfig(IDelegationPool.DelegationConfig({
                minDelegation: inp.minDelegation,
                maxDelegation: inp.maxDelegation,
                maxValidatorDelegation: inp.maxValidatorDelegation,
                unbondingEpochs: inp.unbondingEpochs,
                commissionDelayEpochs: inp.commissionDelayEpochs
            }));
        }
        vm.stopBroadcast();

        if (inp.updateRewardDist) require(pool.rewardDistributor() == inp.rewardDistributor, "rd mismatch");
        if (inp.updateConfig) {
            IDelegationPool.DelegationConfig memory cur = pool.getDelegationConfig();
            require(cur.minDelegation == inp.minDelegation, "min mismatch");
            require(cur.maxDelegation == inp.maxDelegation, "max mismatch");
            require(cur.maxValidatorDelegation == inp.maxValidatorDelegation, "maxValidator mismatch");
            require(cur.unbondingEpochs == inp.unbondingEpochs, "unbond mismatch");
            require(cur.commissionDelayEpochs == inp.commissionDelayEpochs, "delay mismatch");
        }

        console2.log("");
        console2.log("Done.");
    }

    function _readConfigInputs() internal view returns (ConfigInputs memory inp) {
        inp.rewardDistributor = vm.envOr("REWARD_DISTRIBUTOR", address(0));
        inp.minDelegation = vm.envOr("MIN_DELEGATION", type(uint256).max);
        inp.maxDelegation = vm.envOr("MAX_DELEGATION", type(uint256).max);
        inp.maxValidatorDelegation = vm.envOr("MAX_VALIDATOR_DELEGATION", type(uint256).max);
        inp.unbondingEpochs = uint32(vm.envOr("UNBONDING_EPOCHS", uint256(0)));
        inp.commissionDelayEpochs = uint32(vm.envOr("COMMISSION_DELAY_EPOCHS", uint256(0)));

        inp.updateRewardDist = inp.rewardDistributor != address(0);
        inp.updateConfig = inp.minDelegation != type(uint256).max
            && inp.maxDelegation != type(uint256).max
            && inp.maxValidatorDelegation != type(uint256).max
            && inp.unbondingEpochs != 0
            && inp.commissionDelayEpochs != 0;
    }
}
