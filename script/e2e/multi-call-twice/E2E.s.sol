// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {Counter} from "../../../test/mocks/CounterContracts.sol";
import {CallTwice} from "../../../test/mocks/MultiCallContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";

/// @dev Centralized action & entry definitions for the multi-call-twice scenario.
///   Single source of truth — used by Execute, ExecuteL2, and ComputeExpected.
abstract contract MultiCallTwiceActions {
    function _callAction(address counterA, address callTwice) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.CALL,
            rollupId: 1,
            destination: counterA,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            failed: false,
            sourceAddress: callTwice,
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    function _result1Action() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: 1,
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(1)),
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    function _result2Action() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: 1,
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(2)),
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    function _l1Entries(address counterA, address callTwice)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        Action memory call_ = _callAction(counterA, callTwice);
        Action memory result1 = _result1Action();
        Action memory result2 = _result2Action();

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-multicall-after-first");
        bytes32 s2 = keccak256("l2-state-multicall-after-second");

        StateDelta[] memory deltas1 = new StateDelta[](1);
        deltas1[0] = StateDelta({rollupId: 1, currentState: s0, newState: s1, etherDelta: 0});

        StateDelta[] memory deltas2 = new StateDelta[](1);
        deltas2[0] = StateDelta({rollupId: 1, currentState: s1, newState: s2, etherDelta: 0});

        bytes32 actionHash = keccak256(abi.encode(call_));

        entries = new ExecutionEntry[](2);
        entries[0].stateDeltas = deltas1;
        entries[0].actionHash = actionHash;
        entries[0].nextAction = result1;

        entries[1].stateDeltas = deltas2;
        entries[1].actionHash = actionHash;
        entries[1].nextAction = result2;
    }

    function _l2Entries(address counterA, address callTwice)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        Action memory call_ = _callAction(counterA, callTwice);
        Action memory result1 = _result1Action();
        Action memory result2 = _result2Action();

        entries = new ExecutionEntry[](2);
        entries[0].stateDeltas = new StateDelta[](0);
        entries[0].actionHash = keccak256(abi.encode(result1));
        entries[0].nextAction = call_;

        entries[1].stateDeltas = new StateDelta[](0);
        entries[1].actionHash = keccak256(abi.encode(result2));
        entries[1].nextAction = result2;
    }
}

/// @notice Batcher: postBatch + callCounterTwice in one tx
contract Batcher {
    function execute(
        Rollups rollups,
        ExecutionEntry[] calldata entries,
        CallTwice app,
        address counterProxy
    ) external returns (uint256 first, uint256 second) {
        rollups.postBatch(entries, 0, "", "proof");
        (first, second) = app.callCounterTwice(counterProxy);
    }
}

/// @title DeployL2 — Deploy Counter on L2
/// @dev Outputs: COUNTER_A
contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterA = new Counter();
        console.log("COUNTER_A=%s", address(counterA));
        vm.stopBroadcast();
    }
}

/// @title Deploy — Deploy CallTwice + proxy on L1
/// @dev Env: ROLLUPS, COUNTER_A
/// Outputs: CALL_TWICE, PROXY_A
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterAAddr = vm.envAddress("COUNTER_A");
        vm.startBroadcast();

        Rollups rollups = Rollups(rollupsAddr);
        CallTwice callTwice = new CallTwice();

        // Try to create proxy; if it already exists (CreateCollision), compute the address
        address proxyA;
        try rollups.createCrossChainProxy(counterAAddr, 1) returns (address p) {
            proxyA = p;
        } catch {
            proxyA = rollups.computeCrossChainProxyAddress(counterAAddr, 1);
        }

        console.log("CALL_TWICE=%s", address(callTwice));
        console.log("PROXY_A=%s", proxyA);

        vm.stopBroadcast();
    }
}

/// @title ExecuteL2 — Load L2 table + executeIncomingCrossChainCall (chained)
/// @dev Env: MANAGER_L2, COUNTER_A, CALL_TWICE
///
/// L2 execution table (2 entries, chained):
///   [0] hash(RESULT_1) → CALL(counterA again)     ← result of 1st chains to 2nd call
///   [1] hash(RESULT_2) → RESULT_2 (terminal)       ← result of 2nd is terminal
///
/// 1 executeIncomingCrossChainCall. Chaining handles the second invocation.
contract ExecuteL2 is Script, MultiCallTwiceActions {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterAAddr = vm.envAddress("COUNTER_A");
        address callTwiceAddr = vm.envAddress("CALL_TWICE");

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        vm.startBroadcast();

        manager.loadExecutionTable(_l2Entries(counterAAddr, callTwiceAddr));

        // Single call: chaining handles the second invocation
        manager.executeIncomingCrossChainCall(
            counterAAddr, 0, abi.encodeWithSelector(Counter.increment.selector), callTwiceAddr, 0, new uint256[](0)
        );

        console.log("L2 execution complete");
        console.log("counter=%s", Counter(counterAAddr).counter());

        vm.stopBroadcast();
    }
}

/// @title Execute — Local mode: postBatch + callCounterTwice via Batcher
/// @dev Env: ROLLUPS, COUNTER_A, CALL_TWICE, PROXY_A
contract Execute is Script, MultiCallTwiceActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterAAddr = vm.envAddress("COUNTER_A");
        address callTwiceAddr = vm.envAddress("CALL_TWICE");
        address proxyAAddr = vm.envAddress("PROXY_A");

        vm.startBroadcast();

        Batcher batcher = new Batcher();
        (uint256 first, uint256 second) = batcher.execute(
            Rollups(rollupsAddr), _l1Entries(counterAAddr, callTwiceAddr), CallTwice(callTwiceAddr), proxyAAddr
        );

        console.log("done");
        console.log("first=%s", first);
        console.log("second=%s", second);

        vm.stopBroadcast();
    }
}

/// @title ExecuteNetwork — Network mode: user transaction only
/// @dev Env: CALL_TWICE, PROXY_A
/// Returns (target, value, calldata) so the runner can send via `cast send`.
/// We can't use `forge script --broadcast` because the tx reverts in local simulation
/// (no execution table loaded yet). The system intercepts the tx from the mempool
/// and inserts postBatch before it in the same block.
contract ExecuteNetwork is Script {
    function run() external view {
        address callTwiceAddr = vm.envAddress("CALL_TWICE");
        address proxyAAddr = vm.envAddress("PROXY_A");
        bytes memory data = abi.encodeWithSelector(CallTwice.callCounterTwice.selector, proxyAAddr);
        console.log("TARGET=%s", callTwiceAddr);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

/// @title ComputeExpected — Compute expected hashes for CallTwice scenario
/// @dev Env: COUNTER_A, CALL_TWICE
contract ComputeExpected is ComputeExpectedBase, MultiCallTwiceActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_A")) return "Counter";
        if (a == vm.envAddress("CALL_TWICE")) return "CallTwice";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterAAddr = vm.envAddress("COUNTER_A");
        address callTwiceAddr = vm.envAddress("CALL_TWICE");

        // Actions (single source of truth)
        Action memory callAction = _callAction(counterAAddr, callTwiceAddr);
        Action memory result1 = _result1Action();
        Action memory result2 = _result2Action();

        // Entries (single source of truth)
        ExecutionEntry[] memory l1 = _l1Entries(counterAAddr, callTwiceAddr);
        ExecutionEntry[] memory l2 = _l2Entries(counterAAddr, callTwiceAddr);

        // Compute hashes from entries
        bytes32 l1Entry1 = _entryHash(l1[0].actionHash, l1[0].nextAction);
        bytes32 l1Entry2 = _entryHash(l1[1].actionHash, l1[1].nextAction);
        bytes32 l2Entry0 = _entryHash(l2[0].actionHash, l2[0].nextAction);
        bytes32 l2Entry1 = _entryHash(l2[1].actionHash, l2[1].nextAction);

        // L2 call hash: what executeIncomingCrossChainCall emits
        bytes32 l2CallHash = l1[0].actionHash;

        console.log("EXPECTED_L1_HASHES=[%s,%s]", vm.toString(l1Entry1), vm.toString(l1Entry2));
        console.log("EXPECTED_L2_HASHES=[%s,%s]", vm.toString(l2Entry0), vm.toString(l2Entry1));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(l2CallHash));

        // Summary
        console.log("");
        console.log("=== EXPECTED SUMMARY ===");
        _logEntrySummary(0, callAction, result1, false);
        _logEntrySummary(1, callAction, result2, false);

        // ── L1 execution table ──
        {
            console.log("");
            console.log("=== EXPECTED L1 EXECUTION TABLE (2 entries, same action hash) ===");
            _logEntry(0, l1Entry1, l1[0].stateDeltas, _fmtCall(callAction), _fmtResult(result1, "uint256(1)"));
            _logEntry(
                1,
                l1Entry2,
                l1[1].stateDeltas,
                string.concat(_fmtCall(callAction), "  (same hash, 2nd consumption)"),
                _fmtResult(result2, "uint256(2)")
            );
        }

        // ── L2 execution table (chained) ──
        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (2 entries, chained) ===");
        _logL2Entry(
            0,
            l2Entry0,
            _fmtResult(result1, "uint256(1)"),
            string.concat(_fmtCall(callAction), "  (chains to 2nd call)")
        );
        _logL2Entry(
            1,
            l2Entry1,
            _fmtResult(result2, "uint256(2)"),
            string.concat(_fmtResult(result2, "uint256(2)"), "  (terminal)")
        );

        // ── L2 calls ──
        console.log("");
        console.log("=== EXPECTED L2 CALLS (1 call) ===");
        _logL2Call(0, l2CallHash, callAction);
    }
}
