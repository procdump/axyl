// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IOFT} from "../interfaces/IOFT.sol";

/**
 * @title MockOFTBridge
 * @notice Testnet-deployable mock of a LayerZero OFT adapter.
 *         Pulls RLS from the sender and accumulates it (no real cross-chain).
 *         Reports a configurable native fee via quoteSend.
 */
contract MockOFTBridge is IOFT, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable rls;
    uint256 public nativeFee;
    uint64 public nonce;

    event Sent(uint32 indexed dstEid, bytes32 indexed to, uint256 amount, uint256 nativeFeePaid);

    constructor(address rls_, uint256 nativeFee_) Ownable(msg.sender) {
        rls = IERC20(rls_);
        nativeFee = nativeFee_;
    }

    function quoteSend(SendParam calldata, bool) external view override returns (MessagingFee memory) {
        return MessagingFee({nativeFee: nativeFee, lzTokenFee: 0});
    }

    function send(
        SendParam calldata sendParam,
        MessagingFee calldata fee,
        address /* refundAddress */
    ) external payable override returns (MessagingReceipt memory receipt, OFTReceipt memory oftReceipt) {
        require(msg.value >= fee.nativeFee, "insufficient native fee");
        require(fee.nativeFee >= nativeFee, "fee below quote");

        // Pull RLS from sender (FeeAggregator approves this contract)
        rls.safeTransferFrom(msg.sender, address(this), sendParam.amountLD);

        nonce++;
        receipt = MessagingReceipt({
            guid: keccak256(abi.encode(block.chainid, block.number, nonce)),
            nonce: nonce,
            fee: fee
        });
        oftReceipt = OFTReceipt({amountSentLD: sendParam.amountLD, amountReceivedLD: sendParam.amountLD});

        emit Sent(sendParam.dstEid, sendParam.to, sendParam.amountLD, fee.nativeFee);
    }

    // ── Admin ─────────────────────────────────────────────────────────

    function setNativeFee(uint256 newFee) external onlyOwner {
        nativeFee = newFee;
    }

    /// @notice Withdraw any token held by this contract.
    function withdrawToken(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Withdraw native funds collected from send fees.
    function withdrawNative(address payable to, uint256 amount) external onlyOwner {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "native withdraw failed");
    }

    receive() external payable {}
}
