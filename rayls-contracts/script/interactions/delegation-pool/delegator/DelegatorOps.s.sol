// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InteractionScript} from "../../_base/InteractionScript.sol";
import {DelegationPool} from "../../../../src/consensus/DelegationPool.sol";
import {IDelegationPool} from "../../../../src/interfaces/IDelegationPool.sol";

/// @title DelegatorOps
/// @notice Delegator operations on DelegationPool. Pick the action with `--sig`.
///         The broadcasting account IS the delegator.
///
/// Examples:
///   VALIDATOR=0x... AMOUNT=1000000000000000000000 \
///     forge script .../DelegatorOps.s.sol:DelegatorOps --sig "delegate()" \
///     --rpc-url $RPC_URL --broadcast --private-key $DELEGATOR_PK -vvvv
///
///   VALIDATOR=0x... \
///     forge script .../DelegatorOps.s.sol:DelegatorOps --sig "claimRewards()" \
///     --rpc-url $RPC_URL --broadcast --private-key $DELEGATOR_PK -vvvv
contract DelegatorOps is InteractionScript {
    DelegationPool pool;

    function _setUp() internal override {
        pool = DelegationPool(deployments.DelegationPool);
    }

    /// @notice Approve + stake RLS to a validator's pool.
    /// Env vars: VALIDATOR, AMOUNT
    function delegate() public {
        address validator = vm.envAddress("VALIDATOR");
        uint256 amount = vm.envOr("AMOUNT", uint256(0));
        require(amount > 0, "Set AMOUNT env var (1e18 RLS units)");
        require(pool.poolRegistered(validator), "Pool not registered for this validator");

        console2.log("Validator:", validator);
        console2.log("Amount:   ", amount);
        console2.log("Delegator RLS before:", balanceOf(rls, msg.sender));

        vm.startBroadcast();
        IERC20(rls).approve(address(pool), amount);
        pool.delegate(validator, amount);
        vm.stopBroadcast();

        console2.log("");
        console2.log("Delegator RLS after:", balanceOf(rls, msg.sender));
        console2.log("Pool RLS after:     ", balanceOf(rls, address(pool)));
    }

    /// @notice Start unbonding for a portion of staked RLS.
    /// Env vars: VALIDATOR, AMOUNT
    function requestUndelegation() public {
        address validator = vm.envAddress("VALIDATOR");
        uint256 amount = vm.envOr("AMOUNT", uint256(0));
        require(amount > 0, "Set AMOUNT env var");

        console2.log("Validator:", validator);
        console2.log("Amount:   ", amount);

        vm.startBroadcast();
        pool.requestUndelegation(validator, amount);
        vm.stopBroadcast();

        IDelegationPool.DelegatorPosition memory pos = pool.getDelegatorPosition(validator, msg.sender);
        logSection("Undelegation queued");
        console2.log("Amount:          ", pos.undelegateAmount);
        console2.log("Releasable epoch:", uint256(pos.undelegateEpoch));
        console2.log("Remaining staked:", pos.amount);
    }

    /// @notice Withdraw RLS after unbonding period elapsed.
    /// Env vars: VALIDATOR
    function completeUndelegation() public {
        address validator = vm.envAddress("VALIDATOR");
        console2.log("Validator:", validator);

        uint256 balBefore = balanceOf(rls, msg.sender);
        console2.log("Delegator RLS before:", balBefore);

        vm.startBroadcast();
        pool.completeUndelegation(validator);
        vm.stopBroadcast();

        uint256 balAfter = balanceOf(rls, msg.sender);
        console2.log("");
        console2.log("Delegator RLS after:", balAfter);
        console2.log("Withdrawn:          ", balAfter - balBefore);
    }

    /// @notice Claim accrued RLS rewards.
    /// Env vars: VALIDATOR
    function claimRewards() public {
        address validator = vm.envAddress("VALIDATOR");
        address recipient = pool.getRewardRecipient(validator, msg.sender);
        console2.log("Validator:", validator);
        console2.log("Recipient:", recipient);

        (uint256 effectiveAmount, uint256 effectivePending) = pool.getEffectivePosition(validator, msg.sender);
        console2.log("Effective stake:  ", effectiveAmount);
        console2.log("Effective pending:", effectivePending);
        require(effectivePending > 0, "Nothing to claim");

        uint256 balBefore = balanceOf(rls, recipient);
        console2.log("Recipient RLS before:", balBefore);

        vm.startBroadcast();
        pool.claimDelegationRewards(validator);
        vm.stopBroadcast();

        uint256 balAfter = balanceOf(rls, recipient);
        console2.log("");
        console2.log("Recipient RLS after:", balAfter);
        console2.log("Claimed:            ", balAfter - balBefore);
    }

    /// @notice Set custom reward recipient for a (validator, delegator) pair.
    /// Env vars: VALIDATOR, RECIPIENT (0x0 to clear)
    function setRecipient() public {
        address validator = vm.envAddress("VALIDATOR");
        address recipient = vm.envAddress("RECIPIENT");

        console2.log("Validator:    ", validator);
        console2.log("New recipient:", recipient);

        vm.startBroadcast();
        pool.setRewardRecipient(validator, recipient);
        vm.stopBroadcast();

        console2.log("");
        console2.log("Effective recipient for", msg.sender);
        console2.log("on validator", validator, "is now", pool.getRewardRecipient(validator, msg.sender));
    }
}
