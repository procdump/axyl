# Running a Rayls Observer Node

This directory contains the tooling for an external partner to provision and run an
**observer** node that connects to an existing Rayls network. An observer follows
consensus and serves RPC traffic but does not participate in block production.

## What you need from the network operator

Before you start, the network operator must provide you with:

1. **`genesis.yaml`** — the network genesis file
2. **`committee.yaml`** — the current validator committee descriptor
3. **`parameters.yaml`** — the network parameters

Place `genesis.yaml` and `committee.yaml` in a directory of your choice (referenced
below as `GENESISDIR`), and `parameters.yaml` in `GENESISDIR/..` (one level up). This
matches the layout `create-observer.sh` expects:

```
<some-path>/
├── parameters.yaml
└── genesis/                <-- this is GENESISDIR
    ├── genesis.yaml
    └── committee.yaml
```

### Optional: chain-data backup for faster catch-up

Syncing an observer from genesis can take a long time on a mature network. If the
operator can share a recent **chain-data backup** (the contents of the node's
`db/` / state directory), drop it into your `local-observer/` data directory after
key generation and before starting the node. The observer will resume from the
backup height and only sync the delta, which is typically much faster than a full
sync from genesis.

Ask the operator for the most recent snapshot they have available and the height
it was taken at.

## Prerequisites

- Rust toolchain (matching the workspace `rust-toolchain` / `Cargo.toml`)
- A reachable RPC endpoint of an existing network node (validator or observer)
- Public UDP reachability for the QUIC P2P ports if you want inbound peers
  (defaults: `49001` primary, `49101` worker)

## Configuration

1. Copy `.env.example` to `.env`:

   ```bash
   cp .env.example .env
   ```

2. Fill in the variables in `.env`:

   | Variable | Description |
   |---|---|
   | `ADDRESS` | An Ethereum-style address (e.g. `0x...`) passed to `keytool generate observer`. **Not strictly required for observer operation** — observers don't sign blocks. It only becomes meaningful if you later want to **promote this node to a validator**, in which case the same address+keys can be staked. You can set any valid placeholder address here for now. |
   | `GENESISDIR` | Absolute path to the directory containing `genesis.yaml` and `committee.yaml`. `parameters.yaml` is read from `${GENESISDIR}/..` |
   | `RPC_URL` | RPC URL of an existing network node used during bootstrap. If unset, the script will prompt for it |
   | `RL_EXTERNAL_PRIMARY_ADDR` | (Optional) Externally-reachable libp2p multiaddr for the primary worker, e.g. `/ip4/<public-ip>/udp/49001/quic-v1` |
   | `RL_EXTERNAL_WORKER_ADDRS` | (Optional) Externally-reachable libp2p multiaddr(s) for additional workers, e.g. `/ip4/<public-ip>/udp/49101/quic-v1` |

   Set `RL_EXTERNAL_PRIMARY_ADDR` / `RL_EXTERNAL_WORKER_ADDRS` to your public IP if
   you want other peers to dial you. For an outbound-only / NAT'd observer, you can
   leave them at the `0.0.0.0` defaults from `.env.example`.

   > **About the BLS key:** the script also generates a BLS key under
   > `local-observer/node-keys/`. Observers **do not sign** transactions, blocks,
   > or consensus messages — only validators do that. However, the BLS key **is
   > required** for the observer to authenticate the p2p gossip messages it sends
   > to validators (e.g. forwarding user-submitted transactions into the network).
   > Without a valid BLS key, validators will drop those messages and the node
   > will effectively work only as a read-only indexer rather than a fully
   > functional RPC node. In short: the key is needed to **send** traffic into
   > the network, not to sign it. The same BLS key + `ADDRESS` pair can also be
   > reused later if you decide to promote this node to a validator, so keep
   > both safe.

## Generating keys and starting the node

The `create-observer.sh` script handles both provisioning and startup.

### First run — provision only

```bash
./create-observer.sh
```

This will:

1. Build `rayls-network` in release mode (`cargo build --bin rayls-network --release`)
2. Create `local-observer/` next to the script (the node's `DATADIR`)
3. Run `rayls-network keytool generate observer` to create the observer's BLS and
   networking keys under `local-observer/node-keys/` and write `node-info.yaml`
4. Copy `genesis.yaml`, `committee.yaml` from `${GENESISDIR}` into
   `local-observer/genesis/`, and `parameters.yaml` from `${GENESISDIR}/..` into
   `local-observer/`

If `local-observer/` already exists the script skips this step. To re-provision,
remove the directory first.

### (Optional) Restore from a backup

Before the first start, drop the operator-provided chain-data backup into the
`local-observer/` directory so the node resumes from the snapshot height instead
of syncing from genesis:

```bash
tar -xzf <path-to-backup>.tar.gz -C local-observer/
```

The exact layout depends on how the operator packaged the backup — confirm with
them which subdirectories (e.g. `db/`, consensus state) the archive contains and
where they should land inside `local-observer/`.

### First run — provision and start (local-only)

```bash
./create-observer.sh --start
```

Same as above, then starts the observer in the foreground:

- `--observer` mode (no block production)
- HTTP RPC on `http://localhost:8541` (script-only default — see below)
- Consensus metrics on `127.0.0.1:9310`
- Log format: `log-fmt`, verbosity `-vvv`

> Use `--start` **only** when you intend to run the observer on the same machine
> where you generated the keys. If you plan to run it elsewhere (e.g. inside a
> Docker container on a separate host), **omit `--start`** — see the next section.

### A note on the RPC port (8541 vs 8545)

The standard Rayls / Ethereum JSON-RPC port is **`8545`**. The `8541` you see
above is a hardcoded value the script passes via `--http.port` purely for local
development convenience.

- When you launch via `create-observer.sh --start`, you get **`8541`**.
- When you launch the binary yourself or run it inside Docker, you can pass
  `--http.port 8545` (or expose `8541` as `8545` via `docker run -p 8545:8541`),
  and `8545` is what most tooling will expect.

### Running the observer on a separate host (Docker)

Typical production layout: generate the observer's identity and assemble its
data directory on one machine, then ship it to the host that will actually run
the node inside a Docker image.

1. Run **without** `--start` to provision only:

   ```bash
   ./create-observer.sh
   ```

2. (Optional) extract a chain-data backup into `local-observer/` as described
   above so the remote node doesn't have to sync from genesis.

3. Copy the entire `local-observer/` directory to the target host. It contains
   everything the node needs: `node-keys/`, `node-info.yaml`, `parameters.yaml`,
   and `genesis/{genesis,committee}.yaml`.

4. Launch the Rayls observer Docker image on that host, mounting `local-observer/`
   as the node's `--datadir` and overriding the RPC port (and any other flags) as
   needed via `docker run`. **Detailed Docker deployment instructions are
   provided separately** by the network operator.

### Subsequent starts (running the binary directly)

After provisioning, you can start the observer either by re-running
`./create-observer.sh --start` (which is a no-op for setup and just launches the
node), or by invoking `rayls-network` directly. Mirror the flags that
`create-observer.sh` itself passes — in particular `--full` and `--storage.v2`,
which the script always enables. Omitting them will produce a node configured
differently from the script-launched one:

```bash
RL_BLS_PASSPHRASE="local" \
  ./target/release/rayls-network node \
  --datadir etc/observer/local-observer \
  --observer \
  --full \
  --storage.v2 \
  --metrics 127.0.0.1:9310 \
  --log.stdout.format log-fmt \
  -vvv \
  --http \
  --http.port 8545
```

Run from the workspace root.

## Notes

- `RL_BLS_PASSPHRASE` is hardcoded to `"local"` in the script. For any non-local
  deployment, change this in `create-observer.sh` (or set it externally and remove
  the hardcoded export) and use a strong passphrase.
- The HTTP port (`8541`) and metrics port (`9310`) are hardcoded in the script's
  `--start` path. When running the binary directly or via Docker, override them
  with `--http.port` / `--metrics` (or the Docker port mapping) — `8545` is the
  conventional RPC port.
- Verify the observer is healthy by querying its RPC endpoint, e.g.
  `curl -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    http://localhost:8545`
  (use `8541` if you started via `create-observer.sh --start`) and confirming the
  block number advances toward the network head.
