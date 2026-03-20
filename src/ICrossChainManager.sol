// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Action types used in the cross-chain execution protocol
enum ActionType {
    CALL, // A cross-chain call to execute on the destination rollup
    RESULT, // The result of a CALL (success/failure + return data)
    // END, // END Tx, go from result to this
    L2TX, // A pre-computed L2 transaction (RLP-encoded, permissionless)
    REVERT, // Signals a scope revert — triggers state rollback
    REVERT_CONTINUE // Continuation action after a REVERT, looked up from the execution table
}

/// @notice Represents an action in the state transition
struct Action {
    ActionType actionType;
    uint256 rollupId;
    address destination;
    uint256 value;
    bytes data;
    bool failed;
    address sourceAddress;
    uint256 sourceRollup;
    uint256[] scope;
}

/// @notice Represents a state delta
struct StateDelta {
    uint256 rollupId;
    bytes32 currentState;
    bytes32 newState;
    int256 etherDelta;
}

/// @notice Represents a state transition entry (immediate or deferred)
struct ExecutionEntry {
    StateDelta[] stateDeltas;
    bytes32 actionHash;
    Action nextAction;
}

/// @notice Stores the identity of an authorized CrossChainProxy
struct ProxyInfo {
    address originalAddress;
    uint64 originalRollupId;
}

/// @title ICrossChainManager
/// @notice Interface for cross-chain manager contracts (L1 Rollups and L2 CrossChainManagerL2)
interface ICrossChainManager {
    function executeCrossChainCall(address sourceAddress, bytes calldata callData)
        external
        payable
        returns (bytes memory result);
    function createCrossChainProxy(address originalAddress, uint256 originalRollupId) external returns (address proxy);
    function computeCrossChainProxyAddress(address originalAddress, uint256 originalRollupId)
        external
        view
        returns (address);
    function newScope(uint256[] memory scope, Action memory action) external returns (Action memory nextAction);
}
