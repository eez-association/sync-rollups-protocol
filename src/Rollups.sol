// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IZKVerifier} from "./IZKVerifier.sol";
import {CrossChainProxy} from "./CrossChainProxy.sol";

/// @notice Action type enum
enum ActionType {
    CALL,
    RESULT,
    L2TX,
    REVERT,
    REVERT_CONTINUE
}

/// @notice Represents an action in the state transition
/// @dev For CALL: rollupId, destination, value, data (callData), sourceAddress, sourceRollup, and scope are used
/// @dev For RESULT: failed and data (returnData) are used
/// @dev For L2TX: rollupId and data (rlpEncodedTx) are used
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
/// @dev If actionHash == bytes32(0): applied immediately (pure state commitment)
/// @dev If actionHash != bytes32(0): stored in execution table for later consumption
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

/// @notice Rollup configuration
struct RollupConfig {
    address owner;
    bytes32 verificationKey;
    bytes32 stateRoot;
    uint256 etherBalance;
}

/// @title Rollups
/// @notice Main contract for L1/L2 rollup synchronization
/// @dev Manages rollup state roots and L2 execution transitions
contract Rollups {
    /// @notice The ZK verifier contract
    IZKVerifier public immutable ZK_VERIFIER;

    /// @notice Counter for generating rollup IDs
    uint256 public rollupCounter;

    /// @notice Mapping from rollup ID to rollup configuration
    mapping(uint256 rollupId => RollupConfig config) public rollups;

    /// @notice Mapping from action hash to pre-computed executions
    mapping(bytes32 actionHash => ExecutionEntry[] executions) internal _executions;

    /// @notice Mapping of authorized CrossChainProxy contracts to their identity
    mapping(address proxy => ProxyInfo info) public authorizedProxies;

    /// @notice Last block number when state was modified
    uint256 public lastStateUpdateBlock;

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

    /// @notice Error when the sum of ether increments is not zero
    error EtherIncrementsSumNotZero();

    /// @notice Error when a rollup would have negative ether balance
    error InsufficientRollupBalance();

    /// @notice Error when a call execution fails
    error CallExecutionFailed();

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
    /// @param blobCount Number of blobs containing shared data
    /// @param callData Shared data passed via calldata
    /// @param proof The ZK proof covering all entries
    function postBatch(
        ExecutionEntry[] calldata entries,
        uint256 blobCount,
        bytes calldata callData,
        bytes calldata proof
    ) external {
        if (lastStateUpdateBlock == block.number) {
            revert StateAlreadyUpdatedThisBlock();
        }

        // --- Build public inputs ---

        bytes32[] memory entryHashes = new bytes32[](entries.length);
        for (uint256 i = 0; i < entries.length; i++) {
            // Gather verification keys for each delta's rollup
            bytes32[] memory vks = new bytes32[](entries[i].stateDeltas.length);
            for (uint256 j = 0; j < entries[i].stateDeltas.length; j++) {
                vks[j] = rollups[entries[i].stateDeltas[j].rollupId].verificationKey;
            }

            entryHashes[i] = keccak256(
                abi.encodePacked(
                    abi.encode(entries[i].stateDeltas),
                    abi.encode(vks),
                    entries[i].actionHash,
                    abi.encode(entries[i].nextAction)
                )
            );
        }

        bytes32[] memory blobHashes = new bytes32[](blobCount);
        for (uint256 i = 0; i < blobCount; i++) {
            blobHashes[i] = blobhash(i);
        }

        bytes32 publicInputsHash = keccak256(
            abi.encodePacked(
                blockhash(block.number - 1),
                block.number,
                abi.encode(entryHashes),
                abi.encode(blobHashes),
                keccak256(callData)
            )
        );

        _verifyProof(proof, publicInputsHash);

        // --- Process entries ---

        int256 totalEtherDelta = 0;

        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].actionHash == bytes32(0)) {
                // Immediate: apply state deltas now
                _applyStateDeltas(entries[i].stateDeltas); // udpate state roots

                // Track ether deltas for conservation check
                for (uint256 j = 0; j < entries[i].stateDeltas.length; j++) {
                    totalEtherDelta += entries[i].stateDeltas[j].etherDelta;
                }
            } else {
                // Deferred: store in execution table
                _executions[entries[i].actionHash].push(entries[i]);
            }
        }

        if (totalEtherDelta != 0) {
            revert EtherIncrementsSumNotZero();
        }

        lastStateUpdateBlock = block.number;
    }

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

        uint256 proxyRollupId = proxyInfo.originalRollupId;
        address proxyOriginalAddr = proxyInfo.originalAddress;

        // Deposits should be taken in account inside the state transition?

        // Build the CALL action
        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: proxyRollupId,
            destination: proxyOriginalAddr,
            value: msg.value,
            data: callData,
            failed: false,
            sourceAddress: sourceAddress,
            sourceRollup: 0, // MAINNET_ROLLUP_ID
            scope: new uint256[](0)
        });

        bytes32 actionHash = keccak256(abi.encode(action));
        Action memory nextAction = _findAndApplyExecution(actionHash);

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
        // Build the L2TX action
        Action memory action = Action({
            actionType: ActionType.L2TX,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: rlpEncodedTx,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        bytes32 currentActionHash = keccak256(abi.encode(action));
        Action memory nextAction = _findAndApplyExecution(currentActionHash);

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
        if (msg.sender != address(this) && authorizedProxies[msg.sender].originalAddress == address(0)) {
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
                    // This is the target revert scope - capture state and revert
                    uint256 rollupId = nextAction.rollupId;
                    bytes32 stateRoot = rollups[rollupId].stateRoot;
                    Action memory continuation = _getRevertContinuation(rollupId);
                    revert ScopeReverted(abi.encode(continuation), stateRoot, rollupId);
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
        address sourceProxy = this.computeCrossChainProxyAddress(
            action.sourceAddress,
            action.sourceRollup,
            block.chainid
        );

        if (authorizedProxies[sourceProxy].originalAddress == address(0)) {
            _createCrossChainProxyInternal(action.sourceAddress, action.sourceRollup);
        }

        if (action.value > 0) {
            RollupConfig storage config = rollups[action.sourceRollup];
            if (config.etherBalance < action.value) {
                revert InsufficientRollupBalance();
            }
            config.etherBalance -= action.value;
        }

        (bool success, bytes memory returnData) = address(sourceProxy).call{value: action.value}(
            abi.encodeCall(CrossChainProxy.executeOnBehalf, (action.destination, action.data))
        );

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
        nextAction = _findAndApplyExecution(resultHash);

        return (currentScope, nextAction);
    }

    // ──────────────────────────────────────────────
    //  Deposits
    // ──────────────────────────────────────────────

    /// @notice Deposits ether to a rollup's balance
    /// @param rollupId The rollup ID to deposit to
    function depositEther(uint256 rollupId) external payable {
        rollups[rollupId].etherBalance += msg.value;
    }

    // ──────────────────────────────────────────────
    //  Internal helpers
    // ──────────────────────────────────────────────

    /// @notice Finds a matching execution for the given action hash, applies state deltas, and returns the next action
    /// @dev Matches by checking that all deltas' currentState match their rollup's on-chain stateRoot
    /// @param actionHash The action hash to look up
    /// @return nextAction The next action to perform
    function _findAndApplyExecution(bytes32 actionHash) internal returns (Action memory nextAction) {
        ExecutionEntry[] storage executions = _executions[actionHash];

        // Search from the last entry backwards to find matching execution
        for (uint256 i = executions.length; i > 0; i--) {
            ExecutionEntry storage execution = executions[i - 1];

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
                if (i - 1 != lastIndex) {
                    executions[i - 1] = executions[lastIndex];
                }
                executions.pop();

                return nextAction;
            }
        }

        revert ExecutionNotFound();
    }

    /// @notice Applies state deltas and ether balance changes (each delta specifies its own rollupId)
    function _applyStateDeltas(StateDelta[] memory deltas) internal {
        for (uint256 i = 0; i < deltas.length; i++) {
            StateDelta memory delta = deltas[i];
            RollupConfig storage config = rollups[delta.rollupId];
            config.stateRoot = delta.newState;

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
        // Skip 4-byte selector, decode parameters
        require(revertData.length > 4, "Invalid revert data");
        bytes memory withoutSelector = new bytes(revertData.length - 4);
        for (uint256 i = 4; i < revertData.length; i++) {
            withoutSelector[i - 4] = revertData[i];
        }
        // Decode: (bytes nextAction, bytes32 stateRoot, uint256 rollupId)
        (bytes memory actionBytes, bytes32 stateRoot, uint256 rollupId) = abi.decode(withoutSelector, (bytes, bytes32, uint256));

        // Restore state root
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
        return _findAndApplyExecution(revertHash);
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

    function _createCrossChainProxyInternal(address originalAddress, uint256 originalRollupId) internal returns (address proxy) {
        bytes32 salt = keccak256(abi.encodePacked(block.chainid, originalRollupId, originalAddress));

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

    /// @notice Computes the CREATE2 address for an CrossChainProxy
    /// @param originalAddress The original address this proxy represents
    /// @param originalRollupId The original rollup ID
    /// @param domain The domain (chain ID) for the address computation
    /// @return The computed proxy address
    function computeCrossChainProxyAddress(address originalAddress, uint256 originalRollupId, uint256 domain) external view returns (address) {
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
