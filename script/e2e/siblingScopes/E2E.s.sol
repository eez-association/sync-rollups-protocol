// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {Counter, CallTwoProxies} from "../../../test/mocks/CounterContracts.sol";
import {L2TXBatcher, L2TXActionsBase, getOrCreateProxy} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  siblingScopes — L2 -> L1 with scope=[0] then scope=[1] (sibling navigation)
//
//  Tests sibling scope routing. On L2, CallTwoProxies(SCX) calls two
//  L1 counter proxies sequentially. On L1, executeL2TX navigates
//  scope=[0] then scope=[1] — the navigator returns from [0] to the
//  parent, which routes to [1].
//
//  ┌─────────────────────────────────────────────────────────────────┐
//  │  L2 execution                                                  │
//  │    Alice -> SCX.callBoth()                                     │
//  │      -> CounterA_proxy.increment() -> CALL consumed -> RES(1)  │
//  │      -> CounterB_proxy.increment() -> CALL consumed -> RES(1)  │
//  │      <- SCX: result1=1, result2=1                              │
//  │                                                                │
//  │  L1 execution (executeL2TX)                                    │
//  │    L2TX consumed (S0->S1) -> CALL(CounterA, scope=[0])         │
//  │    -> newScope([]) -> newScope([0])                             │
//  │       -> CounterA.increment() returns 1                        │
//  │       -> RESULT consumed (S1->S2) -> CALL(CounterB, scope=[1]) │
//  │       -> newScope([0]) sees [1] as sibling -> breaks           │
//  │    -> newScope([]) routes to newScope([1])                     │
//  │       -> CounterB.increment() returns 1                        │
//  │       -> RESULT consumed (S2->S3) -> terminal                  │
//  └─────────────────────────────────────────────────────────────────┘
// ═══════════════════════════════════════════════════════════════════════

/// @dev Centralized action & entry definitions for the siblingScopes scenario.
///   Single source of truth — used by Execute, ExecuteL2, and ComputeExpected.
abstract contract SiblingScopesActions is L2TXActionsBase {

    function _callToCounter(address counter, address scx, uint256[] memory scope)
        internal
        pure
        returns (Action memory)
    {
        return Action({
            actionType: ActionType.CALL,
            rollupId: 0,
            destination: counter,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            failed: false,
            sourceAddress: scx,
            sourceRollup: L2_ROLLUP_ID,
            scope: scope
        });
    }

    function _resultFromCounter() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: 0,
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(1)),
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    function _delta(bytes32 from, bytes32 to) internal pure returns (StateDelta[] memory d) {
        d = new StateDelta[](1);
        d[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: from, newState: to, etherDelta: 0});
    }

    function _l1Entries(address counterA, address counterB, address scx, bytes memory rlpTx)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;
        uint256[] memory scope1 = new uint256[](1);
        scope1[0] = 1;

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-sibling-step1");
        bytes32 s2 = keccak256("l2-state-sibling-step2");
        bytes32 s3 = keccak256("l2-state-sibling-step3");

        entries = new ExecutionEntry[](3);

        entries[0].stateDeltas = _delta(s0, s1);
        entries[0].actionHash = keccak256(abi.encode(_l2txAction(rlpTx)));
        entries[0].nextAction = _callToCounter(counterA, scx, scope0);

        // Same RESULT hash as entry 2 — differentiated by currentState (s1 vs s2)
        entries[1].stateDeltas = _delta(s1, s2);
        entries[1].actionHash = keccak256(abi.encode(_resultFromCounter()));
        entries[1].nextAction = _callToCounter(counterB, scx, scope1);

        entries[2].stateDeltas = _delta(s2, s3);
        entries[2].actionHash = keccak256(abi.encode(_resultFromCounter()));
        entries[2].nextAction = _terminalResultL2Tx();
    }

    function _l2Entries(address counterA, address counterB, address scx)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        entries = new ExecutionEntry[](2);

        // Entry 0: CALL(CounterA, from=SCX, scope=[]) -> RESULT(1)
        entries[0].stateDeltas = new StateDelta[](0);
        entries[0].actionHash = keccak256(abi.encode(_callToCounter(counterA, scx, new uint256[](0))));
        entries[0].nextAction = _resultFromCounter();

        // Entry 1: CALL(CounterB, from=SCX, scope=[]) -> RESULT(1)
        entries[1].stateDeltas = new StateDelta[](0);
        entries[1].actionHash = keccak256(abi.encode(_callToCounter(counterB, scx, new uint256[](0))));
        entries[1].nextAction = _resultFromCounter();
    }
}

// ═══════════════════════════════════════════════════════════════
//  Deploy contracts
// ═══════════════════════════════════════════════════════════════

/// @title Deploy — Deploy CounterA and CounterB on L1
/// Outputs: COUNTER_A, COUNTER_B, ALICE
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();

        Counter counterA = new Counter();
        Counter counterB = new Counter();

        console.log("COUNTER_A=%s", address(counterA));
        console.log("COUNTER_B=%s", address(counterB));
        console.log("ALICE=%s", msg.sender);

        vm.stopBroadcast();
    }
}

/// @title DeployL2 — Deploy proxies + SCX (CallTwoProxies) on L2
/// @dev Env: MANAGER_L2, COUNTER_A, COUNTER_B
/// Outputs: COUNTER_A_PROXY_L2, COUNTER_B_PROXY_L2, SCX
contract DeployL2 is Script {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterAAddr = vm.envAddress("COUNTER_A");
        address counterBAddr = vm.envAddress("COUNTER_B");

        vm.startBroadcast();

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        // Proxies for L1 counters, deployed on L2
        address counterAProxyL2 = getOrCreateProxy(manager, counterAAddr, 0);
        address counterBProxyL2 = getOrCreateProxy(manager, counterBAddr, 0);

        // SCX: calls both proxies sequentially
        CallTwoProxies scx = new CallTwoProxies(Counter(counterAProxyL2), Counter(counterBProxyL2));

        console.log("COUNTER_A_PROXY_L2=%s", counterAProxyL2);
        console.log("COUNTER_B_PROXY_L2=%s", counterBProxyL2);
        console.log("SCX=%s", address(scx));

        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════
//  Execute
// ═══════════════════════════════════════════════════════════════

/// @title ExecuteL2 — Load L2 table + Alice calls SCX.callBoth() on L2 (local mode)
/// @dev SCX calls CounterA_proxy then CounterB_proxy — two executeCrossChainCalls
/// Env: MANAGER_L2, COUNTER_A, COUNTER_B, SCX
contract ExecuteL2 is Script, SiblingScopesActions {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterAAddr = vm.envAddress("COUNTER_A");
        address counterBAddr = vm.envAddress("COUNTER_B");
        address scxAddr = vm.envAddress("SCX");

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        vm.startBroadcast();

        manager.loadExecutionTable(_l2Entries(counterAAddr, counterBAddr, scxAddr));

        // Alice calls SCX.callBoth() on L2
        CallTwoProxies(scxAddr).callBoth();

        console.log("done");

        vm.stopBroadcast();
    }
}

/// @title Execute — Local mode: postBatch (3 entries) + executeL2TX via L2TXBatcher on L1
/// @dev Entry 0: L2TX -> CALL(CounterA, scope=[0])
///      Entry 1: RESULT(1) -> CALL(CounterB, scope=[1])
///      Entry 2: RESULT(1) -> terminal
/// Env: ROLLUPS, COUNTER_A, COUNTER_B, SCX
contract Execute is Script, SiblingScopesActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterAAddr = vm.envAddress("COUNTER_A");
        address counterBAddr = vm.envAddress("COUNTER_B");
        address scxAddr = vm.envAddress("SCX");

        vm.startBroadcast();

        bytes memory rlpTx = vm.envBytes("RLP_ENCODED_TX");

        L2TXBatcher batcher = new L2TXBatcher();
        batcher.execute(
            Rollups(rollupsAddr), _l1Entries(counterAAddr, counterBAddr, scxAddr, rlpTx), L2_ROLLUP_ID, rlpTx
        );

        console.log("done");
        console.log("counterA=%s", Counter(counterAAddr).counter());
        console.log("counterB=%s", Counter(counterBAddr).counter());

        vm.stopBroadcast();
    }
}

/// @title ExecuteNetworkL2 — Network mode: user transaction on L2 (trigger)
/// @dev Env: SCX
contract ExecuteNetworkL2 is Script {
    function run() external view {
        address target = vm.envAddress("SCX");
        bytes memory data = abi.encodeWithSelector(CallTwoProxies.callBoth.selector);
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

// ═══════════════════════════════════════════════════════════════
//  Verification
// ═══════════════════════════════════════════════════════════════

/// @title ComputeExpected — Compute expected hashes + print expected table
/// @dev Env: COUNTER_A, COUNTER_B, SCX, ALICE
contract ComputeExpected is ComputeExpectedBase, SiblingScopesActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_A")) return "CounterA";
        if (a == vm.envAddress("COUNTER_B")) return "CounterB";
        if (a == vm.envAddress("SCX")) return "SCX";
        if (a == vm.envAddress("ALICE")) return "Alice";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == CallTwoProxies.callBoth.selector) return "callBoth";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterAAddr = vm.envAddress("COUNTER_A");
        address counterBAddr = vm.envAddress("COUNTER_B");
        address scxAddr = vm.envAddress("SCX");
        bytes memory rlpTx = vm.envBytes("RLP_ENCODED_TX");

        // Build entries from single source of truth
        ExecutionEntry[] memory l1 = _l1Entries(counterAAddr, counterBAddr, scxAddr, rlpTx);
        ExecutionEntry[] memory l2 = _l2Entries(counterAAddr, counterBAddr, scxAddr);

        // Compute hashes
        bytes32 l1eh0 = _entryHash(l1[0].actionHash, l1[0].nextAction);
        bytes32 l1eh1 = _entryHash(l1[1].actionHash, l1[1].nextAction);
        bytes32 l1eh2 = _entryHash(l1[2].actionHash, l1[2].nextAction);
        bytes32 l2eh0 = _entryHash(l2[0].actionHash, l2[0].nextAction);
        bytes32 l2eh1 = _entryHash(l2[1].actionHash, l2[1].nextAction);
        bytes32 h_callA = l2[0].actionHash;
        bytes32 h_callB = l2[1].actionHash;

        // Parseable output
        console.log(
            "EXPECTED_L1_HASHES=[%s,%s,%s]", vm.toString(l1eh0), vm.toString(l1eh1), vm.toString(l1eh2)
        );
        console.log("EXPECTED_L2_HASHES=[%s,%s]", vm.toString(l2eh0), vm.toString(l2eh1));
        // No EXPECTED_L2_CALL_HASHES: L2→L1 direction (outgoing executeCrossChainCall, not incoming)

        // Actions for logging
        Action memory l2txAction = _l2txAction(rlpTx);
        Action memory callAUnscoped = _callToCounter(counterAAddr, scxAddr, new uint256[](0));
        Action memory callBUnscoped = _callToCounter(counterBAddr, scxAddr, new uint256[](0));

        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;
        uint256[] memory scope1 = new uint256[](1);
        scope1[0] = 1;
        Action memory callAScoped = _callToCounter(counterAAddr, scxAddr, scope0);
        Action memory callBScoped = _callToCounter(counterBAddr, scxAddr, scope1);
        Action memory result1 = _resultFromCounter();
        Action memory terminal = _terminalResultL2Tx();

        // Summary
        console.log("");
        console.log("=== EXPECTED SUMMARY ===");
        _logEntrySummary(0, l2txAction, callAScoped, false);
        _logEntrySummary(1, result1, callBScoped, false);
        _logEntrySummary(2, result1, terminal, true);

        // L1 execution table
        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (3 entries) ===");
        _logEntry(0, l1[0].actionHash, l1[0].stateDeltas, _fmtL2TX(l2txAction), _fmtCall(callAScoped));
        _logEntry(1, l1[1].actionHash, l1[1].stateDeltas, _fmtResult(result1, "uint256(1)"), _fmtCall(callBScoped));
        _logEntry(
            2,
            l1[2].actionHash,
            l1[2].stateDeltas,
            _fmtResult(result1, "uint256(1)"),
            string.concat(_fmtResult(terminal, "(void)"), "  (terminal)")
        );

        // L2 execution table
        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (2 entries) ===");
        _logL2Entry(0, l2eh0, _fmtCall(callAUnscoped), _fmtResult(result1, "uint256(1)"));
        _logL2Entry(1, l2eh1, _fmtCall(callBUnscoped), _fmtResult(result1, "uint256(1)"));

        // L2 calls
        console.log("");
        console.log("=== EXPECTED L2 CALLS (2 calls) ===");
        _logL2Call(0, h_callA, callAUnscoped);
        _logL2Call(1, h_callB, callBUnscoped);
    }
}
