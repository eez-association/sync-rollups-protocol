// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {Counter, CounterAndProxy} from "../../../test/mocks/CounterContracts.sol";
import {L2TXBatcher, L2TXActionsBase, getOrCreateProxy} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  nestedCounterL2 — Scenario 3: L2 -> L1 -> L2 (nested scope)
//
//  Alice calls CounterAndProxyL1's proxy on L2 (A')
//    -> executeCrossChainCall -> CALL to CounterAndProxyL1 matched
//    -> returns CALL to CounterL2 (nested, scope=[0])
//    -> _resolveScopes -> newScope([0]) -> _processCallAtScope:
//       - A' calls executeOnBehalf(CounterL2, increment)
//       - CounterL2.increment() runs on L2 -> counter 0->1
//       - RESULT matched -> terminal
//
//  Meanwhile on L1 (system posts batch):
//    executeL2TX(rlpAliceTx) -> L2TX matched -> CALL to CounterAndProxyL1
//    -> _processCallAtScope: proxy for Alice calls CounterAndProxyL1.incrementProxy()
//       - inside: calls CounterL2's proxy (B') -> executeCrossChainCall (REENTRANT)
//         -> CALL to CounterL2 matched -> RESULT(1) returned -> targetCounter=1
//       - returns (void) -> RESULT(void) matched -> terminal
// ═══════════════════════════════════════════════════════════════════════

/// @dev Centralized action & entry definitions for the nestedCounterL2 scenario.
///   Single source of truth — used by Execute, ExecuteL2, and ComputeExpected.
abstract contract NestedCounterL2Actions is L2TXActionsBase {

    function _callToCounterAndProxyL1Action(address cap1Addr, address alice)
        internal
        pure
        returns (Action memory)
    {
        return Action({
            actionType: ActionType.CALL,
            rollupId: 0, // MAINNET
            destination: cap1Addr,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            failed: false,
            sourceAddress: alice,
            sourceRollup: L2_ROLLUP_ID,
            scope: new uint256[](0)
        });
    }

    function _callToCounterL2Action(address counterL2, address cap1Addr, uint256[] memory scope)
        internal
        pure
        returns (Action memory)
    {
        return Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: counterL2,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            failed: false,
            sourceAddress: cap1Addr, // CounterAndProxyL1
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: scope
        });
    }

    function _resultFromCounterL2Action() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(1)),
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    function _resultFromCounterAndProxyL1Action() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: 0, // MAINNET
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    /// @dev Spec C.6: Terminal RESULT for L2TX flows.
    ///   rollupId = L2_ROLLUP_ID (the rollup that triggered the L2TX),
    ///   data = "" (empty), sourceAddress = address(0), sourceRollup = 0.
    function _terminalResultAction() internal pure returns (Action memory) {
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

    function _l1Entries(address counterL2, address cap1Addr, address alice, bytes memory rlpEncodedTx)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        Action memory l2tx = _l2txAction(rlpEncodedTx);
        Action memory callToCAP1 = _callToCounterAndProxyL1Action(cap1Addr, alice);
        Action memory callToC2 = _callToCounterL2Action(counterL2, cap1Addr, new uint256[](0));
        Action memory resultC2 = _resultFromCounterL2Action();
        Action memory resultCAP1 = _resultFromCounterAndProxyL1Action();

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-s3-step1");
        bytes32 s2 = keccak256("l2-state-s3-step2");
        bytes32 s3 = keccak256("l2-state-s3-step3");

        StateDelta[] memory deltas0 = new StateDelta[](1);
        deltas0[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s0, newState: s1, etherDelta: 0});

        StateDelta[] memory deltas1 = new StateDelta[](1);
        deltas1[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s1, newState: s2, etherDelta: 0});

        StateDelta[] memory deltas2 = new StateDelta[](1);
        deltas2[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s2, newState: s3, etherDelta: 0});

        entries = new ExecutionEntry[](3);

        entries[0].stateDeltas = deltas0;
        entries[0].actionHash = keccak256(abi.encode(l2tx));
        entries[0].nextAction = callToCAP1;

        entries[1].stateDeltas = deltas1;
        entries[1].actionHash = keccak256(abi.encode(callToC2));
        entries[1].nextAction = resultC2;

        entries[2].stateDeltas = deltas2;
        entries[2].actionHash = keccak256(abi.encode(resultCAP1));
        entries[2].nextAction = _terminalResultAction();
    }

    function _l2Entries(address counterL2, address cap1Addr, address alice)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        Action memory callToCAP1 = _callToCounterAndProxyL1Action(cap1Addr, alice);
        Action memory resultC2 = _resultFromCounterL2Action();
        Action memory resultCAP1 = _resultFromCounterAndProxyL1Action();

        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;
        Action memory callToC2Scoped = _callToCounterL2Action(counterL2, cap1Addr, scope0);

        entries = new ExecutionEntry[](2);

        entries[0].stateDeltas = new StateDelta[](0);
        entries[0].actionHash = keccak256(abi.encode(callToCAP1));
        entries[0].nextAction = callToC2Scoped;

        entries[1].stateDeltas = new StateDelta[](0);
        entries[1].actionHash = keccak256(abi.encode(resultC2));
        entries[1].nextAction = resultCAP1;
    }
}

/// @title DeployL2 — Deploy CounterL2 on L2
/// Outputs: COUNTER_L2, ALICE
contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();

        Counter counterL2 = new Counter();
        console.log("COUNTER_L2=%s", address(counterL2));
        console.log("ALICE=%s", msg.sender);

        vm.stopBroadcast();
    }
}

/// @title Deploy — Deploy CounterAndProxyL1 + CounterL2 proxy on L1
/// @dev Env: ROLLUPS, COUNTER_L2
/// Outputs: COUNTER_PROXY, COUNTER_AND_PROXY
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2Addr = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();

        Rollups rollups = Rollups(rollupsAddr);

        // Proxy for CounterL2, deployed on L1
        address counterProxy = getOrCreateProxy(rollups, counterL2Addr, 1);

        // CounterAndProxyL1: target = CounterL2 proxy
        CounterAndProxy counterAndProxy = new CounterAndProxy(Counter(counterProxy));

        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("COUNTER_AND_PROXY=%s", address(counterAndProxy));

        vm.stopBroadcast();
    }
}

/// @title Deploy2L2 — Create CounterAndProxyL1 proxy on L2
/// @dev Env: MANAGER_L2, COUNTER_AND_PROXY
/// Outputs: COUNTER_AND_PROXY_PROXY_L2
contract Deploy2L2 is Script {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterAndProxyAddr = vm.envAddress("COUNTER_AND_PROXY");

        vm.startBroadcast();

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        // Proxy for CounterAndProxyL1, deployed on L2
        address counterAndProxyProxyL2 = getOrCreateProxy(manager, counterAndProxyAddr, 0);
        console.log("COUNTER_AND_PROXY_PROXY_L2=%s", counterAndProxyProxyL2);

        vm.stopBroadcast();
    }
}

/// @title ExecuteL2 — Load L2 execution table + Alice calls CounterAndProxyL1 proxy on L2 (local mode)
/// @dev Scenario 3 Phase 2:
///   1. Load L2 table: 2 entries
///      - CALL to CounterAndProxyL1 -> CALL to CounterL2 at scope=[0]
///      - RESULT from CounterL2 -> RESULT (terminal)
///   2. Alice calls A'(CounterAndProxyL1 proxy).incrementProxy() via low-level call
/// Env: MANAGER_L2, COUNTER_L2, COUNTER_AND_PROXY, COUNTER_AND_PROXY_PROXY_L2
contract ExecuteL2 is Script, NestedCounterL2Actions {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address counterAndProxyAddr = vm.envAddress("COUNTER_AND_PROXY");
        address counterAndProxyProxyL2Addr = vm.envAddress("COUNTER_AND_PROXY_PROXY_L2");

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        vm.startBroadcast();

        address alice = msg.sender;

        manager.loadExecutionTable(_l2Entries(counterL2Addr, counterAndProxyAddr, alice));

        // Alice calls A' on L2 (low-level call — A' is a proxy)
        bytes memory incrementProxyCallData = abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);
        (bool success,) = counterAndProxyProxyL2Addr.call(incrementProxyCallData);
        require(success, "A' call failed");

        console.log("done");
        console.log("counterL2=%s", Counter(counterL2Addr).counter());

        vm.stopBroadcast();
    }
}

/// @title Execute — Local mode: postBatch (3 entries) + executeL2TX via Batcher on L1
/// @dev Scenario 3 Phase 1:
///   Entry 0: L2TX -> CALL to CounterAndProxyL1        (consumed by executeL2TX)
///   Entry 1: CALL to CounterL2 -> RESULT(1)            (consumed inside reentrant executeCrossChainCall)
///   Entry 2: RESULT(void from CounterAndProxyL1) -> terminal  (consumed after return)
/// Env: ROLLUPS, COUNTER_L2, COUNTER_AND_PROXY, ALICE
contract Execute is Script, NestedCounterL2Actions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address counterAndProxyAddr = vm.envAddress("COUNTER_AND_PROXY");
        address alice = vm.envAddress("ALICE");

        vm.startBroadcast();

        bytes memory rlpTx = vm.envBytes("RLP_ENCODED_TX");

        L2TXBatcher batcher = new L2TXBatcher();
        batcher.execute(
            Rollups(rollupsAddr), _l1Entries(counterL2Addr, counterAndProxyAddr, alice, rlpTx), L2_ROLLUP_ID, rlpTx
        );

        console.log("done");
        console.log("counterAndProxy=%s", CounterAndProxy(counterAndProxyAddr).counter());
        console.log("targetCounter=%s", CounterAndProxy(counterAndProxyAddr).targetCounter());

        vm.stopBroadcast();
    }
}

/// @title ExecuteNetworkL2 — Network mode: user transaction on L2 (trigger)
/// @dev Env: COUNTER_AND_PROXY_PROXY_L2
contract ExecuteNetworkL2 is Script {
    function run() external view {
        address target = vm.envAddress("COUNTER_AND_PROXY_PROXY_L2");
        bytes memory data = abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

/// @title ComputeExpected — Compute expected hashes + print expected table
/// @dev Env: COUNTER_L2, COUNTER_AND_PROXY, ALICE
contract ComputeExpected is ComputeExpectedBase, NestedCounterL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L2")) return "CounterL2";
        if (a == vm.envAddress("COUNTER_AND_PROXY")) return "CounterAndProxyL1";
        if (a == vm.envAddress("ALICE")) return "Alice";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == CounterAndProxy.incrementProxy.selector) return "incrementProxy";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address counterAndProxyAddr = vm.envAddress("COUNTER_AND_PROXY");
        address alice = vm.envAddress("ALICE");
        bytes memory rlpTx = vm.envBytes("RLP_ENCODED_TX");

        // Actions (single source of truth)
        Action memory l2txAction = _l2txAction(rlpTx);
        Action memory callToCounterAndProxyL1 = _callToCounterAndProxyL1Action(counterAndProxyAddr, alice);
        Action memory callToCounterL2 = _callToCounterL2Action(counterL2Addr, counterAndProxyAddr, new uint256[](0));
        Action memory resultFromCounterL2 = _resultFromCounterL2Action();
        Action memory resultFromCounterAndProxyL1 = _resultFromCounterAndProxyL1Action();
        Action memory terminalResult = _terminalResultAction();

        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;
        Action memory callToCounterL2Scoped = _callToCounterL2Action(counterL2Addr, counterAndProxyAddr, scope0);

        // Entries (single source of truth)
        ExecutionEntry[] memory l1 = _l1Entries(counterL2Addr, counterAndProxyAddr, alice, rlpTx);
        ExecutionEntry[] memory l2 = _l2Entries(counterL2Addr, counterAndProxyAddr, alice);

        // Compute hashes from entries
        bytes32 l1eh0 = _entryHash(l1[0].actionHash, l1[0].nextAction);
        bytes32 l1eh1 = _entryHash(l1[1].actionHash, l1[1].nextAction);
        bytes32 l1eh2 = _entryHash(l1[2].actionHash, l1[2].nextAction);
        bytes32 l2eh0 = _entryHash(l2[0].actionHash, l2[0].nextAction);
        bytes32 l2eh1 = _entryHash(l2[1].actionHash, l2[1].nextAction);
        bytes32 h_callToCAP1 = l2[0].actionHash;

        // ── Parseable output ──
        console.log("EXPECTED_L1_HASHES=[%s,%s,%s]", vm.toString(l1eh0), vm.toString(l1eh1), vm.toString(l1eh2));
        console.log("EXPECTED_L2_HASHES=[%s,%s]", vm.toString(l2eh0), vm.toString(l2eh1));
        // No EXPECTED_L2_CALL_HASHES: L2→L1 direction (outgoing executeCrossChainCall, not incoming)

        // Summary
        console.log("");
        console.log("=== EXPECTED SUMMARY ===");
        _logEntrySummary(0, l2txAction, callToCounterAndProxyL1, false);
        _logEntrySummary(1, callToCounterL2, resultFromCounterL2, false);
        _logEntrySummary(2, resultFromCounterAndProxyL1, terminalResult, true);

        // ── Human-readable: L1 execution table (3 entries) ──
        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (3 entries) ===");
        _logEntry(0, l1[0].actionHash, l1[0].stateDeltas, _fmtL2TX(l2txAction), _fmtCall(callToCounterAndProxyL1));
        _logEntry(
            1, l1[1].actionHash, l1[1].stateDeltas, _fmtCall(callToCounterL2), _fmtResult(resultFromCounterL2, "uint256(1)")
        );
        _logEntry(
            2,
            l1[2].actionHash,
            l1[2].stateDeltas,
            _fmtResult(resultFromCounterAndProxyL1, "(void)"),
            string.concat(_fmtResult(terminalResult, "(void)"), "  (terminal)")
        );

        // ── Human-readable: L2 execution table (2 entries) ──
        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (2 entries) ===");
        _logL2Entry(0, l2eh0, _fmtCall(callToCounterAndProxyL1), _fmtCall(callToCounterL2Scoped));
        _logL2Entry(
            1,
            l2eh1,
            _fmtResult(resultFromCounterL2, "uint256(1)"),
            string.concat(_fmtResult(resultFromCounterAndProxyL1, "(void)"), "  (terminal)")
        );

        // ── Human-readable: L2 calls (1 call) ──
        console.log("");
        console.log("=== EXPECTED L2 CALLS (1 call) ===");
        _logL2Call(0, h_callToCAP1, callToCounterAndProxyL1);
    }
}
