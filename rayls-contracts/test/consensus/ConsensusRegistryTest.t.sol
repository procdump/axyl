// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LibString} from "solady/utils/LibString.sol";
import {ConsensusRegistry} from "src/consensus/ConsensusRegistry.sol";
import {SystemCallable} from "src/consensus/SystemCallable.sol";
import {StakeManager} from "src/consensus/StakeManager.sol";
import {Slash, IStakeManager} from "src/interfaces/IStakeManager.sol";
import {IConsensusRegistry} from "src/interfaces/IConsensusRegistry.sol";
import {ConsensusRegistryTestUtils} from "./ConsensusRegistryTestUtils.sol";
import {BlsG1} from "../../src/consensus/BlsG1.sol";

contract ConsensusRegistryTest is ConsensusRegistryTestUtils {
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

        mockRLS.mint(validator5, stakeAmount_);
        vm.prank(validator5);
        mockRLS.approve(address(consensusRegistry), stakeAmount_);

        // allowlist validator5 for staking tests
        vm.prank(crOwner);
        consensusRegistry.allowlistValidator(validator5);

    }

    function test_setUp() public view {
        assertEq(consensusRegistry.getCurrentEpoch(), 0);
        ValidatorInfo[] memory active = consensusRegistry.getValidators(
            ValidatorStatus.Active
        );
        for (uint256 i; i < 3; ++i) {
            assertEq(
                active[i].validatorAddress,
                initialValidators[i].validatorAddress
            );
            assertEq(
                consensusRegistry
                    .getValidator(initialValidators[i].validatorAddress)
                    .validatorAddress,
                active[i].validatorAddress
            );
            assertFalse(
                consensusRegistry.isRetired(
                    initialValidators[i].validatorAddress
                )
            );

            EpochInfo memory info = consensusRegistry.getEpochInfo(uint32(i));
            for (uint256 j; j < 4; ++j) {
                assertEq(
                    info.committee[j],
                    initialValidators[j].validatorAddress
                );
                (uint256 balance,,) = consensusRegistry.getBalanceBreakdown(initialValidators[j].validatorAddress);
                assertEq(balance, stakeAmount_);
            }
        }

        ValidatorInfo[] memory committee = consensusRegistry
            .getCommitteeValidators(0);
        for (uint256 i; i < committee.length; ++i) {
            assertEq(
                committee[i].validatorAddress,
                initialValidators[i].validatorAddress
            );
        }
        assertNotEq(consensusRegistry.validatorsAddresses(3), address(0));
        assertEq(consensusRegistry.getCurrentStakeVersion(), 0);
        assertEq(consensusRegistry.stakeConfig(0).stakeAmount, stakeAmount_);
        assertEq(
            consensusRegistry.stakeConfig(0).minWithdrawAmount,
            minWithdrawAmount_
        );
    }

    function test_stake() public {
        vm.prank(crOwner);

        assertEq(
            consensusRegistry.getValidators(ValidatorStatus.Staked).length,
            0
        );

        // validator signs proof of possession message
        bytes memory message = consensusRegistry.proofOfPossessionMessage(
            validator5BlsPubkey,
            validator5
        );
        bytes memory validator5BlsSig = eip2537PointG1ToUncompressed(
            _blsEIP2537SignatureFromSecret(validator5Secret, message)
        );

        // Check event emission
        bytes memory dummyPubkey = _blsDummyPubkeyFromSecret(validator5Secret);
        vm.expectEmit(true, true, true, true);
        emit ValidatorStaked(
            ValidatorInfo(
                dummyPubkey,
                validator5,
                PENDING_EPOCH,
                uint32(0),
                ValidatorStatus.Staked,
                false,
                false,
                uint8(0)
            )
        );
        vm.prank(validator5);
        consensusRegistry.stake(
            dummyPubkey,
            BlsG1.ProofOfPossession(validator5BlsPubkey, validator5BlsSig)
        );

        // Check validator information
        ValidatorInfo[] memory validators = consensusRegistry.getValidators(
            ValidatorStatus.Staked
        );
        assertEq(validators.length, 1);
        assertEq(validators[0].validatorAddress, validator5);
        assertEq(validators[0].blsPubkey, dummyPubkey);
        assertEq(validators[0].activationEpoch, PENDING_EPOCH);
        assertEq(validators[0].exitEpoch, uint32(0));
        assertEq(validators[0].isRetired, false);
        assertEq(validators[0].isDelegated, false);
        assertEq(validators[0].stakeVersion, uint8(0));
        assertEq(
            uint8(validators[0].currentStatus),
            uint8(ValidatorStatus.Staked)
        );
    }

    function test_delegateStake() public {
        vm.prank(crOwner);
        uint256 validator5PrivateKey = 5;
        validator5 = vm.addr(validator5PrivateKey);
        address delegator = _addressFromPrivateKey(42);
        mockRLS.mint(delegator, stakeAmount_);
        vm.prank(delegator);
        mockRLS.approve(address(consensusRegistry), stakeAmount_);

        // validator signs delegation
        bytes memory dummyPubkey = _blsDummyPubkeyFromSecret(validator5Secret);
        bytes32 structHash = consensusRegistry.delegationDigest(
            dummyPubkey,
            validator5,
            delegator
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            validator5PrivateKey,
            structHash
        );
        bytes memory validatorSig = abi.encodePacked(r, s, v);

        // validator signs proof of possession message
        bytes memory message = consensusRegistry.proofOfPossessionMessage(
            validator5BlsPubkey,
            validator5
        );
        bytes memory validator5BlsSig = eip2537PointG1ToUncompressed(
            _blsEIP2537SignatureFromSecret(validator5Secret, message)
        );

        // Check event emission
        bool isDelegate = true;
        vm.expectEmit(true, true, true, true);
        emit ValidatorStaked(
            ValidatorInfo(
                dummyPubkey,
                validator5,
                PENDING_EPOCH,
                uint32(0),
                ValidatorStatus.Staked,
                false,
                isDelegate,
                uint8(0)
            )
        );

        vm.prank(delegator);
        consensusRegistry.delegateStake(
            dummyPubkey,
            BlsG1.ProofOfPossession(validator5BlsPubkey, validator5BlsSig),
            validator5,
            validatorSig
        );

        // Check validator information
        ValidatorInfo[] memory validators = consensusRegistry.getValidators(
            ValidatorStatus.Staked
        );
        assertEq(validators.length, 1);
        assertEq(validators[0].validatorAddress, validator5);
        assertEq(validators[0].blsPubkey, dummyPubkey);
        assertEq(validators[0].activationEpoch, PENDING_EPOCH);
        assertEq(validators[0].exitEpoch, uint32(0));
        assertEq(validators[0].isRetired, false);
        assertEq(validators[0].isDelegated, true);
        assertEq(validators[0].stakeVersion, uint8(0));
        assertEq(
            uint8(validators[0].currentStatus),
            uint8(ValidatorStatus.Staked)
        );
    }

    function test_activate() public {
        vm.prank(crOwner);

        // validator signs proof of possession message
        bytes memory message = consensusRegistry.proofOfPossessionMessage(
            validator5BlsPubkey,
            validator5
        );
        bytes memory validator5BlsSig = eip2537PointG1ToUncompressed(
            _blsEIP2537SignatureFromSecret(validator5Secret, message)
        );
        bytes memory dummyPubkey = _blsDummyPubkeyFromSecret(validator5Secret);

        vm.prank(validator5);
        consensusRegistry.stake(
            dummyPubkey,
            BlsG1.ProofOfPossession(validator5BlsPubkey, validator5BlsSig)
        );

        // activate and conclude epoch to reach validator5 activationEpoch
        uint256 numActiveBefore = consensusRegistry
            .getValidators(ValidatorStatus.Active)
            .length;
        vm.prank(validator5);
        consensusRegistry.activate();

        ValidatorInfo[] memory activeValidators = consensusRegistry
            .getValidators(ValidatorStatus.Active);
        assertEq(activeValidators.length, numActiveBefore + 1);

        uint32 activationEpoch = consensusRegistry.getCurrentEpoch() + 1;
        vm.expectEmit(true, true, true, true);
        emit ValidatorActivated(
            ValidatorInfo(
                dummyPubkey,
                validator5,
                activationEpoch,
                uint32(0),
                ValidatorStatus.Active,
                false,
                false,
                uint8(0)
            )
        );
        vm.startPrank(sysAddress);
        consensusRegistry.concludeEpoch(
            _createTokenIdCommittee(activeValidators.length)
        );
        vm.stopPrank();

        // Check validator information
        assertEq(activeValidators[0].validatorAddress, validator1);
        assertEq(activeValidators[1].validatorAddress, validator2);
        assertEq(activeValidators[2].validatorAddress, validator3);
        assertEq(activeValidators[3].validatorAddress, validator4);
        assertEq(activeValidators[4].validatorAddress, validator5);
        for (uint256 i; i < activeValidators.length - 1; ++i) {
            assertEq(
                uint8(activeValidators[i].currentStatus),
                uint8(ValidatorStatus.Active)
            );
        }
        assertEq(
            uint8(activeValidators[4].currentStatus),
            uint8(ValidatorStatus.PendingActivation)
        );
    }

    function testRevert_stake_invalidPoint() public {
        vm.prank(validator5);
        // providing identity reverts with actual=256, expected=256
        vm.expectRevert(
            abi.encodeWithSelector(BlsG1.InvalidPoint.selector, 256, 256)
        );
        consensusRegistry.stake(
            new bytes(96),
            BlsG1.ProofOfPossession(new bytes(192), new bytes(128))
        );
    }

    // Test that staking reverts when caller has insufficient RLS allowance
    function testRevert_stake_insufficientAllowance() public {
        // validator signs proof of possession message
        bytes memory message = consensusRegistry.proofOfPossessionMessage(
            validator5BlsPubkey,
            validator5
        );
        bytes memory validator5BlsSig = eip2537PointG1ToUncompressed(
            _blsEIP2537SignatureFromSecret(validator5Secret, message)
        );

        bytes memory dummyPubkey = _blsDummyPubkeyFromSecret(validator5Secret);
        // revoke any existing approval
        vm.startPrank(validator5);
        mockRLS.approve(address(consensusRegistry), 0);
        vm.expectRevert();
        consensusRegistry.stake(
            dummyPubkey,
            BlsG1.ProofOfPossession(validator5BlsPubkey, validator5BlsSig)
        );
        vm.stopPrank();
    }

    function test_beginExit() public {
        vm.prank(crOwner);

        // validator signs proof of possession message
        bytes memory message = consensusRegistry.proofOfPossessionMessage(
            validator5BlsPubkey,
            validator5
        );
        bytes memory validator5BlsSig = eip2537PointG1ToUncompressed(
            _blsEIP2537SignatureFromSecret(validator5Secret, message)
        );
        bytes memory dummyPubkey = _blsDummyPubkeyFromSecret(validator5Secret);
        vm.prank(validator5);
        consensusRegistry.stake(
            dummyPubkey,
            BlsG1.ProofOfPossession(validator5BlsPubkey, validator5BlsSig)
        );

        // activate and conclude epoch to reach validator5 activationEpoch
        vm.prank(validator5);
        consensusRegistry.activate();

        uint32 activationEpoch = consensusRegistry.getCurrentEpoch() + 1;
        uint256 numActiveBefore = consensusRegistry
            .getValidators(ValidatorStatus.Active)
            .length;

        vm.prank(sysAddress);
        consensusRegistry.concludeEpoch(
            _createTokenIdCommittee(numActiveBefore)
        );

        assertEq(
            consensusRegistry.getValidators(ValidatorStatus.PendingExit).length,
            0
        );

        // Check event emission
        vm.expectEmit(true, true, true, true);
        emit ValidatorPendingExit(
            ValidatorInfo(
                dummyPubkey,
                validator5,
                activationEpoch,
                PENDING_EPOCH,
                ValidatorStatus.PendingExit,
                false,
                false,
                uint8(0)
            )
        );
        // begin exit
        vm.prank(validator5);
        consensusRegistry.beginExit();

        // Check validator information is pending exit
        ValidatorInfo[] memory pendingExitValidators = consensusRegistry
            .getValidators(ValidatorStatus.PendingExit);
        assertEq(pendingExitValidators.length, 1);
        assertEq(pendingExitValidators[0].validatorAddress, validator5);
        assertEq(
            uint8(pendingExitValidators[0].currentStatus),
            uint8(ValidatorStatus.PendingExit)
        );

        // Finalize epoch twice to reach exit epoch
        vm.startPrank(sysAddress);
        consensusRegistry.concludeEpoch(_createTokenIdCommittee(4));
        consensusRegistry.concludeEpoch(_createTokenIdCommittee(4));
        vm.stopPrank();

        assertEq(
            consensusRegistry.getValidators(ValidatorStatus.PendingExit).length,
            0
        );
        assertEq(
            consensusRegistry.getValidators(ValidatorStatus.Active).length,
            4
        );

        // Check validator information is exited
        ValidatorInfo[] memory exitValidators = consensusRegistry.getValidators(
            ValidatorStatus.Exited
        );
        assertEq(exitValidators.length, 1);
        assertEq(exitValidators[0].validatorAddress, validator5);
        assertEq(
            uint8(exitValidators[0].currentStatus),
            uint8(ValidatorStatus.Exited)
        );
    }

    // Test for exit by a non-validator
    function testRevert_beginExit_nonValidator() public {
        address nonValidator = address(0x3);

        vm.prank(nonValidator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidatorNotFound.selector,
                nonValidator
            )
        );
        consensusRegistry.beginExit();
    }

    // Test for exit by a validator who is not active
    function testRevert_beginExit_notActive() public {
        vm.prank(crOwner);

        // validator signs proof of possession message
        bytes memory message = consensusRegistry.proofOfPossessionMessage(
            validator5BlsPubkey,
            validator5
        );
        bytes memory validator5BlsSig = eip2537PointG1ToUncompressed(
            _blsEIP2537SignatureFromSecret(validator5Secret, message)
        );
        bytes memory dummyPubkey = _blsDummyPubkeyFromSecret(validator5Secret);

        vm.startPrank(validator5);
        consensusRegistry.stake(
            dummyPubkey,
            BlsG1.ProofOfPossession(validator5BlsPubkey, validator5BlsSig)
        );

        // Attempt to exit without being active
        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidStatus.selector,
                ValidatorStatus.Staked
            )
        );
        consensusRegistry.beginExit();
        vm.stopPrank();
    }

    function test_unstake_exited() public {
        uint256 numActive = consensusRegistry
            .getValidators(ValidatorStatus.Active)
            .length;

        mockRLS.mint(address(consensusRegistry), stakeAmount_ * numActive);

        // validator becomes `PendingExit` status which is still committee eligible
        vm.prank(validator1);
        consensusRegistry.beginExit();
        assertEq(
            numActive,
            consensusRegistry.getValidators(ValidatorStatus.Active).length
        );

        // validators pending exit are only exited after elapsing 3 epochs without committee service
        vm.startPrank(sysAddress);
        address[] memory makeValidator1Wait = _createTokenIdCommittee(
            numActive
        );
        makeValidator1Wait[makeValidator1Wait.length - 1] = validator1;
        consensusRegistry.concludeEpoch(makeValidator1Wait);

        // conclude epoch twice with placeholder committee to simulate protocol-determined exit
        address[] memory tokenIdCommittee = _createTokenIdCommittee(numActive);
        consensusRegistry.concludeEpoch(tokenIdCommittee);
        consensusRegistry.concludeEpoch(tokenIdCommittee);

        // exit occurs on third epoch without validator5 in committee
        uint32 expectedExitEpoch = uint32(
            consensusRegistry.getCurrentEpoch() + 1
        );
        vm.expectEmit(true, true, true, true);
        emit ValidatorExited(
            ValidatorInfo(
                _blsDummyPubkeyFromSecret(1), // recreate validator1 blsPubkey
                validator1,
                uint32(0),
                expectedExitEpoch,
                ValidatorStatus.Exited,
                false,
                false,
                uint8(0)
            )
        );
        uint256 activeAfterExit = numActive - 1;
        address[] memory afterExitCommittee = _createTokenIdCommittee(activeAfterExit);
        consensusRegistry.concludeEpoch(afterExitCommittee);

        uint256 initialBalance = mockRLS.balanceOf(validator1);
        assertEq(initialBalance, 0);

        // conclude one additional epoch to reach unstake eligibility epoch
        consensusRegistry.concludeEpoch(afterExitCommittee);
        vm.stopPrank();

        vm.expectEmit(true, true, true, true);
        emit RewardsClaimed(validator1, stakeAmount_);
        vm.prank(validator1);
        consensusRegistry.unstake(validator1);

        // validator1 earned 4 epochs' rewards, split between 4 validators
        uint256 finalBalance = mockRLS.balanceOf(validator1);
        assertEq(finalBalance, stakeAmount_);
    }

    function test_unstake_staked() public {
        vm.prank(crOwner);

        // validator signs proof of possession message
        bytes memory message = consensusRegistry.proofOfPossessionMessage(
            validator5BlsPubkey,
            validator5
        );
        bytes memory validator5BlsSig = eip2537PointG1ToUncompressed(
            _blsEIP2537SignatureFromSecret(validator5Secret, message)
        );

        // stake stake but never activate
        vm.startPrank(validator5);
        consensusRegistry.stake(
            _blsDummyPubkeyFromSecret(validator5Secret),
            BlsG1.ProofOfPossession(validator5BlsPubkey, validator5BlsSig)
        );

        uint256 initialBalance = mockRLS.balanceOf(validator5);
        assertEq(initialBalance, 0);

        // unstake to abort activation
        vm.expectEmit(true, true, true, true);
        emit RewardsClaimed(validator5, stakeAmount_);
        consensusRegistry.unstake(validator5);

        vm.stopPrank();

        // validator5 should have reclaimed their stake
        uint256 finalBalance = mockRLS.balanceOf(validator5);
        assertEq(finalBalance, stakeAmount_);
    }

    // Test for unstake by a non-validator
    function testRevert_unstake_nonValidator() public {
        address nonValidator = address(0x3);

        vm.prank(nonValidator);
        vm.expectRevert();
        consensusRegistry.unstake(nonValidator);
    }

    // Test for unstake by a validator who has not exited
    function testRevert_unstake_notStakedOrExited() public {
        vm.prank(crOwner);

        // validator signs proof of possession message
        bytes memory message = consensusRegistry.proofOfPossessionMessage(
            validator5BlsPubkey,
            validator5
        );
        bytes memory validator5BlsSig = eip2537PointG1ToUncompressed(
            _blsEIP2537SignatureFromSecret(validator5Secret, message)
        );

        // stake and activate
        vm.startPrank(validator5);
        consensusRegistry.stake(
            _blsDummyPubkeyFromSecret(validator5Secret),
            BlsG1.ProofOfPossession(validator5BlsPubkey, validator5BlsSig)
        );
        consensusRegistry.activate();

        bytes memory dummyPubkey = _blsDummyPubkeyFromSecret(validator5Secret);
        // Attempt to unstake without exiting
        bytes memory err = abi.encodeWithSelector(
            IneligibleUnstake.selector,
            ValidatorInfo(dummyPubkey, validator5, 1, 0, ValidatorStatus.PendingActivation, false, false, 0)
        );
        vm.expectRevert(err);
        consensusRegistry.unstake(validator5);

        vm.stopPrank();
    }

    /// @dev Verifies that unstake() on a PendingExit validator reverts with IneligibleUnstake
    /// rather than a raw Panic(0x11) from exitEpoch overflow (exitEpoch == type(uint32).max).
    function testRevert_unstake_pendingExitReturnsIneligible() public {
        // validator1 begins exit — sets exitEpoch to PENDING_EPOCH (type(uint32).max)
        vm.prank(validator1);
        consensusRegistry.beginExit();

        ValidatorInfo memory v1 = consensusRegistry.getValidator(validator1);
        assertEq(uint8(v1.currentStatus), uint8(ValidatorStatus.PendingExit));
        assertEq(v1.exitEpoch, PENDING_EPOCH);

        // unstake while PendingExit must revert with IneligibleUnstake, not Panic(0x11)
        vm.prank(validator1);
        vm.expectRevert(
            abi.encodeWithSelector(IneligibleUnstake.selector, v1)
        );
        consensusRegistry.unstake(validator1);
    }

    // Test for claim by a non-validator
    function testRevert_claimStakeRewards_nonValidator() public {
        address nonValidator = address(0x3);

        vm.prank(nonValidator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidatorNotFound.selector,
                nonValidator
            )
        );
        consensusRegistry.claimStakeRewards(nonValidator);
    }

    // Test for claim by a validator with insufficient rewards
    function testRevert_claimStakeRewards_insufficientRewards() public {
        // Attempt to claim rewards without applying incentives
        vm.prank(validator1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStakeManager.InsufficientRewards.selector,
                0
            )
        );
        consensusRegistry.claimStakeRewards(validator1);
    }

    function test_concludeEpoch_updatesEpochInfo() public {
        // Initialize test data
        address[] memory newCommittee = new address[](4);
        newCommittee[0] = address(0x69);
        newCommittee[1] = address(0x70);
        newCommittee[2] = address(0x71);
        newCommittee[3] = address(0x72);

        uint32 initialEpoch = consensusRegistry.getCurrentEpoch();
        assertEq(initialEpoch, 0);

        // Call the function
        vm.startPrank(sysAddress);
        consensusRegistry.concludeEpoch(newCommittee);
        consensusRegistry.concludeEpoch(newCommittee);
        vm.stopPrank();

        // Fetch current epoch and verify it has incremented
        uint32 currentEpoch = consensusRegistry.getCurrentEpoch();
        assertEq(currentEpoch, initialEpoch + 2);

        // Verify future epoch information
        EpochInfo memory epochInfo = consensusRegistry.getEpochInfo(
            currentEpoch + 2
        );
        assertEq(epochInfo.blockHeight, 0);
        for (uint256 i; i < epochInfo.committee.length; ++i) {
            assertEq(epochInfo.committee[i], newCommittee[i]);
        }
    }

    // Attempt to call without sysAddress should revert
    function testRevert_concludeEpoch_OnlySystemCall() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                SystemCallable.OnlySystemCall.selector,
                address(this)
            )
        );
        consensusRegistry.concludeEpoch(_createTokenIdCommittee(4));
    }

    // =========================================================================
    //                          Allowlist
    // =========================================================================

    function test_genesisValidatorsAllowlisted() public view {
        assertTrue(consensusRegistry.isAllowlisted(validator1));
        assertTrue(consensusRegistry.isAllowlisted(validator2));
        assertTrue(consensusRegistry.isAllowlisted(validator3));
        assertTrue(consensusRegistry.isAllowlisted(validator4));
    }

    function test_nonGenesisNotAllowlisted() public view {
        address unknown = address(0xDEAD);
        assertFalse(consensusRegistry.isAllowlisted(unknown));
    }

    function testRevert_stake_notAllowlisted() public {
        // delist validator5 (which was allowlisted in setUp)
        vm.prank(crOwner);
        consensusRegistry.delistValidator(validator5);

        bytes memory message = proofOfPossessionMessage(
            validator5BlsPubkey,
            validator5
        );
        bytes memory validator5BlsSig = eip2537PointG1ToUncompressed(
            _blsEIP2537SignatureFromSecret(validator5Secret, message)
        );
        bytes memory dummyPubkey = _blsDummyPubkeyFromSecret(validator5Secret);

        vm.prank(validator5);
        vm.expectRevert(
            abi.encodeWithSelector(
                IConsensusRegistry.NotAllowlisted.selector,
                validator5
            )
        );
        consensusRegistry.stake(
            dummyPubkey,
            BlsG1.ProofOfPossession(validator5BlsPubkey, validator5BlsSig)
        );
    }

    function test_stake_afterAllowlist() public {
        // validator5 is already allowlisted in setUp
        bytes memory message = proofOfPossessionMessage(
            validator5BlsPubkey,
            validator5
        );
        bytes memory validator5BlsSig = eip2537PointG1ToUncompressed(
            _blsEIP2537SignatureFromSecret(validator5Secret, message)
        );
        bytes memory dummyPubkey = _blsDummyPubkeyFromSecret(validator5Secret);

        vm.prank(validator5);
        consensusRegistry.stake(
            dummyPubkey,
            BlsG1.ProofOfPossession(validator5BlsPubkey, validator5BlsSig)
        );

        ValidatorInfo[] memory staked = consensusRegistry.getValidators(
            ValidatorStatus.Staked
        );
        assertEq(staked.length, 1);
        assertEq(staked[0].validatorAddress, validator5);
    }

    function testRevert_delegateStake_notAllowlisted() public {
        // delist validator5
        vm.prank(crOwner);
        consensusRegistry.delistValidator(validator5);

        address delegator = _addressFromPrivateKey(42);
        mockRLS.mint(delegator, stakeAmount_);
        vm.prank(delegator);
        mockRLS.approve(address(consensusRegistry), stakeAmount_);

        bytes memory dummyPubkey = _blsDummyPubkeyFromSecret(validator5Secret);
        bytes32 structHash = consensusRegistry.delegationDigest(
            dummyPubkey,
            validator5,
            delegator
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validator5Secret, structHash);
        bytes memory validatorSig = abi.encodePacked(r, s, v);

        bytes memory pubkey = eip2537PointG2ToUncompressed(
            _blsEIP2537PubkeyFromSecret(validator5Secret)
        );
        bytes memory message = proofOfPossessionMessage(
            pubkey,
            validator5
        );
        bytes memory blsSig = eip2537PointG1ToUncompressed(
            _blsEIP2537SignatureFromSecret(validator5Secret, message)
        );

        vm.prank(delegator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IConsensusRegistry.NotAllowlisted.selector,
                validator5
            )
        );
        consensusRegistry.delegateStake(
            dummyPubkey,
            BlsG1.ProofOfPossession(pubkey, blsSig),
            validator5,
            validatorSig
        );
    }

    function test_delegateStake_ownerBypassesSignature() public {
        uint256 valSecret = 99;
        address valAddr = _addressFromPrivateKey(valSecret);
        mockRLS.mint(crOwner, stakeAmount_);

        bytes memory pubkey = eip2537PointG2ToUncompressed(
            _blsEIP2537PubkeyFromSecret(valSecret)
        );
        bytes memory message = proofOfPossessionMessage(
            pubkey,
            valAddr
        );
        bytes memory blsSig = eip2537PointG1ToUncompressed(
            _blsEIP2537SignatureFromSecret(valSecret, message)
        );

        // allowlist is always required, even for owner
        vm.prank(crOwner);
        consensusRegistry.allowlistValidator(valAddr);

        // owner delegates stake with allowlisting but empty sig — should succeed
        vm.startPrank(crOwner);
        mockRLS.approve(address(consensusRegistry), stakeAmount_);
        consensusRegistry.delegateStake(
            _blsDummyPubkeyFromSecret(valSecret),
            BlsG1.ProofOfPossession(pubkey, blsSig),
            valAddr,
            "" // empty sig, owner bypasses signature only
        );
        vm.stopPrank();

        ValidatorInfo[] memory staked = consensusRegistry.getValidators(
            ValidatorStatus.Staked
        );
        assertEq(staked.length, 1);
        assertEq(staked[0].validatorAddress, valAddr);
    }

    function testRevert_delegateStake_ownerCannotBypassAllowlist() public {
        uint256 valSecret = 99;
        address valAddr = _addressFromPrivateKey(valSecret);
        // do NOT allowlist valAddr
        mockRLS.mint(crOwner, stakeAmount_);

        bytes memory pubkey = eip2537PointG2ToUncompressed(
            _blsEIP2537PubkeyFromSecret(valSecret)
        );
        bytes memory message = proofOfPossessionMessage(
            pubkey,
            valAddr
        );
        bytes memory blsSig = eip2537PointG1ToUncompressed(
            _blsEIP2537SignatureFromSecret(valSecret, message)
        );

        // pre-compute all args that involve precompile calls
        bytes memory dummyPubkey = _blsDummyPubkeyFromSecret(valSecret);
        BlsG1.ProofOfPossession memory pop = BlsG1.ProofOfPossession(pubkey, blsSig);

        // owner tries to delegate without allowlisting — should revert
        vm.startPrank(crOwner);
        mockRLS.approve(address(consensusRegistry), stakeAmount_);
        vm.expectRevert(abi.encodeWithSelector(NotAllowlisted.selector, valAddr));
        consensusRegistry.delegateStake(
            dummyPubkey,
            pop,
            valAddr,
            ""
        );
    }

    function test_allowlistValidator() public {
        address newVal = address(0xBEEF);

        vm.expectEmit(true, false, false, false);
        emit ValidatorAllowlisted(newVal);

        vm.prank(crOwner);
        consensusRegistry.allowlistValidator(newVal);

        assertTrue(consensusRegistry.isAllowlisted(newVal));
    }

    function test_allowlistValidator_idempotent() public {
        address newVal = address(0xBEEF);
        vm.startPrank(crOwner);
        consensusRegistry.allowlistValidator(newVal);
        // second call should not emit event (early return)
        consensusRegistry.allowlistValidator(newVal);
        vm.stopPrank();
        assertTrue(consensusRegistry.isAllowlisted(newVal));
    }

    function test_delistValidator() public {
        vm.expectEmit(true, false, false, false);
        emit ValidatorDelisted(validator1);

        vm.prank(crOwner);
        consensusRegistry.delistValidator(validator1);

        assertFalse(consensusRegistry.isAllowlisted(validator1));
    }

    function test_delistValidator_doesNotAffectExistingValidator() public {
        // validator1 is already active from genesis
        vm.prank(crOwner);
        consensusRegistry.delistValidator(validator1);

        // should still be active
        ValidatorInfo memory info = consensusRegistry.getValidator(validator1);
        assertEq(uint8(info.currentStatus), uint8(ValidatorStatus.Active));
        assertFalse(info.isRetired);
    }

    function test_updateAllowlistBatch() public {
        address addr1 = address(0xA1);
        address addr2 = address(0xA2);
        address addr3 = address(0xA3);

        address[] memory addrs = new address[](3);
        addrs[0] = addr1;
        addrs[1] = addr2;
        addrs[2] = addr3;

        bool[] memory flags = new bool[](3);
        flags[0] = true;
        flags[1] = true;
        flags[2] = false;

        vm.prank(crOwner);
        consensusRegistry.updateAllowlistBatch(addrs, flags);

        assertTrue(consensusRegistry.isAllowlisted(addr1));
        assertTrue(consensusRegistry.isAllowlisted(addr2));
        assertFalse(consensusRegistry.isAllowlisted(addr3));
    }

    function testRevert_updateAllowlistBatch_lengthMismatch() public {
        address[] memory addrs = new address[](2);
        addrs[0] = address(0xA1);
        addrs[1] = address(0xA2);
        bool[] memory flags = new bool[](1);
        flags[0] = true;

        vm.prank(crOwner);
        vm.expectRevert(IConsensusRegistry.AllowlistBatchLengthMismatch.selector);
        consensusRegistry.updateAllowlistBatch(addrs, flags);
    }

    function testRevert_allowlistValidator_notOwner() public {
        vm.prank(validator1);
        vm.expectRevert();
        consensusRegistry.allowlistValidator(address(0xBEEF));
    }

    function testRevert_allowlistValidator_zeroAddress() public {
        vm.prank(crOwner);
        vm.expectRevert(IConsensusRegistry.InvalidValidatorAddress.selector);
        consensusRegistry.allowlistValidator(address(0));
    }

    function testRevert_updateAllowlistBatch_zeroAddress() public {
        address[] memory addrs = new address[](1);
        addrs[0] = address(0);
        bool[] memory flags = new bool[](1);
        flags[0] = true;

        vm.prank(crOwner);
        vm.expectRevert(IConsensusRegistry.InvalidValidatorAddress.selector);
        consensusRegistry.updateAllowlistBatch(addrs, flags);
    }

    // =========================================================================
    //                          Pause/Unpause Tests
    // =========================================================================

    function test_pause() public {
        vm.prank(crOwner);
        consensusRegistry.pause();

        assertTrue(consensusRegistry.paused());
    }

    function test_unpause() public {
        vm.prank(crOwner);
        consensusRegistry.pause();
        assertTrue(consensusRegistry.paused());

        vm.prank(crOwner);
        consensusRegistry.unpause();
        assertFalse(consensusRegistry.paused());
    }

    function testRevert_pause_notOwner() public {
        vm.prank(validator1);
        vm.expectRevert();
        consensusRegistry.pause();
    }

    function testRevert_unpause_notOwner() public {
        vm.prank(crOwner);
        consensusRegistry.pause();

        vm.prank(validator1);
        vm.expectRevert();
        consensusRegistry.unpause();
    }

    function testRevert_stake_whenPaused() public {
        vm.prank(crOwner);
        consensusRegistry.pause();
        assertTrue(consensusRegistry.paused());

        bytes memory message = consensusRegistry.proofOfPossessionMessage(
            validator5BlsPubkey,
            validator5
        );
        bytes memory blsSignature = eip2537PointG1ToUncompressed(
            _blsEIP2537SignatureFromSecret(validator5Secret, message)
        );
        bytes memory dummyPubkey = _blsDummyPubkeyFromSecret(validator5Secret);

        // Use low-level call to verify it reverts when paused
        vm.prank(validator5);
        bytes memory callData = abi.encodeCall(
            consensusRegistry.stake,
            (dummyPubkey, BlsG1.ProofOfPossession(validator5BlsPubkey, blsSignature))
        );
        (bool success, ) = address(consensusRegistry).call(callData);
        assertFalse(success, "stake should revert when paused");
    }

    // =========================================================================
    //                          ApplySlashes Tests
    // =========================================================================

    function test_applySlashes_partialSlash() public {
        // Use validator1 which is already staked and active from genesis
        // Get initial balance
        (uint256 initialBalance,,) = consensusRegistry.getBalanceBreakdown(validator1);

        // Apply partial slash
        uint256 slashAmount = stakeAmount_ / 10; // 10% slash
        Slash[] memory slashes = new Slash[](1);
        slashes[0] = Slash(validator1, slashAmount);

        vm.prank(sysAddress);
        consensusRegistry.applySlashes(slashes);

        // Verify balance decreased
        (uint256 newBalance,,) = consensusRegistry.getBalanceBreakdown(validator1);
        assertEq(newBalance, initialBalance - slashAmount);
    }

    function test_applySlashes_fullSlash_burns() public {
        // Use validator1 which is already staked and active from genesis
        // Fund ConsensusRegistry with enough RLS balance
        mockRLS.mint(address(consensusRegistry), stakeAmount_ * 5);

        // Apply full slash (more than balance) to trigger burn
        Slash[] memory slashes = new Slash[](1);
        slashes[0] = Slash(validator1, stakeAmount_ * 2);

        vm.prank(sysAddress);
        consensusRegistry.applySlashes(slashes);

        // Validator should be retired after burn
        assertTrue(consensusRegistry.isRetired(validator1));
    }

    function testRevert_applySlashes_notSystemCall() public {
        Slash[] memory slashes = new Slash[](1);
        slashes[0] = Slash(validator1, 1 ether);

        vm.prank(crOwner);
        vm.expectRevert();
        consensusRegistry.applySlashes(slashes);
    }

    // =========================================================================
    //                          SetDelegationPool Tests
    // =========================================================================

    function test_setDelegationPool() public {
        address newPool = address(0xDEAD);

        vm.prank(crOwner);
        consensusRegistry.setDelegationPool(newPool);

        assertEq(consensusRegistry.delegationPool(), newPool);
    }

    function testRevert_setDelegationPool_notOwner() public {
        vm.prank(validator1);
        vm.expectRevert();
        consensusRegistry.setDelegationPool(address(0xDEAD));
    }

    // =========================================================================
    //                          WithdrawSlashedFunds Tests
    // =========================================================================

    function test_withdrawSlashedFunds() public {
        // Use validator2 which is already staked and active from genesis
        // Fund ConsensusRegistry with enough RLS balance
        mockRLS.mint(address(consensusRegistry), stakeAmount_ * 5);

        // Apply full slash to trigger burn and accumulate slashed funds
        Slash[] memory slashes = new Slash[](1);
        slashes[0] = Slash(validator2, stakeAmount_ * 2);

        vm.prank(sysAddress);
        consensusRegistry.applySlashes(slashes);

        // Now withdraw slashed funds
        uint256 slashedAmount = consensusRegistry.slashedFunds();
        address recipient = address(0xBEEF);
        uint256 recipientBalanceBefore = mockRLS.balanceOf(recipient);

        if (slashedAmount > 0) {
            vm.prank(crOwner);
            consensusRegistry.withdrawSlashedFunds(recipient, slashedAmount);

            assertEq(mockRLS.balanceOf(recipient), recipientBalanceBefore + slashedAmount);
            assertEq(consensusRegistry.slashedFunds(), 0);
        }
    }

    function testRevert_withdrawSlashedFunds_notOwner() public {
        vm.prank(validator1);
        vm.expectRevert();
        consensusRegistry.withdrawSlashedFunds(address(0xBEEF), 1 ether);
    }

    function testRevert_withdrawSlashedFunds_zeroAmount() public {
        vm.prank(crOwner);
        vm.expectRevert("Zero amount");
        consensusRegistry.withdrawSlashedFunds(address(0xBEEF), 0);
    }

    function testRevert_withdrawSlashedFunds_insufficientFunds() public {
        vm.prank(crOwner);
        vm.expectRevert("Insufficient slashed funds");
        consensusRegistry.withdrawSlashedFunds(address(0xBEEF), 1 ether);
    }

    // =========================================================================
    //                          UpgradeStakeVersion Tests
    // =========================================================================

    function test_upgradeStakeVersion() public {
        uint8 currentVersion = consensusRegistry.getCurrentStakeVersion();

        StakeConfig memory newConfig = StakeConfig({
            stakeAmount: stakeAmount_ * 2,
            minWithdrawAmount: minWithdrawAmount_ * 2,
            epochDuration: epochDuration_ * 2
        });

        vm.prank(crOwner);
        uint8 newVersion = consensusRegistry.upgradeStakeVersion(newConfig);

        assertEq(newVersion, currentVersion + 1);

        StakeConfig memory storedConfig = consensusRegistry.stakeConfig(newVersion);
        assertEq(storedConfig.stakeAmount, newConfig.stakeAmount);
        assertEq(storedConfig.minWithdrawAmount, newConfig.minWithdrawAmount);
        assertEq(storedConfig.epochDuration, newConfig.epochDuration);
    }

    function testRevert_upgradeStakeVersion_notOwner() public {
        StakeConfig memory newConfig = StakeConfig({
            stakeAmount: stakeAmount_,
            minWithdrawAmount: minWithdrawAmount_,
            epochDuration: epochDuration_
        });

        vm.prank(validator1);
        vm.expectRevert();
        consensusRegistry.upgradeStakeVersion(newConfig);
    }

    function testRevert_upgradeStakeVersion_zeroDuration() public {
        StakeConfig memory newConfig = StakeConfig({
            stakeAmount: stakeAmount_,
            minWithdrawAmount: minWithdrawAmount_,
            epochDuration: 0
        });

        vm.prank(crOwner);
        vm.expectRevert(abi.encodeWithSelector(IConsensusRegistry.InvalidDuration.selector, 0));
        consensusRegistry.upgradeStakeVersion(newConfig);
    }

    function testRevert_upgradeStakeVersion_whenPaused() public {
        vm.prank(crOwner);
        consensusRegistry.pause();

        StakeConfig memory newConfig = StakeConfig({
            stakeAmount: stakeAmount_,
            minWithdrawAmount: minWithdrawAmount_,
            epochDuration: epochDuration_
        });

        vm.prank(crOwner);
        vm.expectRevert();
        consensusRegistry.upgradeStakeVersion(newConfig);
    }

    // =========================================================================
    //                          Getter Function Tests
    // =========================================================================

    function test_getCurrentStakeVersion() public view {
        uint8 version = consensusRegistry.getCurrentStakeVersion();
        assertEq(version, 0);
    }

    function test_getCurrentEpoch() public view {
        uint32 epoch = consensusRegistry.getCurrentEpoch();
        assertEq(epoch, 0);
    }

    function test_getCurrentEpochInfo() public view {
        EpochInfo memory info = consensusRegistry.getCurrentEpochInfo();
        assertEq(info.committee.length, 4);
        assertEq(info.epochDuration, epochDuration_);
    }

    function test_getEpochInfo() public view {
        EpochInfo memory info = consensusRegistry.getEpochInfo(0);
        assertEq(info.committee.length, 4);
        assertEq(info.epochDuration, epochDuration_);
    }

    function test_getValidators() public view {
        ValidatorInfo[] memory activeValidators = consensusRegistry.getValidators(ValidatorStatus.Active);
        assertEq(activeValidators.length, 4);

        for (uint256 i = 0; i < activeValidators.length; i++) {
            assertTrue(activeValidators[i].currentStatus == ValidatorStatus.Active);
        }
    }

    function test_getCommitteeValidators() public view {
        ValidatorInfo[] memory committee = consensusRegistry.getCommitteeValidators(0);
        assertEq(committee.length, 4);
    }

    function test_getValidator() public view {
        ValidatorInfo memory info = consensusRegistry.getValidator(validator1);
        assertEq(info.validatorAddress, validator1);
        assertTrue(info.currentStatus == ValidatorStatus.Active);
    }

    function test_isRetired() public view {
        assertFalse(consensusRegistry.isRetired(validator1));
    }

    function test_getRewards() public view {
        uint256 rewards = consensusRegistry.getRewards(validator1);
        assertEq(rewards, 0); // No rewards yet at genesis
    }

    function test_getBalanceBreakdown() public view {
        (uint256 balance, uint256 initialStake, uint256 rewards) = consensusRegistry.getBalanceBreakdown(validator1);
        assertEq(balance, stakeAmount_);
        assertEq(initialStake, stakeAmount_);
        assertEq(rewards, 0); // No rewards yet at genesis
    }

    function test_delegationDigest() public view {
        bytes32 digest = consensusRegistry.delegationDigest(
            _blsDummyPubkeyFromSecret(1),
            validator1,
            address(0xDEAD)
        );
        assertNotEq(digest, bytes32(0));
    }

    /// @dev FIND-011: Verifies that the last strictly-active validator cannot beginExit(),
    /// preventing a mass exit that would leave zero active validators for the next epoch.
    function testRevert_beginExit_lastActiveCannotExit() public {
        // Setup: 4 genesis validators, all Active, committee size 4.
        uint256 numActive = consensusRegistry.getValidators(ValidatorStatus.Active).length;
        assertEq(numActive, 4);

        // Exit validators 1, 2, 3 — leaving validator4 as the last strictly-active
        vm.prank(validator1);
        consensusRegistry.beginExit();

        vm.prank(validator2);
        consensusRegistry.beginExit();

        // validator3 is the 3rd exit; after this, numStrictlyActive = 1 (only validator4)
        vm.prank(validator3);
        consensusRegistry.beginExit();

        // Verify 3 validators are in PendingExit
        assertEq(consensusRegistry.getValidators(ValidatorStatus.PendingExit).length, 3);

        // validator4 is the last strictly-active validator — beginExit must revert
        uint256 committeeSize = consensusRegistry.getEpochInfo(consensusRegistry.getCurrentEpoch()).committee.length;
        vm.prank(validator4);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidCommitteeSize.selector, 1, committeeSize)
        );
        consensusRegistry.beginExit();

        // Confirm validator4 is still Active
        ValidatorInfo memory v4 = consensusRegistry.getValidator(validator4);
        assertEq(uint8(v4.currentStatus), uint8(ValidatorStatus.Active));
    }

    function test_proofOfPossessionMessage() public view {
        bytes memory message = consensusRegistry.proofOfPossessionMessage(
            validator5BlsPubkey,
            validator5
        );
        assertGt(message.length, 0);
    }
}
