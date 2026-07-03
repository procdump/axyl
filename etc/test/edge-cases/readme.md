# Test cases

## 1. Network Partition Scenarios

### Requirements

A blockchain network must have been started using `manage` script using docker backend before executing these tests.

Ensure that all nodes are in "eu" region specified in the topology.json of `manage` script.

Ensure that env variable `DO_NOT_USE_DEFAULT_DOCKER_NETWORK_IN_COMMITTEE` is set to "1" in `manage` script.

### Info

These tests verify that the DAG (Narwhal) continues to propagate and Bullshark continues to order as long as the quorum is maintained.

| Scenario ID | Name | Condition | Expected Result | Script
| :--- | :--- | :--- | :--- | :--- |
| **NET-01** | **Minority Isolation** | Isolate $< 1/3$ of validators (e.g., 2 out of 10) from the rest of the web. | The isolated nodes stop progressing, but the rest of the network continues producing blocks normally. | net-01.sh |
| **NET-02** | **Quorum Breach** | Isolate exactly $1/3$ or more validators. | **Immediate Halt.** No new blocks should be committed. Once the partition is healed, the network must resume from the last state without a fork. | net-02.sh |
| **NET-03** | **"Split Brain" Attempt** | Create two partitions of $50/50$. | The network must halt entirely. Neither side should be able to form a quorum or finalize certificates. | net-03.sh |
| **NET-04** | **Flickering Connectivity** | Rapidly drop/restore 25% of node connections (churn). | High latency in Narwhal's worker-to-worker communication, but Bullshark should eventually order all batches. | net-04.sh |


## 2. Clock Skew Scenarios

### Requirements

A blockchain network with 4 validators must have been started. One of these validators must be on a dedicated machine. You must have SSH access to this dedicated machine and must be able to execute `date` and `datetimectl` without asking for `sudo`.

### Info

Bullshark is generally "partially synchronous," meaning it relies on some timing assumptions to move between rounds, though the DAG structure makes it more robust than older protocols.

### CLK-01: The Future/Past Leader

- **Action:** Shift one validator clock by **30 minutes** forward or backward.
- **Current script behavior:** `clk-01.sh` targets the 4th node from `clk.env` and applies a clock skew there.
- **Success criteria:** Honest nodes should continue progressing, and after the skew is removed the network should converge again.



# Test cases

## Environment files

The scripts read their configuration from two local files placed in the same directory as the `.sh` files:

- `net.env` → used by `net-01.sh`, `net-02.sh`, `net-03.sh`, `net-04.sh`
- `clk.env` → used by `clk-01.sh`

These `.env` files are **not committed to the repository**, so each person running the tests must create them manually before executing the scripts.

### 1) How to create `net.env`

Create a file named `net.env` based on `net.env.example`

#### Meaning of each field

- `NODE_RPCS`: Bash array with the RPC endpoints of all validator nodes.
  - Keep the array in the same order as the validator numbering you want the scripts to use.
  - Every value must be reachable from the machine where the script is executed.
  - `net-01.sh`, `net-02.sh`, `net-03.sh`, and `net-04.sh` use these endpoints to query block height and block hash.
- `NETWORK_NAME`: Docker network name used by the running blockchain deployment.
  - The scripts disconnect and reconnect containers from this Docker network.
- `CONTAINER_PREFIX`: Prefix used to build validator container names.
  - The scripts expect container names in this format:
    - node 1 → `${CONTAINER_PREFIX}001`
    - node 2 → `${CONTAINER_PREFIX}002`
    - node 3 → `${CONTAINER_PREFIX}003`
    - etc.

#### Important notes for `net.env`

- This file is sourced by Bash, so it must use **valid Bash syntax**, not `.properties` or YAML syntax.
- Do **not** put commas inside `NODE_RPCS`.
- Do **not** use spaces around `=`.
- Make sure `NETWORK_NAME` matches the real Docker network exactly.
- Make sure `CONTAINER_PREFIX` matches the real container naming pattern exactly.
- The number of RPCs in `NODE_RPCS` must match the number of validator containers.
- `net-04.sh` requires at least **4 validators**.

### 2) How to create `clk.env`

Create a file named `clk.env` based on `clk.env.example`

#### Meaning of each field

- `NODE_RPCS`: Bash array with exactly **4** validator RPC endpoints.
  - `clk-01.sh` expects exactly 4 values.
  - The script applies the clock skew to the **4th node** (`NODE_RPCS[3]`).
- `SSH_KEY_PATH`: Absolute path to the SSH private key used to access the target host.
- `SSH_PASS`: Password used by `sshpass` during the SSH connection.
- `SSH_USER`: SSH username used to connect to the target host.
- `USE_POSITIVE_CLOCK_SHIFT`:
  - `1` → move the target node clock forward
  - `0` → move the target node clock backward

#### Important notes for `clk.env`

- `clk-01.sh` derives the SSH target host from the **4th RPC URL**, so that RPC must contain the correct host/IP for the machine whose clock will be changed.
- The SSH user must have passwordless `sudo` for at least:
  - `date`
  - `timedatectl`
- The private key file must exist at `SSH_KEY_PATH`.
- Keep this file out of version control because it contains credentials and machine-specific access details.

### 3) Minimal setup steps

Before running any script:

1. Copy or create `net.env` and/or `clk.env` in the same directory as the scripts.
2. Adjust RPC URLs to match your local deployment.
3. Verify Docker network name and container prefix.
4. For clock skew tests, verify SSH access and passwordless `sudo` on the target validator host.
