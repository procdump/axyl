// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {InteractionScript} from "../../_base/InteractionScript.sol";
import {DelegationPool} from "../../../../src/consensus/DelegationPool.sol";
import {IDelegationPool} from "../../../../src/interfaces/IDelegationPool.sol";

/// @title InspectOps
/// @notice Read-only diagnostics for DelegationPool. Pick the action with `--sig`.
///
/// Usage:
///   forge script .../InspectOps.s.sol:InspectOps --sig "status()" \
///     --rpc-url $RPC_URL -vvvv
///
///   VALIDATOR=0x... DELEGATOR=0x... \
///     forge script .../InspectOps.s.sol:InspectOps --sig "rewardDebt()" \
///     --rpc-url $RPC_URL -vvvv
contract InspectOps is InteractionScript {
    DelegationPool pool;

    function _setUp() internal override {
        pool = DelegationPool(deployments.DelegationPool);
    }

    function run() public {
        status();
    }

    /// @notice Pool config + (optional) per-validator + per-delegator detail.
    /// Optional env: VALIDATOR, DELEGATOR, ADMIN
    function status() public {
        address admin = vm.envOr("ADMIN", deployments.admin);

        console2.log("========== DelegationPool Status ==========");
        console2.log("Contract:", address(pool));

        logSection("Wiring");
        console2.log("RLS Token:        ", pool.rlsToken());
        console2.log("ConsensusRegistry:", pool.consensusRegistry());
        console2.log("RewardDistributor:", pool.rewardDistributor());

        logSection("Roles");
        console2.log("Admin:", admin);
        console2.log("  DEFAULT_ADMIN:", pool.hasRole(0x00, admin));
        console2.log("  UPGRADER:     ", pool.hasRole(pool.UPGRADER_ROLE(), admin));

        logSection("Whitelist");
        console2.log("Enabled:", pool.whitelistEnabled());
        console2.log("Root:   ", vm.toString(pool.whitelistRoot()));

        logSection("Delegation Config");
        IDelegationPool.DelegationConfig memory cfg = pool.getDelegationConfig();
        console2.log("Min delegation:           ", cfg.minDelegation);
        console2.log("Max delegation per acct:  ", cfg.maxDelegation);
        console2.log("Max validator delegation: ", cfg.maxValidatorDelegation);
        console2.log("Unbonding epochs:         ", uint256(cfg.unbondingEpochs));
        console2.log("Commission delay epochs:  ", uint256(cfg.commissionDelayEpochs));

        logSection("Balances");
        console2.log("Pool RLS:", balanceOf(rls, address(pool)));

        address validator = vm.envOr("VALIDATOR", address(0));
        if (validator == address(0)) return;

        logSection("Validator detail");
        console2.log("Validator: ", validator);
        console2.log("Registered:", pool.poolRegistered(validator));
        if (pool.poolRegistered(validator)) {
            IDelegationPool.ValidatorPool memory vp = pool.getValidatorPool(validator);
            console2.log("  Total delegated:       ", vp.totalDelegated);
            console2.log("  Commission BPS:        ", vp.commissionBps);
            console2.log("  Pending commission:    ", vp.pendingValidatorRewards);
            console2.log("  Accepting delegations: ", vp.acceptingDelegations);
            console2.log("  Commission recipient:  ", pool.getCommissionRecipient(validator));

            IDelegationPool.PendingCommission memory pc = pool.getPendingCommission(validator);
            if (pc.effectiveEpoch != 0) {
                console2.log("  Pending commission new BPS:", pc.newBps);
                console2.log("  Effective at epoch:        ", uint256(pc.effectiveEpoch));
            }
        }

        address delegator = vm.envOr("DELEGATOR", address(0));
        if (delegator == address(0)) return;

        logSection("Delegator detail");
        console2.log("Delegator:", delegator);
        IDelegationPool.DelegatorPosition memory pos = pool.getDelegatorPosition(validator, delegator);
        console2.log("  Amount:           ", pos.amount);
        console2.log("  Pending rewards:  ", pos.pendingRewards);
        console2.log("  Reward recipient: ", pool.getRewardRecipient(validator, delegator));
        console2.log("  Undelegate amount:", pos.undelegateAmount);
        console2.log("  Undelegate epoch: ", uint256(pos.undelegateEpoch));

        (uint256 effAmount, uint256 effPending) = pool.getEffectivePosition(validator, delegator);
        console2.log("  Effective amount: ", effAmount);
        console2.log("  Effective pending:", effPending);
    }

    /// @notice Diagnostic dump of rewardDebt accounting for a (validator, delegator) pair.
    /// Env vars: VALIDATOR, DELEGATOR (defaults to msg.sender)
    function rewardDebt() public {
        address validator = vm.envAddress("VALIDATOR");
        address delegator = vm.envOr("DELEGATOR", msg.sender);

        console2.log("========== RewardDebt Inspection ==========");
        console2.log("DelegationPool:", address(pool));
        console2.log("Validator:     ", validator);
        console2.log("Delegator:     ", delegator);

        if (!pool.poolRegistered(validator)) {
            console2.log("");
            console2.log("ERROR: Validator pool not registered.");
            return;
        }

        logSection("Pool State");
        IDelegationPool.ValidatorPool memory vp = pool.getValidatorPool(validator);
        console2.log("Total Delegated:         ", vp.totalDelegated);
        console2.log("Commission BPS:          ", vp.commissionBps);
        console2.log("RewardPerShareAccum:     ", vp.rewardPerShareAccum);
        console2.log("Pending Validator Rewards:", vp.pendingValidatorRewards);
        console2.log("SlashPerShareAccum:      ", vp.slashPerShareAccum);

        logSection("Delegator Position");
        IDelegationPool.DelegatorPosition memory pos = pool.getDelegatorPosition(validator, delegator);
        console2.log("Amount:           ", pos.amount);
        console2.log("RewardDebt:       ", pos.rewardDebt);
        console2.log("PendingRewards:   ", pos.pendingRewards);
        console2.log("SlashDebt:        ", pos.slashDebt);
        console2.log("LastDelegateEpoch:", uint256(pos.lastDelegateEpoch));

        logSection("Effective (View)");
        (uint256 effectiveAmount, uint256 pendingRewards) = pool.getEffectivePosition(validator, delegator);
        console2.log("Effective Amount:", effectiveAmount);
        console2.log("Pending Rewards: ", pendingRewards);

        logSection("Delegator RLS balance");
        console2.log("RLS:", balanceOf(rls, delegator));
    }
}
