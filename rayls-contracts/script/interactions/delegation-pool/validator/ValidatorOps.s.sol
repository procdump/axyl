// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {InteractionScript} from "../../_base/InteractionScript.sol";
import {DelegationPool} from "../../../../src/consensus/DelegationPool.sol";

/// @title ValidatorOps
/// @notice Validator operations on DelegationPool. Pick the action with `--sig`.
///
/// register() and claimCommission() broadcast as the calling validator.
/// registerBatch() takes a comma-separated list of PKs and broadcasts each individually.
///
/// Usage:
///   COMMISSION_BPS=500 \
///     forge script .../ValidatorOps.s.sol:ValidatorOps --sig "register()" \
///     --rpc-url $RPC_URL --broadcast --private-key $VALIDATOR_PK -vvvv
///
///   forge script .../ValidatorOps.s.sol:ValidatorOps --sig "claimCommission()" \
///     --rpc-url $RPC_URL --broadcast --private-key $VALIDATOR_PK -vvvv
///
///   VALIDATOR_PKS="0x...,0x...,..." COMMISSION_BPS=500 \
///     forge script .../ValidatorOps.s.sol:ValidatorOps --sig "registerBatch()" \
///     --rpc-url $RPC_URL --broadcast --skip-simulation -vvvv
contract ValidatorOps is InteractionScript {
    DelegationPool pool;

    function _setUp() internal override {
        pool = DelegationPool(deployments.DelegationPool);
    }

    /// @notice Open the calling validator's pool with the given commission.
    /// Env vars: COMMISSION_BPS (0..2000)
    function register() public {
        uint256 commissionBps = vm.envOr("COMMISSION_BPS", type(uint256).max);
        require(commissionBps <= 2000, "Set COMMISSION_BPS env var (<= 2000)");

        console2.log("DelegationPool:", address(pool));
        console2.log("Commission BPS:", commissionBps);

        vm.startBroadcast();
        pool.registerPool(commissionBps);
        vm.stopBroadcast();

        require(pool.poolRegistered(msg.sender), "registration failed");
        console2.log("");
        console2.log("Pool registered for", msg.sender);
    }

    /// @notice Open pools for a batch of validators (one tx per validator).
    /// Do NOT pass --private-key; each validator's PK comes from VALIDATOR_PKS.
    /// Env vars: VALIDATOR_PKS (comma-separated), COMMISSION_BPS
    function registerBatch() public {
        uint256 commissionBps = vm.envOr("COMMISSION_BPS", type(uint256).max);
        require(commissionBps <= 2000, "Set COMMISSION_BPS env var (<= 2000)");

        string[] memory pkStrings = _split(vm.envString("VALIDATOR_PKS"), ",");
        require(pkStrings.length > 0, "VALIDATOR_PKS empty");

        console2.log("DelegationPool:    ", address(pool));
        console2.log("Commission BPS:    ", commissionBps);
        console2.log("Validators in batch:", pkStrings.length);

        uint256 registered;
        uint256 skipped;
        uint256 failed;

        for (uint256 i; i < pkStrings.length; i++) {
            uint256 pk = vm.parseUint(_trim(pkStrings[i]));
            address validator = vm.addr(pk);

            console2.log("");
            console2.log("[%d] %s", i, validator);

            if (pool.poolRegistered(validator)) {
                console2.log("    SKIP - already registered");
                skipped++;
                continue;
            }

            vm.startBroadcast(pk);
            try pool.registerPool(commissionBps) {
                vm.stopBroadcast();
                if (pool.poolRegistered(validator)) {
                    console2.log("    OK - registered");
                    registered++;
                } else {
                    console2.log("    FAIL - did not persist");
                    failed++;
                }
            } catch (bytes memory err) {
                vm.stopBroadcast();
                console2.log("    FAIL - reverted");
                console2.logBytes(err);
                failed++;
            }
        }

        console2.log("");
        console2.log("Summary:");
        console2.log("  registered:", registered);
        console2.log("  skipped:   ", skipped);
        console2.log("  failed:    ", failed);
    }

    /// @notice Validator withdraws their accrued commission RLS.
    function claimCommission() public {
        address validator = msg.sender;
        require(pool.poolRegistered(validator), "Pool not registered for caller");

        address recipient = pool.getCommissionRecipient(validator);
        console2.log("Validator:", validator);
        console2.log("Recipient:", recipient);

        uint256 balBefore = balanceOf(rls, recipient);
        console2.log("Recipient RLS before:", balBefore);

        vm.startBroadcast();
        pool.claimCommission();
        vm.stopBroadcast();

        uint256 balAfter = balanceOf(rls, recipient);
        console2.log("");
        console2.log("Recipient RLS after:", balAfter);
        console2.log("Claimed:            ", balAfter - balBefore);
    }

    // ── String helpers ──────────────────────────────────────────────

    function _split(string memory s, string memory delim) internal pure returns (string[] memory parts) {
        bytes memory b = bytes(s);
        bytes memory d = bytes(delim);
        require(d.length == 1, "delim must be 1 byte");
        bytes1 dc = d[0];

        uint256 count = 1;
        for (uint256 i; i < b.length; i++) {
            if (b[i] == dc) count++;
        }

        parts = new string[](count);
        uint256 idx;
        uint256 start;
        for (uint256 i; i < b.length; i++) {
            if (b[i] == dc) {
                parts[idx++] = _slice(b, start, i);
                start = i + 1;
            }
        }
        parts[idx] = _slice(b, start, b.length);
    }

    function _slice(bytes memory b, uint256 from, uint256 to) internal pure returns (string memory) {
        bytes memory out = new bytes(to - from);
        for (uint256 i; i < to - from; i++) out[i] = b[from + i];
        return string(out);
    }

    function _trim(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 start;
        uint256 end = b.length;
        while (start < end && (b[start] == 0x20 || b[start] == 0x09)) start++;
        while (end > start && (b[end - 1] == 0x20 || b[end - 1] == 0x09)) end--;
        return _slice(b, start, end);
    }
}
