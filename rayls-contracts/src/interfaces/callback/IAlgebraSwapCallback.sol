// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @notice Callback interface that must be implemented by any contract calling `IAlgebraPool.swap`.
/// @dev The pool invokes this on `msg.sender` mid-swap to collect the tokens owed.
///      The implementor must verify the caller is a legitimate Algebra pool before transferring.
interface IAlgebraSwapCallback {
    /// @notice Invoked by the pool after a swap to collect the tokens owed by the caller.
    /// @dev Both deltas may be zero when no tokens changed hands.
    ///      A positive delta means the pool expects that amount to be sent to it.
    ///      A negative delta means the pool is sending that amount to the recipient.
    /// @param amount0Delta Token0 amount owed to (positive) or received from (negative) the pool.
    /// @param amount1Delta Token1 amount owed to (positive) or received from (negative) the pool.
    /// @param data Caller-supplied data forwarded from the original `swap` call.
    function algebraSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}
