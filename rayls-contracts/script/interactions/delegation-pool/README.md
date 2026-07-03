# DelegationPool interactions

Multi-delegator staking pool. Operations are split by caller role; each role has one consolidated `*Ops.s.sol` file. Pick the action with `--sig`.

```
delegation-pool/
├── inspect/InspectOps.s.sol      ← read-only diagnostics
├── admin/AdminOps.s.sol          ← DEFAULT_ADMIN_ROLE
├── validator/ValidatorOps.s.sol  ← validator pool ops
└── delegator/DelegatorOps.s.sol  ← delegator stake/unstake/claim
```

## Functions

### `inspect/InspectOps.s.sol`

| `--sig` | Purpose | Optional env vars |
|---|---|---|
| `status()` | Pool config + (optional) per-validator + per-delegator detail | `VALIDATOR`, `DELEGATOR` |
| `rewardDebt()` | Diagnostic dump of rewardDebt accounting | `VALIDATOR`, `DELEGATOR` |
| `run()` | Default — alias for `status()` | — |

### `admin/AdminOps.s.sol` (DEFAULT_ADMIN_ROLE)

| `--sig` | Purpose | Required env vars |
|---|---|---|
| `setConfig()` | Update wiring + delegation config | any of `REWARD_DISTRIBUTOR`, full set `MIN_DELEGATION+MAX_DELEGATION+MAX_VALIDATOR_DELEGATION+UNBONDING_EPOCHS+COMMISSION_DELAY_EPOCHS` |
| `run()` | Default — alias for `setConfig()` | — |

### `validator/ValidatorOps.s.sol` (broadcasts as the validator)

| `--sig` | Purpose | Required env vars |
|---|---|---|
| `register()` | Open the validator's pool | `COMMISSION_BPS` |
| `registerBatch()` | Open pools for many validators in one run | `VALIDATOR_PKS`, `COMMISSION_BPS` (no `--private-key`) |
| `claimCommission()` | Withdraw accrued commission RLS | — |

### `delegator/DelegatorOps.s.sol` (broadcasts as the delegator)

| `--sig` | Purpose | Required env vars |
|---|---|---|
| `delegate()` | Approve + stake RLS | `VALIDATOR`, `AMOUNT` |
| `requestUndelegation()` | Start unbonding | `VALIDATOR`, `AMOUNT` |
| `completeUndelegation()` | Withdraw after unbonding period | `VALIDATOR` |
| `claimRewards()` | Withdraw accrued RLS rewards | `VALIDATOR` |
| `setRecipient()` | Set custom reward recipient | `VALIDATOR`, `RECIPIENT` (0x0 to clear) |

## Common workflows

### Validator opens a pool

```bash
COMMISSION_BPS=500 \
  forge script script/interactions/delegation-pool/validator/ValidatorOps.s.sol:ValidatorOps \
  --sig "register()" \
  --rpc-url $RPC_URL --broadcast --private-key $VALIDATOR_PK -vvvv
```

### Delegator: stake → claim → unstake cycle

```bash
# Stake 1000 RLS
VALIDATOR=0x... AMOUNT=1000000000000000000000 \
  forge script script/interactions/delegation-pool/delegator/DelegatorOps.s.sol:DelegatorOps \
  --sig "delegate()" \
  --rpc-url $RPC_URL --broadcast --private-key $DELEGATOR_PK -vvvv

# ... epochs pass ...

VALIDATOR=0x... \
  forge script script/interactions/delegation-pool/delegator/DelegatorOps.s.sol:DelegatorOps \
  --sig "claimRewards()" \
  --rpc-url $RPC_URL --broadcast --private-key $DELEGATOR_PK -vvvv

VALIDATOR=0x... AMOUNT=1000000000000000000000 \
  forge script script/interactions/delegation-pool/delegator/DelegatorOps.s.sol:DelegatorOps \
  --sig "requestUndelegation()" \
  --rpc-url $RPC_URL --broadcast --private-key $DELEGATOR_PK -vvvv

# After UNBONDING_EPOCHS pass:
VALIDATOR=0x... \
  forge script script/interactions/delegation-pool/delegator/DelegatorOps.s.sol:DelegatorOps \
  --sig "completeUndelegation()" \
  --rpc-url $RPC_URL --broadcast --private-key $DELEGATOR_PK -vvvv
```

### Audit / debug a position

```bash
VALIDATOR=0x... DELEGATOR=0x... \
  forge script script/interactions/delegation-pool/inspect/InspectOps.s.sol:InspectOps \
  --sig "rewardDebt()" \
  --rpc-url $RPC_URL -vvvv
```

## Notes

- Validator must be allowlisted in ConsensusRegistry and have status `Active` or `PendingActivation` before `register()` succeeds.
- `registerBatch()` does NOT take `--private-key` — each validator's PK comes from `VALIDATOR_PKS` (comma-separated).
- The unbonding period is in epochs — duration depends on `consensusRegistry.getCurrentEpochInfo().epochDuration`.
- Per-delegator slashing is proportional. Use `inspect/InspectOps.s.sol --sig "rewardDebt()"` for accounting walk-through.
