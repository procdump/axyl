# Gasless (Feeless) Network Mode

Rayls supports running a fully gasless network where transactions cost zero fees. This is configured at genesis time and cannot be changed after the network is created.

## How It Works

EIP-1559's base-fee adjustment is *additive*, not multiplicative: each block the base fee moves by a delta whose magnitude is itself proportional to the parent base fee (roughly `delta = parent_base_fee * gas_used_delta / target_gas / DENOMINATOR`). When the parent base fee is `0`, every delta term scales with that `0` and is therefore also `0`, so the base fee stays at zero indefinitely:

```
next_base_fee = parent_base_fee + delta(parent_base_fee, gas_used, target_gas)
              = 0               + 0
              = 0
```

The configurable `min_base_fee` floor is what holds the computed result at zero on a gasless network — the EIP-1559 calculation is then clamped to `max(next_base_fee, min_base_fee)`, which is `max(0, 0) = 0`. Both the genesis `base_fee` and the `min_base_fee` floor must be set to `0` for the gasless property to hold; setting only one is not sufficient.

With `base_fee = 0` and `priority_fee = 0`, the effective gas price for every transaction is zero. No fees are deducted from the sender — only the transferred value is debited.

## Genesis Parameters

Three parameters control the network's fee and gas model, all set during the genesis ceremony:

| Parameter | CLI Flag | Where Stored | Description |
|-----------|----------|-------------|-------------|
| `base_fee` | `--base-fee` | `genesis.yaml` (`baseFeePerGas`) | Starting base fee for the genesis block |
| `min_base_fee` | `--min-base-fee` | `parameters.yaml` | Floor that the EIP-1559 base fee can never drop below |
| `gas_limit` | `--gas-limit` | `genesis.yaml` + `parameters.yaml` | Block gas limit (default: 500M) |

### Gasless Network

```bash
rayls-network genesis \
  --base-fee 0 \
  --min-base-fee 0 \
  --chain-id 0x1e7 \
  ...
```

### Standard Network (default)

Without these flags, both default to 48 Gwei — the same behavior as before this feature was added.

```bash
rayls-network genesis \
  --chain-id 0x1e7 \
  ...
```

## Local Testnet

The `local-testnet.sh` script supports a `--gasless` flag:

```bash
etc/test-network/local-testnet.sh --start --gasless --dev-funds 0xYOUR_ADDRESS
```

## Docker Compose

Pass `GASLESS=true` as an environment variable:

```bash
GASLESS=true docker compose -f etc/docker-network/compose.yaml up
```

## Configuration Flow

```
Genesis CLI                    Node Startup
───────────                    ────────────
--base-fee 0                   genesis.yaml loaded
  → genesis.yaml                 → baseFeePerGas: 0x0
    (baseFeePerGas: 0x0)
                               parameters.yaml loaded
--min-base-fee 0                 → min_base_fee: 0
  → parameters.yaml               → passed to RaylsChainSpec
    (min_base_fee: 0)                → used as floor in compute_next_base_fee()
```

## Implementation Details

The minimum base fee floor flows through:

1. **`parameters.yaml`** — `min_base_fee` field (serde default: 48 Gwei for backward compatibility)
2. **`Parameters` struct** — `crates/infrastructure/config/src/node.rs`
3. **`RaylsChainSpec`** — `min_base_fee` field replaces the hardcoded `MIN_RAYLS_PROTOCOL_BASE_FEE` constant in `compute_next_base_fee()` and `next_block_base_fee()`
4. **`RethEnv::new()`** — receives `min_base_fee` from parameters and passes it to the chain spec builder

The `MIN_RAYLS_PROTOCOL_BASE_FEE` constant (48 Gwei) remains unchanged and serves as the default value when no `min_base_fee` is specified.

## Transaction Requirements

Transactions on a gasless network can set `gasPrice: 0` or `max_fee_per_gas: 0` and `max_priority_fee_per_gas: 0`. No funds are required to send transactions.

Node operators should start validators with `--txpool.minimal-protocol-fee 0` to ensure the transaction pool accepts zero-fee transactions. Without this flag, reth's default pool validation requires `max_fee_per_gas >= 7 wei` — which still results in zero actual cost (since `base_fee = 0`), but may confuse clients that set `gasPrice: 0`.

## Fee Distribution

With gasless mode:
- **Base fee portion** (sent to `basefee_address`): `0 * gas_used = 0`
- **Priority fee portion** (sent to coinbase): `0 * gas_used = 0` (when `max_priority_fee = 0`)
- The fee aggregator and reward distribution pipeline still function, they just have no revenue to distribute.
