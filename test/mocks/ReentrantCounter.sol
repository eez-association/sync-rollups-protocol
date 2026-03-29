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
    /// @dev Increment happens AFTER the nested call, so the innermost call (remainingCalls=0)
    ///      gets count=1 and the outermost gets the highest. Due to reentrancy on each
    ///      chain, L1 count = 3 and L2 count = 3 for 5 reentrant cross-chain calls.
    function deepCall(uint256 remainingCalls) external returns (uint256) {
        if (remainingCalls > 0) {
            ReentrantCounter(peer).deepCall(remainingCalls - 1);
        }
        return ++count;
    }
}
