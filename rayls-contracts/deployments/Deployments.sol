// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @notice Foundry decodes JSON data to Solidity structs using lexicographical ordering
/// therefore upper-case struct member names must come **BEFORE** lower-case ones!
struct Deployments {
    address ConsensusRegistry;
    address DelegationPool;
    address DelegationPoolImpl;
    address FeeAggregator;
    address FeeAggregatorImpl;
    address NativeTokenController;
    address NativeTokenControllerImpl;
    address RLS;
    address RLSAccumulator;
    address RLSAccumulatorImpl;
    address RLSImpl;
    address RewardDistributor;
    address RewardDistributorImpl;
    address Safe;
    address SafeImpl;
    address SafeProxyFactory;
    address StablecoinImpl;
    address StablecoinManager;
    address StablecoinManagerImpl;
    address StakeManager;
    address admin;
}
