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
    bool isStatic; // if true, the CALL must be executed via STATICCALL to the source proxy
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

/// @notice (rollupId, stateRoot) pair pinning the state at which a static call result is valid
struct RollupStateRoot {
    uint256 rollupId;
    bytes32 stateRoot;
}

/// @notice A flat STATICCALL sub-call dependency that the target view function invokes through a source proxy
/// @dev Each sub-call is re-executed at lookup time via the computed source proxy; results are chained into `rollingHash`.
struct StaticSubCall {
    address destination;
    bytes data;
    address sourceAddress;
    uint256 sourceRollup;
}

/// @notice Pre-computed result for a static (read-only) cross-chain call
/// @dev Matched by actionHash. If `failed`, staticCallLookup replays `returnData` as the revert payload.
///      `stateRoots` pins the rollup state roots under which `returnData` is valid; the lookup
///      rejects if any listed rollup's current stateRoot diverges from the expected value.
///      `calls` is the flat list of STATICCALL dependencies replayed in order; their chained
///      keccak256 digest must equal `rollingHash` or the lookup reverts.
struct StaticCall {
    bytes32 actionHash; // keccak256(abi.encode(CALL action)) isStatic=true
    bytes returnData; // pre-computed return data (or revert payload if failed)
    bool failed; // if true, staticCallLookup reverts with returnData
    StaticSubCall[] calls; // flat list of STATICCALL sub-calls to re-execute and fold into rollingHash
    bytes32 rollingHash; // keccak-chain over sub-call (success, retData); must match _processNStaticCalls output
    RollupStateRoot[] stateRoots; // rollup state roots this result is valid against (L1 only)
}

/// @notice Stores the identity of an authorized CrossChainProxy
struct ProxyInfo {
    address originalAddress;
    uint64 originalRollupId;
}

/// @title ICrossChainManager
/// @notice Interface for cross-chain manager contracts (L1 Rollups and L2 CrossChainManagerL2)
interface ICrossChainManager {
    /// @notice Error when a static call lookup finds no matching entry
    error StaticCallNotFound();

    /// @notice Error when a pinned rollup stateRoot on the StaticCall entry does not match current state
    error StaticCallStateRootMismatch();

    /// @notice Error when a StaticCall entry carries non-empty stateRoots on a manager that does not support pinning (L2)
    error StaticCallStateRootsNotSupported();

    /// @notice Error when the replayed sub-call rolling hash does not match the entry's committed `rollingHash`
    error RollingHashMismatch();

    /// @notice Error when a sub-call's source proxy has not been deployed at lookup time
    error ProxyNotDeployed();

    /// @notice Error when two StaticCall entries share the same `actionHash` within one load
    error DuplicateStaticCallActionHash();

    function executeCrossChainCall(address sourceAddress, bytes calldata callData)
        external
        payable
        returns (bytes memory result);
    function staticCallLookup(address sourceAddress, bytes calldata callData)
        external
        view
        returns (bytes memory result);
    function createCrossChainProxy(address originalAddress, uint256 originalRollupId) external returns (address proxy);
    function computeCrossChainProxyAddress(address originalAddress, uint256 originalRollupId)
        external
        view
        returns (address);
    function newScope(uint256[] memory scope, Action memory action) external returns (Action memory nextAction);
}
