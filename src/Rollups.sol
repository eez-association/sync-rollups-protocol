// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IZKVerifier} from "./IZKVerifier.sol";
import {CrossChainProxy} from "./CrossChainProxy.sol";
import {
    ICrossChainManager,
    ActionType,
    Action,
    StateDelta,
    ExecutionEntry,
    StaticCall,
    StaticSubCall,
    RollupStateRoot,
    ProxyInfo
} from "./ICrossChainManager.sol";

/// @notice Rollup configuration
struct RollupConfig {
    address owner;
    bytes32 verificationKey;
    bytes32 stateRoot;
    uint256 etherBalance;
}

/// @title Rollups
/// @notice L1 contract managing rollup state roots, ZK-proven batch posting, and cross-chain call execution
/// @dev Execution entries are posted via `postBatch()` with a ZK proof. Immediate entries (actionHash == 0)
///      update state on the spot. Deferred entries are stored in a flat execution table.
///      When a CrossChainProxy forwards a call to `executeCrossChainCall()`, the contract reconstructs the
///      CALL action, hashes it, looks up a matching execution (whose state deltas match on-chain state),
///      applies the deltas, and returns the pre-computed next action. Nested calls are resolved via
///      recursive `newScope()` calls with try/catch for revert handling.
contract Rollups is ICrossChainManager {
    /// @notice The rollup ID representing L1 mainnet
    uint256 public constant MAINNET_ROLLUP_ID = 0;

    /// @notice The ZK verifier contract
    IZKVerifier public immutable ZK_VERIFIER;

    /// @notice Counter for generating rollup IDs
    uint256 public rollupCounter;

    /// @notice Mapping from rollup ID to rollup configuration
    mapping(uint256 rollupId => RollupConfig config) public rollups;

    /// @notice Array of pre-computed executions
    ExecutionEntry[] public executions;

    /// @notice Array of pre-computed static call results
    /// @dev Populated by postBatch alongside executions; consumed by staticCallLookup via actionHash match
    StaticCall[] public staticCalls;

    /// @notice Mapping of authorized CrossChainProxy contracts to their identity
    mapping(address proxy => ProxyInfo info) public authorizedProxies;

    /// @notice Last block number when state was modified
    uint256 public lastStateUpdateBlock;

    // Transient storage

    /// @notice Transient ether delta accumulator for tracking ETH flow during execution
    /// @dev Positive when contract receives ETH, negative when sending. Must net to zero with state deltas.
    int256 private transient _etherDelta;

    /// @notice Emitted when a new rollup is created
    event RollupCreated(uint256 indexed rollupId, address indexed owner, bytes32 verificationKey, bytes32 initialState);

    /// @notice Emitted when a rollup state is updated
    event StateUpdated(uint256 indexed rollupId, bytes32 newStateRoot);

    /// @notice Emitted when a rollup verification key is updated
    event VerificationKeyUpdated(uint256 indexed rollupId, bytes32 newVerificationKey);

    /// @notice Emitted when a rollup owner is transferred
    event OwnershipTransferred(uint256 indexed rollupId, address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when a new CrossChainProxy is created
    event CrossChainProxyCreated(address indexed proxy, address indexed originalAddress, uint256 indexed originalRollupId);

    /// @notice Emitted when an L2 execution is performed
    event L2ExecutionPerformed(uint256 indexed rollupId, bytes32 currentState, bytes32 newState);

    /// @notice Emitted when an execution is found and applied
    event ExecutionConsumed(bytes32 indexed actionHash, Action action);

    /// @notice Emitted when a cross-chain call is executed via proxy
    event CrossChainCallExecuted(bytes32 indexed actionHash, address indexed proxy, address sourceAddress, bytes callData, uint256 value);

    /// @notice Emitted when a precomputed L2 transaction is executed
    event L2TXExecuted(bytes32 indexed actionHash, uint256 indexed rollupId, bytes rlpEncodedTx);

    /// @notice Emitted when a batch is posted via postBatch
    event BatchPosted(ExecutionEntry[] entries, bytes32 publicInputsHash);

    /// @notice Error when proof verification fails
    error InvalidProof();

    /// @notice Error when caller is not an authorized proxy
    error UnauthorizedProxy();

    /// @notice Error when execution is not found
    error ExecutionNotFound();

    /// @notice Error when caller is not the rollup owner
    error NotRollupOwner();

    /// @notice Error when state was already updated in this block
    error StateAlreadyUpdatedThisBlock();

    /// @notice Error when a rollup would have negative ether balance
    error InsufficientRollupBalance();

    /// @notice Error when a call execution fails
    error CallExecutionFailed();

    /// @notice Error when revert data from a child scope is too short to decode
    error InvalidRevertData();

    /// @notice Error when the ether delta from state deltas doesn't match actual ETH flow
    error EtherDeltaMismatch();

    /// @notice Error when a state delta's currentState doesn't match the rollup's current state root
    error StateRootMismatch();

    /// @notice Error when execution is attempted in a different block than the last state update
    error ExecutionNotInCurrentBlock();

    /// @notice Error when a scope reverts, carrying the next action to continue with
    /// @param nextAction The ABI-encoded next action to continue with
    /// @param stateRoot The state root to restore when catching the revert
    /// @param rollupId The rollup ID whose state to restore
    error ScopeReverted(bytes nextAction, bytes32 stateRoot, uint256 rollupId);

    /// @param _zkVerifier The ZK verifier contract address
    /// @param startingRollupId The starting ID for rollup numbering
    constructor(address _zkVerifier, uint256 startingRollupId) {
        ZK_VERIFIER = IZKVerifier(_zkVerifier);
        rollupCounter = startingRollupId;
    }

    // ──────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────

    modifier onlyRollupOwner(uint256 rollupId) {
        if (rollups[rollupId].owner != msg.sender) {
            revert NotRollupOwner();
        }
        _;
    }

    // ──────────────────────────────────────────────
    //  Rollup creation
    // ──────────────────────────────────────────────

    /// @notice Creates a new rollup
    /// @param initialState The initial state root for the rollup
    /// @param verificationKey The verification key for state transition proofs
    /// @param owner The owner who can update the verification key and state
    /// @return rollupId The ID of the newly created rollup
    function createRollup(
        bytes32 initialState,
        bytes32 verificationKey,
        address owner
    ) external returns (uint256 rollupId) {
        rollupId = rollupCounter++;
        rollups[rollupId] = RollupConfig({
            owner: owner,
            verificationKey: verificationKey,
            stateRoot: initialState,
            etherBalance: 0
        });
        emit RollupCreated(rollupId, owner, verificationKey, initialState);
    }

    // ──────────────────────────────────────────────
    //  Batch posting & execution table (ZK-proven)
    // ──────────────────────────────────────────────

    /// @notice Posts a batch of execution entries with a single ZK proof
    /// @dev Entries with actionHash == bytes32(0) are applied immediately (state commitments)
    /// @dev Entries with actionHash != bytes32(0) are stored in the execution table for later consumption
    /// @param entries The execution entries to process
    /// @param _staticCalls Pre-computed static call results for read-only cross-chain calls
    /// @param blobCount Number of blobs containing shared data
    /// @param callData Shared data passed via calldata
    /// @param proof The ZK proof covering all entries
    function postBatch(
        ExecutionEntry[] calldata entries,
        StaticCall[] calldata _staticCalls,
        uint256 blobCount,
        bytes calldata callData,
        bytes calldata proof
    ) external {
        if (lastStateUpdateBlock == block.number) {
            revert StateAlreadyUpdatedThisBlock();
        }

        // --- Build public inputs ---
        bytes32[] memory entryHashes = _computeEntryHashes(entries);

        bytes32[] memory blobHashes = new bytes32[](blobCount);
        for (uint256 i = 0; i < blobCount; i++) {
            blobHashes[i] = blobhash(i);
        }

        bytes32 publicInputsHash = keccak256(
            abi.encodePacked(
                blockhash(block.number - 1),
                block.timestamp,
                abi.encode(entryHashes),
                abi.encode(blobHashes),
                keccak256(callData),
                keccak256(abi.encode(_staticCalls))
            )
        );

        _verifyProof(proof, publicInputsHash);

        // Delete previous tables
        delete executions;
        delete staticCalls;

        // --- Process entries ---
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].actionHash == bytes32(0)) {
                // verify state roots match current state, then apply deltas
                for (uint256 j = 0; j < entries[i].stateDeltas.length; j++) {
                    StateDelta memory delta = entries[i].stateDeltas[j];
                    if (rollups[delta.rollupId].stateRoot != delta.currentState) {
                        revert StateRootMismatch();
                    }
                }
                _applyStateDeltas(entries[i].stateDeltas);
            } else {
                // Deferred: store in execution table
                executions.push(entries[i]);
            }
        }

        // --- Store static calls ---
        for (uint256 i = 0; i < _staticCalls.length; i++) {
            staticCalls.push(_staticCalls[i]);
        }

        emit BatchPosted(entries, publicInputsHash);
        lastStateUpdateBlock = block.number;
    }

    /// @notice Computes per-entry public-input hashes, pulling each delta's verification key from storage
    /// @dev Extracted from postBatch to relieve stack pressure
    function _computeEntryHashes(ExecutionEntry[] calldata entries) internal view returns (bytes32[] memory entryHashes) {
        entryHashes = new bytes32[](entries.length);
        for (uint256 i = 0; i < entries.length; i++) {
            bytes32[] memory vks = new bytes32[](entries[i].stateDeltas.length);
            for (uint256 j = 0; j < entries[i].stateDeltas.length; j++) {
                vks[j] = rollups[entries[i].stateDeltas[j].rollupId].verificationKey;
            }

            entryHashes[i] = keccak256(
                abi.encodePacked(
                    abi.encode(entries[i].stateDeltas),
                    abi.encode(vks),
                    entries[i].actionHash,
                    abi.encode(entries[i].nextAction) // update to flatten actions TODO
                )
            );
        }
    }

    /// @notice Verifies a ZK proof against the computed public inputs hash
    function _verifyProof(bytes calldata proof, bytes32 publicInputsHash) internal view {
        if (!ZK_VERIFIER.verify(proof, publicInputsHash)) {
            revert InvalidProof();
        }
    }

    // ──────────────────────────────────────────────
    //  L2 execution (proxy entry point)
    // ──────────────────────────────────────────────

    /// @notice Executes an L2 execution initiated by an authorized proxy
    /// @dev Builds the CALL action from the proxy's identity and msg context, then executes
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

        uint256 proxyRollupId = proxyInfo.originalRollupId;
        address proxyOriginalAddr = proxyInfo.originalAddress;

        // Track ETH received
        if (msg.value > 0) {
            _etherDelta += int256(msg.value);
        }

        // Build the CALL action
        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: proxyRollupId,
            destination: proxyOriginalAddr,
            value: msg.value,
            data: callData,
            failed: false,
            isStatic: false,
            sourceAddress: sourceAddress,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        bytes32 actionHash = keccak256(abi.encode(action));
        emit CrossChainCallExecuted(actionHash, msg.sender, sourceAddress, callData, msg.value);
        Action memory nextAction = _findAndApplyExecution(actionHash, action);

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
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        bytes32 actionHash = keccak256(abi.encode(action));

        for (uint256 i = 0; i < staticCalls.length; i++) {
            StaticCall storage sc = staticCalls[i];
            if (sc.actionHash == actionHash) {
                // Verify every pinned (rollupId, stateRoot) matches current on-chain state
                for (uint256 j = 0; j < sc.stateRoots.length; j++) {
                    RollupStateRoot storage sr = sc.stateRoots[j];
                    if (rollups[sr.rollupId].stateRoot != sr.stateRoot) {
                        revert StaticCallStateRootMismatch();
                    }
                }
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

    // ──────────────────────────────────────────────
    //  Execute precomputed L2 transaction
    // ──────────────────────────────────────────────

    /// @notice Executes a precomputed L2 transaction
    /// @param rollupId The rollup ID for the transaction
    /// @param rlpEncodedTx The RLP-encoded transaction data
    /// @return result The result data from the execution
    function executeL2TX(uint256 rollupId, bytes calldata rlpEncodedTx) external returns (bytes memory result) {
        // Executions can only be consumed in the same block they were posted
        if (lastStateUpdateBlock != block.number) {
            revert ExecutionNotInCurrentBlock();
        }

        // Build the L2TX action
        Action memory action = Action({
            actionType: ActionType.L2TX,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: rlpEncodedTx,
            failed: false,
            isStatic: false,
            sourceAddress: address(0),
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        bytes32 currentActionHash = keccak256(abi.encode(action));
        emit L2TXExecuted(currentActionHash, rollupId, rlpEncodedTx);
        Action memory nextAction = _findAndApplyExecution(currentActionHash, action);

        return _resolveScopes(nextAction);
    }

    // ──────────────────────────────────────────────
    //  Scope navigation
    // ──────────────────────────────────────────────

    /// @notice Processes a scoped CALL action by navigating to the correct scope level
    /// @param scope The current scope level we are at
    /// @param action The CALL action to process (action.scope contains target scope)
    /// @return nextAction The next action to process
    function newScope(
        uint256[] memory scope,
        Action memory action
    ) external returns (Action memory nextAction) {
        // Only Rollups contract (self) or authorized proxies can call
        if (msg.sender != address(this)) {
            revert UnauthorizedProxy();
        }

        nextAction = action;

        while (true) {
            if (nextAction.actionType == ActionType.CALL) {
                if (_isChildScope(scope, nextAction.scope)) {
                    // Target is deeper - navigate by appending next element
                    uint256[] memory newScopeArr = _appendToScope(scope, nextAction.scope[scope.length]);

                    // Use try/catch for recursive call to handle reverts from child scopes
                    try this.newScope(newScopeArr, nextAction) returns (Action memory retAction) {
                        nextAction = retAction;
                    } catch (bytes memory revertData) {
                        nextAction = _handleScopeRevert(revertData);
                    }
                } else if (_scopesMatch(scope, nextAction.scope)) {
                    // At target scope - execute the call
                    (, nextAction) = _processCallAtScope(scope, nextAction);
                } else {
                    // Action is at a parent/sibling scope - return to caller
                    break;
                }
            } else if (nextAction.actionType == ActionType.REVERT) {
                if (_scopesMatch(scope, nextAction.scope)) {
                    // This is the target revert scope - consume continuation, capture state, and revert
                    uint256 rollupId = nextAction.rollupId;
                    Action memory continuation = _getRevertContinuation(rollupId);
                    bytes32 stateRoot = rollups[rollupId].stateRoot;
                    revert ScopeReverted(abi.encode(continuation), stateRoot, rollupId); // TODO this might not be enough, multiple touced rollups
                } else {
                    // Revert is for parent/sibling scope - return to caller
                    break;
                }
            } else {
                // RESULT or other action type - return to caller
                break;
            }
        }

        return nextAction;
    }

    // ──────────────────────────────────────────────
    //  Internal helpers
    // ──────────────────────────────────────────────

    /// @notice Executes a single CALL at the current scope and returns the next action
    /// @dev Does NOT loop - returns immediately after getting nextAction
    /// @dev Looping for same-scope calls is handled by newScope
    /// @param currentScope The current scope level
    /// @param action The CALL action to execute
    /// @return scope The scope after processing (always currentScope)
    /// @return nextAction The next action (RESULT or CALL at any scope)
    function _processCallAtScope(
        uint256[] memory currentScope,
        Action memory action
    ) internal returns (uint256[] memory scope, Action memory nextAction) {
        // Execute the CALL through source proxy
        address sourceProxy = computeCrossChainProxyAddress(
            action.sourceAddress,
            action.sourceRollup
        );

        if (authorizedProxies[sourceProxy].originalAddress == address(0)) {
            _createCrossChainProxyInternal(action.sourceAddress, action.sourceRollup);
        }

        bool success;
        bytes memory returnData;
        if (action.isStatic) {
            // Static CALL — invoke the source proxy via STATICCALL. No value transfer allowed.
            (success, returnData) = address(sourceProxy).staticcall(
                abi.encodeCall(CrossChainProxy.executeOnBehalf, (action.destination, action.data))
            );
        } else {
            (success, returnData) = address(sourceProxy).call{value: action.value}(
                abi.encodeCall(CrossChainProxy.executeOnBehalf, (action.destination, action.data))
            );

            // Track ETH sent out from this contract (state deltas handle rollup balance changes)
            if (action.value > 0 && success) {
                _etherDelta -= int256(action.value);
            }
        }

        // Build RESULT action
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

        // Get next action from execution lookup
        bytes32 resultHash = keccak256(abi.encode(resultAction));
        nextAction = _findAndApplyExecution(resultHash, resultAction);

        return (currentScope, nextAction);
    }

    /// @notice Finds a matching execution for the given action hash, applies state deltas, and returns the next action
    /// @dev Matches by checking that all deltas' currentState match their rollup's on-chain stateRoot
    /// @param actionHash The action hash to look up
    /// @return nextAction The next action to perform
    function _findAndApplyExecution(bytes32 actionHash, Action memory action) internal returns (Action memory nextAction) {
        // Search the flat executions array for a matching entry
        for (uint256 i = 0; i < executions.length; i++) {
            ExecutionEntry storage execution = executions[i];

            if (execution.actionHash != actionHash) continue;

            // Check if all state deltas match current rollup states
            bool allMatch = true;
            for (uint256 j = 0; j < execution.stateDeltas.length; j++) {
                StateDelta storage delta = execution.stateDeltas[j];
                if (rollups[delta.rollupId].stateRoot != delta.currentState) {
                    allMatch = false;
                    break;
                }
            }

            if (allMatch) {
                // Found matching execution - apply all state deltas and ether deltas
                _applyStateDeltas(execution.stateDeltas);
                // Copy nextAction to memory before removing from storage
                nextAction = execution.nextAction;

                // Remove the execution from storage (swap-and-pop)
                uint256 lastIndex = executions.length - 1;
                if (i != lastIndex) {
                    executions[i] = executions[lastIndex];
                }
                executions.pop();

                emit ExecutionConsumed(actionHash, action);
                return nextAction;
            }
        }

        revert ExecutionNotFound();
    }

    /// @notice Applies state deltas, ether balance changes, and verifies ether accounting against _etherDelta
    function _applyStateDeltas(StateDelta[] memory deltas) internal {
        int256 totalEtherDelta;

        for (uint256 i = 0; i < deltas.length; i++) {
            StateDelta memory delta = deltas[i];
            RollupConfig storage config = rollups[delta.rollupId];
            config.stateRoot = delta.newState;
            totalEtherDelta += delta.etherDelta;

            if (delta.etherDelta < 0) {
                uint256 decrement = uint256(-delta.etherDelta);
                if (config.etherBalance < decrement) {
                    revert InsufficientRollupBalance();
                }
                config.etherBalance -= decrement;
            } else if (delta.etherDelta > 0) {
                config.etherBalance += uint256(delta.etherDelta);
            }

            emit L2ExecutionPerformed(delta.rollupId, delta.currentState, delta.newState);
        }

        // Verify ether accounting: state delta ether changes must match actual ETH flow
        if (totalEtherDelta != _etherDelta) {
            revert EtherDeltaMismatch();
        }

        // reset _etherDelta
        _etherDelta = 0;

    }

    /// @notice Handles scope navigation and returns the final RESULT, reverting if execution fails
    /// @param nextAction The action to resolve (CALL triggers scope navigation, RESULT returns directly)
    /// @return result The return data from the resolved execution
    function _resolveScopes(Action memory nextAction) internal returns (bytes memory result) {
        if (nextAction.actionType == ActionType.CALL) {
            // Start with empty scope, action.scope contains target
            uint256[] memory emptyScope = new uint256[](0);
            try this.newScope(emptyScope, nextAction) returns (Action memory retAction) {
                nextAction = retAction;
            } catch (bytes memory revertData) {
                // Root scope caught a revert - decode and continue
                nextAction = _handleScopeRevert(revertData);
            }
        }

        // At this point nextAction should be a successful RESULT
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

    /// @notice Handles a ScopeReverted exception by decoding the action and restoring rollup state
    /// @param revertData The raw revert data (includes 4-byte selector)
    /// @return nextAction The decoded continuation action
    function _handleScopeRevert(bytes memory revertData) internal returns (Action memory nextAction) {
        if (revertData.length <= 4) revert InvalidRevertData();

        // Strip 4-byte selector by advancing the memory pointer
        assembly {
            let len := mload(revertData)
            revertData := add(revertData, 4)
            mstore(revertData, sub(len, 4))
        }

        (bytes memory actionBytes, bytes32 stateRoot, uint256 rollupId) = abi.decode(revertData, (bytes, bytes32, uint256));
        rollups[rollupId].stateRoot = stateRoot;
        return abi.decode(actionBytes, (Action));
    }

    /// @notice Gets the continuation action after a revert at the current scope
    /// @param rollupId The rollup ID for the REVERT_CONTINUE action
    /// @return nextAction The next action from REVERT_CONTINUE lookup
    function _getRevertContinuation(uint256 rollupId) internal returns (Action memory nextAction) {
        // Build REVERT_CONTINUE action (empty data)
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

        // Get next action from execution lookup
        bytes32 revertHash = keccak256(abi.encode(revertContinueAction));
        return _findAndApplyExecution(revertHash, revertContinueAction);
    }

    /// @notice Appends an element to a scope array
    /// @param scope The original scope array
    /// @param element The element to append
    /// @return The new scope array with the element appended
    function _appendToScope(uint256[] memory scope, uint256 element) internal pure returns (uint256[] memory) {
        uint256[] memory result = new uint256[](scope.length + 1);
        for (uint256 i = 0; i < scope.length; i++) {
            result[i] = scope[i];
        }
        result[scope.length] = element;
        return result;
    }

    /// @notice Checks if two scopes match exactly
    /// @param a First scope array
    /// @param b Second scope array
    /// @return True if scopes match exactly
    function _scopesMatch(uint256[] memory a, uint256[] memory b) internal pure returns (bool) {
        if (a.length != b.length) return false;
        for (uint256 i = 0; i < a.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    /// @notice Checks if targetScope is a child of currentScope (starts with currentScope prefix and is longer)
    /// @param currentScope The current scope to check against
    /// @param targetScope The target scope to check
    /// @return True if targetScope is a child of currentScope
    function _isChildScope(uint256[] memory currentScope, uint256[] memory targetScope) internal pure returns (bool) {
        if (targetScope.length <= currentScope.length) return false;
        for (uint256 i = 0; i < currentScope.length; i++) {
            if (currentScope[i] != targetScope[i]) return false;
        }
        return true;
    }

    // ──────────────────────────────────────────────
    //  CrossChainProxy creation
    // ──────────────────────────────────────────────

    /// @notice Creates a new CrossChainProxy contract for an original address
    /// @param originalAddress The original address this proxy represents
    /// @param originalRollupId The original rollup ID
    /// @return proxy The address of the deployed CrossChainProxy
    function createCrossChainProxy(address originalAddress, uint256 originalRollupId) external returns (address proxy) {
        return _createCrossChainProxyInternal(originalAddress, originalRollupId);
    }

    /// @notice Deploys a CrossChainProxy via CREATE2 and registers it as authorized
    function _createCrossChainProxyInternal(address originalAddress, uint256 originalRollupId) internal returns (address proxy) {
        bytes32 salt = keccak256(abi.encodePacked(originalRollupId, originalAddress));

        proxy = address(new CrossChainProxy{salt: salt}(address(this), originalAddress, originalRollupId));

        authorizedProxies[proxy] = ProxyInfo(originalAddress, uint64(originalRollupId));

        emit CrossChainProxyCreated(proxy, originalAddress, originalRollupId);
    }

    // ──────────────────────────────────────────────
    //  Rollup management (owner only)
    // ──────────────────────────────────────────────

    /// @notice Updates the state root for a rollup (owner only, no proof required)
    function setStateByOwner(uint256 rollupId, bytes32 newStateRoot) external onlyRollupOwner(rollupId) {
        rollups[rollupId].stateRoot = newStateRoot;
        emit StateUpdated(rollupId, newStateRoot);
    }

    /// @notice Updates the verification key for a rollup (owner only)
    function setVerificationKey(uint256 rollupId, bytes32 newVerificationKey) external onlyRollupOwner(rollupId) {
        rollups[rollupId].verificationKey = newVerificationKey;
        emit VerificationKeyUpdated(rollupId, newVerificationKey);
    }

    /// @notice Transfers ownership of a rollup to a new owner
    function transferRollupOwnership(uint256 rollupId, address newOwner) external onlyRollupOwner(rollupId) {
        address previousOwner = rollups[rollupId].owner;
        rollups[rollupId].owner = newOwner;
        emit OwnershipTransferred(rollupId, previousOwner, newOwner);
    }

    // ──────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────

    /// @notice Computes the deterministic CREATE2 address for a CrossChainProxy
    /// @param originalAddress The original address this proxy represents
    /// @param originalRollupId The original rollup ID
    /// @return The computed proxy address
    function computeCrossChainProxyAddress(address originalAddress, uint256 originalRollupId) public view returns (address) {
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
