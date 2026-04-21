// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {
    Action,
    StateDelta,
    CrossChainCall,
    NestedAction,
    ExecutionEntry
} from "../../../src/ICrossChainManager.sol";
import {RollingHashBuilder} from "./E2EHelpers.sol";

// ════════════════════════════════════════════════════════════════════════
//  Legacy (scope-tree) types from the `main` branch.
//  Kept local so this file compiles on the flatten branch without the
//  old src/ICrossChainManager.sol.
// ════════════════════════════════════════════════════════════════════════

enum LegacyActionType {
    CALL,
    RESULT,
    L2TX,
    REVERT,
    REVERT_CONTINUE
}

struct LegacyAction {
    LegacyActionType actionType;
    uint256 rollupId;
    address destination;
    uint256 value;
    bytes data;
    bool failed;
    address sourceAddress;
    uint256 sourceRollup;
    uint256[] scope;
}

struct LegacyStateDelta {
    uint256 rollupId;
    bytes32 currentState; // dropped in flatten (proof binds prev state)
    bytes32 newState;
    int256 etherDelta;
}

struct LegacyEntry {
    LegacyStateDelta[] stateDeltas;
    bytes32 actionHash;   // hash of the action that TRIGGERS this entry
    LegacyAction nextAction; // the action this entry PRODUCES
}

// ════════════════════════════════════════════════════════════════════════
//  TableTransformer — convert LegacyEntry[] → ExecutionEntry[]
//
//  Direct mapping table:
//
//  legacy nextAction  →  flatten field
//  ─────────────────     ──────────────
//  CALL(scope=[])     →  calls[0]    (top-level call the manager performs)
//  CALL(scope=[N])    →  nestedActions[N-1] (precomputed reentrant return)
//                         … with the follow-up chain collapsed into one.
//  RESULT             →  returnData + success of prev call / nested
//  L2TX               →  entry with actionHash = 0 (immediate) + rlp in calls
//  REVERT             →  enclosing CrossChainCall.revertSpan > 0
//  REVERT_CONTINUE    →  part of a revertSpan-wrapped group
//
//  Supported patterns today:
//    A. Simple "CALL → RESULT" leaf (one legacy entry → one flatten entry).
//    B. Nested "CALL(scope=[]) → CALL(scope=[0]); CALL → RESULT; RESULT → RESULT"
//       (three legacy entries → one flatten entry with 1 call + 1 nested).
//    C. Multicall same-target: N sequential CALL→RESULT pairs.
//
//  Unsupported (left as revert() paths — expand when scenarios need them):
//    D. revertSpan groups (requires modelling REVERT + REVERT_CONTINUE).
//    E. Deep-nested (scope=[0,0,...]) beyond one level — partial support only.
//    F. L2TX → … flows.
// ════════════════════════════════════════════════════════════════════════

library TableTransformer {
    using RollingHashBuilder for bytes32;

    // ── Public API ──────────────────────────────────────────────────────

    /// @notice Transform a legacy scope-tagged table into a flatten table.
    /// @dev Walks `legacy` entries in order and groups them by scope into
    ///      flatten `ExecutionEntry` structs. The number of output entries
    ///      is typically less than the input (scope siblings are collapsed).
    function convertTable(LegacyEntry[] memory legacy)
        internal
        pure
        returns (ExecutionEntry[] memory flat)
    {
        // Two-pass: first pass counts outputs, second pass fills them.
        uint256 count = _countOutputs(legacy);
        flat = new ExecutionEntry[](count);

        uint256 outIdx = 0;
        uint256 i = 0;
        while (i < legacy.length) {
            (ExecutionEntry memory entry, uint256 consumed) = _convertOne(legacy, i);
            flat[outIdx++] = entry;
            i += consumed;
        }
    }

    /// @notice Convert a single "simple" legacy entry (CALL→RESULT leaf) to flatten.
    function convertSimple(LegacyEntry memory leaf)
        internal
        pure
        returns (ExecutionEntry memory entry)
    {
        require(leaf.nextAction.actionType == LegacyActionType.RESULT, "not a leaf");

        entry.stateDeltas = _convertDeltas(leaf.stateDeltas);
        entry.actionHash = leaf.actionHash;
        entry.calls = new CrossChainCall[](0);
        entry.nestedActions = new NestedAction[](0);
        entry.callCount = 0;
        entry.returnData = leaf.nextAction.data;
        entry.failed = leaf.nextAction.failed;
        entry.rollingHash = bytes32(0); // no calls, no nesting
    }

    /// @notice Convert a nested group of legacy entries (1 outer + N inner) to one flatten entry.
    /// @param outer   the entry whose nextAction is CALL(scope=[0]) — opens the nested scope.
    /// @param inner   the entries that live inside that nested scope (in scope order),
    ///                ending with the RESULT(scope=[]) that closes the scope.
    /// @param outerReturn  the RESULT entry that closes the outer scope (maps inner result to outer).
    function convertNested(
        LegacyEntry memory outer,
        LegacyEntry[] memory inner,
        LegacyEntry memory outerReturn
    ) internal pure returns (ExecutionEntry memory entry) {
        require(outer.nextAction.actionType == LegacyActionType.CALL, "outer not CALL");
        require(outerReturn.nextAction.actionType == LegacyActionType.RESULT, "outerReturn not RESULT");

        // calls[0] = the call the outer entry issues (its nextAction, modulo scope)
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = _toCrossChainCall(outer.nextAction);

        // nestedActions[0] = the precomputed reentrant result.
        // Derived from inner[0] (the entry triggered by the nested call): its actionHash
        // matches the reentrant call; its nextAction.data is the precomputed return.
        NestedAction[] memory nested = new NestedAction[](1);
        require(inner.length >= 1, "nested needs >=1 inner");
        LegacyEntry memory innerLeaf = inner[0];
        require(innerLeaf.nextAction.actionType == LegacyActionType.RESULT, "inner not RESULT");
        nested[0] = NestedAction({
            actionHash: innerLeaf.actionHash,
            callCount: 0, // simple case: no deeper nesting
            returnData: innerLeaf.nextAction.data
        });

        // state deltas come from whichever legacy entry carried them (commonly `outer`)
        entry.stateDeltas = _convertDeltas(outer.stateDeltas);
        entry.actionHash = outer.actionHash;
        entry.calls = calls;
        entry.nestedActions = nested;
        entry.callCount = 1;
        entry.returnData = outerReturn.nextAction.data;
        entry.failed = outerReturn.nextAction.failed;

        // rollingHash replay: CALL_BEGIN(1) → NESTED_BEGIN(1) → NESTED_END(1) → CALL_END(1, !failed, retData)
        bytes32 h = bytes32(0);
        h = h.appendCallBegin(1);
        h = h.appendNestedBegin(1);
        h = h.appendNestedEnd(1);
        h = h.appendCallEnd(1, !outerReturn.nextAction.failed, outerReturn.nextAction.data);
        entry.rollingHash = h;
    }

    // ── Internals ───────────────────────────────────────────────────────

    /// @dev Count flatten outputs by dry-running the walker.
    function _countOutputs(LegacyEntry[] memory legacy) private pure returns (uint256 count) {
        uint256 i = 0;
        while (i < legacy.length) {
            LegacyEntry memory head = legacy[i];
            if (head.nextAction.actionType == LegacyActionType.CALL && _isChildScope(head.nextAction.scope)) {
                // Nested group: consume 3 entries (outer + inner leaf + outer return)
                i += 3;
            } else {
                // Simple leaf or top-level CALL
                i += 1;
            }
            count++;
        }
    }

    /// @dev Convert a group starting at `start`. Returns the entry + number of legacy
    ///      entries consumed.
    function _convertOne(LegacyEntry[] memory legacy, uint256 start)
        private
        pure
        returns (ExecutionEntry memory entry, uint256 consumed)
    {
        LegacyEntry memory head = legacy[start];

        // Case A: simple leaf — RESULT at root scope.
        if (head.nextAction.actionType == LegacyActionType.RESULT && head.nextAction.scope.length == 0) {
            return (convertSimple(head), 1);
        }

        // Case B: nested outer — CALL whose scope is [0] (opens depth-1 nested scope).
        //         Heuristic for the simple one-level nested pattern:
        //           legacy[start]       : outer CALL(scope=[0])  — opens nested
        //           legacy[start+1]     : inner leaf — RESULT(scope=[]) closes the nested scope
        //           legacy[start+2]     : outer return — RESULT(scope=[]) closes the outer scope
        //         Consumes exactly 3 entries. Deeper nesting requires recursing on
        //         the inner slice (not implemented here yet — left as TODO).
        if (head.nextAction.actionType == LegacyActionType.CALL && _isChildScope(head.nextAction.scope)) {
            require(start + 2 < legacy.length, "nested group truncated");
            LegacyEntry[] memory inner = new LegacyEntry[](1);
            inner[0] = legacy[start + 1];
            LegacyEntry memory outerReturn = legacy[start + 2];
            return (convertNested(head, inner, outerReturn), 3);
        }

        // Case C: top-level CALL with empty scope (shouldn't happen in well-formed tables,
        // but treat as simple if nextAction is a CALL at root — emit a minimal entry).
        if (head.nextAction.actionType == LegacyActionType.CALL && head.nextAction.scope.length == 0) {
            ExecutionEntry memory e;
            e.stateDeltas = _convertDeltas(head.stateDeltas);
            e.actionHash = head.actionHash;

            CrossChainCall[] memory cc = new CrossChainCall[](1);
            cc[0] = _toCrossChainCall(head.nextAction);
            e.calls = cc;
            e.nestedActions = new NestedAction[](0);
            e.callCount = 1;
            e.returnData = "";
            e.failed = false;

            bytes32 h = bytes32(0);
            h = h.appendCallBegin(1);
            h = h.appendCallEnd(1, true, "");
            e.rollingHash = h;

            return (e, 1);
        }

        revert("unsupported legacy pattern");
    }

    function _convertDeltas(LegacyStateDelta[] memory legacy)
        private
        pure
        returns (StateDelta[] memory flat)
    {
        flat = new StateDelta[](legacy.length);
        for (uint256 i = 0; i < legacy.length; i++) {
            flat[i] = StateDelta({
                rollupId: legacy[i].rollupId,
                newState: legacy[i].newState,
                etherDelta: legacy[i].etherDelta
            });
        }
    }

    function _toCrossChainCall(LegacyAction memory a)
        private
        pure
        returns (CrossChainCall memory)
    {
        return CrossChainCall({
            destination: a.destination,
            value: a.value,
            data: a.data,
            sourceAddress: a.sourceAddress,
            sourceRollup: a.sourceRollup,
            revertSpan: a.actionType == LegacyActionType.REVERT ? 1 : 0
        });
    }

    function _isChildScope(uint256[] memory scope) private pure returns (bool) {
        // Depth-1 child scope: [0] or [N]
        return scope.length == 1;
    }
}

// ════════════════════════════════════════════════════════════════════════
//  Example driver — demonstrates the transformation on a small table.
//  Run:  forge script script/e2e/shared/TableTransformer.sol:DemoTransform
// ════════════════════════════════════════════════════════════════════════

contract DemoTransform is Script {
    function run() external pure {
        // Build a toy legacy table mirroring the main-branch nestedCounter scenario:
        //   [0] trigger: CALL(A)            → CALL(B, scope=[0])    (outer, opens depth-1)
        //   [1] trigger: CALL(B, scope=[])  → RESULT(1)             (inner leaf)
        //   [2] trigger: RESULT(1)          → RESULT(void)          (outer return)
        LegacyEntry[] memory legacy = new LegacyEntry[](3);

        // Shared placeholder addresses
        address A = address(0xAAAA);
        address B = address(0xBBBB);
        address alice = address(0x1111);

        // Entry [0]
        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;

        LegacyStateDelta[] memory deltas = new LegacyStateDelta[](1);
        deltas[0] = LegacyStateDelta({
            rollupId: 1,
            currentState: keccak256("s0"),
            newState: keccak256("s1"),
            etherDelta: 0
        });
        legacy[0] = LegacyEntry({
            stateDeltas: deltas,
            actionHash: keccak256("outerTrigger"),
            nextAction: LegacyAction({
                actionType: LegacyActionType.CALL,
                rollupId: 0,
                destination: B,
                value: 0,
                data: hex"11",
                failed: false,
                sourceAddress: A,
                sourceRollup: 1,
                scope: scope0
            })
        });

        // Entry [1] — inner leaf
        uint256[] memory emptyScope = new uint256[](0);
        legacy[1] = LegacyEntry({
            stateDeltas: new LegacyStateDelta[](0),
            actionHash: keccak256("innerTrigger"),
            nextAction: LegacyAction({
                actionType: LegacyActionType.RESULT,
                rollupId: 0,
                destination: address(0),
                value: 0,
                data: abi.encode(uint256(1)),
                failed: false,
                sourceAddress: address(0),
                sourceRollup: 0,
                scope: emptyScope
            })
        });

        // Entry [2] — outer return (at root scope again)
        legacy[2] = LegacyEntry({
            stateDeltas: new LegacyStateDelta[](0),
            actionHash: keccak256("outerReturnTrigger"),
            nextAction: LegacyAction({
                actionType: LegacyActionType.RESULT,
                rollupId: 1,
                destination: address(0),
                value: 0,
                data: "",
                failed: false,
                sourceAddress: address(0),
                sourceRollup: 0,
                scope: emptyScope
            })
        });

        ExecutionEntry[] memory flat = TableTransformer.convertTable(legacy);
        console.log("flat.length=%s (expected 1)", flat.length);
        console.log("flat[0].actionHash=%s", vm.toString(flat[0].actionHash));
        console.log("flat[0].calls.length=%s", flat[0].calls.length);
        console.log("flat[0].nestedActions.length=%s", flat[0].nestedActions.length);
        console.log("flat[0].callCount=%s", flat[0].callCount);
        console.log("flat[0].rollingHash=%s", vm.toString(flat[0].rollingHash));
        console.log("flat[0].returnData.len=%s", flat[0].returnData.length);

        // silence unused
        alice;
    }
}
