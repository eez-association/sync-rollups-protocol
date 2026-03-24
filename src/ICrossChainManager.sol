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

/// @notice Describes a sub-call to execute in static context
struct StaticSubCall {
    address destination;
    bytes data;
    address sourceAddress;
    uint256 sourceRollup;
}

/// @notice Pre-computed result for a static call or a call that reverts
/// @dev Used for read-only calls and for calls whose revert needs to be replayed.
///      Loaded via postBatch (L1) or loadExecutionTable (L2).
///      All proxies referenced by `calls` must be deployed before staticCallLookup is called.
struct StaticCall {
    bytes32 actionHash; // keccak256(abi.encode(CALL action)) with value=0
    bytes returnData; // pre-computed return data (or revert payload if failed)
    bool failed; // if true, staticCallLookup reverts with returnData
    uint256 executionIndex; // disambiguates: the executionIndex at the time of this static call
    StaticSubCall[] calls; // sub-calls to execute in static context
    bytes32 rollingHash; // expected hash of all sub-call results (verified on-chain)
}

/// @notice Stores the identity of an authorized CrossChainProxy
struct ProxyInfo {
    address originalAddress;
    uint64 originalRollupId;
}

/// @title ICrossChainManager
/// @notice Interface for cross-chain manager contracts (L1 Rollups and L2 CrossChainManagerL2)
interface ICrossChainManager {
    /// @notice Error when caller is not an authorized proxy
    error UnauthorizedProxy();

    /// @notice Error when only self-calls are allowed (e.g. newScope)
    error OnlySelf();

    /// @notice Error when execution is not found
    error ExecutionNotFound();

    /// @notice Error when a call execution fails
    error CallExecutionFailed();

    /// @notice Error when revert data from a child scope is too short to decode
    error InvalidRevertData();

    /// @notice Error when execution is attempted in a different block than the last state update
    error ExecutionNotInCurrentBlock();

    /// @notice Error when a static call lookup finds no matching entry
    error StaticCallNotFound();

    /// @notice Error when static sub-call results don't match the expected rolling hash
    error RollingHashMismatch();

    /// @notice Error when a static sub-call references a proxy that hasn't been deployed yet
    error ProxyNotDeployed();
    function executeCrossChainCall(
        address sourceAddress,
        bytes calldata callData
    ) external payable returns (bytes memory result);
    function staticCallLookup(
        address sourceAddress,
        bytes calldata callData
    ) external view returns (bytes memory result);
    function createCrossChainProxy(
        address originalAddress,
        uint256 originalRollupId
    ) external returns (address proxy);
    function computeCrossChainProxyAddress(
        address originalAddress,
        uint256 originalRollupId
    ) external view returns (address);
    function newScope(
        uint256[] memory scope,
        Action memory action
    ) external returns (Action memory nextAction);
}
