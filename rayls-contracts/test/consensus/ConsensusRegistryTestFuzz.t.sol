// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ConsensusRegistry} from "src/consensus/ConsensusRegistry.sol";
import {IConsensusRegistry} from "src/interfaces/IConsensusRegistry.sol";
import {SystemCallable} from "src/consensus/SystemCallable.sol";
import {StakeManager} from "src/consensus/StakeManager.sol";
import {Slash, RewardInfo, IStakeManager} from "src/interfaces/IStakeManager.sol";
import {ConsensusRegistryTestUtils} from "./ConsensusRegistryTestUtils.sol";

/// @dev Fuzz test module separated into new file with extra setup to avoid `OutOfGas`
contract ConsensusRegistryTestFuzz is ConsensusRegistryTestUtils {
    function setUp() public {
        // target
        consensusRegistry = ConsensusRegistry(0x07E17e17E17e17E17e17E17E17E17e17e17E17e1);

        vm.startStateDiffRecording();

        StakeConfig memory stakeConfig_ = StakeConfig(
            stakeAmount_,
            minWithdrawAmount_,
            epochDuration_
        );
        ConsensusRegistry tempRegistry = new ConsensusRegistry(address(mockRLS), stakeConfig_, initialValidators, initialBLSPops, crOwner);
        Vm.AccountAccess[] memory records = vm.stopAndReturnStateDiff();
        bytes32[] memory slots = saveWrittenSlots(address(tempRegistry), records);
        copyContractState(address(tempRegistry), address(consensusRegistry), slots);

        // set protocol system address
        sysAddress = consensusRegistry.SYSTEM_ADDRESS();

    }

    function testFuzz_concludeEpoch(uint24 numValidators) public {
        numValidators = uint24(bound(uint256(numValidators), 1, 750));

        uint256 numActive = consensusRegistry
            .getValidators(ValidatorStatus.Active)
            .length + numValidators;

        _fuzz_stake(numValidators, stakeAmount_);
        _fuzz_activate(numValidators);

        // identify committee size, conclude an epoch to reach activation epoch, then create a committee
        uint256 committeeSize = _fuzz_computeCommitteeSize(
            numActive,
            numValidators
        );
        // conclude epoch to reach activationEpoch for validators entered in stake & activate loop
        vm.startPrank(sysAddress);
        address[] memory tokenIdCommittee = _createTokenIdCommittee(
            committeeSize
        );
        consensusRegistry.concludeEpoch(tokenIdCommittee);
        address[] memory futureCommittee = _fuzz_createFutureCommittee(
            numActive,
            committeeSize
        );

        // set the subsequent epoch committee by concluding epoch
        EpochInfo memory epochInfo = consensusRegistry.getCurrentEpochInfo();
        uint32 newEpoch = consensusRegistry.getCurrentEpoch() + 1;
        address[] memory newCommittee = consensusRegistry
            .getEpochInfo(newEpoch)
            .committee;
        vm.expectEmit(true, true, true, true);
        emit IConsensusRegistry.NewEpoch(
            IConsensusRegistry.EpochInfo(
                newCommittee,
                uint64(block.number + 1),
                epochInfo.epochDuration,
                epochInfo.stakeVersion
            )
        );
        consensusRegistry.concludeEpoch(futureCommittee);

        // asserts
        uint256 numActiveAfter = consensusRegistry
            .getValidators(ValidatorStatus.Active)
            .length;
        assertEq(numActiveAfter, numActive);
        uint32 returnedEpoch = consensusRegistry.getCurrentEpoch();
        assertEq(returnedEpoch, newEpoch);
        address[] memory currentCommittee = consensusRegistry
            .getEpochInfo(newEpoch)
            .committee;
        for (uint256 i; i < currentCommittee.length; ++i) {
            assertEq(
                currentCommittee[i],
                initialValidators[i].validatorAddress
            );
        }
        address[] memory nextCommittee = consensusRegistry
            .getEpochInfo(newEpoch + 1)
            .committee;
        for (uint256 i; i < nextCommittee.length; ++i) {
            assertEq(nextCommittee[i], tokenIdCommittee[i]);
        }
        address[] memory subsequentCommittee = consensusRegistry
            .getEpochInfo(newEpoch + 2)
            .committee;
        for (uint256 i; i < subsequentCommittee.length; ++i) {
            assertEq(subsequentCommittee[i], futureCommittee[i]);
        }
    }

    function testFuzz_applyIncentives(
        uint24 numValidators,
        uint24 numRewardees
    ) public {
        numValidators = uint24(bound(uint256(numValidators), 1, 800));
        numRewardees = uint24(bound(uint256(numRewardees), 1, numValidators));

        _fuzz_stake(numValidators, stakeAmount_);

        vm.startPrank(sysAddress);
        // apply incentives — now only records performance weights
        (
            RewardInfo[] memory rewardInfos,
            uint256[] memory expectedWeights
        ) = _fuzz_createRewardInfos(numRewardees);
        consensusRegistry.applyIncentives(rewardInfos);
        vm.stopPrank();

        // assert performance weights were recorded correctly
        IConsensusRegistry.PerformanceWeights memory perf = consensusRegistry.getEpochPerformanceWeights();

        // count non-zero weight entries
        uint256 nonZeroCount;
        for (uint256 i; i < expectedWeights.length; ++i) {
            if (expectedWeights[i] > 0) nonZeroCount++;
        }
        assertEq(perf.validators.length, nonZeroCount);

        // verify total weight
        uint256 expectedTotalWeight;
        for (uint256 i; i < expectedWeights.length; ++i) {
            expectedTotalWeight += expectedWeights[i];
        }
        assertEq(perf.totalWeight, expectedTotalWeight);

        // applyIncentives no longer credits balances, so getRewards should be 0
        for (uint256 i; i < rewardInfos.length; ++i) {
            uint256 rewards = consensusRegistry.getRewards(
                rewardInfos[i].validatorAddress
            );
            assertEq(rewards, 0);
        }
    }

    function testFuzz_claimStakeRewards_reverts_noRewards(
        uint24 numValidators,
        uint24 numRewardees
    ) public {
        numValidators = uint24(bound(uint256(numValidators), 1, 800));
        numRewardees = uint24(bound(uint256(numRewardees), 1, numValidators));

        _fuzz_stake(numValidators, stakeAmount_);

        vm.startPrank(sysAddress);
        // apply incentives — only records performance weights, no balance credits
        (
            RewardInfo[] memory rewardInfos,
        ) = _fuzz_createRewardInfos(numRewardees);
        consensusRegistry.applyIncentives(rewardInfos);
        vm.stopPrank();

        // claiming should always revert since applyIncentives no longer credits rewards
        for (uint256 i; i < rewardInfos.length; ++i) {
            address validator = rewardInfos[i].validatorAddress;
            vm.prank(validator);
            vm.expectRevert();
            consensusRegistry.claimStakeRewards(validator);
        }
    }
}
