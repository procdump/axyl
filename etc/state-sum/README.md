# state-sum — USDR supply audit

A single Rust binary that runs the end-to-end on-chain USDR supply audit
in one pass and asserts the reconciliation identity used to derive the
supply-correction hardfork constant. An auditor can re-run it at any time
to verify the number.

The binary draws on **three independent sources** of truth. Any mismatch
between them is a real finding.

| Measurement                                                       | Read from                               |
| ----------------------------------------------------------------- | --------------------------------------- |
| State-trie sum (every account's native balance)                   | a reth datadir snapshot (`db/mdbx.dat`) |
| Stored `totalSupply` slot (what `totalSupply()` reports on chain) | same snapshot, the precompile's storage |
| Event replay (every mint/burn ever emitted by the precompile)     | Blockscout REST API                     |

The genesis pre-allocation amount (a fourth input, supplied by the
auditor) closes the reconciliation:

```
state_trie_sum  ==  (mints − burns)  +  genesis_alloc
```

On agreement, the script computes and prints:

```
correction = state_trie_sum − stored_TOTAL_SUPPLY_slot
```

That's the constant baked into the supply-correction hardfork.

## Background

The USDR precompile at `0x0000000000000000000000000000000000000400`
maintains a `totalSupply()` counter in its own storage. Pre-PR #404, EIP-161
state-clear was reaping the precompile account at the end of every
transaction, wiping the counter even though `mint()` continued to add to
recipients' native balances. The counter therefore under-reports the true
USDR supply by (cumulative pre-#404 mints) + (genesis pre-allocation, which
never emitted a Transfer event in the first place).

## Build

```
cd etc/state-sum
cargo build --release
```

The binary lands at `./target/release/state-sum`. The example commands
below use that path directly. If you'd rather invoke as `state-sum`,
either `cargo install --path .` or symlink it onto your `$PATH`.

Standalone sub-workspace — does not affect the main axyl workspace. The
checked-in `Cargo.lock` pins every reth dependency to an exact commit for
bit-reproducible audit runs.

## Run

```
./target/release/state-sum --datadir DATADIR --genesis PATH [--explorer URL]
```

| Arg / Flag                                 | Purpose                                                                                                                                                                                                                                           |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DATADIR` (positional) or `--datadir PATH` | reth datadir containing `mdbx.dat` (default `./db`). The two forms are equivalent.                                                                                                                                                                |
| `--genesis PATH`                           | path to the chain's mainnet genesis YAML (e.g. `genesis.yaml`). The script scans the `alloc:` block, sums every nonzero `balance:`, and prints the per-address breakdown. When given, the script asserts; when omitted, the assertion is skipped. |
| `--explorer URL`                           | Blockscout base (default `$RAYLS_EXPLORER` or `https://explorer.rayls.com`)                                                                                                                                                                       |

### Exit codes

| Code | Meaning                                                             |
| ---- | ------------------------------------------------------------------- |
| `0`  | audit passes (or `--genesis` not supplied; assertion skipped) |
| `2`  | `state_trie_sum ≠ (mints − burns) + genesis_alloc` — investigate    |
| `3`  | stored slot exceeds state-trie sum — investigate                    |

### How the genesis sum is computed

`--genesis` consumes a reth-format genesis YAML. The script scans the
`alloc:` block, sums every nonzero `balance:` entry (supporting both
`"0xHEX"` and decimal-string formats), and prints the per-address
breakdown so the auditor can eyeball each contribution before trusting
the total. There is no protocol intricacy in the parse — anyone with
basic shell tools can independently reproduce the sum.

The genesis YAML itself is **not** committed to this directory; supply
your own path. This keeps the audit script generic across networks and
makes the canonical genesis a discrete artifact the auditor brings
themselves.

## Interactive testing scripts (`usdr-mint.mjs` / `usdr-burn.mjs`)

Two small Node.js scripts that drive USDR mints and burns against a running
chain via the `NativeTokenController` contract. Used to demonstrate the
supply-correction hardfork end-to-end on a local devnet — they're auxiliary
tooling for *interactive* verification, not part of the audit itself (the
audit is the Rust binary above).

```
cd etc/state-sum
npm install                                       # one-time, pulls ethers
node usdr-mint.mjs [USDR_AMOUNT]                  # default 1000
node usdr-burn.mjs [USDR_AMOUNT]                  # default  500
```

Both scripts:
- Hard-code RPC at `http://localhost:7545` (validator 1 of the docker network)
- Hard-code the dev private key from `etc/docker-network/genesis.sh`
- Grant `MINTER_ROLE` to themselves on first run (idempotent)
- Set an explicit `gasLimit: 250_000` on the mint/burn tx to avoid an estimator
  edge case that under-funds the precompile's gas

The burn script also approves NTC as a spender for the burn amount (the
precompile's `burnFrom` requires allowance from the `_from` account even for
the whitelisted minting module).

### Why event replay does not also read receipts from the snapshot

On axyl, receipts are compacted from MDBX into NippyJar `static_files/` for
older block ranges. A naive `tables::Receipts` cursor returns 0 rows on a
typical archive node, which is misleading. The script therefore queries
Blockscout (which has a working receipts index) rather than walking the
snapshot's static files directly. Running against a different chain would
require a different indexer URL via `--explorer` or `RAYLS_EXPLORER`.
