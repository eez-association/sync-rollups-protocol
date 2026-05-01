// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Rollups, ProofSystemBatch} from "../../../src/Rollups.sol";
import {
    ICrossChainManager,
    ExecutionEntry,
    LookupCall,
    CrossChainCall,
    NestedAction
} from "../../../src/ICrossChainManager.sol";

// ══════════════════════════════════════════════════════════════════════
//  Rolling hash tag constants (must match Rollups.sol / CrossChainManagerL2.sol)
// ══════════════════════════════════════════════════════════════════════
uint8 constant CALL_BEGIN = 1;
uint8 constant CALL_END = 2;
uint8 constant NESTED_BEGIN = 3;
uint8 constant NESTED_END = 4;

// ══════════════════════════════════════════════════════════════════════
//  Idempotent proxy creation helper
// ══════════════════════════════════════════════════════════════════════

/// @notice Returns existing proxy if already deployed, otherwise creates it.
function getOrCreateProxy(ICrossChainManager manager, address originalAddress, uint256 originalRollupId)
    returns (address proxy)
{
    try manager.createCrossChainProxy(originalAddress, originalRollupId) returns (address p) {
        proxy = p;
    } catch {
        proxy = manager.computeCrossChainProxyAddress(originalAddress, originalRollupId);
    }
}

/// @notice Cross-chain call hash builder matching `Rollups.computeCrossChainCallHash`.
/// @dev Same formula on L1 and L2; off-chain tooling and on-chain code share this preimage.
function crossChainCallHash(
    uint256 targetRollupId,
    address targetAddress,
    uint256 value,
    bytes memory data,
    address sourceAddress,
    uint256 sourceRollupId
)
    pure
    returns (bytes32)
{
    return keccak256(abi.encode(targetRollupId, targetAddress, value, data, sourceAddress, sourceRollupId));
}

/// @notice **Backward-compatibility shim** for legacy E2E scripts.
/// @dev The `Action` struct was removed from `ICrossChainManager.sol`. E2E flow scripts
///      pre-refactor used it heavily as an off-chain "tooling-side" record of the inputs
///      that hash to `crossChainCallHash`. Re-defined here with the same field order so
///      existing scripts can keep using `Action({...})` literals; computing the hash via
///      `actionHash(...)` (also shimmed) routes to the canonical formula.
///      New code should call `crossChainCallHash(...)` directly with individual fields.
struct Action {
    uint256 targetRollupId;
    address targetAddress;
    uint256 value;
    bytes data;
    address sourceAddress;
    uint256 sourceRollupId;
}

/// @notice Backward-compat: `actionHash(Action)` → `crossChainCallHash(...)`.
function actionHash(Action memory a) pure returns (bytes32) {
    return crossChainCallHash(a.targetRollupId, a.targetAddress, a.value, a.data, a.sourceAddress, a.sourceRollupId);
}

/// @notice Backward-compat alias: `noStaticCalls()` returns an empty `LookupCall[]`.
function noStaticCalls() pure returns (LookupCall[] memory) {
    return new LookupCall[](0);
}

// ══════════════════════════════════════════════════════════════════════
//  RollingHashBuilder — replay the same tagged-hash sequence that
//  Rollups._processNCalls / _consumeNestedAction produce on-chain.
// ══════════════════════════════════════════════════════════════════════

library RollingHashBuilder {
    /// @notice keccak256(prev ++ CALL_BEGIN ++ callNumber)
    function appendCallBegin(bytes32 prev, uint256 callNumber) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, CALL_BEGIN, callNumber));
    }

    /// @notice keccak256(prev ++ CALL_END ++ callNumber ++ success ++ retData)
    function appendCallEnd(bytes32 prev, uint256 callNumber, bool success, bytes memory retData)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(prev, CALL_END, callNumber, success, retData));
    }

    /// @notice keccak256(prev ++ NESTED_BEGIN ++ nestedNumber)
    function appendNestedBegin(bytes32 prev, uint256 nestedNumber) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, NESTED_BEGIN, nestedNumber));
    }

    /// @notice keccak256(prev ++ NESTED_END ++ nestedNumber)
    function appendNestedEnd(bytes32 prev, uint256 nestedNumber) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, NESTED_END, nestedNumber));
    }
}

// ══════════════════════════════════════════════════════════════════════
//  L2TXBatcher — postBatch + executeL2TX in one tx (local mode).
//  Satisfies the same-block requirement.
//
//  POST-REFACTOR: postBatch now takes `ProofSystemBatch[]`. The batcher wraps the
//  caller's entries into a single sub-batch with the supplied proofSystem + rollupId,
//  then drains immediate entries (transientCount = leading-zero-actionHash run length)
//  and finally calls executeL2TX(rollupId).
// ══════════════════════════════════════════════════════════════════════

contract L2TXBatcher {
    function execute(
        Rollups rollups,
        address proofSystem,
        uint256 rollupId,
        ExecutionEntry[] calldata entries,
        LookupCall[] calldata lookupCalls
    )
        external
    {
        // Compute transientCount as the count of leading entries whose crossChainCallHash == 0
        // (immediate entries — no source action to match, run inline during postBatch).
        uint256 tc = 0;
        while (tc < entries.length && entries[tc].crossChainCallHash == bytes32(0)) {
            tc++;
        }

        address[] memory psList = new address[](1);
        psList[0] = proofSystem;
        uint256[] memory rids = new uint256[](1);
        rids[0] = rollupId;
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";
        ProofSystemBatch[] memory batches = new ProofSystemBatch[](1);
        batches[0] = ProofSystemBatch({
            proofSystems: psList,
            rollupIds: rids,
            entries: entries,
            lookupCalls: lookupCalls,
            transientCount: tc,
            transientLookupCallCount: 0,
            blobIndices: new uint256[](0),
            callData: "",
            proof: proofs,
            crossProofSystemInteractions: bytes32(0)
        });
        rollups.postBatch(batches);
        rollups.executeL2TX(rollupId);
    }
}

// ══════════════════════════════════════════════════════════════════════
//  Common empty helpers (saves boilerplate in E2E scripts)
// ══════════════════════════════════════════════════════════════════════

/// @notice Returns an empty LookupCall[] (for flows that don't use lookup calls).
function noLookupCalls() pure returns (LookupCall[] memory) {
    return new LookupCall[](0);
}

/// @notice Returns an empty NestedAction[].
function noNestedActions() pure returns (NestedAction[] memory) {
    return new NestedAction[](0);
}

/// @notice Returns an empty CrossChainCall[].
function noCalls() pure returns (CrossChainCall[] memory) {
    return new CrossChainCall[](0);
}
