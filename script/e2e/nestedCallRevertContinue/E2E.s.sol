// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {RevertCounter} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {getOrCreateProxy} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  nestedCallRevertContinue — L1 -> L2 with L1 success despite L2 failure
//
//  Compare with revertCounter (L1 -> L2 with terminal failure on both):
//    revertCounter:              L1 RESULT(failed) -> Alice's L1 call also fails
//    nestedCallRevertContinue:   L1 RESULT(ok) -> Alice's L1 call succeeds
//
//  The call reverts locally on L2 — no cross-chain call was made from L2,
//  so there is nothing to propagate. Terminal RESULT(failed) on L2.
//  The L1 entry was pre-computed with RESULT(ok) to reflect that the L2
//  failure was expected and accounted for in state deltas.
//
//  Alice calls RevertCounter's proxy on L1
//    -> executeCrossChainCall -> CALL consumed -> RESULT(ok, void)
//    -> _resolveScopes: RESULT is ok -> returns empty data
//    -> Alice's call succeeds
//
//  Meanwhile on L2 (system executes):
//    executeIncomingCrossChainCall(RevertCounter, increment, ...)
//    -> _processCallAtScope -> RevertCounter.increment() reverts locally
//    -> RESULT(failed=true) consumed -> RESULT(failed=true) (terminal)
//    -> _resolveScopes: RESULT.failed -> CallExecutionFailed
//    -> executeIncomingCrossChainCall reverts (expected)
// ═══════════════════════════════════════════════════════════════════════

/// @dev Centralized action & entry definitions for the nestedCallRevertContinue scenario.
abstract contract NestedCallRevertContinueActions {
    uint256 internal constant L2_ROLLUP_ID = 1;

    function _revertData() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", "always reverts");
    }

    /// @dev CALL action as produced by executeCrossChainCall on L1 (Alice calls proxy)
    function _callAction(address revertCounterL2, address sourceAddr) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: revertCounterL2,
            value: 0,
            data: abi.encodeWithSelector(RevertCounter.increment.selector),
            failed: false,
            sourceAddress: sourceAddr,
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    /// @dev RESULT(ok) returned to L1 — L2 handled the revert, call appears successful
    function _resultOkAction() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    /// @dev RESULT(failed) built by _processCallAtScope after RevertCounter reverts
    function _resultFailedAction() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: _revertData(),
            failed: true,
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
        Action memory resultOk = _resultOkAction();

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-revert-handled"),
            etherDelta: 0
        });

        entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = keccak256(abi.encode(call_));
        entries[0].nextAction = resultOk;
    }

    function _l2Entries() internal pure returns (ExecutionEntry[] memory entries) {
        Action memory resultFailed = _resultFailedAction();

        entries = new ExecutionEntry[](1);

        // Entry 0: RESULT(failed) -> RESULT(failed) (terminal)
        // No REVERT/REVERT_CONTINUE — the call reverted locally on L2, no cross-chain call to propagate.
        entries[0].stateDeltas = new StateDelta[](0);
        entries[0].actionHash = keccak256(abi.encode(resultFailed));
        entries[0].nextAction = resultFailed;
    }
}

/// @notice Batcher: postBatch + proxy call in one tx (local mode only)
/// @dev The proxy call succeeds — L1 entry maps CALL to RESULT(ok).
contract Batcher {
    function execute(Rollups rollups, ExecutionEntry[] calldata entries, address proxy, bytes calldata data) external {
        rollups.postBatch(entries, 0, "", "proof");
        (bool success, bytes memory ret) = proxy.call(data);
        if (!success) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
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

/// @title ExecuteL2 — Load L2 execution table + executeIncomingCrossChainCall on L2
/// @dev The incoming call reverts — terminal RESULT(failed), no cross-chain call to propagate.
///   1. Load L2 table: 1 entry (terminal)
///      - RESULT(failed) -> RESULT(failed) (terminal)
///   2. System calls executeIncomingCrossChainCall(RevertCounter, increment, ...)
///      -> RevertCounter reverts locally -> RESULT(failed) terminal -> CallExecutionFailed
///      -> executeIncomingCrossChainCall reverts (expected)
/// Env: MANAGER_L2, REVERT_COUNTER_L2, REVERT_COUNTER_PROXY
contract ExecuteL2 is Script, NestedCallRevertContinueActions {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address revertCounterL2Addr = vm.envAddress("REVERT_COUNTER_L2");
        address revertCounterProxyAddr = vm.envAddress("REVERT_COUNTER_PROXY");

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        vm.startBroadcast();

        manager.loadExecutionTable(_l2Entries());

        // System executes the incoming cross-chain call.
        // RevertCounter.increment() reverts locally on L2 — terminal failure.
        // executeIncomingCrossChainCall reverts with CallExecutionFailed (expected).
        // Use low-level call so forge sees a successful tx and continues.
        (bool success,) = address(manager).call(
            abi.encodeCall(
                CrossChainManagerL2.executeIncomingCrossChainCall,
                (revertCounterL2Addr, 0, abi.encodeWithSelector(RevertCounter.increment.selector), revertCounterProxyAddr, 0, new uint256[](0))
            )
        );
        success; // Expected to revert — suppress unused warning

        console.log("done");
        // counter should still be 0 — increment() reverted
        console.log("counter=%s", RevertCounter(revertCounterL2Addr).counter());

        vm.stopBroadcast();
    }
}

/// @title Execute — Local mode: postBatch + proxy call via Batcher on L1
/// @dev The proxy call succeeds — L1 entry pre-computed with RESULT(ok).
/// Env: ROLLUPS, REVERT_COUNTER_L2, REVERT_COUNTER_PROXY
contract Execute is Script, NestedCallRevertContinueActions {
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
/// The tx succeeds on-chain (L1 entry pre-computed with RESULT(ok)).
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
contract ComputeExpected is ComputeExpectedBase, NestedCallRevertContinueActions {
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
        Action memory resultOk = _resultOkAction();
        Action memory resultFailed = _resultFailedAction();

        // Entries (single source of truth)
        ExecutionEntry[] memory l1 = _l1Entries(revertCounterL2Addr, alice);
        ExecutionEntry[] memory l2 = _l2Entries();

        // Compute hashes from entries
        bytes32 l1Hash = _entryHash(l1[0].actionHash, l1[0].nextAction);
        bytes32 l2eh0 = _entryHash(l2[0].actionHash, l2[0].nextAction);
        bytes32 callActionHash = l1[0].actionHash;

        // Parseable lines
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2eh0));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(callActionHash));

        // Summary
        console.log("");
        console.log("=== EXPECTED SUMMARY ===");
        _logEntrySummary(0, callAction, resultOk, false);

        // Human-readable: L1 execution table (1 entry)
        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (1 entry) ===");
        _logEntry(0, l1[0].actionHash, l1[0].stateDeltas, _fmtCall(callAction), _fmtResult(resultOk, "(void)"));

        // Human-readable: L2 execution table (1 entry)
        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (1 entry) ===");
        _logL2Entry(
            0, l2eh0, _fmtResult(resultFailed, "(revert data)"),
            string.concat(_fmtResult(resultFailed, "(revert data)"), "  (terminal)")
        );

        // Human-readable: L2 calls (1 call)
        console.log("");
        console.log("=== EXPECTED L2 CALLS (1 call) ===");
        _logL2Call(0, callActionHash, callAction);
    }
}
