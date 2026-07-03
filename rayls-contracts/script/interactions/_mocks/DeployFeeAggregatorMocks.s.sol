// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InteractionScript} from "../_base/InteractionScript.sol";
import {MockAlgebraPool, MockAlgebraRouter} from "../../../src/mocks/MockAlgebraDex.sol";
import {MockOFTBridge} from "../../../src/mocks/MockOFTBridge.sol";
import {FeeAggregator} from "../../../src/fees/FeeAggregator.sol";

/// @title DeployFeeAggregatorMocks
/// @notice TESTNET ONLY. Deploys MockAlgebraRouter, MockAlgebraPool, MockOFTBridge,
///         then wires them into the FeeAggregator. Optionally funds the router with RLS.
/// @dev Requires DEFAULT_ADMIN_ROLE on FeeAggregator.
/// @dev Refuses to run on the production chain id (487).
///
/// Env vars:
///   - STABLECOIN          (must already be added via FeeAggregator.addStablecoin)
///   - DST_EID             (default 30101 = Ethereum LayerZero EID)
///   - ROUTER_RLS_FUND     (RLS to send from deployer to router; default 0)
///   - NATIVE_FEE          (mock OFT native fee; default 0)
///
/// Usage:
///   STABLECOIN=0x... [DST_EID=30101] [ROUTER_RLS_FUND=...] [NATIVE_FEE=...] \
///     forge script script/interactions/_mocks/DeployFeeAggregatorMocks.s.sol:DeployFeeAggregatorMocks \
///     --rpc-url $RPC_URL --broadcast --private-key $ADMIN_PK -vvvv
contract DeployFeeAggregatorMocks is InteractionScript {
    /// @notice Production chain id — refuse to deploy mocks here.
    uint256 internal constant MAINNET_CHAIN_ID = 487;

    FeeAggregator feeAggregator;

    function _setUp() internal override {
        feeAggregator = FeeAggregator(payable(deployments.FeeAggregator));
    }

    function run() public {
        require(block.chainid != MAINNET_CHAIN_ID, "TESTNET ONLY: refusing to deploy mocks on mainnet");

        address stablecoin = vm.envAddress("STABLECOIN");
        uint32 dstEid = uint32(vm.envOr("DST_EID", uint256(30101)));
        uint256 routerFund = vm.envOr("ROUTER_RLS_FUND", uint256(0));
        uint256 nativeFee = vm.envOr("NATIVE_FEE", uint256(0));

        logSection("Deployment plan");
        console2.log("FeeAggregator:", address(feeAggregator));
        console2.log("RLS Token:    ", rls);
        console2.log("Stablecoin:   ", stablecoin);
        console2.log("DST_EID:      ", uint256(dstEid));
        console2.log("Router fund:  ", routerFund);
        console2.log("Native fee:   ", nativeFee);

        // Pool token0/token1 ordering is address-sorted; zeroForOne = stablecoin is token0
        bool stableIsToken0 = stablecoin < rls;
        (address token0, address token1) = stableIsToken0 ? (stablecoin, rls) : (rls, stablecoin);
        bool zeroForOne = stableIsToken0;

        // sqrtPriceX96 ≈ 1:1 (= 2^96)
        uint160 initialSqrtPrice = 79228162514264337593543950336;

        vm.startBroadcast();

        MockAlgebraRouter router = new MockAlgebraRouter(rls);
        MockAlgebraPool pool = new MockAlgebraPool(token0, token1, initialSqrtPrice);

        // Set 1 RLS per 1 whole stablecoin
        router.setRate(stablecoin, 1e18, _decimals(stablecoin));

        if (routerFund > 0) {
            IERC20(rls).transfer(address(router), routerFund);
        }

        MockOFTBridge oft = new MockOFTBridge(rls, nativeFee);

        feeAggregator.setAlgebraRouter(address(router));
        // V1.9 PoolConfig: use address(0) deployer for the standard pool path.
        feeAggregator.setPoolConfig(stablecoin, address(pool), zeroForOne, address(0));
        feeAggregator.setOftBridge(address(oft));
        feeAggregator.setDstEid(dstEid);

        vm.stopBroadcast();

        require(feeAggregator.algebraRouter() == address(router), "router not set");
        require(feeAggregator.oftBridge() == address(oft), "oft not set");
        require(feeAggregator.dstEid() == dstEid, "dstEid not set");

        logSection("Deployed");
        console2.log("MockAlgebraRouter:", address(router));
        console2.log("MockAlgebraPool:  ", address(pool));
        console2.log("MockOFTBridge:    ", address(oft));

        logSection("Wiring");
        console2.log("FA.algebraRouter:", feeAggregator.algebraRouter());
        console2.log("FA.oftBridge:    ", feeAggregator.oftBridge());
        console2.log("FA.dstEid:       ", uint256(feeAggregator.dstEid()));
        console2.log("Pool zeroForOne: ", zeroForOne);
    }

    function _decimals(address token) internal view returns (uint8) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("decimals()"));
        require(ok && ret.length >= 32, "decimals() failed");
        return uint8(uint256(bytes32(ret)));
    }
}
