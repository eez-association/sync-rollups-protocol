// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {Counter, CounterAndProxy, NestedCaller} from "../../../test/mocks/CounterContracts.sol";
import {L2TXBatcher, L2TXActionsBase, getOrCreateProxy} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  deepScopeRevert — L2 -> L1 with scope=[0,0] + REVERT at scope=[0]
//
//  Tests REVERT bubbling up through the scope tree. A cross-chain call
//  at scope=[0,0] succeeds, but its parent scope [0] reverts — rolling
//  back the successful call's effects via ScopeReverted.
//
//  This mirrors the L2 execution:
//    SCA calls SCB -> SCB calls CounterL1 (cross-chain, succeeds)
//    SCA reverts after SCB returns
//
//  ┌──────────────────────────────────────────────────────────────────┐
//  │  L1 execution (executeL2TX)                                     │
//  │    L2TX consumed (S0->S1) -> CALL(CounterL1, scope=[0,0])       │
//  │    -> newScope([]) -> newScope([0]) -> newScope([0,0])           │
//  │       -> CounterL1.increment() returns 1                        │
//  │       -> RESULT consumed (S1->S2) -> REVERT(scope=[0])          │
//  │       -> newScope([0,0]): scopesMatch([0,0],[0])=false -> break  │
//  │    -> newScope([0]): scopesMatch([0],[0])=true                   │
//  │       -> REVERT_CONTINUE consumed (S2->S3)                      │
//  │       -> ScopeReverted: rolls back S1->S2,S2->S3                │
//  │       -> state restored to S2                                    │
//  │    -> newScope([]): catches ScopeReverted                        │
//  │       -> continuation = RESULT(ok) -> terminal                   │
//  │    -> executeL2TX succeeds                                       │
//  │                                                                  │
//  │  L2 execution                                                    │
//  │    Alice calls SCA.callNested() on L2                            │
//  │      -> SCB.incrementProxy() -> CounterL1_proxy -> CALL consumed │
//  │      <- RESULT(1) returned                                       │
//  │    <- SCA: counter=1 (SCA doesn't revert on L2 in this test —   │
//  │       the revert is modeled in the L1 execution table)           │
//  └──────────────────────────────────────────────────────────────────┘
//
//  NOTE: On L2, SCA doesn't actually revert — the revert behavior is
//  modeled entirely in the L1 execution table entries (REVERT + REVERT_CONTINUE).
//  The L2 test exercises the cross-chain call; the L1 test exercises the
//  scope revert navigation.
// ═══════════════════════════════════════════════════════════════════════

/// @dev Centralized action & entry definitions for the deepScopeRevert scenario.
abstract contract DeepScopeRevertActions is L2TXActionsBase {

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
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
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
        bytes32 s1 = keccak256("l2-state-dsrev-step1");
        bytes32 s2 = keccak256("l2-state-dsrev-step2");
        bytes32 s3 = keccak256("l2-state-dsrev-step3");

        entries = new ExecutionEntry[](3);

        entries[0].stateDeltas = _delta(s0, s1);
        entries[0].actionHash = keccak256(abi.encode(_l2txAction(rlpTx)));
        entries[0].nextAction = _callToCounterL1(counterL1, scb, scope00);

        entries[1].stateDeltas = _delta(s1, s2);
        entries[1].actionHash = keccak256(abi.encode(_resultFromCounterL1()));
        entries[1].nextAction = _revertAction();

        entries[2].stateDeltas = _delta(s2, s3);
        entries[2].actionHash = keccak256(abi.encode(_revertContinueAction()));
        entries[2].nextAction = _terminalResultL2Tx();
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

/// @title DeployL2 — Deploy CounterL1 proxy + SCB + SCA on L2
/// @dev Env: MANAGER_L2, COUNTER_L1
/// Outputs: COUNTER_L1_PROXY_L2, SCB, SCA
contract DeployL2 is Script {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        address counterL1ProxyL2 = getOrCreateProxy(manager, counterL1Addr, 0);
        CounterAndProxy scb = new CounterAndProxy(Counter(counterL1ProxyL2));
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
/// @dev On L2, the cross-chain call succeeds normally (SCA doesn't revert on L2).
///      The revert is modeled in the L1 execution table.
/// Env: MANAGER_L2, COUNTER_L1, SCB, SCA
contract ExecuteL2 is Script, DeepScopeRevertActions {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address scbAddr = vm.envAddress("SCB");
        address scaAddr = vm.envAddress("SCA");

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        vm.startBroadcast();

        manager.loadExecutionTable(_l2Entries(counterL1Addr, scbAddr));

        NestedCaller(scaAddr).callNested();

        console.log("done");
        console.log("sca_counter=%s", NestedCaller(scaAddr).counter());
        console.log("scb_counter=%s", CounterAndProxy(scbAddr).counter());
        console.log("scb_targetCounter=%s", CounterAndProxy(scbAddr).targetCounter());

        vm.stopBroadcast();
    }
}

/// @title Execute — Local mode: postBatch (3 entries) + executeL2TX via L2TXBatcher on L1
/// @dev Entry 0: L2TX -> CALL(CounterL1, scope=[0,0])
///      Entry 1: RESULT(1) -> REVERT(scope=[0])
///      Entry 2: REVERT_CONTINUE -> final RESULT(ok)
/// Env: ROLLUPS, COUNTER_L1, SCB
contract Execute is Script, DeepScopeRevertActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address scbAddr = vm.envAddress("SCB");

        vm.startBroadcast();

        bytes memory rlpTx = vm.envBytes("RLP_ENCODED_TX");

        L2TXBatcher batcher = new L2TXBatcher();
        batcher.execute(Rollups(rollupsAddr), _l1Entries(counterL1Addr, scbAddr, rlpTx), L2_ROLLUP_ID, rlpTx);

        console.log("done");
        // CounterL1 should be 0 — increment() succeeded but was rolled back by ScopeReverted
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
contract ComputeExpected is ComputeExpectedBase, DeepScopeRevertActions {
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

        ExecutionEntry[] memory l1 = _l1Entries(counterL1Addr, scbAddr, rlpTx);
        ExecutionEntry[] memory l2 = _l2Entries(counterL1Addr, scbAddr);

        bytes32 l1eh0 = _entryHash(l1[0].actionHash, l1[0].nextAction);
        bytes32 l1eh1 = _entryHash(l1[1].actionHash, l1[1].nextAction);
        bytes32 l1eh2 = _entryHash(l1[2].actionHash, l1[2].nextAction);
        bytes32 l2eh0 = _entryHash(l2[0].actionHash, l2[0].nextAction);
        bytes32 h_callToCounterL1 = l2[0].actionHash;

        console.log(
            "EXPECTED_L1_HASHES=[%s,%s,%s]", vm.toString(l1eh0), vm.toString(l1eh1), vm.toString(l1eh2)
        );
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2eh0));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(h_callToCounterL1));

        // Actions for logging
        Action memory l2txAction = _l2txAction(rlpTx);
        Action memory callUnscoped = _callToCounterL1(counterL1Addr, scbAddr, new uint256[](0));
        uint256[] memory scope00 = new uint256[](2);
        scope00[0] = 0;
        scope00[1] = 0;
        Action memory callScoped = _callToCounterL1(counterL1Addr, scbAddr, scope00);
        Action memory resultC1 = _resultFromCounterL1();
        Action memory revertAct = _revertAction();
        Action memory revertCont = _revertContinueAction();
        Action memory finalRes = _terminalResultL2Tx();

        console.log("");
        console.log("=== EXPECTED SUMMARY ===");
        _logEntrySummary(0, l2txAction, callScoped, false);
        _logEntrySummary(1, resultC1, revertAct, false);
        _logEntrySummary(2, revertCont, finalRes, false);

        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (3 entries) ===");
        _logEntry(0, l1[0].actionHash, l1[0].stateDeltas, _fmtL2TX(l2txAction), _fmtCall(callScoped));
        _logEntry(
            1,
            l1[1].actionHash,
            l1[1].stateDeltas,
            _fmtResult(resultC1, "uint256(1)"),
            "REVERT rollupId=1 scope=[0]"
        );
        _logEntry(
            2,
            l1[2].actionHash,
            l1[2].stateDeltas,
            "REVERT_CONTINUE rollupId=1",
            string.concat(_fmtResult(finalRes, "(void)"), "  (continuation)")
        );

        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (1 entry) ===");
        _logL2Entry(0, l2eh0, _fmtCall(callUnscoped), _fmtResult(resultC1, "uint256(1)"));

        console.log("");
        console.log("=== EXPECTED L2 CALLS (1 call) ===");
        _logL2Call(0, h_callToCounterL1, callUnscoped);
    }
}
