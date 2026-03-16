// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Action types used to identify execution entry entrypoints
enum ActionType {
    CALL, // A cross-chain call to execute on the destination rollup
    L2TX // A pre-computed L2 transaction (RLP-encoded, permissionless)
}

/// @notice Represents an action used to build the entrypoint hash
struct Action {
    ActionType actionType;
    uint256 rollupId;
    address destination;
    uint256 value;
    bytes data;
    address sourceAddress;
    uint256 sourceRollup;
    bool failed;
    bytes returnData;
}

/// @notice Represents a state delta
struct StateDelta {
    uint256 rollupId;
    bytes32 newState;
    int256 etherDelta;
}

/// @notice Represents a cross-chain call within an execution entry
struct SubCall {
    address destination;
    uint256 value;
    bytes data;
    address sourceAddress;
    uint256 sourceRollup;
    bool failed;
    uint256 contextDepth;
}

/// @notice Represents an execution entry with pre-computed calls and return hash verification
struct ExecutionEntry {
    StateDelta[] stateDeltas;
    Action action;
    SubCall[] calls;
    bytes returnData;
    bool failed;
    bytes32 returnHash;
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
}
