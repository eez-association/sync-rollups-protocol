// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IProofSystem} from "./IProofSystem.sol";
import {ProofSystemRegistry} from "./ProofSystemRegistry.sol";
import {CrossChainProxy} from "./CrossChainProxy.sol";
import {ICrossChainManager, ActionType, Action, StateDelta, ExecutionEntry, ProxyInfo} from "./ICrossChainManager.sol";

/// @notice Rollup configuration
struct RollupConfig {
    address owner;
    uint256 threshold;
    uint256 proofSystemCount;
    bytes32 stateRoot;
    uint256 etherBalance;
}

/// @notice A group of proof systems sharing the same entries, verified atomically
struct ProofSystemBatch {
    address[] proofSystem;
    uint256[] rollupIds;
    ExecutionEntry[] entries;
    uint256 blobCount;
    bytes callData;
    bytes[] proof;
    bytes32 crossProofSystemInteractions;
}

/// @notice A state transition applied in the current block, auto-invalidated when the block advances
/// @dev Readers must check `blockNumber == block.number` — otherwise the entry is stale.
struct BatchUpdate {
    uint256 blockNumber;
    bytes32 previousState;
    bytes32 newState;
    int256 etherDelta;
}

/// @title Rollups
/// @notice L1 contract managing rollup state roots, ZK-proven batch posting, and cross-chain call execution
/// @dev Execution entries are posted via `postBatch()` with a ZK proof. Immediate entries (actionHash == 0)
///      update state on the spot. Deferred entries are stored in a flat execution table.
///      When a CrossChainProxy forwards a call to `executeCrossChainCall()`, the contract reconstructs the
///      CALL action, hashes it, looks up a matching execution (whose state deltas match on-chain state),
///      applies the deltas, and returns the pre-computed next action. Nested calls are resolved via
///      recursive `newScope()` calls with try/catch for revert handling.
contract Rollups is ICrossChainManager, ProofSystemRegistry {
    /// @notice The rollup ID representing L1 mainnet
    uint256 public constant MAINNET_ROLLUP_ID = 0;

    /// @notice Counter for generating rollup IDs
    uint256 public rollupCounter;

    /// @notice Mapping from rollup ID to rollup configuration
    mapping(uint256 rollupId => RollupConfig config) public rollups;

    /// @notice Per-rollup verification key for a given proofSystem
    /// @dev `bytes32(0)` means "this proofSystem is not allowed for this rollup".
    mapping(uint256 rollupId => mapping(address proofSystem => bytes32 vkey)) public verificationKeys;

    /// @notice Block-scoped record of the last `postBatch` transition per rollup
    /// @dev Entries are only valid when `blockNumber == block.number`; older entries are treated
    ///      as empty. This gives us a lazy "reset on new block" without any explicit cleanup pass.
    mapping(uint256 rollupId => BatchUpdate update) public batchUpdates;

    /// @notice Array of pre-computed executions
    ExecutionEntry[] public executions;

    /// @notice Mapping of authorized CrossChainProxy contracts to their identity
    mapping(address proxy => ProxyInfo info) public authorizedProxies;

    /// @notice Last block number when state was modified
    uint256 public lastStateUpdateBlock;

    // Transient storage

    /// @notice Transient ether delta accumulator for tracking ETH flow during execution
    /// @dev Positive when contract receives ETH, negative when sending. Must net to zero with state deltas.
    int256 private transient _etherDelta;

    /// @notice Emitted when a new rollup is created
    event RollupCreated(uint256 indexed rollupId, address indexed owner, address[] proofSystems, bytes32[] vkeys, uint256 threshold, bytes32 initialState);

    /// @notice Emitted when a rollup state is updated
    event StateUpdated(uint256 indexed rollupId, bytes32 newStateRoot);

    /// @notice Emitted when a rollup's verification key is updated
    event VerificationKeyUpdated(uint256 indexed rollupId, address indexed proofSystem, bytes32 newVerificationKey);

    /// @notice Emitted when a proof system is added to a rollup
    event ProofSystemAdded(uint256 indexed rollupId, address indexed proofSystem, bytes32 verificationKey);

    /// @notice Emitted when a proof system is removed from a rollup
    event ProofSystemRemoved(uint256 indexed rollupId, address indexed proofSystem);

    /// @notice Emitted when a rollup's threshold is changed
    event ThresholdChanged(uint256 indexed rollupId, uint256 newThreshold);

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
    event BatchPosted(uint256 indexed batchCount);

    /// @notice Error when proof verification fails
    error InvalidProof();

    /// @notice Error when caller is not an authorized proxy
    error UnauthorizedProxy();

    /// @notice Error when execution is not found
    error ExecutionNotFound();

    /// @notice Error when caller is not the rollup owner
    error NotRollupOwner();

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

    /// @notice Error when a proof system is not allowed for a rollup touched by the batch
    error ProofSystemNotAllowedForRollup(uint256 rollupId, address proofSystem);

    /// @notice Error when createRollup / proof-system management inputs are malformed
    error InvalidProofSystemConfig();

    /// @notice Error when a proof system is already allowed for a rollup
    error ProofSystemAlreadyAllowed(uint256 rollupId, address proofSystem);

    /// @notice Error when fewer than threshold proof systems submitted valid proofs for a rollup
    error ThresholdNotMet(uint256 rollupId, uint256 submittedCount, uint256 threshold);

    /// @notice Error when duplicate proof systems are submitted in a single postBatch call
    error DuplicateProofSystem(address proofSystem);

    /// @notice Error when a submitted proof system is not allowed for any touched rollup
    error UnrelatedProofSystem(address proofSystem);

    /// @notice Error when a state delta references a rollup not declared in the batch's `rollupIds`
    error StateDeltaRollupNotInBatch(uint256 rollupId);

    /// @notice Error when the same rollup appears in more than one sub-batch's `rollupIds`
    error RollupInMultipleBatches(uint256 rollupId);

    /// @notice Error when a scope reverts, carrying the next action to continue with
    /// @param nextAction The ABI-encoded next action to continue with
    /// @param stateRoot The state root to restore when catching the revert
    /// @param rollupId The rollup ID whose state to restore
    error ScopeReverted(bytes nextAction, bytes32 stateRoot, uint256 rollupId);

    /// @param startingRollupId The starting ID for rollup numbering
    constructor(uint256 startingRollupId) {
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

    /// @notice Creates a new rollup with M-of-N proof system verification
    /// @param initialState The initial state root for the rollup
    /// @param proofSystems The proof system addresses allowed to verify this rollup
    /// @param vkeys The per-proof-system verification keys (parallel array with proofSystems)
    /// @param threshold Minimum number of proof systems that must verify each batch (1 ≤ threshold ≤ proofSystems.length)
    /// @param owner The owner who can manage proof systems, keys, threshold, and state
    /// @return rollupId The ID of the newly created rollup
    function createRollup(
        bytes32 initialState,
        address[] calldata proofSystems,
        bytes32[] calldata vkeys,
        uint256 threshold,
        address owner
    ) external returns (uint256 rollupId) {
        if (owner == address(0)) revert InvalidProofSystemConfig();
        if (proofSystems.length == 0) revert InvalidProofSystemConfig();
        if (proofSystems.length != vkeys.length) revert InvalidProofSystemConfig();
        if (threshold == 0 || threshold > proofSystems.length) revert InvalidProofSystemConfig();

        rollupId = rollupCounter++;
        rollups[rollupId] = RollupConfig({
            owner: owner,
            threshold: threshold,
            proofSystemCount: proofSystems.length,
            stateRoot: initialState,
            etherBalance: 0
        });

        for (uint256 i = 0; i < proofSystems.length; i++) {
            if (!isProofSystem[proofSystems[i]]) revert ProofSystemNotRegistered(proofSystems[i]);
            if (vkeys[i] == bytes32(0)) revert InvalidProofSystemConfig();
            if (verificationKeys[rollupId][proofSystems[i]] != bytes32(0)) revert DuplicateProofSystem(proofSystems[i]);
            verificationKeys[rollupId][proofSystems[i]] = vkeys[i];
        }

        emit RollupCreated(rollupId, owner, proofSystems, vkeys, threshold, initialState);
    }

    // ──────────────────────────────────────────────
    //  Batch posting & execution table (ZK-proven)
    // ──────────────────────────────────────────────

    /// @notice Posts a batch composed of one or more sub-batches, each proven by N proof systems
    /// @dev Each `ProofSystemBatch` groups proof systems that share the same entries, callData,
    ///      blobs, and `crossProofSystemInteractions`. Every proof system in the group independently verifies
    ///      the shared entries (each with its own vkeys). ALL proofs must verify.
    ///      Each rollup may appear in at most one sub-batch's `rollupIds` — this guarantees that every
    ///      (rollup, proof-system) pair is verified at most once per call. Within that single sub-batch,
    ///      the rollup must have ≥ `threshold` proof systems holding a vkey for it (per-batch threshold).
    ///      Every submitted proof system must be relevant to at least one rollup in its own group.
    /// @param batches Array of proof-system groups (rollupIds disjoint across groups)
    function postBatch(ProofSystemBatch[] calldata batches) external {
        if (batches.length == 0) revert InvalidProofSystemConfig();

        // Per-batch validate → per-batch threshold/relevance → per-batch verify, all in one loop.
        // Cheap checks run first so a bad batch reverts before paying for a ZK verify.
        for (uint256 b = 0; b < batches.length; b++) {
            ProofSystemBatch calldata batch = batches[b];
            if (batch.proofSystem.length == 0) revert InvalidProofSystemConfig();
            if (batch.proofSystem.length != batch.proof.length) revert InvalidProofSystemConfig();
            if (batch.rollupIds.length == 0) revert InvalidProofSystemConfig();

            // rollupIds must be strictly increasing within this batch AND must not appear in any
            // earlier batch's rollupIds. Disjointness across batches means each rollup is attested
            // by exactly one group, so no PS can verify the same rollup twice in a single call.
            uint256 prevRollupID = MAINNET_ROLLUP_ID;
            for (uint256 i = 0; i < batch.rollupIds.length; i++) {
                uint256 rid = batch.rollupIds[i];
                if (rid <= prevRollupID) revert InvalidProofSystemConfig();
                if (rollups[rid].threshold == 0) revert InvalidProofSystemConfig();
                for (uint256 b2 = 0; b2 < b; b2++) {
                    if (_containsRollup(batches[b2].rollupIds, rid)) { // TODO can be encoded different e.g rollupIndex
                        revert RollupInMultipleBatches(rid);
                    }
                }
                prevRollupID = rid;
            }

            // proofSystem must be strictly increasing by address (rejects address(0) and duplicates)
            address prevPs = address(0);
            for (uint256 k = 0; k < batch.proofSystem.length; k++) {
                if (uint160(batch.proofSystem[k]) <= uint160(prevPs)) revert DuplicateProofSystem(batch.proofSystem[k]);
                if (!isProofSystem[batch.proofSystem[k]]) revert ProofSystemNotRegistered(batch.proofSystem[k]);
                prevPs = batch.proofSystem[k];
            }

            // Every state delta must reference a rollup declared in this batch's rollupIds
            for (uint256 i = 0; i < batch.entries.length; i++) {
                StateDelta[] calldata deltas = batch.entries[i].stateDeltas;
                for (uint256 j = 0; j < deltas.length; j++) {
                    if (!_containsRollup(batch.rollupIds, deltas[j].rollupId)) {
                        revert StateDeltaRollupNotInBatch(deltas[j].rollupId);
                    }
                }
            }

            // Per-batch threshold: each rollup in this group must have ≥ threshold PSes from THIS
            // group attesting to it. No cross-batch counting.
            for (uint256 r = 0; r < batch.rollupIds.length; r++) {
                uint256 rid = batch.rollupIds[r];
                uint256 count = 0;
                for (uint256 k = 0; k < batch.proofSystem.length; k++) {
                    if (verificationKeys[rid][batch.proofSystem[k]] != bytes32(0)) {
                        count++;
                    }
                }
                if (count < rollups[rid].threshold) {
                    revert ThresholdNotMet(rid, count, rollups[rid].threshold);
                }
            }

            // Sanity check (not a security gate): every PS in this group must hold a vkey for at
            // least one rollup in the group. Prevents gas griefing via padding the group with
            // irrelevant proof systems whose proofs would still be verified.
            for (uint256 k = 0; k < batch.proofSystem.length; k++) {
                bool relevant = false;
                for (uint256 r = 0; r < batch.rollupIds.length; r++) {
                    if (verificationKeys[batch.rollupIds[r]][batch.proofSystem[k]] != bytes32(0)) {
                        relevant = true;
                        break;
                    }
                }
                if (!relevant) revert UnrelatedProofSystem(batch.proofSystem[k]);
            }

            // Cheap checks all passed — verify the (expensive) proofs
            _verifyProofSystemBatch(batch);
        }

        // Delete previous execution table only if it's stale (from a prior block).
        // Multiple batches posted in the same block accumulate in the same table.
        if (lastStateUpdateBlock != block.number) {
            // Create multiple "stacks" or executions TODO
            delete executions;
        }

        // Process all entries across all sub-batches
        for (uint256 b = 0; b < batches.length; b++) {
            for (uint256 i = 0; i < batches[b].entries.length; i++) {
                ExecutionEntry calldata entry = batches[b].entries[i];
                if (entry.actionHash == bytes32(0)) {
                    for (uint256 j = 0; j < entry.stateDeltas.length; j++) {
                        if (rollups[entry.stateDeltas[j].rollupId].stateRoot != entry.stateDeltas[j].currentState) {
                            revert StateRootMismatch();
                        }
                    }
                    _applyStateDeltas(entry.stateDeltas);
                } else {
                    executions.push(entry);
                }
            }
        }

        emit BatchPosted(batches.length);
        lastStateUpdateBlock = block.number;
    }

    /// @notice Verifies all proof systems in a sub-batch against the shared entries
    /// @dev Each proof system gets its own public-inputs hash (using its own vkeys for each delta).
    ///      The entries, blobs, callData, and crossProofSystemInteractions are shared within the group.
    ///      Membership of every state delta's rollupId in `rollupIds` is enforced on-chain by `postBatch`.
    function _verifyProofSystemBatch(ProofSystemBatch calldata batch) internal view {
        bytes32[] memory blobHashes = new bytes32[](batch.blobCount);
        for (uint256 i = 0; i < batch.blobCount; i++) {
            blobHashes[i] = blobhash(i);
        }

        bytes32[] memory entryHashes = new bytes32[](batch.entries.length);
        for (uint256 i = 0; i < batch.entries.length; i++) {
            entryHashes[i] = keccak256(
                abi.encodePacked(
                    abi.encode(batch.entries[i].stateDeltas),
                    batch.entries[i].actionHash,
                    abi.encode(batch.entries[i].nextAction)
                )
            );
        }

        for (uint256 k = 0; k < batch.proofSystem.length; k++) {
            bytes32[] memory rollupVks = new bytes32[](batch.rollupIds.length);
            for (uint256 r = 0; r < batch.rollupIds.length; r++) {
                rollupVks[r] = verificationKeys[batch.rollupIds[r]][batch.proofSystem[k]];
            }

            bytes32 publicInputsHash = keccak256(
                abi.encodePacked(
                    blockhash(block.number - 1),
                    block.timestamp,
                    abi.encode(batch.rollupIds),
                    abi.encode(rollupVks),
                    abi.encode(entryHashes),
                    abi.encode(blobHashes),
                    keccak256(batch.callData),
                    batch.crossProofSystemInteractions
                )
            );

            if (!IProofSystem(batch.proofSystem[k]).verify(batch.proof[k], publicInputsHash)) {
                revert InvalidProof();
            }
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
                    revert ScopeReverted(abi.encode(continuation), stateRoot, rollupId); // TODO this might not be enough, multiple touched rollups
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

        (bool success, bytes memory returnData) = address(sourceProxy).call{value: action.value}(
            abi.encodeCall(CrossChainProxy.executeOnBehalf, (action.destination, action.data))
        );

        // Track ETH sent out from this contract (state deltas handle rollup balance changes)
        if (action.value > 0 && success) {
            _etherDelta -= int256(action.value);
        }

        // Build RESULT action
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

            // Record the transition for this rollup in the block-scoped batchUpdates map.
            // Stale entries from prior blocks are overwritten; readers guard on blockNumber.
            batchUpdates[delta.rollupId] = BatchUpdate({
                blockNumber: block.number,
                previousState: delta.currentState,
                newState: delta.newState,
                etherDelta: delta.etherDelta
            });

            emit L2ExecutionPerformed(delta.rollupId, delta.currentState, delta.newState);
        }

        // Verify ether accounting: state delta ether changes must match actual ETH flow
        if (totalEtherDelta != _etherDelta) {
            revert EtherDeltaMismatch();
        }

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
        if (nextAction.actionType != ActionType.RESULT || nextAction.failed) {
            revert CallExecutionFailed();
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

    /// @notice Binary-search membership check in a strictly-increasing array of rollup IDs
    /// @param sortedRollupIds Strictly-increasing array (validated by caller)
    /// @param rollupId The rollup ID to search for
    /// @return True if rollupId is present in sortedRollupIds
    function _containsRollup(uint256[] calldata sortedRollupIds, uint256 rollupId) internal pure returns (bool) {
        uint256 lo = 0;
        uint256 hi = sortedRollupIds.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            uint256 v = sortedRollupIds[mid];
            if (v == rollupId) return true;
            if (v < rollupId) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return false;
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

    /// @notice Rotates the verification key for a specific proof system on this rollup (owner only)
    function setVerificationKey(uint256 rollupId, address proofSystem, bytes32 newVkey) external onlyRollupOwner(rollupId) {
        if (newVkey == bytes32(0)) revert InvalidProofSystemConfig();
        if (verificationKeys[rollupId][proofSystem] == bytes32(0)) revert ProofSystemNotAllowedForRollup(rollupId, proofSystem);
        verificationKeys[rollupId][proofSystem] = newVkey;
        emit VerificationKeyUpdated(rollupId, proofSystem, newVkey);
    }

    /// @notice Adds a proof system to a rollup's allowed set (owner only)
    function addProofSystem(uint256 rollupId, address proofSystem, bytes32 vkey) external onlyRollupOwner(rollupId) {
        if (!isProofSystem[proofSystem]) revert ProofSystemNotRegistered(proofSystem);
        if (vkey == bytes32(0)) revert InvalidProofSystemConfig();
        if (verificationKeys[rollupId][proofSystem] != bytes32(0)) revert ProofSystemAlreadyAllowed(rollupId, proofSystem);

        verificationKeys[rollupId][proofSystem] = vkey;
        rollups[rollupId].proofSystemCount++;
        emit ProofSystemAdded(rollupId, proofSystem, vkey);
    }

    /// @notice Removes a proof system from a rollup's allowed set (owner only)
    /// @dev Remaining count must stay ≥ threshold
    function removeProofSystem(uint256 rollupId, address proofSystem) external onlyRollupOwner(rollupId) {
        if (verificationKeys[rollupId][proofSystem] == bytes32(0)) revert ProofSystemNotAllowedForRollup(rollupId, proofSystem);
        if (rollups[rollupId].proofSystemCount <= rollups[rollupId].threshold) revert InvalidProofSystemConfig();

        delete verificationKeys[rollupId][proofSystem];
        rollups[rollupId].proofSystemCount--;
        emit ProofSystemRemoved(rollupId, proofSystem);
    }

    /// @notice Sets the threshold for a rollup (owner only)
    /// @dev 1 ≤ newThreshold ≤ proofSystemCount
    function setThreshold(uint256 rollupId, uint256 newThreshold) external onlyRollupOwner(rollupId) {
        if (newThreshold == 0 || newThreshold > rollups[rollupId].proofSystemCount) revert InvalidProofSystemConfig();
        rollups[rollupId].threshold = newThreshold;
        emit ThresholdChanged(rollupId, newThreshold);
    }

    /// @notice Transfers ownership of a rollup to a new owner
    function transferRollupOwnership(uint256 rollupId, address newOwner) external onlyRollupOwner(rollupId) {
        if (newOwner == address(0)) revert InvalidProofSystemConfig();
        address previousOwner = rollups[rollupId].owner;
        rollups[rollupId].owner = newOwner;
        emit OwnershipTransferred(rollupId, previousOwner, newOwner);
    }

    // ──────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────

    /// @notice Returns the `BatchUpdate` recorded for `rollupId` in the current block, or an empty
    ///         struct (all zero) if none was recorded this block. Stale entries from previous
    ///         blocks are reported as empty — no storage cleanup needed.
    function currentBlockUpdate(uint256 rollupId) external view returns (BatchUpdate memory) {
        BatchUpdate memory u = batchUpdates[rollupId];
        if (u.blockNumber != block.number) return BatchUpdate(0, bytes32(0), bytes32(0), 0);
        return u;
    }

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
