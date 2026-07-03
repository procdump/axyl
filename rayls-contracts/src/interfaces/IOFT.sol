// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IOFT
/// @notice Minimal interface for LayerZero OFT (Omnichain Fungible Token) cross-chain sends.
/// @dev Matches layerzerolabs/oft-evm send interface. The OFTAdapter will be deployed by LayerZero.
interface IOFT {
    struct SendParam {
        uint32 dstEid;
        bytes32 to;
        uint256 amountLD;
        uint256 minAmountLD;
        bytes extraOptions;
        bytes composeMsg;
        bytes oftCmd;
    }

    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

    struct MessagingReceipt {
        bytes32 guid;
        uint64 nonce;
        MessagingFee fee;
    }

    struct OFTReceipt {
        uint256 amountSentLD;
        uint256 amountReceivedLD;
    }

    /// @notice Estimate the messaging fee for a cross-chain send.
    function quoteSend(
        SendParam calldata _sendParam,
        bool _payInLzToken
    ) external view returns (MessagingFee memory);

    /// @notice Send tokens cross-chain via LayerZero.
    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    ) external payable returns (MessagingReceipt memory, OFTReceipt memory);
}
