# RewardDistributor interactions

All operations live in [`RewardDistributorOps.s.sol`](RewardDistributorOps.s.sol). Pick the action with `--sig`.

The RewardDistributor receives RLS from the FeeAggregator and allocates per-validator rewards each epoch using consensus performance weights (or pure stake fallback). When `targetApyBps > 0` and fee throughput is below target, it pulls top-ups from the `RLSAccumulator`. Validators (or their custom recipients) claim accrued RLS via `claim`.

## Functions

| `--sig` | Purpose | Caller role | Required env vars |
|---|---|---|---|
| `status()` | Wiring, balances, APY, per-validator pending | none | — (`VALIDATOR`, `ADMIN` optional) |
| `setConfig()` | Update FA / DP / CR / Accumulator wiring + `targetApyBps` | DEFAULT_ADMIN_ROLE | any of `FEE_AGGREGATOR`, `DELEGATION_POOL`, `CONSENSUS_REGISTRY`, `ACCUMULATOR`, `TARGET_APY_BPS` |
| `claim()` | Withdraw a validator's pending RLS | anyone | `VALIDATOR` |
| `setRecipient()` | Validator sets custom reward recipient | the validator | `RECIPIENT` (0x0 to clear) |
| `run()` | Default — alias for `status()` | none | — |

## Examples

### Set 50% target APY (subsidy on)

```bash
TARGET_APY_BPS=5000 \
  forge script script/interactions/reward-distributor/RewardDistributorOps.s.sol:RewardDistributorOps \
  --sig "setConfig()" \
  --rpc-url $RPC_URL --broadcast --private-key $ADMIN_PK -vvvv
```

### Validator claims rewards

```bash
VALIDATOR=0x... \
  forge script script/interactions/reward-distributor/RewardDistributorOps.s.sol:RewardDistributorOps \
  --sig "claim()" \
  --rpc-url $RPC_URL --broadcast --private-key $VALIDATOR_PK -vvvv
```

### Validator routes rewards to a cold wallet

```bash
RECIPIENT=0xColdWalletAddress \
  forge script script/interactions/reward-distributor/RewardDistributorOps.s.sol:RewardDistributorOps \
  --sig "setRecipient()" \
  --rpc-url $RPC_URL --broadcast --private-key $VALIDATOR_PK -vvvv
```

## Notes

- Per-epoch allocation (`distributeRewards`) is a **system call** — runs automatically each epoch, not via these scripts.
- `ACCUMULATOR` env var uses `0x000000000000000000000000000000000000dEaD` as a "not provided" sentinel because `address(0)` is a valid input meaning "disable top-ups".
- `setRecipient` here is for validator's portion. Delegators set their own recipients on the DelegationPool.
