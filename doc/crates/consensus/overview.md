# Overview of the Axyl system.

## Consensus transaction flow

A transaction arrives at a Rayls node and lands in the execution layer’s transaction pool. The
node’s worker watches that pool for new, pending transactions. When enough transactions are
available (or a timer fires), the worker’s batch builder selects the “best” pending transactions
and packages them into a batch without executing them yet. It records per‑sender nonce ranges and
seals the batch.

The worker broadcasts the sealed batch to peer workers using the consensus network. Peers validate
that the batch is well‑formed, matches its digest, and respects size and gas limits. Once enough
acknowledgements are collected (quorum), the batch is considered accepted by the worker’s quorum
waiter and is ready to be referenced by the primary node.

The primary node receives batch digests from its workers, bundles them into a header proposal, and
broadcasts that header to other primaries. As votes accumulate, the header becomes a certificate
that represents a committed step in the consensus DAG. State sync logic keeps slow peers up to date
by fetching any missing headers and batches.

When a certificate is committed, the execution layer consumes the referenced batches and executes
their transactions to produce blocks. Transactions included in the executed batches are then
removed from the transaction pool. Any transactions that were not sealed into a quorum‑accepted
batch remain in the pool to be retried in a future batch.

## Narwhal & Bullshark in Rayls

Rayls follows the Narwhal + Bullshark split: Narwhal provides data availability and a fast,
authenticated DAG of certificates, while Bullshark defines how that DAG is ordered into a linear
chain of commits. The two pieces show up as complementary roles inside the consensus crates.

In short (human version), Narwhal batches transactions from the local txpool and broadcasts them to the
other validators (primaries). The primaries then form a vote to determine the accepted block to be
produced.

### Narwhal (data availability + DAG)

> Paper: [Narwhal and Tusk: A DAG-based Mempool and Efficient BFT Consensus](https://arxiv.org/abs/2105.11827)

Narwhal focuses on **getting data to all validators** quickly and proving that it was received.
Workers create batches from the execution txpool and gossip them to other workers. Primaries then
propose headers that reference those batches. A header becomes a **certificate** once it collects
enough votes from other primaries. The certificate graph (the DAG) grows round by round and
captures the partial order of data availability.

In Rayls this maps to:

- Worker batch construction, validation, and broadcast (data availability).
- Primary header proposal + vote aggregation (certificate creation).
- The DAG itself, where each certificate references parents from previous rounds.

### Bullshark (ordering + commits)

> Paper: [Bullshark: DAG BFT Protocols Made Practical](https://arxiv.org/abs/2201.05677)

Bullshark takes the Narwhal DAG and **chooses an ordered sequence** of certificates to commit.
It relies on a leader schedule per round and commit rules that ensure safety and liveness. When a
leader certificate gains enough support from subsequent rounds, the algorithm commits it and
sequences a chain of certificates behind it. Those commits drive execution in the EVM layer.

In Rayls this maps to:

- Leader schedule and commit rules in the primary consensus loop.
- Commit selection that converts the DAG into an execution order.
- Execution of committed batches into blocks and removal from the txpool.

## Where is Narwhal implemented in Axyl?

Narwhal is spread across the `crates/consensus/` crates, with responsibilities split as in the paper:

**Workers** — [`crates/consensus/worker/`](../../../crates/consensus/worker/)
Batch creation, validation, and broadcast to peer workers (the data-availability layer). Receives batch digests from the txpool, gossips sealed batches, and forwards digests to the primary.

**Primary** — [`crates/consensus/primary/`](../../../crates/consensus/primary/)

| File | Role |
|------|------|
| [`primary/src/primary.rs`](../../../crates/consensus/primary/src/primary.rs) | Entry point — spawns all primary tasks |
| [`primary/src/proposer/`](../../../crates/consensus/primary/src/proposer/) | Collects enough parents + worker digests → proposes a new header (entry `mod.rs`; helpers in `header_builder.rs`, `recovery.rs`, `round.rs`, `run_loop.rs`) |
| [`primary/src/certifier.rs`](../../../crates/consensus/primary/src/certifier.rs) | Broadcasts headers, collects votes from peers, aggregates into certificates |
| [`primary/src/certificate_fetcher.rs`](../../../crates/consensus/primary/src/certificate_fetcher.rs) | Fetches missing ancestor certificates from other primaries |
| [`primary/src/consensus/state.rs`](../../../crates/consensus/primary/src/consensus/state.rs) | Maintains the in-memory DAG (`ConsensusState`) and reconstructs it from the cert store on restart |
| [`primary/src/consensus/utils.rs`](../../../crates/consensus/primary/src/consensus/utils.rs) | DFS traversal over the DAG to order a committed sub-dag |

**State sync** — [`crates/consensus/state-sync/`](../../../crates/consensus/state-sync/)
Keeps slow or recovering peers up to date by fetching missing headers and batches.

**Shared types** — [`crates/infrastructure/types/src/primary/`](../../../crates/infrastructure/types/src/primary/)
`Certificate`, `Header`, `CommittedSubDag`, and related types used across all of the above.

In short: `worker` = Narwhal's data-availability half; `primary` = Narwhal's DAG-building half + Bullshark ordering on top.

## Where is Bullshark implemented in Axyl?

Bullshark lives entirely inside [`primary/src/consensus/`](../../../crates/consensus/primary/src/consensus/):

| File | Role |
|------|------|
| [`primary/src/consensus/bullshark.rs`](../../../crates/consensus/primary/src/consensus/bullshark.rs) | Core `Bullshark` struct — `process_certificate`, `commit_leader`, `order_leaders`, `linked` |
| [`primary/src/consensus/leader_schedule.rs`](../../../crates/consensus/primary/src/consensus/leader_schedule.rs) | Leader election per round; `LeaderSchedule` and `LeaderSwapTable` for reputation-based rotation |
| [`primary/src/consensus/state.rs`](../../../crates/consensus/primary/src/consensus/state.rs) | `ConsensusState` — the in-memory DAG that Bullshark reads from; also tracks `last_committed` rounds and garbage-collection depth |
| [`primary/src/consensus/utils.rs`](../../../crates/consensus/primary/src/consensus/utils.rs) | `order_dag` — DFS pre-order traversal that flattens a leader's sub-dag into a linear certificate sequence |

The commit path is:
1. `process_certificate` inserts the new certificate into the DAG and checks whether the current round is an even (leader-election) round.
2. `commit_leader` looks up the elected leader via `LeaderSchedule`, checks it has f+1 support from the next round, then calls `order_leaders` to collect all unchained past leaders.
3. For each leader, `utils::order_dag` does a DFS to produce the ordered sequence of certificates that form the committed sub-dag (`CommittedSubDag`).
4. After each commit, `update_leader_schedule` may rotate the leader table based on accumulated reputation scores.
