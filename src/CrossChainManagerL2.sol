// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CrossChainProxy} from "./CrossChainProxy.sol";
import {ICrossChainManager, ActionType, Action, ExecutionEntry, ProxyInfo} from "./ICrossChainManager.sol";

/// @title CrossChainManagerL2
/// @notice L2-side contract for cross-chain execution via pre-computed execution tables
/// @dev No rollups, no state deltas, no ZK proofs. System address loads execution tables,
///      which are consumed via proxy calls (executeCrossChainCall) or system executeIncomingCrossChainCall.
contract CrossChainManagerL2 is ICrossChainManager {
    /// @notice The rollup ID this L2 belongs to
    uint256 public immutable ROLLUP_ID;

    /// @notice The system address authorized for admin operations
    address public immutable SYSTEM_ADDRESS;

    /// @notice Mapping from action hash to pre-computed executions
    mapping(bytes32 actionHash => ExecutionEntry[] executions) internal _executions;

    /// @notice Mapping of authorized CrossChainProxy contracts to their identity
    mapping(address proxy => ProxyInfo info) public authorizedProxies;

    /// @notice Number of pending (unconsumed) execution entries in the table
    uint256 public pendingEntryCount;

    /// @notice Error when caller is not the system address
    error Unauthorized();

    /// @notice Error when caller is not a registered CrossChainProxy
    error UnauthorizedProxy();

    /// @notice Error when no matching execution entry exists for the action hash
    error ExecutionNotFound();

    /// @notice Error when a cross-chain call resolves to a failed or non-RESULT action
    error CallExecutionFailed();

    /// @notice Error used to unwind scope during revert handling, carrying the continuation action
    /// @param nextAction The ABI-encoded continuation action to resume with after the revert
    error ScopeReverted(bytes nextAction);

    /// @notice Error when revert data from a child scope is too short to decode
    error InvalidRevertData();

    /// @notice Emitted when a new CrossChainProxy is deployed and registered
    event CrossChainProxyCreated(address indexed proxy, address indexed originalAddress, uint256 indexed originalRollupId);

    /// @param _rollupId The rollup ID this L2 instance belongs to
    /// @param _systemAddress The privileged address allowed to load execution tables and call executeIncomingCrossChainCall
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
    /// @param entries The execution entries to load
    function loadExecutionTable(ExecutionEntry[] calldata entries) external onlySystemAddress {
        for (uint256 i = 0; i < entries.length; i++) {
            _executions[entries[i].actionHash].push(entries[i]);
        }
        pendingEntryCount += entries.length;
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

        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: proxyInfo.originalRollupId,
            destination: proxyInfo.originalAddress,
            value: msg.value,
            data: callData,
            failed: false,
            sourceAddress: sourceAddress,
            sourceRollup: ROLLUP_ID,
            scope: new uint256[](0)
        });

        bytes32 actionHash = keccak256(abi.encode(action));
        Action memory nextAction = _consumeExecution(actionHash);
        return _resolveScopes(nextAction);
    }

    /// @notice Executes a remote cross-chain call (system only)
    /// @dev The rollupId is always this contract's rollupId
    /// @param destination The destination address
    /// @param value The ETH value to send
    /// @param data The calldata for the call
    /// @param sourceAddress The original caller address on the source chain
    /// @param sourceRollup The source rollup ID
    /// @param scope The scope for nested call navigation
    /// @return result The return data from the execution
    function executeIncomingCrossChainCall(
        address destination,
        uint256 value,
        bytes calldata data,
        address sourceAddress,
        uint256 sourceRollup,
        uint256[] calldata scope
    ) external onlySystemAddress returns (bytes memory result) {
        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: ROLLUP_ID,
            destination: destination,
            value: value,
            data: data,
            failed: false,
            sourceAddress: sourceAddress,
            sourceRollup: sourceRollup,
            scope: scope
        });

        uint256[] memory emptyScope = new uint256[](0);
        Action memory nextAction;
        try this.newScope(emptyScope, action) returns (Action memory retAction) {
            nextAction = retAction;
        } catch (bytes memory revertData) {
            nextAction = _handleScopeRevert(revertData);
        }

        if (nextAction.actionType != ActionType.RESULT || nextAction.failed) {
            revert CallExecutionFailed();
        }
        return nextAction.data;
    }

    // ──────────────────────────────────────────────
    //  Scope navigation
    // ──────────────────────────────────────────────

    /// @notice Recursively navigates the scope tree to execute nested cross-chain calls
    /// @dev Called via `this.newScope()` (external self-call) so that try/catch can isolate reverts
    ///      per scope level. Each scope level processes CALL actions at its depth, delegates deeper
    ///      scopes to recursive calls, and bubbles up REVERT actions via ScopeReverted.
    /// @param scope The current scope level (e.g., [0] means first child of root)
    /// @param action The action to start processing at this scope level
    /// @return nextAction The resulting action after scope processing (RESULT, or a CALL/REVERT for a parent scope)
    function newScope(
        uint256[] memory scope,
        Action memory action
    ) external returns (Action memory nextAction) {
        if (msg.sender != address(this) && authorizedProxies[msg.sender].originalAddress == address(0)) {
            revert UnauthorizedProxy();
        }

        nextAction = action;

        while (true) {
            if (nextAction.actionType == ActionType.CALL) {
                if (_isChildScope(scope, nextAction.scope)) {
                    // Target is deeper — recurse into child scope
                    uint256[] memory newScopeArr = _appendToScope(scope, nextAction.scope[scope.length]);
                    try this.newScope(newScopeArr, nextAction) returns (Action memory retAction) {
                        nextAction = retAction;
                    } catch (bytes memory revertData) {
                        nextAction = _handleScopeRevert(revertData);
                    }
                } else if (_scopesMatch(scope, nextAction.scope)) {
                    // At target scope — execute the call via source proxy
                    (, nextAction) = _processCallAtScope(scope, nextAction);
                } else {
                    // Action belongs to a parent/sibling scope — return to caller
                    break;
                }
            } else if (nextAction.actionType == ActionType.REVERT) {
                if (_scopesMatch(scope, nextAction.scope)) {
                    // Revert at this scope — look up continuation and bubble up via ScopeReverted
                    Action memory continuation = _getRevertContinuation(nextAction.rollupId);
                    revert ScopeReverted(abi.encode(continuation));
                } else {
                    break;
                }
            } else {
                // RESULT or other — return to caller
                break;
            }
        }

        return nextAction;
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
        bytes32 salt = keccak256(abi.encodePacked(block.chainid, originalRollupId, originalAddress));
        proxy = address(new CrossChainProxy{salt: salt}(address(this), originalAddress, originalRollupId));
        authorizedProxies[proxy] = ProxyInfo(originalAddress, uint64(originalRollupId));
        emit CrossChainProxyCreated(proxy, originalAddress, originalRollupId);
    }

    /// @notice Consumes the last execution entry for the given action hash
    function _consumeExecution(bytes32 actionHash) internal returns (Action memory nextAction) {
        ExecutionEntry[] storage executions = _executions[actionHash];
        if (executions.length == 0) revert ExecutionNotFound();

        // Save the next action before removing the entry
        nextAction = executions[0].nextAction;
        // Swap-and-pop: move the last entry into the consumed slot, then remove the last element
        executions[0] = executions[executions.length - 1];
        executions.pop();
        pendingEntryCount--;

        return nextAction;
    }

    /// @notice If nextAction is a CALL, enters scope navigation; then asserts a successful RESULT
    /// @param nextAction The action to resolve (CALL triggers scope navigation, RESULT returns directly)
    /// @return result The return data from the resolved execution
    function _resolveScopes(Action memory nextAction) internal returns (bytes memory result) {
        if (nextAction.actionType == ActionType.CALL) {
            uint256[] memory emptyScope = new uint256[](0);
            try this.newScope(emptyScope, nextAction) returns (Action memory retAction) {
                nextAction = retAction;
            } catch (bytes memory revertData) {
                nextAction = _handleScopeRevert(revertData);
            }
        }

        if (nextAction.actionType != ActionType.RESULT || nextAction.failed) {
            revert CallExecutionFailed();
        }
        return nextAction.data;
    }

    /// @notice Executes a CALL action at the current scope by forwarding through the source proxy
    /// @dev Auto-creates the source proxy if it doesn't exist yet. After execution, builds a
    ///      RESULT action from the call outcome and consumes the next execution entry.
    /// @param currentScope The current scope level
    /// @param action The CALL action to execute
    /// @return scope The scope after processing (always currentScope)
    /// @return nextAction The next action from the execution table
    function _processCallAtScope(
        uint256[] memory currentScope,
        Action memory action
    ) internal returns (uint256[] memory scope, Action memory nextAction) {
        address sourceProxy = computeCrossChainProxyAddress(
            action.sourceAddress,
            action.sourceRollup,
            block.chainid
        );

        if (authorizedProxies[sourceProxy].originalAddress == address(0)) {
            _createProxyInternal(action.sourceAddress, action.sourceRollup);
        }

        (bool success, bytes memory returnData) = address(sourceProxy).call{value: action.value}(
            abi.encodeCall(CrossChainProxy.executeOnBehalf, (action.destination, action.data))
        );

        Action memory resultAction = Action({
            actionType: ActionType.RESULT,
            rollupId: action.rollupId,
            destination: address(0),
            value: 0,
            data: returnData,
            failed: !success,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        bytes32 resultHash = keccak256(abi.encode(resultAction));
        nextAction = _consumeExecution(resultHash);

        return (currentScope, nextAction);
    }

    /// @notice Decodes a ScopeReverted error's payload back into a continuation Action
    /// @param revertData The raw revert bytes (includes the 4-byte selector)
    /// @return nextAction The decoded continuation action
    function _handleScopeRevert(bytes memory revertData) internal pure returns (Action memory nextAction) {
        if (revertData.length <= 4) revert InvalidRevertData();

        // Strip 4-byte selector by advancing the memory pointer
        assembly {
            let len := mload(revertData)
            revertData := add(revertData, 4)
            mstore(revertData, sub(len, 4))
        }

        (bytes memory actionBytes) = abi.decode(revertData, (bytes));
        return abi.decode(actionBytes, (Action));
    }

    /// @notice Builds a REVERT_CONTINUE action and looks up the next action from the execution table
    /// @param rollupId The rollup ID that reverted
    /// @return nextAction The continuation action after the revert
    function _getRevertContinuation(uint256 rollupId) internal returns (Action memory nextAction) {
        Action memory revertContinueAction = Action({
            actionType: ActionType.REVERT_CONTINUE,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: "",
            failed: true,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        bytes32 revertHash = keccak256(abi.encode(revertContinueAction));
        return _consumeExecution(revertHash);
    }

    /// @notice Appends an element to a scope array, creating a new child scope level
    function _appendToScope(uint256[] memory scope, uint256 element) internal pure returns (uint256[] memory) {
        uint256[] memory result = new uint256[](scope.length + 1);
        for (uint256 i = 0; i < scope.length; i++) {
            result[i] = scope[i];
        }
        result[scope.length] = element;
        return result;
    }

    /// @notice Returns true if two scope arrays are identical
    function _scopesMatch(uint256[] memory a, uint256[] memory b) internal pure returns (bool) {
        if (a.length != b.length) return false;
        for (uint256 i = 0; i < a.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    /// @notice Returns true if targetScope is strictly deeper than currentScope (shares its prefix)
    function _isChildScope(uint256[] memory currentScope, uint256[] memory targetScope) internal pure returns (bool) {
        if (targetScope.length <= currentScope.length) return false;
        for (uint256 i = 0; i < currentScope.length; i++) {
            if (currentScope[i] != targetScope[i]) return false;
        }
        return true;
    }

    // ──────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────

    /// @notice Computes the deterministic CREATE2 address for a CrossChainProxy
    /// @param originalAddress The address this proxy represents on the source rollup
    /// @param originalRollupId The source rollup ID
    /// @param domain The domain (chain ID) used in the CREATE2 salt
    /// @return The computed proxy address
    function computeCrossChainProxyAddress(
        address originalAddress,
        uint256 originalRollupId,
        uint256 domain
    ) public view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(domain, originalRollupId, originalAddress));
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(
                type(CrossChainProxy).creationCode,
                abi.encode(address(this), originalAddress, originalRollupId)
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)))));
    }
}
