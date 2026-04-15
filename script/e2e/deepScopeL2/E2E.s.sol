// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta, StaticCall} from "../../../src/ICrossChainManager.sol";
import {Counter, CounterAndProxy, NestedCaller} from "../../../test/mocks/CounterContracts.sol";
import {L2TXBatcher, L2TXActionsBase, getOrCreateProxy} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  deepScope — L2 -> L1 with scope=[0,0] (deep nesting)
//
//  Tests scope navigation at depth 2. On L2, NestedCaller(SCA) calls
//  CounterAndProxy(SCB) which calls CounterL1's proxy — two levels of
//  L2 calls wrapping a cross-chain operation. On L1, executeL2TX
//  navigates scope=[0,0].
//
//  ┌─────────────────────────────────────────────────────────────┐
//  │  L2 execution                                              │
//  │    Alice -> SCA.callNested()                               │
//  │      -> SCB.incrementProxy()                               │
//  │         -> CounterL1_proxy.increment()                     │
//  │            -> executeCrossChainCall -> CALL consumed        │
//  │            <- RESULT(1) returned via table                 │
//  │         <- SCB: targetCounter=1, counter=1                 │
//  │      <- SCA: counter=1                                     │
//  │                                                            │
//  │  L1 execution (executeL2TX)                                │
//  │    L2TX consumed (S0->S1) -> CALL(CounterL1, scope=[0,0]) │
//  │    -> newScope([]) -> newScope([0]) -> newScope([0,0])     │
//  │       -> SCB_proxy.executeOnBehalf(CounterL1, increment)   │
//  │       -> CounterL1.increment() returns 1                   │
//  │    -> RESULT consumed (S1->S2) -> terminal                 │
//  └─────────────────────────────────────────────────────────────┘
// ═══════════════════════════════════════════════════════════════════════

/// @dev Centralized action & entry definitions for the deepScope scenario.
///   Single source of truth — used by Execute, ExecuteL2, and ComputeExpected.
abstract contract DeepScopeActions is L2TXActionsBase {

    function _callToCounterL1(address counterL1, address scb, uint256[] memory scope)
        internal
        pure
        returns (Action memory)
    {
        return Action({
            actionType: ActionType.CALL,
            rollupId: 0,
            destination: counterL1,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            failed: false,
            isStatic: false,
            sourceAddress: scb,
            sourceRollup: L2_ROLLUP_ID,
            scope: scope
        });
    }

    function _resultFromCounterL1() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: 0,
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(1)),
            failed: false,
            isStatic: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    function _delta(bytes32 from, bytes32 to) internal pure returns (StateDelta[] memory d) {
        d = new StateDelta[](1);
        d[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: from, newState: to, etherDelta: 0});
    }

    function _l1Entries(address counterL1, address scb, bytes memory rlpTx)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        uint256[] memory scope00 = new uint256[](2);
        scope00[0] = 0;
        scope00[1] = 0;

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-deep-step1");
        bytes32 s2 = keccak256("l2-state-deep-step2");

        entries = new ExecutionEntry[](2);

        entries[0].stateDeltas = _delta(s0, s1);
        entries[0].actionHash = keccak256(abi.encode(_l2txAction(rlpTx)));
        entries[0].nextAction = _callToCounterL1(counterL1, scb, scope00);

        entries[1].stateDeltas = _delta(s1, s2);
        entries[1].actionHash = keccak256(abi.encode(_resultFromCounterL1()));
        entries[1].nextAction = _terminalResultL2Tx();
    }

    function _l2Entries(address counterL1, address scb)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        entries = new ExecutionEntry[](1);

        entries[0].stateDeltas = new StateDelta[](0);
        entries[0].actionHash = keccak256(abi.encode(_callToCounterL1(counterL1, scb, new uint256[](0))));
        entries[0].nextAction = _resultFromCounterL1();
    }
}

// ═══════════════════════════════════════════════════════════════
//  Deploy contracts
// ═══════════════════════════════════════════════════════════════

/// @title Deploy — Deploy CounterL1 on L1
/// Outputs: COUNTER_L1, ALICE
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();

        Counter counterL1 = new Counter();
        console.log("COUNTER_L1=%s", address(counterL1));
        console.log("ALICE=%s", msg.sender);

        vm.stopBroadcast();
    }
}

/// @title DeployL2 — Deploy CounterL1 proxy + SCB (CounterAndProxy) + SCA (NestedCaller) on L2
/// @dev Env: MANAGER_L2, COUNTER_L1
/// Outputs: COUNTER_L1_PROXY_L2, SCB, SCA
contract DeployL2 is Script {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        // Proxy for CounterL1, deployed on L2
        address counterL1ProxyL2 = getOrCreateProxy(manager, counterL1Addr, 0);

        // SCB: CounterAndProxy targeting CounterL1's proxy on L2
        CounterAndProxy scb = new CounterAndProxy(Counter(counterL1ProxyL2));

        // SCA: NestedCaller targeting SCB
        NestedCaller sca = new NestedCaller(scb);

        console.log("COUNTER_L1_PROXY_L2=%s", counterL1ProxyL2);
        console.log("SCB=%s", address(scb));
        console.log("SCA=%s", address(sca));

        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════
//  Execute
// ═══════════════════════════════════════════════════════════════

/// @title ExecuteL2 — Load L2 table + Alice calls SCA.callNested() on L2 (local mode)
/// @dev SCA -> SCB.incrementProxy() -> CounterL1_proxy -> executeCrossChainCall
/// Env: MANAGER_L2, COUNTER_L1, SCB, SCA
contract ExecuteL2 is Script, DeepScopeActions {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address scbAddr = vm.envAddress("SCB");
        address scaAddr = vm.envAddress("SCA");

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        vm.startBroadcast();

        manager.loadExecutionTable(_l2Entries(counterL1Addr, scbAddr), new StaticCall[](0));

        // Alice calls SCA.callNested() on L2
        NestedCaller(scaAddr).callNested();

        console.log("done");
        console.log("sca_counter=%s", NestedCaller(scaAddr).counter());
        console.log("scb_counter=%s", CounterAndProxy(scbAddr).counter());
        console.log("scb_targetCounter=%s", CounterAndProxy(scbAddr).targetCounter());

        vm.stopBroadcast();
    }
}

/// @title Execute — Local mode: postBatch (2 entries) + executeL2TX via L2TXBatcher on L1
/// @dev Entry 0: L2TX -> CALL(CounterL1, scope=[0,0])
///      Entry 1: RESULT(1) -> terminal
/// Env: ROLLUPS, COUNTER_L1, SCB
contract Execute is Script, DeepScopeActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address scbAddr = vm.envAddress("SCB");

        vm.startBroadcast();

        bytes memory rlpTx = vm.envBytes("RLP_ENCODED_TX");

        L2TXBatcher batcher = new L2TXBatcher();
        batcher.execute(Rollups(rollupsAddr), _l1Entries(counterL1Addr, scbAddr, rlpTx), L2_ROLLUP_ID, rlpTx);

        console.log("done");
        console.log("counterL1=%s", Counter(counterL1Addr).counter());

        vm.stopBroadcast();
    }
}

/// @title ExecuteNetworkL2 — Network mode: user transaction on L2 (trigger)
/// @dev Env: SCA
contract ExecuteNetworkL2 is Script {
    function run() external view {
        address target = vm.envAddress("SCA");
        bytes memory data = abi.encodeWithSelector(NestedCaller.callNested.selector);
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

// ═══════════════════════════════════════════════════════════════
//  Verification
// ═══════════════════════════════════════════════════════════════

/// @title ComputeExpected — Compute expected hashes + print expected table
/// @dev Env: COUNTER_L1, SCB, SCA, ALICE
contract ComputeExpected is ComputeExpectedBase, DeepScopeActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L1")) return "CounterL1";
        if (a == vm.envAddress("SCB")) return "SCB";
        if (a == vm.envAddress("SCA")) return "SCA";
        if (a == vm.envAddress("ALICE")) return "Alice";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == NestedCaller.callNested.selector) return "callNested";
        if (sel == CounterAndProxy.incrementProxy.selector) return "incrementProxy";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address scbAddr = vm.envAddress("SCB");
        bytes memory rlpTx = vm.envBytes("RLP_ENCODED_TX");

        // Build entries from single source of truth
        ExecutionEntry[] memory l1 = _l1Entries(counterL1Addr, scbAddr, rlpTx);
        ExecutionEntry[] memory l2 = _l2Entries(counterL1Addr, scbAddr);

        // Compute hashes
        bytes32 l1eh0 = _entryHash(l1[0].actionHash, l1[0].nextAction);
        bytes32 l1eh1 = _entryHash(l1[1].actionHash, l1[1].nextAction);
        bytes32 l2eh0 = _entryHash(l2[0].actionHash, l2[0].nextAction);
        bytes32 h_callToCounterL1 = l2[0].actionHash;

        // Parseable output
        console.log("EXPECTED_L1_HASHES=[%s,%s]", vm.toString(l1eh0), vm.toString(l1eh1));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2eh0));

        // Actions for logging
        Action memory l2txAction = _l2txAction(rlpTx);
        Action memory callUnscoped = _callToCounterL1(counterL1Addr, scbAddr, new uint256[](0));
        uint256[] memory scope00 = new uint256[](2);
        scope00[0] = 0;
        scope00[1] = 0;
        Action memory callScoped = _callToCounterL1(counterL1Addr, scbAddr, scope00);
        Action memory resultC1 = _resultFromCounterL1();
        Action memory terminal = _terminalResultL2Tx();

        // Summary
        console.log("");
        console.log("=== EXPECTED SUMMARY ===");
        _logEntrySummary(0, l2txAction, callScoped, false);
        _logEntrySummary(1, resultC1, terminal, true);

        // L1 execution table
        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (2 entries) ===");
        _logEntry(0, l1[0].actionHash, l1[0].stateDeltas, _fmtL2TX(l2txAction), _fmtCall(callScoped));
        _logEntry(
            1,
            l1[1].actionHash,
            l1[1].stateDeltas,
            _fmtResult(resultC1, "uint256(1)"),
            string.concat(_fmtResult(terminal, "(void)"), "  (terminal)")
        );

        // L2 execution table
        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (1 entry) ===");
        _logL2Entry(0, l2eh0, _fmtCall(callUnscoped), _fmtResult(resultC1, "uint256(1)"));

        // L2 calls
        console.log("");
        console.log("=== EXPECTED L2 CALLS (1 call) ===");
        _logL2Call(0, h_callToCounterL1, callUnscoped);
    }
}
