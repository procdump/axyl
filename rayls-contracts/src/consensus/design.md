Consensus Registry

# ConsensusRegistry Design

The `ConsensusRegistry` contract is a core component of the Rayls Network, designed to manage the validator lifecycle, staking mechanisms, and historical epoch data.

## Consensus Mechanisms

### System Calls

The Rayls Network leverages Bullshark and Narwhal protocols, enabling nodes to build blocks in parallel. Epochs are delineated by timestamps rather than block numbers.

At the epoch boundary, the protocol performs gasless system calls to the ConsensusRegistry to update its state with epoch, validator, and rewards information. System call logic is abstracted into the `SystemCallable` module.

- **Epoch Conclusion (`concludeEpoch()`)**: Finalizes the previous epoch, updates the voting committee and validator set, and stores new epoch information. Validator committees are protocol-managed and stored historically and for future epochs using ring buffers.
- **Performance Tracking (`applyIncentives()`)**: Records block production performance weights (stake x consensusHeaderCount) for each validator. These weights are stored on-chain and consumed by the RewardDistributor to proportionally distribute fee-based rewards. Must be called before slashing and epoch conclusion.
- **Slashing (`applySlashes()`)**: Proportionally slashes validator stake and delegated stake. When a validator's balance is fully depleted, triggers a consensus burn that ejects the validator from all committees and retires them. Slashed funds from DelegationPool are accumulated in the registry and withdrawable by governance.This is not live yet but has a preliminary implementation.

## Staking and Delegation

- **Configurable Stake Amounts**: Stake amounts are configurable to support iterative adjustments in early phases based on node operator feedback and protocol updates.
- **Stake Versions**: Records are kept of validators joining under different versions for accurate stake tracking and weighted reward calculation
- **Delegation**: DPOS is supported via the DelegationPool contract. Validators accept delegated stake from multiple delegators.
- **Delegation Rewards**: Rewards are split proportionally between the validator's own stake and delegated stake by the RewardDistributor. The DelegationPool deducts a configurable commission (basis points) for the validator, then distributes the remainder to delegators via per-share reward accumulators.

## Fee-Based Rewards

- **No Token Issuance**: No new tokens are minted at block production. Rewards are sourced entirely from transaction fees.
- **Fee Flow**: Transaction gas fees are paid in the native token (USDr). The FeeAggregator collects accumulated USDr, swaps it to RLS via the Algebra DEX, and distributes the resulting RLS to configured recipients (validator pool via RewardDistributor, ecosystem treasury, and burn).
- **RewardDistributor**: Receives the validator pool share of RLS from FeeAggregator. Distributes to validators weighted by performance data (stake x consensusHeaderCount) recorded by `applyIncentives()`. Falls back to pure stake-proportional distribution if no performance data exists.
- **Rewards Claiming**: Pull-only claim flow. Validators claim pending rewards from the RewardDistributor and pool commission from DelegationPool. Delegators claim their proportional share from DelegationPool. Both may set custom reward recipients.
- **Balance Tracking**: Validator stake balances use a uint256 ledger in the StakeManager. Reward balances are tracked separately in the RewardDistributor.
