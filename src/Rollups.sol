// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IZKVerifier} from "./IZKVerifier.sol";
import {CrossChainProxy} from "./CrossChainProxy.sol";
import {ICrossChainManager, ActionType, StateDelta, SubCall, ExecutionEntry, ProxyInfo} from "./ICrossChainManager.sol";

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
///      update state on the spot. Deferred entries are stored in a flat execution table and consumed
///      sequentially. Each entry contains pre-computed calls and a return hash for verification.
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

    /// @notice Index of the next execution entry to consume
    uint256 public executionIndex;

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
    event L2ExecutionPerformed(uint256 indexed rollupId, bytes32 newState);

    /// @notice Emitted when an execution entry is consumed
    event ExecutionConsumed(bytes32 indexed actionHash, uint256 indexed entryIndex);

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

    /// @notice Error when executeInContext is called by an external address
    error NotSelf();

    /// @notice Error when execution is not found or actionHash doesn't match next entry
    error ExecutionNotFound();

    /// @notice Error when caller is not the rollup owner
    error NotRollupOwner();

    /// @notice Error when state was already updated in this block
    error StateAlreadyUpdatedThisBlock();

    /// @notice Error when a rollup would have negative ether balance
    error InsufficientRollupBalance();

    /// @notice Error when the ether delta from state deltas doesn't match actual ETH flow
    error EtherDeltaMismatch();


    /// @notice Error when execution is attempted in a different block than the last state update
    error ExecutionNotInCurrentBlock();

    /// @notice Error when the computed return hash doesn't match the entry's returnHash
    error ReturnHashMismatch();

    /// @notice Carries execution results out of a reverted context
    error ContextResult(bytes32 computedHash);

    /// @notice Error when executeInContext reverts with an unexpected error
    error UnexpectedContextRevert(bytes revertData);

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
    /// @dev Only the first entry may have actionHash == bytes32(0) (immediate state commitment + optional subcalls).
    ///      All remaining entries must have actionHash != bytes32(0) and are stored for deferred consumption.
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
            // Gather verification keys and current state roots for each delta's rollup
            bytes32[] memory vks = new bytes32[](entries[i].stateDeltas.length);
            bytes32[] memory prevStates = new bytes32[](entries[i].stateDeltas.length);
            for (uint256 j = 0; j < entries[i].stateDeltas.length; j++) {
                RollupConfig storage cfg = rollups[entries[i].stateDeltas[j].rollupId];
                vks[j] = cfg.verificationKey;
                prevStates[j] = cfg.stateRoot;
            }

            entryHashes[i] = keccak256(
                abi.encodePacked(
                    abi.encode(entries[i].stateDeltas),
                    abi.encode(vks),
                    abi.encode(prevStates),
                    entries[i].actionHash,
                    entries[i].returnHash
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
                block.timestamp,
                abi.encode(entryHashes),
                abi.encode(blobHashes),
                keccak256(callData)
            )
        );

        _verifyProof(proof, publicInputsHash);

        // Delete previous execution table and reset index
        delete executions;
        executionIndex = 0;

        // --- Process entries ---
        // First entry may have actionHash == 0 (immediate state commitment with optional subcalls).
        // All remaining entries must have actionHash != 0 (deferred, consumed via proxy calls).
        uint256 startIdx = 0;
        if (entries.length > 0 && entries[0].actionHash == bytes32(0)) {
            _applyAndExecute(entries[0].stateDeltas, entries[0].calls, entries[0].returnHash, 0);
            startIdx = 1;
        }
        for (uint256 i = startIdx; i < entries.length; i++) {
            executions.push(entries[i]);
        }

        emit BatchPosted(entries, publicInputsHash);
        lastStateUpdateBlock = block.number;
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

        // Build the action input hash for matching
        bytes32 actionHash = _computeActionInputHash(
            ActionType.CALL,
            proxyInfo.originalRollupId,
            proxyInfo.originalAddress,
            msg.value,
            callData,
            sourceAddress,
            MAINNET_ROLLUP_ID
        );

        emit CrossChainCallExecuted(actionHash, msg.sender, sourceAddress, callData, msg.value);

        return _consumeAndExecute(actionHash, int256(msg.value));
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

        // Build the action input hash for matching
        bytes32 actionHash = _computeActionInputHash(
            ActionType.L2TX,
            rollupId,
            address(0),
            0,
            rlpEncodedTx,
            address(0),
            MAINNET_ROLLUP_ID
        );

        emit L2TXExecuted(actionHash, rollupId, rlpEncodedTx);

        return _consumeAndExecute(actionHash, 0);
    }

    // ──────────────────────────────────────────────
    //  Internal execution
    // ──────────────────────────────────────────────

    /// @notice Consumes the next execution entry, applies state deltas, executes calls, and verifies return hash
    /// @param actionHash The expected action input hash for the next entry
    /// @param etherIn The ETH value received (msg.value) for ether accounting
    /// @return result The pre-computed return data from the action
    function _consumeAndExecute(bytes32 actionHash, int256 etherIn) internal returns (bytes memory result) {
        uint256 idx = executionIndex++;
        if (idx >= executions.length) revert ExecutionNotFound();

        ExecutionEntry storage entry = executions[idx];
        if (entry.actionHash != actionHash) revert ExecutionNotFound();

        emit ExecutionConsumed(actionHash, idx);

        _applyAndExecute(entry.stateDeltas, entry.calls, entry.returnHash, etherIn);

        bytes memory returnData = entry.returnData;

        // If the action failed, revert with the return data
        if (entry.failed) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }

        return returnData;
    }

    /// @notice Applies state deltas, processes subcalls, verifies return hash, and checks ether balance
    function _applyAndExecute(
        StateDelta[] memory deltas,
        SubCall[] memory calls,
        bytes32 returnHash,
        int256 etherIn
    ) internal {
        int256 totalEtherDelta = _applyStateDeltas(deltas);
        (bytes32 computedHash, int256 etherOut) = _processSubCalls(bytes32(0), calls);
        if (computedHash != returnHash) revert ReturnHashMismatch();
        if (totalEtherDelta != etherIn - etherOut) revert EtherDeltaMismatch();
    }

    /// @notice Processes sub-calls, opening new contexts for revertSpan subcalls
    /// @param runningHash The accumulated hash from prior calls
    /// @param calls The sub-calls to process
    /// @return computedHash The chained hash of all results
    /// @return etherOut Total ETH sent in successful (non-reverted) calls
    function _processSubCalls(bytes32 runningHash, SubCall[] memory calls) internal returns (
        bytes32 computedHash,
        int256 etherOut
    ) {
        computedHash = runningHash;
        uint256 i = 0;
        while (i < calls.length) {
            SubCall memory subCall = calls[i];

            if (subCall.revertSpan > 0) {
                // Build the slice of calls to execute in an isolated revert context
                SubCall[] memory contextCalls = new SubCall[](subCall.revertSpan);
                for (uint256 j = 0; j < subCall.revertSpan; j++) {
                    contextCalls[j] = calls[i + j];
                }
                // Clear revertSpan on the first call so it executes normally inside the context
                contextCalls[0].revertSpan = 0;

                // Execute in isolated context (always reverts via ContextResult)
                try this.executeInContext(computedHash, contextCalls) {
                    // unreachable — executeInContext always reverts
                } catch (bytes memory revertData) {
                    computedHash = _decodeContextResult(revertData);
                }

                i += subCall.revertSpan;
            } else {
                // Normal execution
                address sourceProxy = computeCrossChainProxyAddress(subCall.sourceAddress, subCall.sourceRollup);
                if (authorizedProxies[sourceProxy].originalAddress == address(0)) {
                    _createCrossChainProxyInternal(subCall.sourceAddress, subCall.sourceRollup);
                }

                (bool success, bytes memory retData) = sourceProxy.call{value: subCall.value}(
                    abi.encodeCall(CrossChainProxy.executeOnBehalf, (subCall.destination, subCall.data))
                );

                if (subCall.value > 0 && success) {
                    etherOut += int256(subCall.value);
                }

                computedHash = keccak256(abi.encodePacked(computedHash, success, retData));

                i++;
            }
        }
    }

    /// @notice Executes sub-calls in an isolated context that always reverts (for failed subcalls)
    /// @dev Can only be called by this contract. Results are encoded in the ContextResult revert.
    /// @param calls The sub-calls to execute in the isolated context
    function executeInContext(bytes32 runningHash, SubCall[] calldata calls) external {
        if (msg.sender != address(this)) revert NotSelf();
        (bytes32 computedHash,) = _processSubCalls(runningHash, calls);
        revert ContextResult(computedHash);
    }

    /// @notice Decodes a ContextResult revert payload, reverting if selector doesn't match
    function _decodeContextResult(bytes memory revertData) internal pure returns (bytes32 computedHash) {
        if (bytes4(revertData) != ContextResult.selector) {
            revert UnexpectedContextRevert(revertData);
        }
        assembly {
            computedHash := mload(add(revertData, 36)) // skip length(32) + selector(4)
        }
    }

    /// @notice Applies state deltas and rollup balance changes
    /// @param deltas The state deltas to apply
    /// @return totalEtherDelta The sum of ether deltas across all rollups
    function _applyStateDeltas(StateDelta[] memory deltas) internal returns (int256 totalEtherDelta) {
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

            emit L2ExecutionPerformed(delta.rollupId, delta.newState);
        }
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
