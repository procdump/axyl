// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InteractionScript} from "../_base/InteractionScript.sol";
import {RLSAccumulator} from "../../../src/fees/RLSAccumulator.sol";

/// @title RlsAccumulatorOps
/// @notice Unified operations for the RLSAccumulator. Pick the action with `--sig`.
///
/// Read:
///   forge script .../RlsAccumulatorOps.s.sol:RlsAccumulatorOps --sig "status()" \
///     --rpc-url $RPC_URL -vvvv
///
/// Anyone with RLS:
///   AMOUNT=... forge script .../RlsAccumulatorOps.s.sol:RlsAccumulatorOps --sig "deposit()" \
///     --rpc-url $RPC_URL --broadcast --private-key $DEPOSITOR_PK -vvvv
///
/// Admin:
///   forge script .../RlsAccumulatorOps.s.sol:RlsAccumulatorOps --sig "refreshApproval()" \
///     --rpc-url $RPC_URL --broadcast --private-key $ADMIN_PK -vvvv
contract RlsAccumulatorOps is InteractionScript {
    RLSAccumulator acc;

    function _setUp() internal override {
        acc = RLSAccumulator(deployments.RLSAccumulator);
    }

    function run() public {
        status();
    }

    // ── READ ────────────────────────────────────────────────────────────

    /// @notice Print balance, wiring, and (optional) runway estimate.
    /// Optional env: APY_RUNWAY_STAKE_RLS — total network stake (1e18) for runway calc.
    /// Optional env: ADMIN — defaults to deployments.admin.
    function status() public {
        address admin = vm.envOr("ADMIN", deployments.admin);

        console2.log("========== RLSAccumulator Status ==========");
        console2.log("Contract:", address(acc));

        logSection("Wiring");
        console2.log("RLS Token:        ", acc.rlsToken());
        console2.log("RewardDistributor:", acc.rewardDistributor());

        logSection("Roles");
        console2.log("Admin:", admin);
        console2.log("  DEFAULT_ADMIN:", acc.hasRole(0x00, admin));
        console2.log("  UPGRADER:     ", acc.hasRole(acc.UPGRADER_ROLE(), admin));

        logSection("Balance");
        uint256 bal = balanceOf(rls, address(acc));
        console2.log("RLS balance:    ", bal);
        console2.log("Allowance to RD:", allowance(rls, address(acc), acc.rewardDistributor()));

        uint256 stake = vm.envOr("APY_RUNWAY_STAKE_RLS", uint256(0));
        if (stake > 0) {
            logSection("Runway Estimate");
            console2.log("Network stake input (RLS):", stake);
            (bool ok, bytes memory ret) =
                acc.rewardDistributor().staticcall(abi.encodeWithSignature("targetApyBps()"));
            if (ok && ret.length >= 32) {
                uint256 apyBps = abi.decode(ret, (uint256));
                console2.log("Target APY BPS:           ", apyBps);
                if (apyBps > 0) {
                    uint256 yearly = (stake * apyBps) / 10_000;
                    console2.log("Worst-case yearly drain:  ", yearly);
                    if (yearly > 0) console2.log("Years of runway (worst):  ", bal / yearly);
                }
            }
        }
    }

    // ── ANYONE ──────────────────────────────────────────────────────────

    /// @notice Approve + deposit RLS into the reserve.
    /// Env vars: AMOUNT
    function deposit() public {
        uint256 amount = vm.envOr("AMOUNT", uint256(0));
        require(amount > 0, "Set AMOUNT env var (1e18 RLS units)");

        console2.log("Accumulator:", address(acc));
        console2.log("Amount:     ", amount);

        uint256 balBefore = balanceOf(rls, address(acc));
        console2.log("Accumulator balance before:", balBefore);

        vm.startBroadcast();
        IERC20(rls).approve(address(acc), amount);
        acc.deposit(amount);
        vm.stopBroadcast();

        uint256 balAfter = balanceOf(rls, address(acc));
        console2.log("");
        console2.log("Accumulator balance after:", balAfter);
        console2.log("Deposited:               ", balAfter - balBefore);
    }

    // ── ADMIN ───────────────────────────────────────────────────────────

    /// @notice Update wiring. Env vars: REWARD_DISTRIBUTOR, RLS_TOKEN (any subset).
    function setConfig() public {
        address newRewardDistributor = vm.envOr("REWARD_DISTRIBUTOR", address(0));
        address newRlsToken = vm.envOr("RLS_TOKEN", address(0));

        bool updateRD = newRewardDistributor != address(0);
        bool updateToken = newRlsToken != address(0);
        require(updateRD || updateToken, "Set REWARD_DISTRIBUTOR or RLS_TOKEN env var");

        logSection("Current");
        console2.log("RewardDistributor:", acc.rewardDistributor());
        console2.log("RLS Token:        ", acc.rlsToken());
        if (updateRD) console2.log("New RewardDistributor:", newRewardDistributor);
        if (updateToken) console2.log("New RLS Token:        ", newRlsToken);

        vm.startBroadcast();
        if (updateRD) acc.setRewardDistributor(newRewardDistributor);
        if (updateToken) acc.setRlsToken(newRlsToken);
        vm.stopBroadcast();

        if (updateRD) require(acc.rewardDistributor() == newRewardDistributor, "rd mismatch");
        if (updateToken) require(acc.rlsToken() == newRlsToken, "rls mismatch");

        console2.log("");
        console2.log("Done.");
    }

    /// @notice Re-grant RewardDistributor's max RLS allowance. Admin only.
    function refreshApproval() public {
        address rd = acc.rewardDistributor();
        console2.log("RewardDistributor:", rd);
        console2.log("Allowance before: ", allowance(rls, address(acc), rd));

        vm.startBroadcast();
        acc.refreshApproval();
        vm.stopBroadcast();

        console2.log("");
        console2.log("Allowance after:", allowance(rls, address(acc), rd));
    }

    /// @notice Revoke RewardDistributor's allowance — kill-switch. Admin only.
    function revokeApproval() public {
        address rd = acc.rewardDistributor();
        console2.log("RewardDistributor:", rd);
        console2.log("Allowance before: ", allowance(rls, address(acc), rd));

        vm.startBroadcast();
        acc.revokeApproval();
        vm.stopBroadcast();

        console2.log("");
        console2.log("Allowance after:", allowance(rls, address(acc), rd));
    }
}
