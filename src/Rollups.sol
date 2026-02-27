// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IZKVerifier} from "./IZKVerifier.sol";
import {L2Proxy} from "./L2Proxy.sol";
import {Proxy} from "./Proxy.sol";

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

/// @notice Represents a state delta for a single rollup (before/after snapshot)
struct StateDelta {
    uint256 rollupId;
    bytes32 currentState;
    bytes32 newState;
    int256 etherDelta;
}

/// @notice Represents a state commitment for a rollup (used in postBatch)
struct StateCommitment {
    uint256 rollupId;
    bytes32 newState;
    int256 etherIncrement;
}

/// @notice Represents a pre-computed execution that can affect multiple rollups
struct Execution {
    StateDelta[] stateDeltas;
    bytes32 actionHash;
    Action nextAction;
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
    IZKVerifier public immutable zkVerifier;

    /// @notice The L2Proxy implementation contract
    address public immutable l2ProxyImplementation;

    /// @notice Counter for generating rollup IDs
    uint256 public rollupCounter;

    /// @notice Mapping from rollup ID to rollup configuration
    mapping(uint256 rollupId => RollupConfig config) public rollups;

    /// @notice Mapping from action hash to array of pre-computed executions
    mapping(bytes32 actionHash => Execution[] executions) internal _executions;

    /// @notice Mapping from (actionHash, index) to block number when execution was loaded
    /// @dev Tracked separately from Execution struct to avoid breaking ZK proof public inputs
    mapping(bytes32 => uint256) internal _executionBlockLoaded;

    /// @notice Mapping of authorized L2Proxy contracts
    mapping(address proxy => bool authorized) public authorizedProxies;

    /// @notice Last block number when state was modified
    uint256 public lastStateUpdateBlock;

    /// @notice Default maximum age (in blocks) for stale execution cleanup
    /// @dev ~51 minutes at 12s/slot, aligned with BLOCKHASH opcode window
    uint256 public constant MAX_EXECUTION_AGE = 256;

    /// @notice Emitted when a new rollup is created
    event RollupCreated(
        uint256 indexed rollupId,
        address indexed owner,
        bytes32 verificationKey,
        bytes32 initialState
    );

    /// @notice Emitted when a rollup state is updated
    event StateUpdated(uint256 indexed rollupId, bytes32 newStateRoot);

    /// @notice Emitted when a rollup verification key is updated
    event VerificationKeyUpdated(
        uint256 indexed rollupId,
        bytes32 newVerificationKey
    );

    /// @notice Emitted when a rollup owner is transferred
    event OwnershipTransferred(
        uint256 indexed rollupId,
        address indexed previousOwner,
        address indexed newOwner
    );

    /// @notice Emitted when a new L2Proxy is created
    event L2ProxyCreated(
        address indexed proxy,
        address indexed originalAddress,
        uint256 indexed originalRollupId
    );

    /// @notice Emitted when executions are loaded
    event ExecutionsLoaded(uint256 count);

    /// @notice Emitted when stale executions are cleaned up
    event StaleExecutionsCleaned(bytes32 indexed actionHash, uint256 count);

    /// @notice Emitted when an L2 execution is performed
    event L2ExecutionPerformed(
        uint256 indexed rollupId,
        bytes32 currentState,
        bytes32 newState
    );

    /// @notice Error when proof verification fails
    error InvalidProof();

    /// @notice Error when caller is not an authorized proxy
    error UnauthorizedProxy();

    /// @notice Error when execution is not found
    error ExecutionNotFound();

    /// @notice Error when rollup does not exist
    error RollupNotFound();

    /// @notice Error when caller is not the rollup owner
    error NotRollupOwner();

    /// @notice Error when updateStates is called more than once in the same block
    error StateAlreadyUpdatedThisBlock();

    /// @notice Error when the sum of ether increments is not zero
    error EtherIncrementsSumNotZero();

    /// @notice Error when a rollup would have negative ether balance
    error InsufficientRollupBalance();

    /// @notice Error when ether transfer fails
    error EtherTransferFailed();

    /// @notice Error when a call execution fails
    error CallExecutionFailed();

    /// @notice Error when cleanup is called with no stale executions to remove
    error NoStaleExecutions();

    /// @notice Error when a scope reverts, carrying the next action to continue with
    /// @param nextAction The ABI-encoded next action to continue with
    /// @param stateRoot The state root to restore when catching the revert
    /// @param rollupId The rollup ID whose state to restore
    error ScopeReverted(bytes nextAction, bytes32 stateRoot, uint256 rollupId);

    /// @param _zkVerifier The ZK verifier contract address
    /// @param startingRollupId The starting ID for rollup numbering
    constructor(address _zkVerifier, uint256 startingRollupId) {
        zkVerifier = IZKVerifier(_zkVerifier);
        rollupCounter = startingRollupId;
        l2ProxyImplementation = address(new L2Proxy());
    }

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

    /// @notice Creates a new L2Proxy contract for an original address
    /// @param originalAddress The original address this proxy represents
    /// @param originalRollupId The original rollup ID
    /// @return proxy The address of the deployed Proxy
    function createL2ProxyContract(
        address originalAddress,
        uint256 originalRollupId
    ) external returns (address proxy) {
        return
            _createL2ProxyContractInternal(originalAddress, originalRollupId);
    }

    /// @notice Modifier to check if caller is the rollup owner
    modifier onlyRollupOwner(uint256 rollupId) {
        if (rollups[rollupId].owner != msg.sender) {
            revert NotRollupOwner();
        }
        _;
    }

    /// @notice Posts a batch of state commitments for multiple rollups with ZK proof verification
    /// @param commitments The state commitments for each rollup
    /// @param blobCount Number of blobs containing shared data
    /// @param callData Shared data passed via calldata
    /// @param proof The ZK proof
    function postBatch(
        StateCommitment[] calldata commitments,
        uint256 blobCount,
        bytes calldata callData,
        bytes calldata proof
    ) external {
        // Check if state was already updated in this block
        if (lastStateUpdateBlock == block.number) {
            revert StateAlreadyUpdatedThisBlock();
        }

        // Collect current states and verification keys
        bytes32[] memory currentStates = new bytes32[](commitments.length);
        bytes32[] memory verificationKeys = new bytes32[](commitments.length);
        bytes32[] memory newStates = new bytes32[](commitments.length);

        for (uint256 i = 0; i < commitments.length; i++) {
            RollupConfig storage config = rollups[commitments[i].rollupId];
            currentStates[i] = config.stateRoot;
            verificationKeys[i] = config.verificationKey;
            newStates[i] = commitments[i].newState;
        }

        // Collect blob hashes
        bytes32[] memory blobHashes = new bytes32[](blobCount);
        for (uint256 i = 0; i < blobCount; i++) {
            blobHashes[i] = blobhash(i);
        }

        // Prepare public inputs hash for verification
        // First byte indicates proof type: 0x00 = postBatch
        bytes32 publicInputsHash = keccak256(
            abi.encodePacked(
                bytes1(0x00),
                blockhash(block.number - 1),
                abi.encode(commitments),
                abi.encode(currentStates),
                abi.encode(verificationKeys),
                abi.encode(blobHashes),
                keccak256(callData)
            )
        );

        if (!zkVerifier.verify(proof, publicInputsHash)) {
            revert InvalidProof();
        }

        // Verify that the sum of ether increments is zero
        int256 totalIncrement = 0;
        for (uint256 i = 0; i < commitments.length; i++) {
            totalIncrement += commitments[i].etherIncrement;
        }
        if (totalIncrement != 0) {
            revert EtherIncrementsSumNotZero();
        }

        // Apply state commitments and ether increments
        for (uint256 i = 0; i < commitments.length; i++) {
            RollupConfig storage config = rollups[commitments[i].rollupId];
            config.stateRoot = commitments[i].newState;

            // Apply ether increment
            int256 increment = commitments[i].etherIncrement;
            if (increment < 0) {
                uint256 decrement = uint256(-increment);
                if (config.etherBalance < decrement) {
                    revert InsufficientRollupBalance();
                }
                config.etherBalance -= decrement;
            } else {
                config.etherBalance += uint256(increment);
            }

            emit StateUpdated(commitments[i].rollupId, commitments[i].newState);
        }
    }

    /// @notice Updates the state root for a rollup (owner only, no proof required)
    /// @param rollupId The rollup ID to update
    /// @param newStateRoot The new state root
    function setStateByOwner(
        uint256 rollupId,
        bytes32 newStateRoot
    ) external onlyRollupOwner(rollupId) {
        rollups[rollupId].stateRoot = newStateRoot;
        emit StateUpdated(rollupId, newStateRoot);
    }

    /// @notice Updates the verification key for a rollup (owner only)
    /// @param rollupId The rollup ID to update
    /// @param newVerificationKey The new verification key
    function setVerificationKey(
        uint256 rollupId,
        bytes32 newVerificationKey
    ) external onlyRollupOwner(rollupId) {
        rollups[rollupId].verificationKey = newVerificationKey;
        emit VerificationKeyUpdated(rollupId, newVerificationKey);
    }

    /// @notice Transfers ownership of a rollup to a new owner
    /// @param rollupId The rollup ID
    /// @param newOwner The new owner address
    function transferRollupOwnership(
        uint256 rollupId,
        address newOwner
    ) external onlyRollupOwner(rollupId) {
        address previousOwner = rollups[rollupId].owner;
        rollups[rollupId].owner = newOwner;
        emit OwnershipTransferred(rollupId, previousOwner, newOwner);
    }

    /// @notice Loads pre-computed L2 executions with ZK proof verification
    /// @param executions The executions to load
    /// @param proof The ZK proof
    function loadL2Executions(
        Execution[] calldata executions,
        bytes calldata proof
    ) external {
        // Build public inputs hash from all executions
        bytes32[] memory executionHashes = new bytes32[](executions.length);
        for (uint256 i = 0; i < executions.length; i++) {
            // Collect verification keys for each state delta
            bytes32[] memory verificationKeys = new bytes32[](
                executions[i].stateDeltas.length
            );
            for (uint256 j = 0; j < executions[i].stateDeltas.length; j++) {
                verificationKeys[j] = rollups[
                    executions[i].stateDeltas[j].rollupId
                ].verificationKey;
            }

            executionHashes[i] = keccak256(
                abi.encodePacked(
                    abi.encode(executions[i].stateDeltas),
                    abi.encode(verificationKeys),
                    executions[i].actionHash,
                    abi.encode(executions[i].nextAction)
                )
            );
        }

        // Hash all execution hashes into a single public inputs hash
        // First byte indicates proof type: 0x01 = loadL2Executions
        bytes32 publicInputsHash = keccak256(
            abi.encodePacked(bytes1(0x01), abi.encode(executionHashes))
        );

        if (!zkVerifier.verify(proof, publicInputsHash)) {
            revert InvalidProof();
        }

        // Store executions - key is actionHash, track block loaded for cleanup
        for (uint256 i = 0; i < executions.length; i++) {
            bytes32 ah = executions[i].actionHash;
            uint256 idx = _executions[ah].length;
            _executions[ah].push(executions[i]);
            _executionBlockLoaded[keccak256(abi.encode(ah, idx))] = block
                .number;
        }

        emit ExecutionsLoaded(executions.length);
    }

    /// @notice Executes an L2 execution by an authorized proxy
    /// @param actionHash The action hash to look up
    /// @return nextAction The next action to perform
    function executeL2Execution(
        bytes32 actionHash
    ) external returns (Action memory nextAction) {
        if (!authorizedProxies[msg.sender]) {
            revert UnauthorizedProxy();
        }
        return _findAndApplyExecution(actionHash);
    }

    /// @notice Internal function to find and apply an execution
    /// @param actionHash The action hash to look up
    /// @return nextAction The next action to perform
    function _findAndApplyExecution(
        bytes32 actionHash
    ) internal returns (Action memory nextAction) {
        // Look up executions array
        Execution[] storage executions = _executions[actionHash];

        // Search from the last entry backwards to find matching execution
        for (uint256 i = executions.length; i > 0; i--) {
            Execution storage execution = executions[i - 1];

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
                for (uint256 k = 0; k < execution.stateDeltas.length; k++) {
                    StateDelta storage delta = execution.stateDeltas[k];
                    RollupConfig storage config = rollups[delta.rollupId];
                    config.stateRoot = delta.newState;

                    // Apply ether delta
                    if (delta.etherDelta < 0) {
                        uint256 decrement = uint256(-delta.etherDelta);
                        if (config.etherBalance < decrement) {
                            revert InsufficientRollupBalance();
                        }
                        config.etherBalance -= decrement;
                    } else if (delta.etherDelta > 0) {
                        config.etherBalance += uint256(delta.etherDelta);
                    }

                    emit L2ExecutionPerformed(
                        delta.rollupId,
                        delta.currentState,
                        delta.newState
                    );
                }

                // Record this block as having an L2 execution
                lastStateUpdateBlock = block.number;

                // Copy nextAction to memory before removing from storage
                nextAction = execution.nextAction;

                // Remove the execution from storage to free space
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

    /// @notice Processes a scoped CALL action by navigating to the correct scope level
    /// @param scope The current scope level we are at
    /// @param action The CALL action to process (action.scope contains target scope)
    /// @return nextAction The next action to process
    function newScope(
        uint256[] memory scope,
        Action memory action
    ) external returns (Action memory nextAction) {
        // Only Rollups contract (self) or authorized proxies can call
        if (msg.sender != address(this) && !authorizedProxies[msg.sender]) {
            revert UnauthorizedProxy();
        }

        nextAction = action;

        while (true) {
            if (nextAction.actionType == ActionType.CALL) {
                if (_isChildScope(scope, nextAction.scope)) {
                    // Target is deeper - navigate by appending next element
                    uint256[] memory newScopeArr = _appendToScope(
                        scope,
                        nextAction.scope[scope.length]
                    );

                    // Use try/catch for recursive call to handle reverts from child scopes
                    try this.newScope(newScopeArr, nextAction) returns (
                        Action memory retAction
                    ) {
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
                    Action memory continuation = _getRevertContinuation(
                        rollupId
                    );
                    revert ScopeReverted(
                        abi.encode(continuation),
                        stateRoot,
                        rollupId
                    );
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
        address sourceProxy = this.computeL2ProxyAddress(
            action.sourceAddress,
            action.sourceRollup,
            block.chainid
        );

        if (!authorizedProxies[sourceProxy]) {
            _createL2ProxyContractInternal(
                action.sourceAddress,
                action.sourceRollup
            );
        }

        if (action.value > 0) {
            RollupConfig storage config = rollups[action.sourceRollup];
            if (config.etherBalance < action.value) {
                revert InsufficientRollupBalance();
            }
            config.etherBalance -= action.value;
        }

        (bool success, bytes memory returnData) = L2Proxy(payable(sourceProxy))
            .executeOnBehalf{value: action.value}(
            action.destination,
            action.data
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

    /// @notice Executes an L2 transaction
    /// @param rollupId The rollup ID for the transaction
    /// @param rlpEncodedTx The RLP-encoded transaction data
    /// @return result The result data from the execution
    function executeL2TX(
        uint256 rollupId,
        bytes calldata rlpEncodedTx
    ) external returns (bytes memory result) {
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

        // Compute action hash and get first nextAction
        bytes32 currentActionHash = keccak256(abi.encode(action));
        Action memory nextAction = _findAndApplyExecution(currentActionHash);

        if (nextAction.actionType == ActionType.CALL) {
            // Delegate all scope handling to newScope with try/catch for reverts
            // Start with empty scope, action.scope contains target
            uint256[] memory emptyScope = new uint256[](0);
            try this.newScope(emptyScope, nextAction) returns (
                Action memory retAction
            ) {
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

    /// @notice Internal function to create an L2Proxy contract
    /// @param originalAddress The original address this proxy represents
    /// @param originalRollupId The original rollup ID
    /// @return proxy The address of the deployed Proxy
    function _createL2ProxyContractInternal(
        address originalAddress,
        uint256 originalRollupId
    ) internal returns (address proxy) {
        bytes32 salt = keccak256(
            abi.encodePacked(block.chainid, originalRollupId, originalAddress)
        );

        proxy = address(
            new Proxy{salt: salt}(
                l2ProxyImplementation,
                address(this),
                originalAddress,
                originalRollupId
            )
        );

        authorizedProxies[proxy] = true;

        emit L2ProxyCreated(proxy, originalAddress, originalRollupId);
    }

    /// @notice Removes expired executions (TTL-based garbage collection)
    /// @dev Permissionless — anyone can call to reclaim storage. Callers receive
    ///      gas refunds from SSTORE zero-ing via EIP-2929/3529.
    ///      This implements TTL (time-to-live) semantics: executions expire after
    ///      maxAge blocks and must be re-submitted if still needed.
    /// @param actionHash The action hash whose execution array to clean
    /// @param maxAge Maximum age in blocks. Executions loaded more than maxAge blocks ago
    ///        expire and are removed. Pass 0 to use the default MAX_EXECUTION_AGE.
    function cleanupStaleExecutions(
        bytes32 actionHash,
        uint256 maxAge
    ) external {
        if (maxAge == 0) {
            maxAge = MAX_EXECUTION_AGE;
        }

        Execution[] storage executions = _executions[actionHash];
        uint256 len = executions.length;
        uint256 cleaned = 0;

        // Iterate backwards to safely remove elements via swap-and-pop
        for (uint256 i = len; i > 0; i--) {
            bytes32 key = keccak256(abi.encode(actionHash, i - 1));
            uint256 loadedAt = _executionBlockLoaded[key];

            // TTL expiry check: execution has exceeded its validity window
            if (loadedAt > 0 && block.number > loadedAt + maxAge) {
                // Clean up blockLoaded tracking
                delete _executionBlockLoaded[key];

                // Swap with last element and pop
                uint256 lastIndex = executions.length - 1;
                if (i - 1 != lastIndex) {
                    // Update blockLoaded key for the swapped element
                    bytes32 lastKey = keccak256(
                        abi.encode(actionHash, lastIndex)
                    );
                    _executionBlockLoaded[
                        keccak256(abi.encode(actionHash, i - 1))
                    ] = _executionBlockLoaded[lastKey];
                    delete _executionBlockLoaded[lastKey];

                    executions[i - 1] = executions[lastIndex];
                }
                executions.pop();
                cleaned++;
            }
        }

        if (cleaned == 0) {
            revert NoStaleExecutions();
        }

        emit StaleExecutionsCleaned(actionHash, cleaned);
    }

    /// @notice Returns the number of stored executions for a given action hash
    /// @param actionHash The action hash to query
    /// @return count The number of executions stored
    function getExecutionCount(
        bytes32 actionHash
    ) external view returns (uint256 count) {
        return _executions[actionHash].length;
    }

    /// @notice Returns the block number when an execution was loaded
    /// @param actionHash The action hash
    /// @param index The index within the executions array
    /// @return blockNumber The block number when the execution was stored (0 if not tracked)
    function getExecutionBlockLoaded(
        bytes32 actionHash,
        uint256 index
    ) external view returns (uint256 blockNumber) {
        return _executionBlockLoaded[keccak256(abi.encode(actionHash, index))];
    }

    /// @notice Deposits ether to a rollup's balance
    /// @param rollupId The rollup ID to deposit to
    function depositEther(uint256 rollupId) external payable {
        rollups[rollupId].etherBalance += msg.value;
    }

    /// @notice Withdraws ether from a rollup's balance (only callable by authorized proxies)
    /// @param rollupId The rollup ID to withdraw from
    /// @param amount The amount of ether to withdraw
    function withdrawEther(uint256 rollupId, uint256 amount) external {
        if (!authorizedProxies[msg.sender]) {
            revert UnauthorizedProxy();
        }
        RollupConfig storage config = rollups[rollupId];
        if (config.etherBalance < amount) {
            revert InsufficientRollupBalance();
        }
        config.etherBalance -= amount;
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        if (!success) {
            revert EtherTransferFailed();
        }
    }

    /// @notice Appends an element to a scope array
    /// @param scope The original scope array
    /// @param element The element to append
    /// @return The new scope array with the element appended
    function _appendToScope(
        uint256[] memory scope,
        uint256 element
    ) internal pure returns (uint256[] memory) {
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
    function _scopesMatch(
        uint256[] memory a,
        uint256[] memory b
    ) internal pure returns (bool) {
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
    function _isChildScope(
        uint256[] memory currentScope,
        uint256[] memory targetScope
    ) internal pure returns (bool) {
        if (targetScope.length <= currentScope.length) return false;
        for (uint256 i = 0; i < currentScope.length; i++) {
            if (currentScope[i] != targetScope[i]) return false;
        }
        return true;
    }

    /// @notice Handles a ScopeReverted exception by decoding the action and restoring rollup state
    /// @param revertData The raw revert data (includes 4-byte selector)
    /// @return nextAction The decoded continuation action
    function _handleScopeRevert(
        bytes memory revertData
    ) internal returns (Action memory nextAction) {
        // Skip 4-byte selector, decode parameters
        require(revertData.length > 4, "Invalid revert data");
        bytes memory withoutSelector = new bytes(revertData.length - 4);
        for (uint256 i = 4; i < revertData.length; i++) {
            withoutSelector[i - 4] = revertData[i];
        }
        // Decode: (bytes nextAction, bytes32 stateRoot, uint256 rollupId)
        (bytes memory actionBytes, bytes32 stateRoot, uint256 rollupId) = abi
            .decode(withoutSelector, (bytes, bytes32, uint256));

        // Restore state root
        rollups[rollupId].stateRoot = stateRoot;

        return abi.decode(actionBytes, (Action));
    }

    /// @notice Gets the continuation action after a revert at the current scope
    /// @param rollupId The rollup ID for the REVERT_CONTINUE action
    /// @return nextAction The next action from REVERT_CONTINUE lookup
    function _getRevertContinuation(
        uint256 rollupId
    ) internal returns (Action memory nextAction) {
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

    /// @notice Computes the CREATE2 address for an L2Proxy
    /// @param originalAddress The original address this proxy represents
    /// @param originalRollupId The original rollup ID
    /// @param domain The domain (chain ID) for the address computation
    /// @return The computed proxy address
    function computeL2ProxyAddress(
        address originalAddress,
        uint256 originalRollupId,
        uint256 domain
    ) external view returns (address) {
        bytes32 salt = keccak256(
            abi.encodePacked(domain, originalRollupId, originalAddress)
        );
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(
                type(Proxy).creationCode,
                abi.encode(
                    l2ProxyImplementation,
                    address(this),
                    originalAddress,
                    originalRollupId
                )
            )
        );

        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xff),
                                address(this),
                                salt,
                                bytecodeHash
                            )
                        )
                    )
                )
            );
    }
}
