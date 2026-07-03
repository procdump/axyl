// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {IStakeManager} from "../interfaces/IStakeManager.sol";
import {BlsG1} from "./BlsG1.sol";

/**
 * @title StakeManager
 * @notice Rayls Core Ltd., Telcoin Association
 *
 * @notice This abstract contract provides modular management of consensus validator stake
 * @dev Designed for inheritance by the ConsensusRegistry
 */
abstract contract StakeManager is EIP712, IStakeManager {
    using SafeERC20 for IERC20;

    uint8 internal stakeVersion;
    address[] public validatorsAddresses;
    mapping(address => uint256) internal validatorIndex; // index + 1 so 0 means non-existent
    mapping(uint8 => StakeConfig) internal versions;
    mapping(address => uint256) internal balances;
    mapping(address => Delegation) internal delegations;

    /// @dev The ERC-20 RLS token used for staking
    IERC20 public immutable _rls;

    /// @dev Address of the DelegationPool contract for multi-delegator staking
    address public delegationPool;
    /// @dev Accumulated pool reward balances per validator, claimed by DelegationPool
    mapping(address => uint256) public poolRewardBalances;

    /// @dev EIP-712 typed struct hash used to enable delegated proof of stake
    bytes32 constant DELEGATION_TYPEHASH =
        keccak256(
            "Delegation(bytes32 blsPubkeyHash,address validatorAddress,address delegator,uint8 validatorVersion,uint64 nonce)"
        );

    constructor(address rls_) {
        _rls = IERC20(rls_);
    }

    /// @inheritdoc IStakeManager
    function stake(
        bytes calldata blsPubkey,
        BlsG1.ProofOfPossession calldata proofOfPossession
    ) external virtual;

    /// @inheritdoc IStakeManager
    function delegateStake(
        bytes calldata blsPubkey,
        BlsG1.ProofOfPossession calldata proofOfPossession,
        address validatorAddress,
        bytes calldata validatorSig
    ) external virtual;

    /// @inheritdoc IStakeManager
    function claimStakeRewards(address ecsdaPubkey) external virtual;

    /// @inheritdoc IStakeManager
    function unstake(address validatorAddress) external virtual;

    /// @inheritdoc IStakeManager
    function getRewards(
        address validatorAddress
    ) public view virtual returns (uint256);

    /// @inheritdoc IStakeManager
    function getBalanceBreakdown(address validatorAddress) public view virtual returns (uint256, uint256, uint256);

    /// @inheritdoc IStakeManager
    function stakeConfig(
        uint8 version
    ) public view virtual returns (StakeConfig memory) {
        return versions[version];
    }

    /// @inheritdoc IStakeManager
    function getCurrentStakeConfig() public view returns (StakeConfig memory) {
        return versions[stakeVersion];
    }

    /// @inheritdoc IStakeManager
    function upgradeStakeVersion(
        StakeConfig calldata config
    ) external virtual returns (uint8);

    /// @inheritdoc IStakeManager
    function rlsToken() external view override returns (address) {
        return address(_rls);
    }

    /**
     *
     *   internals
     *
     */
    function _claimStakeRewards(
        address validatorAddress,
        address recipient,
        uint8 validatorVersion
    ) internal virtual returns (uint256) {
        // check rewards are claimable and send via ERC-20 transfer
        uint256 rewards = _checkRewards(validatorAddress, validatorVersion);
        balances[validatorAddress] -= rewards;
        _rls.safeTransfer(recipient, rewards);

        return rewards;
    }

    function _addValidator(address validatorAddress) internal virtual {
        validatorsAddresses.push(validatorAddress);
        validatorIndex[validatorAddress] = validatorsAddresses.length; // index + 1
    }

    function _removeValidator(address validatorAddress) internal virtual {
        uint256 index = validatorIndex[validatorAddress];
        if (index == 0) revert ValidatorNotFound(validatorAddress);

        uint256 lastIndex = validatorsAddresses.length;
        if (index != lastIndex) {
            // swap with last element
            address lastValidator = validatorsAddresses[lastIndex - 1];
            validatorsAddresses[index - 1] = lastValidator;
            validatorIndex[lastValidator] = index; // update index
        }

        // remove last element
        validatorsAddresses.pop();
        delete validatorIndex[validatorAddress];
    }

    function _stake(
        address validatorAddress,
        uint256 stakeAmt
    ) internal virtual {
        balances[validatorAddress] = stakeAmt;
        _addValidator(validatorAddress);
    }

    function _unstake(address validatorAddress, address recipient) internal virtual returns (uint256) {

        if (validatorsAddresses.length <= 1) revert InvalidValidatorSupply();

        _removeValidator(validatorAddress);

        (uint256 bal, uint256 stakeAmt, uint256 rewards) = getBalanceBreakdown(validatorAddress);
        // zero outstanding balance implies burn context, no further action needed- ledgers are already settled
        if (bal == 0) return bal;

        // otherwise wipe existing balance & identify the amount of stake due to recipient
        balances[validatorAddress] = 0;

        // forward outstanding stake + rewards to recipient via ERC-20 transfer
        uint256 unstakeAmt;
        if (bal >= stakeAmt) {
            // recipient is entitled to full initial stake amount and any outstanding rewards
            unstakeAmt = stakeAmt;
        } else {
            // recipient has been slashed below initial stake; only outstanding bal will be sent
            unstakeAmt = bal;
        }

        // transfer total (stake + rewards) to recipient
        uint256 totalPayout = unstakeAmt + rewards;
        if (totalPayout > 0) {
            _rls.safeTransfer(recipient, totalPayout);
        }

        return totalPayout;
    }

    function _checkRewards(
        address validatorAddress,
        uint8 validatorVersion
    ) internal virtual returns (uint256) {
        uint256 initialStake = versions[validatorVersion].stakeAmount;
        uint256 rewards = _getRewards(validatorAddress, initialStake);

        if (
            rewards == 0 ||
            rewards < versions[validatorVersion].minWithdrawAmount
        ) {
            revert InsufficientRewards(rewards);
        }

        return rewards;
    }

    function _checkStakeValue(
        uint256 value,
        uint8 version
    ) internal virtual returns (uint256) {
        if (value != versions[version].stakeAmount)
            revert InvalidStakeAmount(value, versions[version].stakeAmount);

        return uint256(value);
    }

    function _getRewards(
        address validatorAddress,
        uint256 initialStake
    ) internal view virtual returns (uint256) {
        uint256 balance = balances[validatorAddress];
        uint256 rewards = balance > initialStake ? balance - initialStake : 0;

        return rewards;
    }

    /// @dev Identifies the validator's rewards recipient, ie the stake originator
    /// @return _ Returns the validator's delegator if one exists, else the validator itself
    function _getRecipient(
        address validatorAddress
    ) internal view returns (address) {
        Delegation storage delegation = delegations[validatorAddress];
        address recipient = delegation.delegator;
        if (recipient == address(0x0)) recipient = validatorAddress;

        return recipient;
    }

    function _setDelegationPool(address pool) internal {
        delegationPool = pool;
    }

    function _domainNameAndVersion()
        internal
        view
        virtual
        override
        returns (string memory, string memory)
    {
        return ("Rayls StakeManager", "1");
    }
}
