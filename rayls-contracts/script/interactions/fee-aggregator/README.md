# FeeAggregator interactions

All operations live in [`FeeAggregatorOps.s.sol`](FeeAggregatorOps.s.sol). Pick the action with `--sig "funcName()"`.

The FeeAggregator collects ERC-20 stablecoin fees, swaps them to RLS via Algebra DEX, and routes the RLS to validators (via `RewardDistributor`), an ecosystem treasury, and a burn address (via LayerZero OFT).

## Functions

| `--sig` | Purpose | Caller role | Required env vars |
|---|---|---|---|
| `status()` | Print balances, config, roles, supported stablecoins, stats | none (read-only) | — |
| `setConfig()` | Update any subset of: BPS / USDr / router / pool config | DEFAULT_ADMIN_ROLE | any of `VALIDATOR_BPS+ECOSYSTEM_BPS+BURN_BPS`, `USDR_TOKEN`, `ALGEBRA_ROUTER`, `POOL_STABLECOIN+POOL_ADDRESS+POOL_ZERO_FOR_ONE` |
| `swap()` | Convert accumulated stablecoin to RLS | KEEPER_ROLE | `STABLECOIN`, `AMOUNT`, `MIN_RLS_OUT` (default 0) |
| `distribute()` | Split + send pending RLS to recipients | KEEPER_ROLE | — |
| `pipeline()` | `swap` + `distribute` in one tx | KEEPER_ROLE | `STABLECOIN`, `AMOUNT`, `MIN_RLS_OUT` (default 0) |
| `run()` | Default — alias for `status()` | none | — |

Mock deployment (testnet only): [`../_mocks/DeployFeeAggregatorMocks.s.sol`](../_mocks/DeployFeeAggregatorMocks.s.sol)

## Examples

### Inspect

```bash
forge script script/interactions/fee-aggregator/FeeAggregatorOps.s.sol:FeeAggregatorOps \
  --sig "status()" --rpc-url $RPC_URL -vvvv
```

(Default `run()` also calls `status()` — both work.)

### Update distribution split (50/0/50)

```bash
VALIDATOR_BPS=5000 ECOSYSTEM_BPS=0 BURN_BPS=5000 \
  forge script script/interactions/fee-aggregator/FeeAggregatorOps.s.sol:FeeAggregatorOps \
  --sig "setConfig()" \
  --rpc-url $RPC_URL --broadcast --private-key $ADMIN_PK -vvvv
```

### Wire Algebra router + pool + USDr in one tx

```bash
ALGEBRA_ROUTER=0xRouter \
POOL_STABLECOIN=0x0000000000000000000000000000000000000400 \
POOL_ADDRESS=0xPool POOL_ZERO_FOR_ONE=true \
USDR_TOKEN=0x0000000000000000000000000000000000000400 \
  forge script script/interactions/fee-aggregator/FeeAggregatorOps.s.sol:FeeAggregatorOps \
  --sig "setConfig()" \
  --rpc-url $RPC_URL --broadcast --private-key $ADMIN_PK -vvvv
```

### Keeper: swap + distribute in one shot

```bash
STABLECOIN=0x0000000000000000000000000000000000000400 \
AMOUNT=1000000000000000000000 \
  forge script script/interactions/fee-aggregator/FeeAggregatorOps.s.sol:FeeAggregatorOps \
  --sig "pipeline()" \
  --rpc-url $RPC_URL --broadcast --skip-simulation --private-key $KEEPER_PK -vvvv
```

### Keeper: just distribute (after a previous swap)

```bash
forge script script/interactions/fee-aggregator/FeeAggregatorOps.s.sol:FeeAggregatorOps \
  --sig "distribute()" \
  --rpc-url $RPC_URL --broadcast --skip-simulation --private-key $KEEPER_PK -vvvv
```

## Notes

- **`--skip-simulation`** is required when interacting with the USDr precompile (`0x...0400`), the LayerZero OFT bridge, or any feature missing from forge's local revm.
- Default swap limits: min `1000e6`, max `100_000e6` (6-decimal USD). Out-of-range amounts revert with `BelowMinimumSwap` / `ExceedsMaximumSwap`.
- `setUsdrToken` validates the token is an added stablecoin with a configured pool. `setConfig()` orders calls so a pool added in the same tx satisfies that check.
