// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta, StaticCall} from "../../../src/ICrossChainManager.sol";
import {Counter, RevertCounter, SafeCounterAndProxy} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {getOrCreateProxy} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  nestedCallRevert — L1 -> L2 -> L1 nested with inner revert
//
//  D on L2 makes a cross-chain call to RC on L1. RC reverts. D catches the
//  error (try/catch) and returns OK. Both sides succeed.
//
//  No REVERT_CONTINUE needed: RC failed (nothing committed to undo), so
//  RESULT(failed) maps directly to RESULT(ok) on L1. REVERT_CONTINUE is
//  only needed when a scope has SUCCESSFUL calls whose state must be undone.
//
//  Alice on L1 calls D'(proxy for D on L2)
//    -> executeCrossChainCall -> CALL(D) consumed
//    -> scope navigation: CALL(RC, scope=[0])
//    -> RC.increment() reverts on L1
//    -> RESULT(failed) -> RESULT(ok) (no REVERT_CONTINUE — nothing to undo)
//    -> Alice's call succeeds
//
//  Meanwhile on L2 (system executes):
//    executeIncomingCrossChainCall(D, incrementProxy, Alice, MAINNET, [])
//    -> D.incrementProxy() runs on L2
//    -> D calls RC'(proxy for RC on L1) via try/catch
//    -> executeCrossChainCall -> CALL(RC) consumed -> RESULT(failed)
//    -> CallExecutionFailed -> executeCrossChainCall reverts -> entry[0] rolled back
//    -> D catches the revert (try/catch) -> lastCallFailed=true, counter++
//    -> D returns OK -> RESULT(ok) consumed -> terminal
//    -> executeIncomingCrossChainCall succeeds
// ═══════════════════════════════════════════════════════════════════════

/// @dev Centralized action & entry definitions.
abstract contract NestedCallRevertActions {
    uint256 internal constant L2_ROLLUP_ID = 1;
    uint256 internal constant MAINNET_ROLLUP_ID = 0;

    function _revertData() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", "always reverts");
    }

    // ── L1 actions ──

    /// @dev CALL to D on L2 (outer call, from Alice/Batcher on L1)
    function _callToDAction(address counterAndProxyL2, address sourceAddr) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: counterAndProxyL2,
            value: 0,
            data: abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector),
            failed: false,
            isStatic: false,
            sourceAddress: sourceAddr,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });
    }

    /// @dev CALL to RC on L1 at scope=[0] (inner cross-chain call from D)
    function _callToRCScopedAction(address revertCounterL1, address counterAndProxyL2)
        internal
        pure
        returns (Action memory)
    {
        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;
        return Action({
            actionType: ActionType.CALL,
            rollupId: MAINNET_ROLLUP_ID,
            destination: revertCounterL1,
            value: 0,
            data: abi.encodeWithSelector(RevertCounter.increment.selector),
            failed: false,
            isStatic: false,
            sourceAddress: counterAndProxyL2,
            sourceRollup: L2_ROLLUP_ID,
            scope: scope0
        });
    }

    /// @dev RESULT(failed) from RC.increment() reverting
    function _resultFailedAction() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: MAINNET_ROLLUP_ID,
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

    /// @dev Terminal RESULT(ok) — D succeeded, call completes
    function _resultOkAction() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            isStatic: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    // ── L2 actions ──

    /// @dev CALL to RC on L1 (scope=[] — built by executeCrossChainCall on L2)
    function _callToRCAction(address revertCounterL1, address counterAndProxyL2)
        internal
        pure
        returns (Action memory)
    {
        return Action({
            actionType: ActionType.CALL,
            rollupId: MAINNET_ROLLUP_ID,
            destination: revertCounterL1,
            value: 0,
            data: abi.encodeWithSelector(RevertCounter.increment.selector),
            failed: false,
            isStatic: false,
            sourceAddress: counterAndProxyL2,
            sourceRollup: L2_ROLLUP_ID,
            scope: new uint256[](0)
        });
    }

    // ── Entry builders ──

    function _l1Entries(address revertCounterL1, address counterAndProxyL2, address sourceAddr)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        Action memory callToD = _callToDAction(counterAndProxyL2, sourceAddr);
        Action memory callToRCScoped = _callToRCScopedAction(revertCounterL1, counterAndProxyL2);
        Action memory resultFailed = _resultFailedAction();
        Action memory resultOk = _resultOkAction();

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-ncrc-step1");
        bytes32 s2 = keccak256("l2-state-ncrc-step2");

        StateDelta[] memory deltas0 = new StateDelta[](1);
        deltas0[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s0, newState: s1, etherDelta: 0});

        StateDelta[] memory deltas1 = new StateDelta[](1);
        deltas1[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s1, newState: s2, etherDelta: 0});

        entries = new ExecutionEntry[](2);

        // Entry 0: CALL(D) -> CALL(RC, scope=[0])
        entries[0].stateDeltas = deltas0;
        entries[0].actionHash = keccak256(abi.encode(callToD));
        entries[0].nextAction = callToRCScoped;

        // Entry 1: RESULT(failed) -> RESULT(ok)
        // RC failed — nothing committed to undo, so no REVERT_CONTINUE needed.
        // Just map the failure to success directly.
        entries[1].stateDeltas = deltas1;
        entries[1].actionHash = keccak256(abi.encode(resultFailed));
        entries[1].nextAction = resultOk;
    }

    function _l2Entries(address revertCounterL1, address counterAndProxyL2)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        Action memory callToRC = _callToRCAction(revertCounterL1, counterAndProxyL2);
        Action memory resultFailed = _resultFailedAction();
        Action memory resultOk = _resultOkAction();

        entries = new ExecutionEntry[](2);

        // Entry 0: CALL(RC) -> RESULT(failed)
        // Consumed inside D's reentrant executeCrossChainCall, then rolled back when it reverts.
        // D catches the revert via try/catch and continues.
        entries[0].stateDeltas = new StateDelta[](0);
        entries[0].actionHash = keccak256(abi.encode(callToRC));
        entries[0].nextAction = resultFailed;

        // Entry 1: RESULT(ok) -> RESULT(ok) (terminal)
        // D returned OK (caught the revert). This is D's overall result.
        entries[1].stateDeltas = new StateDelta[](0);
        entries[1].actionHash = keccak256(abi.encode(resultOk));
        entries[1].nextAction = resultOk;
    }
}

/// @notice Batcher: postBatch + proxy call in one tx (local mode only)
/// @dev Alice's proxy call succeeds — RESULT(failed) maps to RESULT(ok) on L1.
contract Batcher {
    function execute(Rollups rollups, ExecutionEntry[] calldata entries, address proxy, bytes calldata data) external {
        rollups.postBatch(entries, new StaticCall[](0), 0, "", "proof");
        (bool success, bytes memory ret) = proxy.call(data);
        if (!success) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

/// @title Deploy — Deploy RevertCounter on L1
/// Outputs: REVERT_COUNTER_L1, ALICE
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        RevertCounter rc = new RevertCounter();
        console.log("REVERT_COUNTER_L1=%s", address(rc));
        console.log("ALICE=%s", msg.sender);
        vm.stopBroadcast();
    }
}

/// @title DeployL2 — Deploy D(SafeCounterAndProxy) on L2 targeting RC' proxy
/// @dev Env: MANAGER_L2, REVERT_COUNTER_L1
/// Outputs: COUNTER_AND_PROXY_L2, REVERT_COUNTER_PROXY_L2
contract DeployL2 is Script {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address revertCounterL1Addr = vm.envAddress("REVERT_COUNTER_L1");

        vm.startBroadcast();

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        // RC' = proxy for RevertCounter(L1) on L2
        address revertCounterProxyL2 = getOrCreateProxy(manager, revertCounterL1Addr, 0);

        // D = SafeCounterAndProxy on L2, target = RC' proxy (has try/catch)
        SafeCounterAndProxy d = new SafeCounterAndProxy(Counter(revertCounterProxyL2));

        console.log("COUNTER_AND_PROXY_L2=%s", address(d));
        console.log("REVERT_COUNTER_PROXY_L2=%s", revertCounterProxyL2);

        vm.stopBroadcast();
    }
}

/// @title Deploy2 — Create D' proxy on L1
/// @dev Env: ROLLUPS, COUNTER_AND_PROXY_L2
/// Outputs: COUNTER_AND_PROXY_PROXY_L1
contract Deploy2 is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterAndProxyL2Addr = vm.envAddress("COUNTER_AND_PROXY_L2");

        vm.startBroadcast();

        Rollups rollups = Rollups(rollupsAddr);
        address proxy = getOrCreateProxy(rollups, counterAndProxyL2Addr, 1);
        console.log("COUNTER_AND_PROXY_PROXY_L1=%s", proxy);

        vm.stopBroadcast();
    }
}

/// @title ExecuteL2 — Load L2 table + executeIncomingCrossChainCall (local mode)
/// @dev D.incrementProxy() calls RC' → inner cross-chain call fails → D catches →
///      D returns OK → executeIncomingCrossChainCall SUCCEEDS.
/// Env: MANAGER_L2, REVERT_COUNTER_L1, COUNTER_AND_PROXY_L2
contract ExecuteL2 is Script, NestedCallRevertActions {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address revertCounterL1Addr = vm.envAddress("REVERT_COUNTER_L1");
        address counterAndProxyL2Addr = vm.envAddress("COUNTER_AND_PROXY_L2");

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        vm.startBroadcast();

        address alice = msg.sender; // broadcaster = system = alice in local mode

        manager.loadExecutionTable(_l2Entries(revertCounterL1Addr, counterAndProxyL2Addr), new StaticCall[](0));

        // System executes the incoming cross-chain call.
        // D.incrementProxy() calls RC' → inner call fails → D catches via try/catch →
        // D returns OK → this call SUCCEEDS.
        manager.executeIncomingCrossChainCall(
            counterAndProxyL2Addr,
            0,
            abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector),
            alice,
            MAINNET_ROLLUP_ID,
            new uint256[](0)
        );

        console.log("done");
        // D.counter = 1 (incremented despite inner failure)
        console.log("counter=%s", SafeCounterAndProxy(counterAndProxyL2Addr).counter());
        // D.lastCallFailed = true (caught the revert)
        console.log("lastCallFailed=%s", SafeCounterAndProxy(counterAndProxyL2Addr).lastCallFailed());

        vm.stopBroadcast();
    }
}

/// @title Execute — Local mode: postBatch + Alice calls D' via Batcher on L1
/// @dev RC's RESULT(failed) maps to RESULT(ok) → Alice's call succeeds.
/// Env: ROLLUPS, REVERT_COUNTER_L1, COUNTER_AND_PROXY_L2, COUNTER_AND_PROXY_PROXY_L1
contract Execute is Script, NestedCallRevertActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address revertCounterL1Addr = vm.envAddress("REVERT_COUNTER_L1");
        address counterAndProxyL2Addr = vm.envAddress("COUNTER_AND_PROXY_L2");
        address proxyL1Addr = vm.envAddress("COUNTER_AND_PROXY_PROXY_L1");

        vm.startBroadcast();

        // Predict Batcher address — it will be the sourceAddress for the CALL on L1
        address batcherAddr = vm.computeCreateAddress(msg.sender, vm.getNonce(msg.sender));

        Batcher batcher = new Batcher();
        batcher.execute(
            Rollups(rollupsAddr),
            _l1Entries(revertCounterL1Addr, counterAndProxyL2Addr, batcherAddr),
            proxyL1Addr,
            abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector)
        );

        console.log("done");
        // RC.counter = 0 (reverted inside scope, rolled back by ScopeReverted)
        console.log("counter=%s", RevertCounter(revertCounterL1Addr).counter());

        vm.stopBroadcast();
    }
}

/// @title ExecuteNetwork — Network mode: user transaction only (no Batcher)
/// @dev Env: COUNTER_AND_PROXY_PROXY_L1
contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("COUNTER_AND_PROXY_PROXY_L1");
        bytes memory data = abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector);
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

/// @title ComputeExpected — Compute expected hashes + print expected table
/// @dev Env: REVERT_COUNTER_L1, COUNTER_AND_PROXY_L2, ALICE
contract ComputeExpected is ComputeExpectedBase, NestedCallRevertActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("REVERT_COUNTER_L1")) return "RevertCounter";
        if (a == vm.envAddress("COUNTER_AND_PROXY_L2")) return "SafeCounterAndProxy";
        if (a == vm.envAddress("ALICE")) return "Alice";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == RevertCounter.increment.selector) return "increment";
        if (sel == SafeCounterAndProxy.incrementProxy.selector) return "incrementProxy";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address rcL1 = vm.envAddress("REVERT_COUNTER_L1");
        address capL2 = vm.envAddress("COUNTER_AND_PROXY_L2");
        address alice = vm.envAddress("ALICE");

        // Entries
        ExecutionEntry[] memory l1 = _l1Entries(rcL1, capL2, alice);
        ExecutionEntry[] memory l2 = _l2Entries(rcL1, capL2);

        // Hashes
        bytes32 l1eh0 = _entryHash(l1[0].actionHash, l1[0].nextAction);
        bytes32 l1eh1 = _entryHash(l1[1].actionHash, l1[1].nextAction);
        bytes32 l2eh0 = _entryHash(l2[0].actionHash, l2[0].nextAction);
        bytes32 l2eh1 = _entryHash(l2[1].actionHash, l2[1].nextAction);

        console.log("EXPECTED_L1_HASHES=[%s,%s]", vm.toString(l1eh0), vm.toString(l1eh1));
        console.log("EXPECTED_L2_HASHES=[%s,%s]", vm.toString(l2eh0), vm.toString(l2eh1));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(l1[0].actionHash));

        // Summary
        console.log("");
        console.log("=== EXPECTED SUMMARY ===");
        _logEntrySummary(0, _callToDAction(capL2, alice), _callToRCScopedAction(rcL1, capL2), false);
        _logEntrySummary(1, _resultFailedAction(), _resultOkAction(), false);

        // L1 table (2 entries)
        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (2 entries) ===");
        _logEntry(
            0,
            l1[0].actionHash,
            l1[0].stateDeltas,
            _fmtCall(_callToDAction(capL2, alice)),
            _fmtCall(_callToRCScopedAction(rcL1, capL2))
        );
        _logEntry(
            1,
            l1[1].actionHash,
            l1[1].stateDeltas,
            _fmtResult(_resultFailedAction(), "(revert data)"),
            _fmtResult(_resultOkAction(), "(void)")
        );

        // L2 table (2 entries)
        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (2 entries) ===");
        _logL2Entry(
            0,
            l2eh0,
            _fmtCall(_callToRCAction(rcL1, capL2)),
            _fmtResult(_resultFailedAction(), "(revert data)")
        );
        _logL2Entry(
            1,
            l2eh1,
            _fmtResult(_resultOkAction(), "(void)"),
            string.concat(_fmtResult(_resultOkAction(), "(void)"), "  (terminal)")
        );

        // L2 calls (1 call)
        console.log("");
        console.log("=== EXPECTED L2 CALLS (1 call) ===");
        _logL2Call(0, l1[0].actionHash, _callToDAction(capL2, alice));
    }
}
