// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Deployments} from "../../../deployments/Deployments.sol";

/// @title InteractionScript
/// @notice Shared base for all interaction scripts under script/interactions/.
///         Provides the deployments registry and precompile-safe ERC20 helpers.
///
/// Conventions:
///   - Scripts inherit this and override run() (and optionally _setUp()).
///   - Use balanceOf() / allowance() instead of IERC20(...).<call>() — the USDr precompile
///     at 0x0000...0400 is not present in forge's local revm.
///   - Use logSection() to keep output formatting consistent across scripts.
abstract contract InteractionScript is Script {
    Deployments internal deployments;
    address internal rls;

    function setUp() public virtual {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/deployments/deployments.json"));
        deployments = abi.decode(vm.parseJson(json), (Deployments));
        rls = deployments.RLS;
        _setUp();
    }

    /// @dev Override in concrete scripts for additional setup. Default: no-op.
    function _setUp() internal virtual {}

    // ── ERC20 helpers (precompile-safe) ──────────────────────────────────

    /// @dev Returns 0 if the call reverts (e.g. token contract not deployed,
    ///      or precompile not in local simulation revm).
    function balanceOf(address token, address account) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeCall(IERC20.balanceOf, (account)));
        if (ok && ret.length >= 32) return abi.decode(ret, (uint256));
        return 0;
    }

    function allowance(address token, address owner, address spender) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeCall(IERC20.allowance, (owner, spender)));
        if (ok && ret.length >= 32) return abi.decode(ret, (uint256));
        return 0;
    }

    // ── Logging ──────────────────────────────────────────────────────────

    function logSection(string memory title) internal pure {
        console2.log("");
        console2.log(string.concat("--- ", title, " ---"));
    }
}
