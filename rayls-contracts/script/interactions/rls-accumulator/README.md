# RLSAccumulator interactions

All operations live in [`RlsAccumulatorOps.s.sol`](RlsAccumulatorOps.s.sol). Pick the action with `--sig`.

Reserve of RLS used by the `RewardDistributor` to top-up validator rewards when fee-derived income falls short of `targetApyBps`. The distributor pulls RLS via a pre-approved `transferFrom` each epoch.

## Functions

| `--sig` | Purpose | Caller role | Required env vars |
|---|---|---|---|
| `status()` | Balance, wiring, runway estimate | none | — (`APY_RUNWAY_STAKE_RLS` optional) |
| `deposit()` | Deposit RLS into the reserve | any account with RLS | `AMOUNT` |
| `setConfig()` | Update `rewardDistributor` / `rlsToken` wiring | DEFAULT_ADMIN_ROLE | `REWARD_DISTRIBUTOR` and/or `RLS_TOKEN` |
| `refreshApproval()` | Re-grant max allowance to RewardDistributor | DEFAULT_ADMIN_ROLE | — |
| `revokeApproval()` | Kill-switch: stop all top-ups | DEFAULT_ADMIN_ROLE | — |
| `run()` | Default — alias for `status()` | none | — |

## Examples

### Initial bring-up

```bash
# 1. Fund (e.g., 100M RLS for ~10y runway at 50% APY on 20M staked)
AMOUNT=100000000000000000000000000 \
  forge script script/interactions/rls-accumulator/RlsAccumulatorOps.s.sol:RlsAccumulatorOps \
  --sig "deposit()" \
  --rpc-url $RPC_URL --broadcast --private-key $RLS_HOLDER_PK -vvvv

# 2. Verify
APY_RUNWAY_STAKE_RLS=20000000000000000000000000 \
  forge script script/interactions/rls-accumulator/RlsAccumulatorOps.s.sol:RlsAccumulatorOps \
  --sig "status()" \
  --rpc-url $RPC_URL -vvvv
```

### Incident response

```bash
# Pause all top-ups
forge script script/interactions/rls-accumulator/RlsAccumulatorOps.s.sol:RlsAccumulatorOps \
  --sig "revokeApproval()" \
  --rpc-url $RPC_URL --broadcast --private-key $ADMIN_PK -vvvv

# ... investigate / fix ...

# Resume
forge script script/interactions/rls-accumulator/RlsAccumulatorOps.s.sol:RlsAccumulatorOps \
  --sig "refreshApproval()" \
  --rpc-url $RPC_URL --broadcast --private-key $ADMIN_PK -vvvv
```

## Notes

- The accumulator's allowance to the RewardDistributor is set to `type(uint256).max` at deploy and on `refreshApproval`. It can be `revokeApproval`d as an emergency stop.
- Setting `targetApyBps` and pointing the RewardDistributor at this accumulator is done from `script/interactions/reward-distributor/RewardDistributorOps.s.sol --sig "setConfig()"`.
