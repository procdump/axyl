// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {InteractionScript} from "../_base/InteractionScript.sol";
import {RLS} from "../../../src/token/RLS.sol";

/// @title RlsOps
/// @notice Read-only diagnostics for the RLS token. Pick the action with `--sig`.
///
/// Usage:
///   forge script .../RlsOps.s.sol:RlsOps --sig "status()" \
///     --rpc-url $RPC_URL -vvvv
///
///   ACCOUNT=0x... \
///     forge script .../RlsOps.s.sol:RlsOps --sig "balanceOfAccount()" \
///     --rpc-url $RPC_URL -vvvv
contract RlsOps is InteractionScript {
    RLS token;

    function _setUp() internal override {
        token = RLS(deployments.RLS);
    }

    function run() public {
        status();
    }

    /// @notice Token metadata, supply, pause state, roles, and genesis-funded balances.
    /// Optional env: ACCOUNT — print balance for an arbitrary address.
    function status() public {
        address admin = vm.envOr("ADMIN", deployments.admin);

        console2.log("========== RLS Token Status ==========");
        console2.log("Contract:", address(token));

        logSection("Metadata");
        console2.log("Name:    ", token.name());
        console2.log("Symbol:  ", token.symbol());
        console2.log("Decimals:", uint256(token.decimals()));
        console2.log("Version: ", token.version());

        logSection("State");
        console2.log("Paused:        ", token.paused());
        console2.log("Bridge paused: ", token.bridgePaused());

        logSection("Supply");
        uint256 supply = token.totalSupply();
        uint256 maxSupply = token.MAX_SUPPLY();
        console2.log("Total supply:", supply);
        console2.log("Max supply:  ", maxSupply);
        console2.log("Headroom:    ", maxSupply - supply);
        if (maxSupply > 0) {
            console2.log("Used (BPS of max):", (supply * 10_000) / maxSupply);
        }

        logSection("Roles");
        console2.log("Admin:", admin);
        console2.log("  DEFAULT_ADMIN:", token.hasRole(0x00, admin));
        console2.log("  PAUSER:       ", token.hasRole(token.PAUSER_ROLE(), admin));
        console2.log("  UPGRADER:     ", token.hasRole(token.UPGRADER_ROLE(), admin));
        console2.log("  MINTER:       ", token.hasRole(token.MINTER_ROLE(), admin));
        console2.log("  BURNER:       ", token.hasRole(token.BURNER_ROLE(), admin));

        logSection("System balances");
        uint256 admBal = token.balanceOf(admin);
        uint256 crBal = token.balanceOf(deployments.ConsensusRegistry);
        uint256 dpBal = token.balanceOf(deployments.DelegationPool);
        uint256 rdBal = token.balanceOf(deployments.RewardDistributor);
        uint256 accBal = token.balanceOf(deployments.RLSAccumulator);
        uint256 faBal = token.balanceOf(deployments.FeeAggregator);
        uint256 ntcBal = token.balanceOf(deployments.NativeTokenController);

        console2.log("admin                ", admin, admBal);
        console2.log("ConsensusRegistry    ", deployments.ConsensusRegistry, crBal);
        console2.log("DelegationPool       ", deployments.DelegationPool, dpBal);
        console2.log("RewardDistributor    ", deployments.RewardDistributor, rdBal);
        console2.log("RLSAccumulator       ", deployments.RLSAccumulator, accBal);
        console2.log("FeeAggregator        ", deployments.FeeAggregator, faBal);
        console2.log("NativeTokenController", deployments.NativeTokenController, ntcBal);

        uint256 sumKnown = admBal + crBal + dpBal + rdBal + accBal + faBal + ntcBal;
        logSection("Distribution");
        console2.log("Sum of known holders:", sumKnown);
        console2.log("Held elsewhere:      ", supply > sumKnown ? supply - sumKnown : 0);

        address account = vm.envOr("ACCOUNT", address(0));
        if (account != address(0)) {
            logSection("Account");
            console2.log("Address:", account);
            console2.log("Balance:", token.balanceOf(account));
            console2.log("Nonce:  ", token.nonces(account));
        }
    }

    /// @notice Print balance + permit nonce for an arbitrary address. Env: ACCOUNT.
    function balanceOfAccount() public view {
        address account = vm.envAddress("ACCOUNT");
        console2.log("RLS:    ", address(token));
        console2.log("Account:", account);
        console2.log("Balance:", token.balanceOf(account));
        console2.log("Nonce:  ", token.nonces(account));
    }
}
