# Managing a rayls network

Scripts for starting a new network from scratch using the following steps:

0. Start all machines in a docker environment (configurable)
1. Connect to all machines using SSH
2. Check the status of the nodes
3. Stop existing running nodes
4. Delete all data
5. Create `node-info.yaml` files
6. Generate genesis
7. Start validators and observers

The script assumes that its operator has SSH access to all machines with root access.

# Prerequirements

Check out the repo/branch/tag that you want to deploy, because this script uses the same repo as its source.

The number of machines must be equal to the number of nodes, because each node runs on a standalone machine.

The machines must be connected in a private network with internet access.

The PC where the script runs must be able to connect to each node machine via SSH using keys. The account used for SSH must be able to execute `sudo` without asking for a password, for example by being part of `sudoers`. More information can be found <a href="https://www.cyberciti.biz/faq/linux-unix-running-sudo-command-without-a-password/">here</a>.

Docker must be installed.

# Config

## Step 1

Prepare `./config/.env` based on `./config/.env.example`.

It contains the following variables:

1. **DEVCONTAINER_DOCKER_NETWORK_NAME:** If you are using a VS Code DevContainer, put the name of the devcontainer Docker network here; otherwise leave it empty.
2. **USE_CACHE:** `0` or `1`.
   - `0` = rebuild containers
   - `1` = use Docker build cache if available
3. **DO_NOT_USE_DEFAULT_DOCKER_NETWORK_IN_COMMITTEE:** `0` or `1`.
   - `0` = use the full topology as configured
   - `1` = limit Docker-network operations to the configured regions available in the Docker environment
4. **UPGRADE_ONLY:** `0` or `1`.
   - `0` = run the full flow
   - `1` = run upgrade-only behavior
5. **NETWORK_ADMIN_ADDRESS:** Network admin wallet address.
6. **NETWORK_ADMIN_PRIVATE_KEY:** Private key for the network admin account.
7. **RAYLS_NETWORK:** Target Rayls network name, for example `testnet`, `devnet` or `mainnet`.

## Step 2

Prepare `./config/topology.json` based on `./config/topology.json.example`.

`topology.json` has the following structure:

```json
{
  "computers": "Computer[]",
  "validators": "Validator[]",
  "observers": "string[]",
  "regions": "string[]",
  "config": "Config"
}
```

- **computers:** Defines each computer where a node will be deployed.
- **validators:** Defines each validator.
- **observers:** Array of computer IDs.
- **regions:** Array of region names using only lowercase letters and `-`.
- **config:** Network configuration.

### `Computer` object

Each entry in `computers` has the following structure:

```json
{
  "id": "string",
  "dataDirPath": "string",
  "consensusIp": "string",
  "consensusPort": "string",
  "consensusRegion": "string",
  "rpcPort": "string",
  "metricsPort": "string",
  "sshIp": "string",
  "sshPort": "string",
  "sshUser": "string",
  "sshKeyPath": "string",
  "sshPass": "string"
}
```

Field descriptions:

- **id:** Unique identifier of the machine.
- **dataDirPath:** Path to the data directory on the host machine that will be mounted as the Rayls data directory.
- **consensusIp:** IP used for consensus. DNS is not allowed here.
- **consensusPort:** Port used for consensus.
- **consensusRegion:** One of the regions listed in `regions`.
- **rpcPort:** Port where RPC will be exposed.
- **metricsPort:** Optional metrics port. If not set, metrics will not be exposed.
- **sshIp:** SSH service IP.
- **sshPort:** SSH service port, usually `22`.
- **sshUser:** SSH user.
- **sshKeyPath:** Absolute path to the SSH key used for access.
- **sshPass:** Password for the SSH key, if applicable.

### `Validator` object

```json
{
  "computerId": "string",
  "walletAddress": "string",
  "blsPassphrase": "string"
}
```

Field descriptions:

- **computerId:** ID of the computer where this validator node will run.
- **walletAddress:** Address that should receive block rewards.
- **blsPassphrase:** Optional. Passphrase used to encrypt this validator's BLS keystore (`RL_BLS_PASSPHRASE`). If omitted, defaults to `"local"`. Keep per-validator passphrases out of version control — `topology.json` is gitignored.

### `Config` object

```json
{
  "chainId": "string",
  "epochDurationInSecs": "string",
  "devFundedWalletAddress": "string",
  "maxHeaderDelayMs": "string",
  "minHeaderDelayMs": "string",
  "consensusRegistryOwner": "string",
  "networkAdmin": "string"
}
```

Field descriptions:

- **chainId:** Chain identifier for the network.
- **epochDurationInSecs:** Epoch duration in seconds.
- **devFundedWalletAddress:** Faucet wallet address.
- **maxHeaderDelayMs:** Maximum block interval in milliseconds.
- **minHeaderDelayMs:** Minimum block interval in milliseconds.
- **consensusRegistryOwner:** Consensus registry owner address.
- **networkAdmin:** Network admin address used by the topology configuration.

## Step 3 (optional): Prefund accounts at genesis

The script can optionally pre-fund accounts at genesis with a native (USDr) balance and/or an RLS ERC-20 balance. Both are independent — include either, both, or neither.

- Native balances: copy `./config/accounts.example.yaml` to `./config/accounts.yaml` and edit the address/balance entries. If this file is present, the script passes it to `rayls genesis --accounts`.
- RLS balances: copy `./config/rls-accounts.example.yaml` to `./config/rls-accounts.yaml` and edit the entries. If present, the script passes it to `rayls genesis --rls-accounts`.

Both `accounts.yaml` and `rls-accounts.yaml` are gitignored; the `*.example.yaml` files document the format.

## Remarks

- Each **computer** instance can be used by only a single node.

# Usage

Run the deployment using:

```bash
./manage.sh
```
