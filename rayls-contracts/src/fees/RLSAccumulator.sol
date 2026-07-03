// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title RLSAccumulator
 * @notice A Rayls Contract
 *
 * @notice Holds RLS reserves for APY top-up subsidies during early network operation.
 * @dev RewardDistributor pulls RLS from this contract via transferFrom each epoch
 *      to cover the shortfall between target APY rewards and actual fee revenue.
 * @dev UUPS upgradeable with AccessControl
 */
contract RLSAccumulator is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @custom:storage-location erc7201:rlsaccumulator.storage.v1
    struct AccumulatorStorage {
        IERC20 rls;
        address rewardDistributor;
    }

    // keccak256(abi.encode(uint256(keccak256("rlsaccumulator.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION =
        0x1434b6d7a9cd896918fc9e177be6ce103a3f4b47c31c2a0c7a187bcc052a1c00;

    error ZeroAddress();
    error ZeroAmount();

    event Deposited(address indexed from, uint256 amount);
    event RlsTokenUpdated(address indexed oldToken, address indexed newToken);
    event RewardDistributorUpdated(address indexed oldDistributor, address indexed newDistributor);
    event ApprovalRefreshed(address indexed rewardDistributor, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address rls_,
        address rewardDistributor_,
        address admin_
    ) external initializer {
        if (rls_ == address(0)) revert ZeroAddress();
        if (rewardDistributor_ == address(0)) revert ZeroAddress();
        if (admin_ == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(UPGRADER_ROLE, admin_);

        AccumulatorStorage storage $ = _getStorage();
        $.rls = IERC20(rls_);
        $.rewardDistributor = rewardDistributor_;

        // Approve RewardDistributor to pull RLS
        IERC20(rls_).forceApprove(rewardDistributor_, type(uint256).max);
    }

    /// @notice Deposit RLS into the accumulator reserve
    /// @param amount The amount of RLS to deposit
    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        AccumulatorStorage storage $ = _getStorage();
        $.rls.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount);
    }

    /// @notice Get the current RLS balance available for top-ups
    function balance() external view returns (uint256) {
        AccumulatorStorage storage $ = _getStorage();
        return $.rls.balanceOf(address(this));
    }

    /// @notice Get the RLS token address
    function rlsToken() external view returns (address) {
        return address(_getStorage().rls);
    }

    /// @notice Get the RewardDistributor address
    function rewardDistributor() external view returns (address) {
        return _getStorage().rewardDistributor;
    }

    /// @notice Update the RLS token address
    /// @dev Revokes the RewardDistributor's approval on the old token and grants it on the new one.
    ///      Any remaining balance of the old token can be recovered via recoverTokens().
    function setRlsToken(address newRls) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRls == address(0)) revert ZeroAddress();
        AccumulatorStorage storage $ = _getStorage();

        address oldRls = address($.rls);
        // Revoke old approval
        $.rls.forceApprove($.rewardDistributor, 0);

        // Set new token and approve RewardDistributor
        $.rls = IERC20(newRls);
        IERC20(newRls).forceApprove($.rewardDistributor, type(uint256).max);

        emit RlsTokenUpdated(oldRls, newRls);
    }

    /// @notice Update the RewardDistributor address and refresh approval
    function setRewardDistributor(address newDistributor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newDistributor == address(0)) revert ZeroAddress();
        AccumulatorStorage storage $ = _getStorage();

        // Revoke old approval
        address oldDistributor = $.rewardDistributor;
        $.rls.forceApprove(oldDistributor, 0);

        // Set new and approve
        $.rewardDistributor = newDistributor;
        $.rls.forceApprove(newDistributor, type(uint256).max);

        emit RewardDistributorUpdated(oldDistributor, newDistributor);
    }

    /// @notice Refresh the approval for RewardDistributor (in case it was consumed)
    function refreshApproval() external onlyRole(DEFAULT_ADMIN_ROLE) {
        AccumulatorStorage storage $ = _getStorage();
        $.rls.forceApprove($.rewardDistributor, type(uint256).max);
        emit ApprovalRefreshed($.rewardDistributor, type(uint256).max);
    }

    /// @notice Revoke the RewardDistributor's approval to pull RLS
    /// @dev Emergency kill-switch. Stops all accumulator top-ups until refreshApproval() is called.
    function revokeApproval() external onlyRole(DEFAULT_ADMIN_ROLE) {
        AccumulatorStorage storage $ = _getStorage();
        $.rls.forceApprove($.rewardDistributor, 0);
        emit ApprovalRefreshed($.rewardDistributor, 0);
    }

    /// @notice Emergency recovery of stuck tokens
    function recoverTokens(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    function _getStorage() private pure returns (AccumulatorStorage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
