// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ReentrantCounter
/// @notice Counter that chains reentrant cross-chain calls.
///         Same contract code is deployed on both L1 and L2.
///         `peer` is the local proxy for the other chain's ReentrantCounter.
contract ReentrantCounter {
    uint256 public count;
    address public peer;

    constructor(address _peer) {
        peer = _peer;
    }

    function setPeer(address _peer) external {
        peer = _peer;
    }

    /// @notice Makes a cross-chain call if remainingCalls > 0, then increments and returns count.
    function deepCall(uint256 remainingCalls) external returns (uint256) {
        if (remainingCalls > 0) {
            ReentrantCounter(peer).deepCall(remainingCalls - 1);
        }
        return ++count;
    }
}
