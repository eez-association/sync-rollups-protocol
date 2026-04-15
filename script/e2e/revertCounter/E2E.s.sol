// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta, StaticCall} from "../../../src/ICrossChainManager.sol";
import {RevertCounter} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {getOrCreateProxy} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  revertCounter — L1 -> L2 with terminal revert
//
//  Terminal revert: the call fails on L2, no state change is propagated.
//  The system does NOT load an L2 execution table or execute anything on L2.
//  E2E verification checks that L2 entries are ABSENT.
//
//  L1 side:
//    Alice calls RevertCounter's proxy on L1
//    -> executeCrossChainCall -> CALL consumed -> RESULT(failed=true)
//    -> _resolveScopes reverts (CallExecutionFailed)
//    -> Batcher catches the revert, postBatch still committed
//
//  L2 side:
//    No execution. Terminal revert means no L2 state change.
//    The system skips loading an execution table for this batch.
// ═══════════════════════════════════════════════════════════════════════

/// @dev Centralized action & entry definitions for the revertCounter scenario.
abstract contract RevertCounterActions {
    function _revertData() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", "always reverts");
    }

    function _callAction(address revertCounterL2, address sourceAddr) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.CALL,
            rollupId: 1,
            destination: revertCounterL2,
            value: 0,
            data: abi.encodeWithSelector(RevertCounter.increment.selector),
            failed: false,
            isStatic: false,
            sourceAddress: sourceAddr,
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    function _resultFailedAction() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: 1,
            destination: address(0),
            value: 0,
            data: _revertData(),
            failed: true,
            isStatic: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    function _l1Entries(address revertCounterL2, address sourceAddr)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        Action memory call_ = _callAction(revertCounterL2, sourceAddr);
        Action memory result = _resultFailedAction();

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: 1,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-revert-counter"),
            etherDelta: 0
        });

        entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = keccak256(abi.encode(call_));
        entries[0].nextAction = result;
    }

    /// @dev Computes what L2 entries WOULD look like if the system incorrectly included them.
    ///      Used by ComputeExpected to output ABSENT_L2_HASHES for negative verification.
    function _l2Entries() internal pure returns (ExecutionEntry[] memory entries) {
        Action memory result = _resultFailedAction();

        entries = new ExecutionEntry[](1);

        // Entry 0: RESULT(failed) -> RESULT(failed) (terminal, self-referencing)
        entries[0].stateDeltas = new StateDelta[](0);
        entries[0].actionHash = keccak256(abi.encode(result));
        entries[0].nextAction = result;
    }
}

/// @notice Batcher: postBatch + proxy call in one tx (local mode only)
/// @dev The proxy call is expected to revert (RevertCounter always reverts).
///      We use a low-level call so postBatch effects are preserved.
contract Batcher {
    function execute(Rollups rollups, ExecutionEntry[] calldata entries, address proxy, bytes calldata data) external {
        rollups.postBatch(entries, new StaticCall[](0), 0, "", "proof");
        (bool success,) = proxy.call(data);
        success; // Expected to revert — suppress unused warning
    }
}

/// @title DeployL2 — Deploy RevertCounter on L2
/// Outputs: REVERT_COUNTER_L2
contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        RevertCounter rc = new RevertCounter();
        console.log("REVERT_COUNTER_L2=%s", address(rc));
        vm.stopBroadcast();
    }
}

/// @title Deploy — Create proxy for RevertCounter(L2) on L1
/// @dev Env: ROLLUPS, REVERT_COUNTER_L2
/// Outputs: REVERT_COUNTER_PROXY, ALICE
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address revertCounterL2Addr = vm.envAddress("REVERT_COUNTER_L2");

        vm.startBroadcast();

        Rollups rollups = Rollups(rollupsAddr);
        address revertCounterProxy = getOrCreateProxy(rollups, revertCounterL2Addr, 1);

        console.log("REVERT_COUNTER_PROXY=%s", revertCounterProxy);
        console.log("ALICE=%s", msg.sender);

        vm.stopBroadcast();
    }
}

/// @title ExecuteL2 — No-op: terminal revert means no L2 execution
/// @dev The call reverts on L1 — no state change is propagated to L2.
///      In network mode, the system does NOT load an execution table or call
///      executeIncomingCrossChainCall for terminal reverts.
///      This is a no-op so the local runner can proceed.
contract ExecuteL2 is Script {
    function run() external {
        vm.startBroadcast();
        console.log("done (no-op: terminal revert, no L2 activity)");
        vm.stopBroadcast();
    }
}

/// @title Execute — Local mode: postBatch + proxy call via Batcher on L1
/// @dev The proxy call reverts (RevertCounter always reverts). The Batcher catches
///      the revert so postBatch effects are preserved.
/// Env: ROLLUPS, REVERT_COUNTER_L2, REVERT_COUNTER_PROXY
contract Execute is Script, RevertCounterActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address revertCounterL2Addr = vm.envAddress("REVERT_COUNTER_L2");
        address revertCounterProxyAddr = vm.envAddress("REVERT_COUNTER_PROXY");

        vm.startBroadcast();

        // Predict Batcher address — it will be the sourceAddress for the CALL on L1
        address batcherAddr = vm.computeCreateAddress(msg.sender, vm.getNonce(msg.sender));

        Batcher batcher = new Batcher();
        batcher.execute(
            Rollups(rollupsAddr),
            _l1Entries(revertCounterL2Addr, batcherAddr),
            revertCounterProxyAddr,
            abi.encodeWithSelector(RevertCounter.increment.selector)
        );

        console.log("done");

        vm.stopBroadcast();
    }
}

/// @title ExecuteNetwork — Network mode: user transaction only (no Batcher)
/// @dev Env: REVERT_COUNTER_PROXY
/// The tx reverts on-chain (RevertCounter always reverts). The system still processes the L2 side.
contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("REVERT_COUNTER_PROXY");
        bytes memory data = abi.encodeWithSelector(RevertCounter.increment.selector);
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

/// @title ComputeExpected — Compute expected hashes + print expected table
/// @dev Env: REVERT_COUNTER_L2, ALICE
contract ComputeExpected is ComputeExpectedBase, RevertCounterActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("REVERT_COUNTER_L2")) return "RevertCounter";
        if (a == vm.envAddress("ALICE")) return "Alice";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == RevertCounter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address revertCounterL2Addr = vm.envAddress("REVERT_COUNTER_L2");
        address alice = vm.envAddress("ALICE");

        // Actions (single source of truth)
        Action memory callAction = _callAction(revertCounterL2Addr, alice);
        Action memory resultFailed = _resultFailedAction();

        // Entries (single source of truth)
        ExecutionEntry[] memory l1 = _l1Entries(revertCounterL2Addr, alice);

        // Compute hashes from entries
        bytes32 l1Hash = _entryHash(l1[0].actionHash, l1[0].nextAction);

        // Compute L2 entry hashes — these should NOT appear on L2 (terminal revert = no L2 activity)
        ExecutionEntry[] memory l2 = _l2Entries();
        bytes32 l2eh0 = _entryHash(l2[0].actionHash, l2[0].nextAction);

        // Parseable lines
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("EXPECTED_L2_HASHES=[]");
        console.log("EXPECTED_L2_CALL_HASHES=[]");
        // Terminal revert: these L2 entries must NOT be present on L2
        console.log("ABSENT_L2_HASHES=[%s]", vm.toString(l2eh0));

        // Summary
        console.log("");
        console.log("=== EXPECTED SUMMARY ===");
        _logEntrySummary(0, callAction, resultFailed, false);
        console.log("  L2: terminal revert -- verify ABSENT (no L2 state change)");

        // Human-readable: L1 execution table (1 entry)
        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (1 entry) ===");
        _logEntry(
            0, l1[0].actionHash, l1[0].stateDeltas, _fmtCall(callAction), _fmtResult(resultFailed, "(revert data)")
        );

        // L2: show what WOULD be there (but shouldn't)
        console.log("");
        console.log("=== ABSENT L2 ENTRIES (must NOT appear on L2) ===");
        _logL2Entry(
            0, l2eh0, _fmtResult(resultFailed, "(revert data)"),
            string.concat(_fmtResult(resultFailed, "(revert data)"), "  (terminal)")
        );
    }
}
