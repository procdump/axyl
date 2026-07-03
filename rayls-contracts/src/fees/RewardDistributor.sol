// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRewardDistributor} from "../interfaces/IRewardDistributor.sol";
import {IConsensusRegistry} from "../interfaces/IConsensusRegistry.sol";
import {IStakeManager} from "../interfaces/IStakeManager.sol";
import {IDelegationPool} from "../interfaces/IDelegationPool.sol";
import {SystemCallable} from "../consensus/SystemCallable.sol";

/**
 * @title RewardDistributor
 * @notice A Rayls Contract
 *
 * @notice Distributes ERC-20 RLS staking rewards to validators and delegators
 * @dev Receives ERC-20 RLS from FeeAggregator (after USDr → RLS swap) and distributes
 *      based on block production performance weights (stake × consensusHeaderCount)
 * @dev Falls back to pure stake-based distribution if no performance data is available
 * @dev UUPS upgradeable with AccessControl
 * @dev RLS is an ERC-20 token; USDr is ERC-20 stablecoin
 */
contract RewardDistributor is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuard,
    SystemCallable,
    IRewardDistributor
{
    using SafeERC20 for IERC20;

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @custom:storage-location erc7201:rewarddistributor.storage.v1
    struct RewardDistributorStorage {
        /// @notice The RLS token contract (ERC-20 staking token)
        IERC20 rls;
        /// @notice The FeeAggregator contract (only caller allowed to receive rewards)
        address feeAggregator;
        /// @notice The ConsensusRegistry contract
        IConsensusRegistry consensusRegistry;
        /// @notice The DelegationPool contract
        IDelegationPool delegationPool;
        /// @notice Pending rewards per validator (in RLS tokens)
        mapping(address => uint256) pendingValidatorRewards;
        /// @notice Custom reward recipient per validator (if set, rewards go here instead of validator address)
        mapping(address => address) rewardRecipients;
        /// @notice Total undistributed rewards (in RLS tokens)
        uint256 totalPending;
        // -- deprecated fields retained for storage layout compatibility --
        IRewardDistributor.DistributionState _deprecated_distributionState;
        address[] _deprecated_cachedValidators;
        uint256[] _deprecated_cachedStakes;
        uint256[] _deprecated_cachedValidatorStakes;
        // -- end deprecated --
        /// @notice RLS Accumulator for APY top-up subsidies
        address accumulator;
        /// @notice Target APY in basis points (e.g., 5000 = 50%)
        uint256 targetApyBps;
        /// @notice Sum of all pendingValidatorRewards — protects unclaimed rewards from recoverTokens
        uint256 totalUnclaimedRewards;
    }

    // keccak256(abi.encode(uint256(keccak256("rewarddistributor.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant REWARD_DISTRIBUTOR_STORAGE_LOCATION =
        0x8a40cc0ccf5a2d030058c860d76601e04104947950ec7475e80ab15a7d69d600;

    function _getRewardDistributorStorage() private pure returns (RewardDistributorStorage storage $) {
        assembly {
            $.slot := REWARD_DISTRIBUTOR_STORAGE_LOCATION
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address rls_,
        address feeAggregator_,
        address consensusRegistry_,
        address delegationPool_,
        address admin_
    ) external initializer {
        if (rls_ == address(0)) revert ZeroAddress();
        if (consensusRegistry_ == address(0)) revert ZeroAddress();
        if (admin_ == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(UPGRADER_ROLE, admin_);

        RewardDistributorStorage storage $ = _getRewardDistributorStorage();
        $.rls = IERC20(rls_);
        $.feeAggregator = feeAggregator_;
        $.consensusRegistry = IConsensusRegistry(consensusRegistry_);
        $.delegationPool = IDelegationPool(delegationPool_);
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    /// @inheritdoc IRewardDistributor
    function rlsToken() external view override returns (address) {
        return address(_getRewardDistributorStorage().rls);
    }

    /// @inheritdoc IRewardDistributor
    function feeAggregator() external view override returns (address) {
        return _getRewardDistributorStorage().feeAggregator;
    }

    /// @inheritdoc IRewardDistributor
    function consensusRegistry() external view override returns (address) {
        return address(_getRewardDistributorStorage().consensusRegistry);
    }

    /// @inheritdoc IRewardDistributor
    function delegationPool() external view override returns (address) {
        return address(_getRewardDistributorStorage().delegationPool);
    }

    modifier onlyFeeAggregator() {
        if (msg.sender != _getRewardDistributorStorage().feeAggregator) revert OnlyFeeAggregator();
        _;
    }

    /// @inheritdoc IRewardDistributor
    function receiveRewards(uint256 amount) external override onlyFeeAggregator {
        if (amount == 0) revert ZeroAmount();
        RewardDistributorStorage storage $ = _getRewardDistributorStorage();
        $.totalPending += amount;
        uint256 balance = $.rls.balanceOf(address(this));
        if (balance < $.totalPending) {
            revert InsufficientBalance($.totalPending, balance);
        }
        emit RewardsReceived(amount);
    }

    // ========== DISTRIBUTION ==========

    /// @inheritdoc IRewardDistributor
    /// @dev Distributes all pending rewards in a single call.
    ///      Uses performance weights (stake × headerCount) if available, falls back to pure stake.
    ///      Fetches each validator's own-stake and delegated-stake exactly once (used for both
    ///      APY top-up calculation and the validator/pool reward split).
    function distributeRewards() external override onlySystemCall nonReentrant {
        RewardDistributorStorage storage $ = _getRewardDistributorStorage();

        uint256 totalRewards = $.totalPending;

        // Distribution keys and pre-fetched stake data (one pass over validators)
        address[] memory validators;
        uint256[] memory weights;
        uint256[] memory ownStakes;
        uint256[] memory delegatedStakes;
        uint256 totalWeight;
        uint256 totalStaked;

        IConsensusRegistry.PerformanceWeights memory perf = $.consensusRegistry.getEpochPerformanceWeights();

        if (perf.totalWeight > 0 && perf.validators.length > 0) {
            uint256 n = perf.validators.length;
            validators = perf.validators;
            weights = perf.weights;
            totalWeight = perf.totalWeight;
            ownStakes = new uint256[](n);
            delegatedStakes = new uint256[](n);

            // Single pass: fetch stake data for APY calc + later split
            for (uint256 i; i < n; ++i) {
                (, uint256 ownStake, ) = IStakeManager(address($.consensusRegistry)).getBalanceBreakdown(validators[i]);
                ownStakes[i] = ownStake;
                uint256 delegated;
                if (address($.delegationPool) != address(0)) {
                    delegated = $.delegationPool.getTotalDelegatedStake(validators[i]);
                }
                delegatedStakes[i] = delegated;
                totalStaked += ownStake + delegated;
            }

            totalRewards = _pullAccumulatorTopUp(totalRewards, totalStaked);
        } else {
            IConsensusRegistry.ValidatorInfo[] memory activeValidators = $.consensusRegistry.getValidators(
                IConsensusRegistry.ValidatorStatus.Active
            );
            if (activeValidators.length == 0) revert NoActiveValidators();

            uint256 n = activeValidators.length;
            validators = new address[](n);
            weights = new uint256[](n);
            ownStakes = new uint256[](n);
            delegatedStakes = new uint256[](n);

            for (uint256 i; i < n; ++i) {
                address validatorAddr = activeValidators[i].validatorAddress;
                (, uint256 ownStake, ) = IStakeManager(address($.consensusRegistry)).getBalanceBreakdown(validatorAddr);

                uint256 delegated;
                if (address($.delegationPool) != address(0)) {
                    delegated = $.delegationPool.getTotalDelegatedStake(validatorAddr);
                }

                validators[i] = validatorAddr;
                ownStakes[i] = ownStake;
                delegatedStakes[i] = delegated;
                weights[i] = ownStake + delegated;
                totalWeight += weights[i];
            }

            totalRewards = _pullAccumulatorTopUp(totalRewards, totalWeight);
        }

        if (totalWeight == 0) revert NoActiveValidators();

        if (totalRewards == 0) {
            emit RewardsDistributed(0, 0);
            return;
        }

        // Distribute to each validator proportionally using pre-fetched stakes
        uint256 distributed;
        for (uint256 i; i < validators.length; ++i) {
            uint256 validatorReward = (totalRewards * weights[i]) / totalWeight;
            if (validatorReward == 0) continue;

            distributed += _distributeToValidator(validators[i], validatorReward, ownStakes[i], delegatedStakes[i]);
        }

        // Subtract full totalRewards so rounding dust is freed from totalPending
        $.totalPending -= totalRewards;
        emit RewardsDistributed(distributed, validators.length);
    }

    /// @dev Distributes a reward to a validator, splitting between own stake and delegation pool.
    ///      Uses pre-fetched stake values to avoid redundant external calls.
    function _distributeToValidator(
        address validatorAddr,
        uint256 validatorReward,
        uint256 ownStake,
        uint256 delegatedStake
    ) internal returns (uint256) {
        if (validatorReward == 0) return 0;

        RewardDistributorStorage storage $ = _getRewardDistributorStorage();
        uint256 totalValidatorStake = ownStake + delegatedStake;

        if (delegatedStake > 0 && totalValidatorStake > 0 && address($.delegationPool) != address(0)) {
            uint256 validatorShare = (validatorReward * ownStake) / totalValidatorStake;
            uint256 poolShare = validatorReward - validatorShare;

            if (poolShare > 0) {
                $.rls.safeTransfer(address($.delegationPool), poolShare);
                $.delegationPool.distributePoolRewards(validatorAddr, poolShare);
            }

            $.pendingValidatorRewards[validatorAddr] += validatorShare;
            $.totalUnclaimedRewards += validatorShare;
            emit ValidatorRewardDistributed(validatorAddr, validatorShare, poolShare);
        } else {
            $.pendingValidatorRewards[validatorAddr] += validatorReward;
            $.totalUnclaimedRewards += validatorReward;
            emit ValidatorRewardDistributed(validatorAddr, validatorReward, 0);
        }

        return validatorReward;
    }

    // ========== CLAIMS ==========

    /// @notice Claim pending rewards for a validator
    /// @dev Only the validator themselves can claim their rewards
    function claimRewards(address validatorAddress) external nonReentrant {
        if (msg.sender != validatorAddress) revert NotAuthorized();

        RewardDistributorStorage storage $ = _getRewardDistributorStorage();
        uint256 amount = $.pendingValidatorRewards[validatorAddress];
        if (amount == 0) revert ZeroAmount();

        $.pendingValidatorRewards[validatorAddress] = 0;
        $.totalUnclaimedRewards -= amount;

        address recipient = $.rewardRecipients[validatorAddress];
        if (recipient == address(0)) {
            recipient = validatorAddress;
        }

        $.rls.safeTransfer(recipient, amount);
        emit PendingRewardsClaimed(validatorAddress, amount);
    }

    /// @inheritdoc IRewardDistributor
    function getPendingRewards(
        address validatorAddress
    ) external view override returns (uint256) {
        return _getRewardDistributorStorage().pendingValidatorRewards[validatorAddress];
    }

    /// @inheritdoc IRewardDistributor
    function totalPendingRewards() external view override returns (uint256) {
        return _getRewardDistributorStorage().totalPending;
    }

    // ========== ADMIN ==========

    /// @inheritdoc IRewardDistributor
    function setFeeAggregator(address newAggregator) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAggregator == address(0)) revert ZeroAddress();
        RewardDistributorStorage storage $ = _getRewardDistributorStorage();
        address oldAggregator = $.feeAggregator;
        $.feeAggregator = newAggregator;
        emit FeeAggregatorUpdated(oldAggregator, newAggregator);
    }

    /// @inheritdoc IRewardDistributor
    function setDelegationPool(address newPool) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        RewardDistributorStorage storage $ = _getRewardDistributorStorage();
        address oldPool = address($.delegationPool);
        $.delegationPool = IDelegationPool(newPool);
        emit DelegationPoolUpdated(oldPool, newPool);
    }

    /// @notice Set the ConsensusRegistry address
    function setConsensusRegistry(address newRegistry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRegistry == address(0)) revert ZeroAddress();
        RewardDistributorStorage storage $ = _getRewardDistributorStorage();
        address oldRegistry = address($.consensusRegistry);
        $.consensusRegistry = IConsensusRegistry(newRegistry);
        emit ConsensusRegistryUpdated(oldRegistry, newRegistry);
    }

    /// @inheritdoc IRewardDistributor
    function getRewardRecipient(address validatorAddress) external view override returns (address) {
        address recipient = _getRewardDistributorStorage().rewardRecipients[validatorAddress];
        return recipient == address(0) ? validatorAddress : recipient;
    }

    /// @inheritdoc IRewardDistributor
    function setRewardRecipient(address recipient) external override {
        RewardDistributorStorage storage $ = _getRewardDistributorStorage();
        address oldRecipient = $.rewardRecipients[msg.sender];
        $.rewardRecipients[msg.sender] = recipient;
        emit RewardRecipientUpdated(msg.sender, oldRecipient, recipient);
    }

    // ========== ACCUMULATOR ==========

    /// @inheritdoc IRewardDistributor
    function accumulator() external view override returns (address) {
        return _getRewardDistributorStorage().accumulator;
    }

    /// @inheritdoc IRewardDistributor
    function setAccumulator(address newAccumulator) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        RewardDistributorStorage storage $ = _getRewardDistributorStorage();
        address oldAccumulator = $.accumulator;
        $.accumulator = newAccumulator;
        emit AccumulatorUpdated(oldAccumulator, newAccumulator);
    }

    /// @inheritdoc IRewardDistributor
    function targetApyBps() external view override returns (uint256) {
        return _getRewardDistributorStorage().targetApyBps;
    }

    uint256 public constant MAX_APY_BPS = 10_000; // 100% max

    /// @inheritdoc IRewardDistributor
    function setTargetApyBps(uint256 newApyBps) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newApyBps > MAX_APY_BPS) revert InvalidApyBps();
        RewardDistributorStorage storage $ = _getRewardDistributorStorage();
        uint256 oldApyBps = $.targetApyBps;
        $.targetApyBps = newApyBps;
        emit TargetApyBpsUpdated(oldApyBps, newApyBps);
    }

    /// @dev Pull RLS from the accumulator to cover APY shortfall.
    ///      Never reverts — failed pull is silently skipped.
    function _pullAccumulatorTopUp(uint256 currentRewards, uint256 totalStaked) internal returns (uint256) {
        RewardDistributorStorage storage $ = _getRewardDistributorStorage();

        if ($.accumulator == address(0) || $.targetApyBps == 0 || totalStaked == 0) {
            return currentRewards;
        }

        uint256 epochSecs = $.consensusRegistry.getCurrentEpochInfo().epochDuration;
        uint256 targetReward = (totalStaked * $.targetApyBps * epochSecs) / (365 days * 10_000);

        if (targetReward <= currentRewards) {
            return currentRewards;
        }

        uint256 shortfall = targetReward - currentRewards;
        uint256 available = $.rls.balanceOf($.accumulator);
        uint256 pullAmount = shortfall < available ? shortfall : available;

        if (pullAmount > 0) {
            try IERC20($.rls).transferFrom($.accumulator, address(this), pullAmount) returns (bool ok) {
                if (ok) {
                    $.totalPending += pullAmount;
                    emit AccumulatorTopUp(pullAmount, targetReward, currentRewards + pullAmount);
                    return currentRewards + pullAmount;
                } else {
                    emit AccumulatorTopUpFailed(pullAmount);
                }
            } catch {
                emit AccumulatorTopUpFailed(pullAmount);
            }
        }

        return currentRewards;
    }

    // ========== EMERGENCY ==========

    /// @notice Emergency function to recover stuck ERC-20 tokens
    /// @dev Cannot recover RLS that is pending distribution or unclaimed
    function recoverTokens(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();

        RewardDistributorStorage storage $ = _getRewardDistributorStorage();
        if (token == address($.rls)) {
            uint256 reserved = $.totalPending + $.totalUnclaimedRewards;
            uint256 balance = $.rls.balanceOf(address(this));
            uint256 available = balance > reserved ? balance - reserved : 0;
            if (amount > available) revert InsufficientBalance(amount, available);
        }

        IERC20(token).safeTransfer(to, amount);
    }
}
