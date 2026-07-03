# Local network via Docker Compose

A 4-validator local network packaged as a Docker Compose stack. Bring it up
from the workspace root with the convenience targets in the root `Makefile`:

```sh
make up    # build + start in detached mode
make down  # tear down containers + volumes
```

Both targets shell out to the compose file in this directory:
[`compose.yaml`](compose.yaml). Each `make up` rebuilds from scratch and erases all
data left by the previous run; `make down` removes orphans and named volumes.

The stack spins up four `setup_validator` containers that generate keys and
node info into shared volumes, then a `committee` service that produces and
distributes `genesis.yaml` and `committee.yaml`, then four `validator`
services that run `rayls-network node`.

## RPC ports on the host

| Validator | URL |
|---|---|
| validator 1 | http://127.0.0.1:7545 |
| validator 2 | http://127.0.0.1:7544 |
| validator 3 | http://127.0.0.1:7543 |
| validator 4 | http://127.0.0.1:7542 |

## Tunables (environment variables)

The compose file reads the following environment variables (set them on the
command line in front of `make up` or in a `.env` next to `compose.yaml`):

| Variable | Default | Meaning |
|---|---|---|
| `GASLESS` | unset | When set to `true`, the genesis pass adds `--base-fee 0 --min-base-fee 0`, producing a zero-fee chain (see [`doc/gasless-mode.md`](../../doc/gasless-mode.md)). |
| `GAS_LIMIT` | unset | When set, passed to `rayls-network genesis --gas-limit <value>`. Defaults to the binary's built-in value (currently 500M) when unset. |

```sh
GASLESS=true make up                 # zero-fee network
GAS_LIMIT=300000000 make up          # custom gas limit
```

Only `genesis.yaml` and `committee.yaml` are distributed by the committee
service. There is no `worker_cache.yaml` step — that file does not exist in
the current networking model.
