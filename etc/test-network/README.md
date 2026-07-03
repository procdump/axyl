# Local 4-validator test network

`local-testnet.sh` generates keys, runs genesis, and starts four validators
locally so a developer can interact with the chain over RPC. Keys and data
directories are created under `local-validators/` next to the script.

## Quick start

```sh
# first time only
cp .env.example .env

# fund a dev address and start the chain
./local-testnet.sh --start --dev-funds 0xYOUR_ADDRESS
```

`--dev-funds` is **required** the first time the network is created — it
funds the address you supply with the dev allocation and is used only at
genesis time. On subsequent runs, omit it (or any other genesis flag) and
just pass `--start` to relaunch the existing local network.

After `--start` the script reports the RPC endpoint each validator is
listening on. Nodes run in the background; kill them with `kill` / `killall`
when you are done.

## Companion scripts

- `start-local-validator.sh` — start a single previously-provisioned
  validator (useful when iterating on one node at a time without re-running
  the whole `--start` flow).
- `start-local-observer.sh` — bring up an observer node against the
  already-running local validators.
- `clear-validators-db.sh`, `clear-datadir.sh` — wipe the on-disk state so
  `./local-testnet.sh --start` can re-create the network from scratch.
- `erc20_precompile_test.sh` — sanity-check the USDr precompile against the
  running chain.

There is no `verify-genesis.sh` in this directory.

For running this local network seeded with real testnet chain state (4 validators on a snapshot), see [`doc/testnet-replay.md`](../../doc/testnet-replay.md).

## Optional prefund files

`local-testnet.sh` reads two optional YAML files from this directory:

- `accounts.yaml` — native/USDr prefunds (`address: balance`)
- `rls-accounts.yaml` — RLS ERC-20 prefunds (same schema)

If a file is present, `local-testnet.sh` passes it to `rayls-network genesis`
via `--accounts` / `--rls-accounts`. Missing files are skipped silently — the
chain boots with just validator stake and no extra prefunds.

Examples live next to them as `accounts.example.yaml` /
`rls-accounts.example.yaml`; copy one and edit.

## Gasless mode

Append `--gasless` to disable transaction fees (zero base fee + zero floor):

```sh
./local-testnet.sh --start --gasless --dev-funds 0xYOUR_ADDRESS
```

See [`doc/gasless-mode.md`](../../doc/gasless-mode.md).
