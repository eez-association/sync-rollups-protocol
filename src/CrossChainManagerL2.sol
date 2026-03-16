// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CrossChainProxy} from "./CrossChainProxy.sol";
import {ICrossChainManager, ActionType, Action, StateDelta, SubCall, ExecutionEntry, ProxyInfo} from "./ICrossChainManager.sol";

/// @title CrossChainManagerL2
/// @notice L2-side contract for cross-chain execution via pre-computed execution tables
/// @dev No rollups, no state deltas, no ZK proofs. System address loads execution tables,
///      which are consumed sequentially via proxy calls (executeCrossChainCall).
contract CrossChainManagerL2 is ICrossChainManager {
    /// @notice The rollup ID this L2 belongs to
    uint256 public immutable ROLLUP_ID;

    /// @notice The system address authorized for admin operations
    address public immutable SYSTEM_ADDRESS;

    /// @notice Array of pre-computed executions
    ExecutionEntry[] public executions;

    /// @notice Mapping of authorized CrossChainProxy contracts to their identity
    mapping(address proxy => ProxyInfo info) public authorizedProxies;

    /// @notice Last block number when execution table was loaded
    uint256 public lastLoadBlock;

    /// @notice Index of the next execution entry to consume
    uint256 public executionIndex;

    /// @notice Error when caller is not the system address
    error Unauthorized();

    /// @notice Error when caller is not a registered CrossChainProxy
    error UnauthorizedProxy();

    /// @notice Error when no matching execution entry exists for the action hash
    error ExecutionNotFound();

    /// @notice Error when execution is attempted in a different block than the last load
    error ExecutionNotInCurrentBlock();

    /// @notice Error when the computed return hash doesn't match the entry's returnHash
    error ReturnHashMismatch();

    /// @notice Carries execution results out of a reverted context
    error ContextResult(bytes32 computedHash, bytes returnData, bool actuallyFailed, uint256 consumedCount);

    /// @notice Error when ETH transfer to system address fails
    error EtherTransferFailed();

    /// @notice Emitted when a new CrossChainProxy is deployed and registered
    event CrossChainProxyCreated(address indexed proxy, address indexed originalAddress, uint256 indexed originalRollupId);

    /// @notice Emitted when execution entries are loaded into the execution table
    event ExecutionTableLoaded(ExecutionEntry[] entries);

    /// @notice Emitted when an execution entry is consumed
    event ExecutionConsumed(bytes32 indexed actionHash, uint256 indexed entryIndex);

    /// @notice Emitted when a cross-chain call is executed via proxy
    event CrossChainCallExecuted(bytes32 indexed actionHash, address indexed proxy, address sourceAddress, bytes callData, uint256 value);

    /// @param _rollupId The rollup ID this L2 instance belongs to
    /// @param _systemAddress The privileged address allowed to load execution tables
    constructor(uint256 _rollupId, address _systemAddress) {
        ROLLUP_ID = _rollupId;
        SYSTEM_ADDRESS = _systemAddress;
    }

    modifier onlySystemAddress() {
        if (msg.sender != SYSTEM_ADDRESS) revert Unauthorized();
        _;
    }

    // ──────────────────────────────────────────────
    //  Admin: load execution table
    // ──────────────────────────────────────────────

    /// @notice Loads execution entries into the execution table (system only)
    /// @dev Clears previous entries and stores new ones. Entries must be consumed in the same block.
    /// @param entries The execution entries to load
    function loadExecutionTable(ExecutionEntry[] calldata entries) external onlySystemAddress {
        // Delete previous execution table and execution index
        delete executions;
        executionIndex = 0;

        for (uint256 i = 0; i < entries.length; i++) {
            executions.push(entries[i]);
        }
        lastLoadBlock = block.number;
        emit ExecutionTableLoaded(entries);
    }

    // ──────────────────────────────────────────────
    //  Execution entry points
    // ──────────────────────────────────────────────

    /// @notice Executes a cross-chain call initiated by an authorized proxy
    /// @param sourceAddress The original caller address (msg.sender as seen by the proxy)
    /// @param callData The original calldata sent to the proxy
    /// @return result The return data from the execution
    function executeCrossChainCall(address sourceAddress, bytes calldata callData) external payable returns (bytes memory result) {
        ProxyInfo storage proxyInfo = authorizedProxies[msg.sender];
        if (proxyInfo.originalAddress == address(0)) revert UnauthorizedProxy();

        // Executions can only be consumed in the same block they were loaded
        if (lastLoadBlock != block.number) revert ExecutionNotInCurrentBlock();

        // burn ether — return to system address
        if (msg.value > 0) {
            (bool success,) = SYSTEM_ADDRESS.call{value: msg.value}("");
            if (!success) revert EtherTransferFailed();
        }

        bytes32 actionHash = _computeActionInputHash(
            ActionType.CALL,
            proxyInfo.originalRollupId,
            proxyInfo.originalAddress,
            msg.value,
            callData,
            sourceAddress,
            ROLLUP_ID
        );
        emit CrossChainCallExecuted(actionHash, msg.sender, sourceAddress, callData, msg.value);

        return _consumeAndExecute(actionHash);
    }

    // ──────────────────────────────────────────────
    //  Proxy creation
    // ──────────────────────────────────────────────

    /// @notice Creates a new CrossChainProxy for an address on another rollup
    /// @param originalAddress The address this proxy represents on the source rollup
    /// @param originalRollupId The source rollup ID
    /// @return proxy The deployed proxy address
    function createCrossChainProxy(address originalAddress, uint256 originalRollupId) external returns (address proxy) {
        return _createProxyInternal(originalAddress, originalRollupId);
    }

    // ──────────────────────────────────────────────
    //  Internal helpers
    // ──────────────────────────────────────────────

    /// @notice Deploys a CrossChainProxy via CREATE2 and registers it as authorized
    function _createProxyInternal(address originalAddress, uint256 originalRollupId) internal returns (address proxy) {
        bytes32 salt = keccak256(abi.encodePacked(originalRollupId, originalAddress));
        proxy = address(new CrossChainProxy{salt: salt}(address(this), originalAddress, originalRollupId));
        authorizedProxies[proxy] = ProxyInfo(originalAddress, uint64(originalRollupId));
        emit CrossChainProxyCreated(proxy, originalAddress, originalRollupId);
    }

    /// @notice Consumes the next execution entry, executes calls, and verifies return hash
    /// @param actionHash The expected action input hash for the next entry
    /// @return result The pre-computed return data from the action
    function _consumeAndExecute(bytes32 actionHash) internal returns (bytes memory result) {
        uint256 idx = executionIndex;
        if (idx >= executions.length) revert ExecutionNotFound();
        ExecutionEntry storage entry = executions[idx];
        if (_computeActionInputHash(entry.action.actionType, entry.action.rollupId, entry.action.destination, entry.action.value, entry.action.data, entry.action.sourceAddress, entry.action.sourceRollup) != actionHash) revert ExecutionNotFound();

        // Copy entry data before advancing index
        SubCall[] memory calls = entry.calls;
        bytes32 expectedReturnHash = entry.returnHash;
        bool failed = entry.failed;
        bytes memory returnData = entry.returnData;
        executionIndex = idx + 1;

        emit ExecutionConsumed(actionHash, idx);

        // Execute all calls and verify return hash
        _executeCallsAndVerify(calls, expectedReturnHash);

        // If the action failed, revert with the return data
        if (failed) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }

        return returnData;
    }

    /// @notice Executes sub-calls in an isolated context that always reverts (for failed subcalls)
    /// @dev Can only be called by this contract. Results are encoded in the ContextResult revert.
    function executeInContext(SubCall[] calldata calls) external {
        if (msg.sender != address(this)) revert UnauthorizedProxy();
        (bytes32 computedHash, bytes memory returnData, bool actuallyFailed, uint256 consumed) =
            _processSubCalls(calls);
        revert ContextResult(computedHash, returnData, actuallyFailed, consumed);
    }

    /// @notice Processes sub-calls, opening new contexts for failed subcalls
    function _processSubCalls(SubCall[] memory calls) internal returns (
        bytes32 computedHash,
        bytes memory returnData,
        bool actuallyFailed,
        uint256 consumed
    ) {
        uint256 i = 0;
        while (i < calls.length) {
            SubCall memory sub = calls[i];

            if (sub.failed) {
                uint256 endIdx = i + 1;
                while (endIdx < calls.length && calls[endIdx].contextDepth > sub.contextDepth) {
                    endIdx++;
                }

                SubCall[] memory contextCalls = new SubCall[](endIdx - i);
                for (uint256 j = i; j < endIdx; j++) {
                    contextCalls[j - i] = calls[j];
                }

                try this.executeInContext(contextCalls) {
                    // unreachable
                } catch (bytes memory revertData) {
                    (bytes32 ctxHash, bytes memory ctxReturnData, bool ctxFailed,) =
                        _decodeContextResult(revertData);
                    computedHash = keccak256(abi.encodePacked(computedHash, ctxHash));
                    if (i == 0) {
                        returnData = ctxReturnData;
                        actuallyFailed = ctxFailed;
                    }
                }

                i = endIdx;
            } else {
                address sourceProxy = computeCrossChainProxyAddress(sub.sourceAddress, sub.sourceRollup);
                if (authorizedProxies[sourceProxy].originalAddress == address(0)) {
                    _createProxyInternal(sub.sourceAddress, sub.sourceRollup);
                }

                (bool success, bytes memory retData) = sourceProxy.call{value: sub.value}(
                    abi.encodeCall(CrossChainProxy.executeOnBehalf, (sub.destination, sub.data))
                );

                computedHash = keccak256(abi.encodePacked(computedHash, success, retData));

                if (i == 0) {
                    returnData = retData;
                    actuallyFailed = !success;
                }

                i++;
            }
        }
        consumed = calls.length;
    }

    /// @notice Decodes a ContextResult revert payload
    function _decodeContextResult(bytes memory revertData) internal pure returns (
        bytes32 computedHash, bytes memory returnData, bool actuallyFailed, uint256 consumedCount
    ) {
        assembly {
            let len := mload(revertData)
            revertData := add(revertData, 4)
            mstore(revertData, sub(len, 4))
        }
        return abi.decode(revertData, (bytes32, bytes, bool, uint256));
    }

    /// @notice Executes all sub-calls and verifies the return hash
    function _executeCallsAndVerify(SubCall[] memory calls, bytes32 expectedReturnHash) internal {
        (bytes32 computedHash,,,) = _processSubCalls(calls);
        if (computedHash != expectedReturnHash) revert ReturnHashMismatch();
    }

    // ──────────────────────────────────────────────
    //  Action hash helpers
    // ──────────────────────────────────────────────

    /// @notice Computes the action input hash from individual fields
    function _computeActionInputHash(
        ActionType actionType,
        uint256 rollupId,
        address destination,
        uint256 value,
        bytes memory data,
        address sourceAddress,
        uint256 sourceRollup
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(actionType, rollupId, destination, value, data, sourceAddress, sourceRollup));
    }

    // ──────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────

    /// @notice Computes the deterministic CREATE2 address for a CrossChainProxy
    /// @param originalAddress The address this proxy represents on the source rollup
    /// @param originalRollupId The source rollup ID
    /// @return The computed proxy address
    function computeCrossChainProxyAddress(
        address originalAddress,
        uint256 originalRollupId
    ) public view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(originalRollupId, originalAddress));
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(
                type(CrossChainProxy).creationCode,
                abi.encode(address(this), originalAddress, originalRollupId)
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)))));
    }
}
