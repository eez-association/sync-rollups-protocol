// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta, StaticCall} from "../../../src/ICrossChainManager.sol";
import {RevertCounter} from "../../../test/mocks/CounterContracts.sol";
import {L2TXBatcher, L2TXActionsBase, getOrCreateProxy} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  revertCounterL2 — L2 -> L1 with REVERT_CONTINUE on L1 (L2TX)
//
//  RC reverts locally on L1 inside executeL2TX. L2TX applies state deltas
//  when consuming entries — even though RC failed, the deltas from entry[0]
//  are committed within the scope. REVERT_CONTINUE is needed so
//  ScopeReverted can roll back those committed deltas.
//
//  Alice calls RevertCounter's proxy on L2
//    -> executeCrossChainCall -> CALL consumed -> RESULT(failed=true)
//    -> _resolveScopes reverts (CallExecutionFailed)
//    -> Alice's call reverts (expected, terminal failure on L2)
//
//  Meanwhile on L1 (system posts batch + executeL2TX):
//    postBatch stores 3 deferred entries
//    executeL2TX triggers scope navigation:
//      -> L2TX consumed (S0→S1) -> CALL(RevertCounter, scope=[0])
//      -> newScope([0]): RevertCounter.increment() reverts on L1
//      -> RESULT(failed) consumed (S1→S2) -> REVERT(scope=[0])
//      -> _getRevertContinuation -> REVERT_CONTINUE consumed (S2→S3)
//      -> ScopeReverted: rolls back S2,S3 -> state restored to S2
//      -> continuation RESULT(ok) -> executeL2TX succeeds
// ═══════════════════════════════════════════════════════════════════════

/// @dev Centralized action & entry definitions for the revertCounterL2 scenario.
abstract contract RevertCounterL2Actions is L2TXActionsBase {
    function _revertData() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", "always reverts");
    }

    /// @dev CALL action as produced by executeCrossChainCall on L2 (scope=[])
    function _callAction(address revertCounterL1, address sourceAddr) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.CALL,
            rollupId: 0,
            destination: revertCounterL1,
            value: 0,
            data: abi.encodeWithSelector(RevertCounter.increment.selector),
            failed: false,
            isStatic: false,
            sourceAddress: sourceAddr,
            sourceRollup: L2_ROLLUP_ID,
            scope: new uint256[](0)
        });
    }

    function _resultFailedAction() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: 0,
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

    /// @dev Same CALL but with scope=[0] for L1 scope navigation
    function _callActionScoped(address revertCounterL1, address sourceAddr) internal pure returns (Action memory) {
        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;
        return Action({
            actionType: ActionType.CALL,
            rollupId: 0,
            destination: revertCounterL1,
            value: 0,
            data: abi.encodeWithSelector(RevertCounter.increment.selector),
            failed: false,
            isStatic: false,
            sourceAddress: sourceAddr,
            sourceRollup: L2_ROLLUP_ID,
            scope: scope0
        });
    }

    function _revertAction() internal pure returns (Action memory) {
        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;
        return Action({
            actionType: ActionType.REVERT,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            isStatic: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: scope0
        });
    }

    function _revertContinueAction() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.REVERT_CONTINUE,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: "",
            failed: true,
            isStatic: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    function _finalResultAction() internal pure returns (Action memory) {
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

    function _l1Entries(address revertCounterL1, address sourceAddr, bytes memory rlpEncodedTx)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        Action memory l2tx = _l2txAction(rlpEncodedTx);
        Action memory callScoped = _callActionScoped(revertCounterL1, sourceAddr);
        Action memory resultFailed = _resultFailedAction();
        Action memory revertAct = _revertAction();
        Action memory revertCont = _revertContinueAction();
        Action memory finalResult = _finalResultAction();

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-revctr-step1");
        bytes32 s2 = keccak256("l2-state-revctr-step2");
        bytes32 s3 = keccak256("l2-state-revctr-step3");

        StateDelta[] memory deltas0 = new StateDelta[](1);
        deltas0[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s0, newState: s1, etherDelta: 0});

        StateDelta[] memory deltas1 = new StateDelta[](1);
        deltas1[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s1, newState: s2, etherDelta: 0});

        StateDelta[] memory deltas2 = new StateDelta[](1);
        deltas2[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s2, newState: s3, etherDelta: 0});

        entries = new ExecutionEntry[](3);

        // Entry 0: L2TX -> CALL(RevertCounter, scope=[0])
        entries[0].stateDeltas = deltas0;
        entries[0].actionHash = keccak256(abi.encode(l2tx));
        entries[0].nextAction = callScoped;

        // Entry 1: RESULT(failed) -> REVERT(scope=[0])
        entries[1].stateDeltas = deltas1;
        entries[1].actionHash = keccak256(abi.encode(resultFailed));
        entries[1].nextAction = revertAct;

        // Entry 2: REVERT_CONTINUE -> final RESULT(ok)
        // L2TX applies deltas on consumption — ScopeReverted needed to roll them back.
        entries[2].stateDeltas = deltas2;
        entries[2].actionHash = keccak256(abi.encode(revertCont));
        entries[2].nextAction = finalResult;
    }

    function _l2Entries(address revertCounterL1, address sourceAddr)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        Action memory call_ = _callAction(revertCounterL1, sourceAddr);
        Action memory resultFailed = _resultFailedAction();

        entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = new StateDelta[](0);
        entries[0].actionHash = keccak256(abi.encode(call_));
        entries[0].nextAction = resultFailed;
    }
}

/// @title Deploy — Deploy RevertCounter on L1
/// @dev Env: (none)
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

/// @title DeployL2 — Create proxy for RevertCounter(L1) on L2
/// @dev Env: MANAGER_L2, REVERT_COUNTER_L1
/// Outputs: REVERT_COUNTER_PROXY_L2
contract DeployL2 is Script {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address revertCounterL1Addr = vm.envAddress("REVERT_COUNTER_L1");

        vm.startBroadcast();

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);
        address revertCounterProxyL2 = getOrCreateProxy(manager, revertCounterL1Addr, 0);

        console.log("REVERT_COUNTER_PROXY_L2=%s", revertCounterProxyL2);

        vm.stopBroadcast();
    }
}

/// @notice Helper: wraps Alice's proxy call so the revert doesn't crash the forge script.
///         The cross-chain RESULT(failed=true) causes CallExecutionFailed, which reverts
///         executeCrossChainCall. This helper catches it via low-level call.
contract RevertCallHelper {
    function callExpectRevert(address proxy, bytes calldata data) external {
        (bool success,) = proxy.call(data);
        success; // Expected to revert — suppress unused warning
    }
}

/// @title ExecuteL2 — Load L2 table + Alice calls RevertCounter proxy (local mode)
/// @dev Alice's call is expected to revert — executeCrossChainCall returns RESULT(failed=true)
///      which causes _resolveScopes to revert with CallExecutionFailed.
///      We deploy RevertCallHelper to wrap the call so forge sees all txs as successful.
/// Env: MANAGER_L2, REVERT_COUNTER_L1, REVERT_COUNTER_PROXY_L2
contract ExecuteL2 is Script, RevertCounterL2Actions {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address revertCounterL1Addr = vm.envAddress("REVERT_COUNTER_L1");
        address revertCounterProxyL2Addr = vm.envAddress("REVERT_COUNTER_PROXY_L2");

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        vm.startBroadcast();

        // Predict RevertCallHelper address — it will be the sourceAddress (msg.sender at proxy level)
        address helperAddr = vm.computeCreateAddress(msg.sender, vm.getNonce(msg.sender));

        manager.loadExecutionTable(_l2Entries(revertCounterL1Addr, helperAddr), new StaticCall[](0));

        // Alice calls RevertCounter proxy on L2 — expected to revert.
        // Use RevertCallHelper so forge broadcasts a successful tx (the helper catches the revert).
        RevertCallHelper helper = new RevertCallHelper();
        helper.callExpectRevert(revertCounterProxyL2Addr, abi.encodeWithSelector(RevertCounter.increment.selector));

        console.log("done");

        vm.stopBroadcast();
    }
}

/// @title Execute — Local mode: postBatch + executeL2TX via L2TXBatcher on L1
/// @dev executeL2TX succeeds — REVERT_CONTINUE handles RC's failure within scope.
/// Env: ROLLUPS, REVERT_COUNTER_L1, ALICE
contract Execute is Script, RevertCounterL2Actions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address revertCounterL1Addr = vm.envAddress("REVERT_COUNTER_L1");
        address alice = vm.envAddress("ALICE");

        vm.startBroadcast();

        bytes memory rlpTx = vm.envBytes("RLP_ENCODED_TX");

        L2TXBatcher batcher = new L2TXBatcher();
        batcher.execute(Rollups(rollupsAddr), _l1Entries(revertCounterL1Addr, alice, rlpTx), L2_ROLLUP_ID, rlpTx);

        console.log("done");
        // RevertCounter.counter should still be 0 — increment() reverted inside scope
        console.log("counter=%s", RevertCounter(revertCounterL1Addr).counter());

        vm.stopBroadcast();
    }
}

/// @title ExecuteNetworkL2 — Network mode: user transaction on L2 (trigger)
/// @dev Env: REVERT_COUNTER_PROXY_L2
/// The tx reverts on-chain (RESULT failed -> CallExecutionFailed).
/// The system still processes the L1 side via postBatch + executeL2TX.
contract ExecuteNetworkL2 is Script {
    function run() external view {
        address target = vm.envAddress("REVERT_COUNTER_PROXY_L2");
        bytes memory data = abi.encodeWithSelector(RevertCounter.increment.selector);
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

/// @title ComputeExpected — Compute expected hashes + print expected table
/// @dev Env: REVERT_COUNTER_L1, ALICE
contract ComputeExpected is ComputeExpectedBase, RevertCounterL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("REVERT_COUNTER_L1")) return "RevertCounter";
        if (a == vm.envAddress("ALICE")) return "Alice";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == RevertCounter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        _logHashes();
        _logSummary();
        _logL1Table();
        _logL2Table();
    }

    function _logHashes() internal view {
        address rc = vm.envAddress("REVERT_COUNTER_L1");
        address alice = vm.envAddress("ALICE");
        bytes memory rlpTx = vm.envBytes("RLP_ENCODED_TX");

        ExecutionEntry[] memory l1 = _l1Entries(rc, alice, rlpTx);
        ExecutionEntry[] memory l2 = _l2Entries(rc, alice);

        bytes32 l1eh0 = _entryHash(l1[0].actionHash, l1[0].nextAction);
        bytes32 l1eh1 = _entryHash(l1[1].actionHash, l1[1].nextAction);
        bytes32 l1eh2 = _entryHash(l1[2].actionHash, l1[2].nextAction);
        bytes32 l2eh0 = _entryHash(l2[0].actionHash, l2[0].nextAction);

        console.log("EXPECTED_L1_HASHES=[%s,%s,%s]", vm.toString(l1eh0), vm.toString(l1eh1), vm.toString(l1eh2));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2eh0));
    }

    function _logSummary() internal view {
        address rc = vm.envAddress("REVERT_COUNTER_L1");
        address alice = vm.envAddress("ALICE");
        bytes memory rlpTx = vm.envBytes("RLP_ENCODED_TX");

        console.log("");
        console.log("=== EXPECTED SUMMARY ===");
        _logEntrySummary(0, _l2txAction(rlpTx), _callActionScoped(rc, alice), false);
        _logEntrySummary(1, _resultFailedAction(), _revertAction(), false);
        _logEntrySummary(2, _revertContinueAction(), _finalResultAction(), false);
    }

    function _logL1Table() internal view {
        address rc = vm.envAddress("REVERT_COUNTER_L1");
        address alice = vm.envAddress("ALICE");
        bytes memory rlpTx = vm.envBytes("RLP_ENCODED_TX");

        ExecutionEntry[] memory l1 = _l1Entries(rc, alice, rlpTx);

        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (3 entries) ===");
        _logEntry(
            0, l1[0].actionHash, l1[0].stateDeltas, _fmtL2TX(_l2txAction(rlpTx)), _fmtCall(_callActionScoped(rc, alice))
        );
        _logEntry(
            1,
            l1[1].actionHash,
            l1[1].stateDeltas,
            _fmtResult(_resultFailedAction(), "(revert data)"),
            "REVERT rollupId=1 scope=[0]"
        );
        _logEntry(
            2,
            l1[2].actionHash,
            l1[2].stateDeltas,
            "REVERT_CONTINUE rollupId=1",
            _fmtResult(_finalResultAction(), "(void)  (continuation)")
        );
    }

    function _logL2Table() internal view {
        address rc = vm.envAddress("REVERT_COUNTER_L1");
        address alice = vm.envAddress("ALICE");

        ExecutionEntry[] memory l2 = _l2Entries(rc, alice);
        bytes32 l2eh0 = _entryHash(l2[0].actionHash, l2[0].nextAction);

        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (1 entry) ===");
        _logL2Entry(0, l2eh0, _fmtCall(_callAction(rc, alice)), _fmtResult(_resultFailedAction(), "(revert data)"));

        // No L2 calls for L2->L1 scenario
    }
}
