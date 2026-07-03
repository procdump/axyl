// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {InteractionScript} from "../_base/InteractionScript.sol";
import {IFeeAggregator} from "../../../src/interfaces/IFeeAggregator.sol";
import {FeeAggregator} from "../../../src/fees/FeeAggregator.sol";

/// @title FeeAggregatorOps
/// @notice Unified operations for the FeeAggregator. Pick the action with `--sig`.
///
/// Read (no broadcast):
///   forge script .../FeeAggregatorOps.s.sol:FeeAggregatorOps --sig "status()" \
///     --rpc-url $RPC_URL -vvvv
///
/// Admin (DEFAULT_ADMIN_ROLE):
///   VALIDATOR_BPS=5000 ECOSYSTEM_BPS=0 BURN_BPS=5000 \
///     forge script .../FeeAggregatorOps.s.sol:FeeAggregatorOps --sig "setConfig()" \
///     --rpc-url $RPC_URL --broadcast --private-key $ADMIN_PK -vvvv
///
/// Keeper (KEEPER_ROLE) — pass --skip-simulation when STABLECOIN is the USDr precompile:
///   STABLECOIN=0x... AMOUNT=... MIN_RLS_OUT=0 \
///     forge script .../FeeAggregatorOps.s.sol:FeeAggregatorOps --sig "swap()" \
///     --rpc-url $RPC_URL --broadcast --skip-simulation --private-key $KEEPER_PK -vvvv
///
///   forge script .../FeeAggregatorOps.s.sol:FeeAggregatorOps --sig "distribute()" \
///     --rpc-url $RPC_URL --broadcast --skip-simulation --private-key $KEEPER_PK -vvvv
///
///   STABLECOIN=0x... AMOUNT=... \
///     forge script .../FeeAggregatorOps.s.sol:FeeAggregatorOps --sig "pipeline()" \
///     --rpc-url $RPC_URL --broadcast --skip-simulation --private-key $KEEPER_PK -vvvv
contract FeeAggregatorOps is InteractionScript {
    FeeAggregator fa;
    address admin;

    function _setUp() internal override {
        fa = FeeAggregator(payable(deployments.FeeAggregator));
        admin = deployments.admin;
    }

    /// @notice Default = status().
    function run() public {
        status();
    }

    // ── READ ────────────────────────────────────────────────────────────

    /// @notice Print balances, config, roles, supported stablecoins, stats.
    function status() public {
        console2.log("========== FeeAggregator Status ==========");
        console2.log("Contract:", address(fa));
        console2.log("Version: ", fa.version());
        console2.log("Paused:  ", fa.paused());

        logSection("Balances");
        console2.log("Native:", address(fa).balance);
        console2.log("RLS:   ", balanceOf(rls, address(fa)));

        address[] memory stablecoins = fa.getSupportedStablecoins();
        for (uint256 i; i < stablecoins.length; i++) {
            console2.log("Stablecoin", stablecoins[i], "balance:", balanceOf(stablecoins[i], address(fa)));
        }

        logSection("Roles");
        console2.log("Admin:", admin);
        console2.log("  DEFAULT_ADMIN:", fa.hasRole(0x00, admin));
        console2.log("  KEEPER:       ", fa.hasRole(fa.KEEPER_ROLE(), admin));
        console2.log("  PAUSER:       ", fa.hasRole(fa.PAUSER_ROLE(), admin));
        console2.log("  UPGRADER:     ", fa.hasRole(fa.UPGRADER_ROLE(), admin));

        logSection("Distribution Config");
        IFeeAggregator.DistributionConfig memory cfg = fa.getConfig();
        console2.log("Validator Pool BPS:", cfg.validatorPoolBps);
        console2.log("Ecosystem BPS:     ", cfg.ecosystemBps);
        console2.log("Burn BPS:          ", cfg.burnBps);

        logSection("Tokens");
        console2.log("RLS Token: ", rls);
        console2.log("USDr Token:", fa.usdrToken());

        logSection("Recipients");
        console2.log("Reward Distributor:", fa.rewardDistributor());
        console2.log("Ecosystem Treasury:", fa.ecosystemTreasury());
        console2.log("Burn Address:      ", fa.burnAddress());

        logSection("DEX & Bridge");
        console2.log("Algebra Router: ", fa.algebraRouter());
        console2.log("OFT Bridge:     ", fa.oftBridge());
        console2.log("Destination EID:", uint256(fa.dstEid()));

        logSection("Swap Limits (6-decimal USD)");
        (uint256 minSwap, uint256 maxSwap) = fa.getSwapLimits();
        console2.log("Min:", minSwap);
        console2.log("Max:", maxSwap);

        logSection("Supported Stablecoins");
        console2.log("Count:", stablecoins.length);
        for (uint256 i; i < stablecoins.length; i++) {
            IFeeAggregator.PoolConfig memory poolCfg = fa.getPoolConfig(stablecoins[i]);
            console2.log("  [%d] %s", i, stablecoins[i]);
            console2.log("      Pool:      ", poolCfg.pool);
            console2.log("      zeroForOne:", poolCfg.zeroForOne);
            console2.log("      deployer:  ", poolCfg.deployer);
        }

        logSection("Statistics");
        (uint256 totalSwaps, uint256 totalDistributed) = fa.getStats();
        console2.log("Total Swaps:          ", totalSwaps);
        console2.log("Total RLS Distributed:", totalDistributed);

        logSection("Pending Distribution");
        (uint256 unsplit, uint256 val, uint256 eco, uint256 burn) = fa.getPendingDistribution();
        console2.log("Unsplit RLS:      ", unsplit);
        console2.log("Pending Validator:", val);
        console2.log("Pending Ecosystem:", eco);
        console2.log("Pending Burn:     ", burn);
    }

    // ── ADMIN ───────────────────────────────────────────────────────────

    struct ConfigInputs {
        uint256 validatorBps;
        uint256 ecosystemBps;
        uint256 burnBps;
        address usdrToken;
        address algebraRouter;
        address poolStablecoin;
        address poolAddress;
        bool poolZeroForOne;
        address poolDeployer;
        bool updateBps;
        bool updateUsdr;
        bool updateRouter;
        bool updatePool;
    }

    /// @notice Update any combination of distribution BPS / USDr / router / pool config.
    /// Env vars (any subset):
    ///   VALIDATOR_BPS+ECOSYSTEM_BPS+BURN_BPS, USDR_TOKEN,
    ///   ALGEBRA_ROUTER, POOL_STABLECOIN+POOL_ADDRESS+POOL_ZERO_FOR_ONE+POOL_DEPLOYER
    function setConfig() public {
        ConfigInputs memory inp = _readConfigInputs();
        require(
            inp.updateBps || inp.updateUsdr || inp.updateRouter || inp.updatePool,
            "Set BPS / USDR_TOKEN / ALGEBRA_ROUTER / pool env vars"
        );

        _logConfigCurrent();
        _logConfigPlanned(inp);

        vm.startBroadcast();
        if (inp.updateBps) {
            fa.setConfig(IFeeAggregator.DistributionConfig({
                validatorPoolBps: inp.validatorBps,
                ecosystemBps: inp.ecosystemBps,
                burnBps: inp.burnBps
            }));
        }
        if (inp.updateRouter) fa.setAlgebraRouter(inp.algebraRouter);
        if (inp.updatePool) fa.setPoolConfig(inp.poolStablecoin, inp.poolAddress, inp.poolZeroForOne, inp.poolDeployer);
        // setUsdrToken last — pool config from above must be in place for its validation
        if (inp.updateUsdr) fa.setUsdrToken(inp.usdrToken);
        vm.stopBroadcast();

        _verifyConfig(inp);
        console2.log("");
        console2.log("Done.");
    }

    function _readConfigInputs() internal view returns (ConfigInputs memory inp) {
        inp.validatorBps = vm.envOr("VALIDATOR_BPS", type(uint256).max);
        inp.ecosystemBps = vm.envOr("ECOSYSTEM_BPS", type(uint256).max);
        inp.burnBps = vm.envOr("BURN_BPS", type(uint256).max);
        inp.usdrToken = vm.envOr("USDR_TOKEN", address(0));
        inp.algebraRouter = vm.envOr("ALGEBRA_ROUTER", address(0));
        inp.poolStablecoin = vm.envOr("POOL_STABLECOIN", address(0));
        inp.poolAddress = vm.envOr("POOL_ADDRESS", address(0));
        inp.poolZeroForOne = vm.envOr("POOL_ZERO_FOR_ONE", false);
        inp.poolDeployer = vm.envOr("POOL_DEPLOYER", address(0));

        inp.updateBps = inp.validatorBps != type(uint256).max
            && inp.ecosystemBps != type(uint256).max
            && inp.burnBps != type(uint256).max;
        inp.updateUsdr = inp.usdrToken != address(0);
        inp.updateRouter = inp.algebraRouter != address(0);
        inp.updatePool = inp.poolStablecoin != address(0) && inp.poolAddress != address(0);

        if (inp.updateBps) {
            require(inp.validatorBps + inp.ecosystemBps + inp.burnBps == 10_000, "BPS must sum to 10000");
        }
    }

    function _logConfigCurrent() internal view {
        IFeeAggregator.DistributionConfig memory cur = fa.getConfig();
        logSection("Current");
        console2.log("Validator BPS: ", cur.validatorPoolBps);
        console2.log("Ecosystem BPS: ", cur.ecosystemBps);
        console2.log("Burn BPS:      ", cur.burnBps);
        console2.log("USDr Token:    ", fa.usdrToken());
        console2.log("Algebra Router:", fa.algebraRouter());
    }

    function _logConfigPlanned(ConfigInputs memory inp) internal pure {
        if (inp.updateBps) {
            logSection("New distribution config");
            console2.log("Validator BPS:", inp.validatorBps);
            console2.log("Ecosystem BPS:", inp.ecosystemBps);
            console2.log("Burn BPS:     ", inp.burnBps);
        }
        if (inp.updateUsdr) {
            logSection("New USDr token");
            console2.log("USDr:", inp.usdrToken);
        }
        if (inp.updateRouter) {
            logSection("New Algebra router");
            console2.log("Router:", inp.algebraRouter);
        }
        if (inp.updatePool) {
            logSection("New pool config");
            console2.log("Stablecoin:", inp.poolStablecoin);
            console2.log("Pool:      ", inp.poolAddress);
            console2.log("zeroForOne:", inp.poolZeroForOne);
            console2.log("Deployer:  ", inp.poolDeployer);
        }
    }

    function _verifyConfig(ConfigInputs memory inp) internal view {
        if (inp.updateBps) {
            IFeeAggregator.DistributionConfig memory cur = fa.getConfig();
            require(cur.validatorPoolBps == inp.validatorBps, "validator bps mismatch");
            require(cur.ecosystemBps == inp.ecosystemBps, "ecosystem bps mismatch");
            require(cur.burnBps == inp.burnBps, "burn bps mismatch");
        }
        if (inp.updateUsdr) require(fa.usdrToken() == inp.usdrToken, "usdr mismatch");
        if (inp.updateRouter) require(fa.algebraRouter() == inp.algebraRouter, "router mismatch");
        if (inp.updatePool) {
            IFeeAggregator.PoolConfig memory pc = fa.getPoolConfig(inp.poolStablecoin);
            require(pc.pool == inp.poolAddress, "pool mismatch");
            require(pc.zeroForOne == inp.poolZeroForOne, "zeroForOne mismatch");
            require(pc.deployer == inp.poolDeployer, "deployer mismatch");
        }
    }

    // ── KEEPER ──────────────────────────────────────────────────────────

    /// @notice Swap stablecoin → RLS. Requires KEEPER_ROLE.
    /// Env vars: STABLECOIN, AMOUNT, MIN_RLS_OUT (default 0)
    function swap() public {
        (address stablecoin, uint256 amount, uint256 minRlsOut) = _readSwapInputs();

        logSection("Swap parameters");
        console2.log("Stablecoin: ", stablecoin);
        console2.log("Amount:     ", amount);
        console2.log("Min RLS out:", minRlsOut);
        console2.log("Pre-swap stablecoin balance:", balanceOf(stablecoin, address(fa)));
        console2.log("Pre-swap RLS balance:       ", balanceOf(rls, address(fa)));

        vm.startBroadcast();
        uint256 rlsReceived = fa.swapToRls(IFeeAggregator.SwapParams({
            stablecoin: stablecoin,
            stablecoinAmount: amount,
            minRlsOut: minRlsOut
        }));
        vm.stopBroadcast();

        logSection("Swap executed");
        console2.log("RLS received:           ", rlsReceived);
        console2.log("Stablecoin balance after:", balanceOf(stablecoin, address(fa)));
        console2.log("RLS balance after:      ", balanceOf(rls, address(fa)));
    }

    /// @notice Split + send pending RLS to recipients. Requires KEEPER_ROLE.
    function distribute() public {
        IFeeAggregator.DistributionConfig memory cfg = fa.getConfig();
        logSection("Config");
        console2.log("Validator BPS:", cfg.validatorPoolBps);
        console2.log("Ecosystem BPS:", cfg.ecosystemBps);
        console2.log("Burn BPS:     ", cfg.burnBps);

        (uint256 uB, uint256 vB, uint256 eB, uint256 bB) = fa.getPendingDistribution();
        logSection("Pending before");
        console2.log("Unsplit:  ", uB);
        console2.log("Validator:", vB);
        console2.log("Ecosystem:", eB);
        console2.log("Burn:     ", bB);

        vm.startBroadcast();
        uint256 dist = fa.distributeEpochFees();
        vm.stopBroadcast();

        logSection("Result");
        console2.log("RLS distributed:", dist);

        (uint256 uA, uint256 vA, uint256 eA, uint256 bA) = fa.getPendingDistribution();
        logSection("Pending after");
        console2.log("Unsplit:  ", uA);
        console2.log("Validator:", vA);
        console2.log("Ecosystem:", eA);
        console2.log("Burn:     ", bA);
    }

    /// @notice Swap + distribute in a single broadcast. Requires KEEPER_ROLE.
    /// Env vars: STABLECOIN, AMOUNT, MIN_RLS_OUT (default 0)
    function pipeline() public {
        (address stablecoin, uint256 amount, uint256 minRlsOut) = _readSwapInputs();

        logSection("Pipeline inputs");
        console2.log("Stablecoin: ", stablecoin);
        console2.log("Amount:     ", amount);
        console2.log("Min RLS out:", minRlsOut);

        IFeeAggregator.DistributionConfig memory cfg = fa.getConfig();
        logSection("Config");
        console2.log("Validator BPS:", cfg.validatorPoolBps);
        console2.log("Ecosystem BPS:", cfg.ecosystemBps);
        console2.log("Burn BPS:     ", cfg.burnBps);

        logSection("Before");
        console2.log("FA stablecoin:", balanceOf(stablecoin, address(fa)));
        console2.log("FA RLS:       ", balanceOf(rls, address(fa)));

        vm.startBroadcast();
        uint256 rlsReceived = fa.swapToRls(IFeeAggregator.SwapParams({
            stablecoin: stablecoin,
            stablecoinAmount: amount,
            minRlsOut: minRlsOut
        }));
        uint256 distributed = fa.distributeEpochFees();
        vm.stopBroadcast();

        logSection("Result");
        console2.log("RLS received from swap:", rlsReceived);
        console2.log("RLS distributed:       ", distributed);

        logSection("After");
        console2.log("FA stablecoin:", balanceOf(stablecoin, address(fa)));
        console2.log("FA RLS:       ", balanceOf(rls, address(fa)));
        (uint256 uA, uint256 vA, uint256 eA, uint256 bA) = fa.getPendingDistribution();
        console2.log("Pending unsplit:  ", uA);
        console2.log("Pending validator:", vA);
        console2.log("Pending ecosystem:", eA);
        console2.log("Pending burn:     ", bA);
    }

    function _readSwapInputs() internal view returns (address stablecoin, uint256 amount, uint256 minRlsOut) {
        stablecoin = vm.envAddress("STABLECOIN");
        amount = vm.envOr("AMOUNT", uint256(0));
        minRlsOut = vm.envOr("MIN_RLS_OUT", uint256(0));
        require(amount > 0, "Set AMOUNT env var");
    }
}
