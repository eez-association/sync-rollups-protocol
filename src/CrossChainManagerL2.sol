// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CrossChainProxy} from "./CrossChainProxy.sol";
import {
    ICrossChainManager,
    ActionType,
    Action,
    ExecutionEntry,
    StaticCall,
    StaticSubCall,
    ProxyInfo
} from "./ICrossChainManager.sol";

/// @title CrossChainManagerL2
/// @notice L2-side contract for cross-chain execution via pre-computed execution tables
/// @dev No rollups, no state deltas, no ZK proofs. System address loads execution tables,
///      which are consumed via proxy calls (executeCrossChainCall) or system executeIncomingCrossChainCall.
contract CrossChainManagerL2 is ICrossChainManager {
    /// @notice The rollup ID this L2 belongs to
    uint256 public immutable ROLLUP_ID;

    /// @notice The system address authorized for admin operations
    address public immutable SYSTEM_ADDRESS;

    /// @notice Array of pre-computed executions
    ExecutionEntry[] public executions;

    /// @notice Array of pre-computed static call results
    /// @dev Populated by loadExecutionTable alongside executions; staticCallLookup reverts StaticCallNotFound if not present
    StaticCall[] public staticCalls;

    /// @notice Mapping of authorized CrossChainProxy contracts to their identity
    mapping(address proxy => ProxyInfo info) public authorizedProxies;

    /// @notice Last block number when the execution table was loaded
    uint256 public lastStateUpdateBlock;

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

    /// @notice Error when ETH transfer to system address fails
    error EtherTransferFailed();

    /// @notice Error when execution is attempted in a different block than the last table load
    error ExecutionNotInCurrentBlock();

    /// @notice Emitted when a new CrossChainProxy is deployed and registered
    event CrossChainProxyCreated(address indexed proxy, address indexed originalAddress, uint256 indexed originalRollupId);

    /// @notice Emitted when execution entries are loaded into the execution table
    event ExecutionTableLoaded(ExecutionEntry[] entries);

    /// @notice Emitted when an execution entry is consumed from the execution table
    event ExecutionConsumed(bytes32 indexed actionHash, Action action);

    /// @notice Emitted when a cross-chain call is executed via proxy
    event CrossChainCallExecuted(bytes32 indexed actionHash, address indexed proxy, address sourceAddress, bytes callData, uint256 value);

    /// @notice Emitted when an incoming cross-chain call is executed via system address
    event IncomingCrossChainCallExecuted(bytes32 indexed actionHash, address destination, uint256 value, bytes data, address sourceAddress, uint256 sourceRollup, uint256[] scope);

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
    /// @dev Deletes the previous execution table before loading new entries
    /// @param entries The execution entries to load
    /// @param _staticCalls The static call table to load
    function loadExecutionTable(ExecutionEntry[] calldata entries, StaticCall[] calldata _staticCalls) external onlySystemAddress {
        // Uniqueness pre-check: on L2 there is no stateRoots disambiguator, so two entries sharing an
        // actionHash would collide at lookup time (first-match-wins). Reject the whole batch instead.
        for (uint256 i = 0; i < _staticCalls.length; i++) {
            for (uint256 j = i + 1; j < _staticCalls.length; j++) {
                if (_staticCalls[i].actionHash == _staticCalls[j].actionHash) {
                    revert DuplicateStaticCallActionHash();
                }
            }
        }

        // Delete previous execution table
        delete executions;
        delete staticCalls;

        for (uint256 i = 0; i < entries.length; i++) {
            executions.push(entries[i]);
        }

        for (uint256 i = 0; i < _staticCalls.length; i++) {
            staticCalls.push(_staticCalls[i]);
        }

        lastStateUpdateBlock = block.number;
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
        if (proxyInfo.originalAddress == address(0)) {
            revert UnauthorizedProxy();
        }

        // Executions can only be consumed in the same block they were posted
        if (lastStateUpdateBlock != block.number) {
            revert ExecutionNotInCurrentBlock();
        }

        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: proxyInfo.originalRollupId,
            destination: proxyInfo.originalAddress,
            value: msg.value,
            data: callData,
            failed: false,
            isStatic: false,
            sourceAddress: sourceAddress,
            sourceRollup: ROLLUP_ID,
            scope: new uint256[](0)
        });
        
        // burn ether — return to system address
        if (msg.value > 0) {
            (bool success,) = SYSTEM_ADDRESS.call{value: msg.value}("");
            if (!success) revert EtherTransferFailed();
        }

        bytes32 actionHash = keccak256(abi.encode(action));
        emit CrossChainCallExecuted(actionHash, msg.sender, sourceAddress, callData, msg.value);
        Action memory nextAction = _consumeExecution(actionHash, action);
        return _resolveScopes(nextAction);
    }

    // ──────────────────────────────────────────────
    //  Static call lookup
    // ──────────────────────────────────────────────

    /// @notice Looks up a pre-computed result for a static (read-only) cross-chain call
    /// @dev Called by CrossChainProxy when it detects a STATICCALL context.
    ///      msg.sender must be an authorized proxy. Matches by actionHash.
    ///      If the entry is marked as failed, reverts with the pre-computed returnData.
    /// @param sourceAddress The original caller address (msg.sender as seen by the proxy)
    /// @param callData The original calldata sent to the proxy
    /// @return result The pre-computed return data
    function staticCallLookup(
        address sourceAddress,
        bytes calldata callData
    ) external view returns (bytes memory result) {
        ProxyInfo storage proxyInfo = authorizedProxies[msg.sender];
        if (proxyInfo.originalAddress == address(0)) {
            revert UnauthorizedProxy();
        }

        // Executions can only be consumed in the same block they were posted
        if (lastStateUpdateBlock != block.number) {
            revert ExecutionNotInCurrentBlock();
        }

        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: proxyInfo.originalRollupId,
            destination: proxyInfo.originalAddress,
            value: 0,
            data: callData,
            failed: false,
            isStatic: true,
            sourceAddress: sourceAddress,
            sourceRollup: ROLLUP_ID,
            scope: new uint256[](0)
        });

        bytes32 actionHash = keccak256(abi.encode(action));

        for (uint256 i = 0; i < staticCalls.length; i++) {
            StaticCall storage sc = staticCalls[i];
            if (sc.actionHash == actionHash) {
                // L2 has no rollup stateRoot mapping; entries must not pin any.
                if (sc.stateRoots.length != 0) revert StaticCallStateRootsNotSupported();
                // Replay flat sub-call dependencies and verify their rolling hash
                if (sc.calls.length > 0) {
                    if (_processNStaticCalls(sc.calls) != sc.rollingHash) revert RollingHashMismatch();
                }
                if (sc.failed) {
                    bytes memory returnData = sc.returnData;
                    assembly {
                        revert(add(returnData, 0x20), mload(returnData))
                    }
                }
                return sc.returnData;
            }
        }

        revert StaticCallNotFound();
    }

    /// @notice Re-executes the flat list of sub-call dependencies via their source proxies and folds
    ///         `(success, subCallReturnData)` into a rolling keccak chain used to verify `StaticCall.rollingHash`.
    /// @dev Static calls cannot mutate state, so this helper can replay every sub-call in a flat loop
    ///      without any of the bookkeeping the normal execution path needs: no scope tree, no
    ///      try/catch for `ScopeReverted`, no `REVERT_CONTINUE` lookup, no partial-revert rollback,
    ///      no state-delta application. Individual sub-calls may legitimately revert — we still fold
    ///      `(success=false, returnData)` into the rolling hash and keep going. The only invariant the
    ///      caller needs is that the final `rollingHash` matches the prover-committed value.
    ///      Must run in a `view` context — STATICCALL forbids SSTORE/TSTORE, and `staticCallLookup`
    ///      is itself reached via STATICCALL from the proxy, so this helper is read-only too.
    ///      Each sub-call's source proxy must already be deployed; otherwise reverts `ProxyNotDeployed`.
    /// @param subCalls The flat sub-call dependency list (storage ref)
    /// @return rollingHash The rolling keccak256 digest chained over each sub-call's (success, returnData)
    function _processNStaticCalls(
        StaticSubCall[] storage subCalls
    ) internal view returns (bytes32 rollingHash) {
        for (uint256 i = 0; i < subCalls.length; i++) {
            StaticSubCall storage subCall = subCalls[i];
            address sourceProxy = computeCrossChainProxyAddress(subCall.sourceAddress, subCall.sourceRollup);
            if (sourceProxy.code.length == 0) revert ProxyNotDeployed();
            (bool success, bytes memory subCallReturnData) = sourceProxy.staticcall(
                abi.encodeCall(CrossChainProxy.executeOnBehalf, (subCall.destination, subCall.data))
            );
            rollingHash = keccak256(abi.encodePacked(rollingHash, success, subCallReturnData));
        }
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
    ) external payable onlySystemAddress returns (bytes memory result) {
        if (lastStateUpdateBlock != block.number) {
            revert ExecutionNotInCurrentBlock();
        }

        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: ROLLUP_ID,
            destination: destination,
            value: value,
            data: data,
            failed: false,
            isStatic: false,
            sourceAddress: sourceAddress,
            sourceRollup: sourceRollup,
            scope: scope
        });

        bytes32 actionHash = keccak256(abi.encode(action));
        emit IncomingCrossChainCallExecuted(actionHash, destination, value, data, sourceAddress, sourceRollup, scope);

        return _resolveScopes(action);
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
        if (msg.sender != address(this)) {
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
        bytes32 salt = keccak256(abi.encodePacked(originalRollupId, originalAddress));
        proxy = address(new CrossChainProxy{salt: salt}(address(this), originalAddress, originalRollupId));
        authorizedProxies[proxy] = ProxyInfo(originalAddress, uint64(originalRollupId));
        emit CrossChainProxyCreated(proxy, originalAddress, originalRollupId);
    }

    /// @notice Finds a matching execution for the given action hash, marks it as consumed, and returns the next action
    function _consumeExecution(bytes32 actionHash, Action memory action) internal returns (Action memory nextAction) {
        for (uint256 i = 0; i < executions.length; i++) {
            // TODO, multiple executions with same action hahs, were 1 reverts and the other no, in the same block is NOT supported
            // This can happen if between 2 executions theres some update on L1 state
            // Prob will need table to add L1 state or/and system address updating l1 state
            if (executions[i].actionHash != actionHash) continue;

            nextAction = executions[i].nextAction;

            // Mark as consumed (preserves insertion order for duplicate action hashes)
            executions[i].actionHash = bytes32(0);

            emit ExecutionConsumed(actionHash, action);
            return nextAction;
        }

        revert ExecutionNotFound();
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

        if (nextAction.actionType != ActionType.RESULT) {
            revert CallExecutionFailed();
        }
        if (nextAction.failed) {
            // Replay the raw revert data from the failed execution entry
            bytes memory returnData = nextAction.data;
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
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
            action.sourceRollup
        );

        if (authorizedProxies[sourceProxy].originalAddress == address(0)) {
            _createProxyInternal(action.sourceAddress, action.sourceRollup);
        }

        bool success;
        bytes memory returnData;
        if (action.isStatic) {
            // Static CALL — invoke the source proxy via STATICCALL. No value transfer.
            (success, returnData) = address(sourceProxy).staticcall(
                abi.encodeCall(CrossChainProxy.executeOnBehalf, (action.destination, action.data))
            );
        } else {
            (success, returnData) = address(sourceProxy).call{value: action.value}(
                abi.encodeCall(CrossChainProxy.executeOnBehalf, (action.destination, action.data))
            );
        }

        Action memory resultAction = Action({
            actionType: ActionType.RESULT,
            rollupId: action.rollupId,
            destination: address(0),
            value: 0,
            data: returnData,
            failed: !success,
            isStatic: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        bytes32 resultHash = keccak256(abi.encode(resultAction));
        nextAction = _consumeExecution(resultHash, resultAction);

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
            isStatic: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        bytes32 revertHash = keccak256(abi.encode(revertContinueAction));
        return _consumeExecution(revertHash, revertContinueAction);
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
