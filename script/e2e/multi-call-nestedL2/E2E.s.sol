// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {Counter, CounterAndProxy} from "../../../test/mocks/CounterContracts.sol";
import {CallTwiceNestedAndOnce} from "../../../test/mocks/MultiCallContracts.sol";
import {L2TXBatcher, L2TXActionsBase, getOrCreateProxy} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  multi-call-nestedL2 — L2-starting multicall with nested cross-chain calls
//
//  CallTwiceNestedAndOnce (on L2) makes 3 cross-chain calls:
//    1. CounterAndProxyL1' proxy on L2 (L2->L1->L2 nested)
//       CounterAndProxyL1 on L1 calls CounterL2' back to L2
//    2. Same proxy again (second nested call)
//    3. CounterL1' proxy on L2 (simple L2->L1 call)
//
//  L1 side (system posts batch with L2TX):
//    executeL2TX -> CALL to CounterAndProxyL1 (no scope)
//    -> _processCallAtScope: proxy(CallTwiceNestedAndOnce, L2) calls CAP1.incrementProxy()
//       - inside: calls CounterL2' proxy -> executeCrossChainCall (REENTRANT)
//         -> CALL to CounterL2 matched -> RESULT(1) returned -> targetCounter=1
//       - returns (void) -> RESULT(void) matched -> chains to 2nd CALL to CAP1
//    -> _processCallAtScope: proxy calls CAP1.incrementProxy() again
//       - inside: calls CounterL2' proxy -> executeCrossChainCall (REENTRANT)
//         -> CALL to CounterL2 matched -> RESULT(2) returned -> targetCounter=2
//       - returns (void) -> RESULT(void) matched -> chains to CALL to CounterL1
//    -> _processCallAtScope: proxy calls CounterL1.increment()
//       - returns 1 -> RESULT(1) matched -> terminal
//
//  L2 side (user calls CallTwiceNestedAndOnce):
//    CallTwiceNestedAndOnce.execute(cap1ProxyL2, counterL1ProxyL2)
//      1. cap1ProxyL2.incrementProxy() -> executeCrossChainCall
//         -> CALL to CAP1 matched -> CALL to CounterL2 at scope=[0]
//         -> _resolveScopes -> newScope([0]) -> executeOnBehalf(CounterL2, increment)
//         -> CounterL2.increment() runs -> counter 0->1
//         -> RESULT(1) matched -> RESULT(void CAP1) returned
//      2. cap1ProxyL2.incrementProxy() -> executeCrossChainCall
//         -> CALL to CAP1 matched -> CALL to CounterL2 at scope=[0]
//         -> _resolveScopes -> newScope([0]) -> executeOnBehalf(CounterL2, increment)
//         -> CounterL2.increment() runs -> counter 1->2
//         -> RESULT(2) matched -> RESULT(void CAP1) returned
//      3. counterL1ProxyL2.increment() -> executeCrossChainCall
//         -> CALL to CounterL1 matched -> RESULT(1) returned
// ═══════════════════════════════════════════════════════════════════════

/// @dev Centralized action & entry definitions for the multi-call-nestedL2 scenario.
///   Single source of truth — used by Execute, ExecuteL2, and ComputeExpected.
abstract contract MultiCallNestedL2Actions is L2TXActionsBase {

    function _callToCAP1Action(address cap1Addr, address callTwiceNested)
        internal
        pure
        returns (Action memory)
    {
        return Action({
            actionType: ActionType.CALL,
            rollupId: MAINNET_ROLLUP_ID,
            destination: cap1Addr,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            failed: false,
            sourceAddress: callTwiceNested,
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
            sourceAddress: cap1Addr,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: scope
        });
    }

    function _callToCounterL1Action(address counterL1, address callTwiceNested)
        internal
        pure
        returns (Action memory)
    {
        return Action({
            actionType: ActionType.CALL,
            rollupId: MAINNET_ROLLUP_ID,
            destination: counterL1,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            failed: false,
            sourceAddress: callTwiceNested,
            sourceRollup: L2_ROLLUP_ID,
            scope: new uint256[](0)
        });
    }

    function _resultCounterL2_1Action() internal pure returns (Action memory) {
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

    function _resultCounterL2_2Action() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(2)),
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    function _resultCAP1Action() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: MAINNET_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    function _resultCounterL1Action() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: MAINNET_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(1)),
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    /// @dev Spec C.6: Terminal RESULT for L2TX flows.
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

    function _l1Entries(
        address counterL2,
        address cap1Addr,
        address counterL1,
        address callTwiceNested,
        bytes memory rlpEncodedTx
    ) internal pure returns (ExecutionEntry[] memory entries) {
        Action memory l2tx = _l2txAction(rlpEncodedTx);
        Action memory callToCAP1 = _callToCAP1Action(cap1Addr, callTwiceNested);
        Action memory callToC2 = _callToCounterL2Action(counterL2, cap1Addr, new uint256[](0));
        Action memory resultC2_1 = _resultCounterL2_1Action();
        Action memory resultC2_2 = _resultCounterL2_2Action();
        Action memory resultCAP1 = _resultCAP1Action();
        Action memory callToC1 = _callToCounterL1Action(counterL1, callTwiceNested);
        Action memory resultC1 = _resultCounterL1Action();

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-mcnl2-step1");
        bytes32 s2 = keccak256("l2-state-mcnl2-step2");
        bytes32 s3 = keccak256("l2-state-mcnl2-step3");
        bytes32 s4 = keccak256("l2-state-mcnl2-step4");
        bytes32 s5 = keccak256("l2-state-mcnl2-step5");
        bytes32 s6 = keccak256("l2-state-mcnl2-step6");

        StateDelta[] memory deltas0 = new StateDelta[](1);
        deltas0[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s0, newState: s1, etherDelta: 0});

        StateDelta[] memory deltas1 = new StateDelta[](1);
        deltas1[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s1, newState: s2, etherDelta: 0});

        StateDelta[] memory deltas2 = new StateDelta[](1);
        deltas2[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s2, newState: s3, etherDelta: 0});

        StateDelta[] memory deltas3 = new StateDelta[](1);
        deltas3[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s3, newState: s4, etherDelta: 0});

        StateDelta[] memory deltas4 = new StateDelta[](1);
        deltas4[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s4, newState: s5, etherDelta: 0});

        StateDelta[] memory deltas5 = new StateDelta[](1);
        deltas5[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s5, newState: s6, etherDelta: 0});

        entries = new ExecutionEntry[](6);

        // Entry 0: L2TX -> CALL to CounterAndProxyL1
        entries[0].stateDeltas = deltas0;
        entries[0].actionHash = keccak256(abi.encode(l2tx));
        entries[0].nextAction = callToCAP1;

        // Entry 1: CALL to CounterL2 -> RESULT(1)
        entries[1].stateDeltas = deltas1;
        entries[1].actionHash = keccak256(abi.encode(callToC2));
        entries[1].nextAction = resultC2_1;

        // Entry 2: RESULT(void from CAP1) -> chains to 2nd CALL to CAP1
        entries[2].stateDeltas = deltas2;
        entries[2].actionHash = keccak256(abi.encode(resultCAP1));
        entries[2].nextAction = callToCAP1;

        // Entry 3: CALL to CounterL2 (same hash as entry 1) -> RESULT(2)
        entries[3].stateDeltas = deltas3;
        entries[3].actionHash = keccak256(abi.encode(callToC2));
        entries[3].nextAction = resultC2_2;

        // Entry 4: RESULT(void from CAP1, same hash as entry 2) -> chains to CALL to CounterL1
        entries[4].stateDeltas = deltas4;
        entries[4].actionHash = keccak256(abi.encode(resultCAP1));
        entries[4].nextAction = callToC1;

        // Entry 5: RESULT(1 from CounterL1) -> terminal
        entries[5].stateDeltas = deltas5;
        entries[5].actionHash = keccak256(abi.encode(resultC1));
        entries[5].nextAction = _terminalResultAction();
    }

    function _l2Entries(address counterL2, address cap1Addr, address counterL1, address callTwiceNested)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        Action memory callToCAP1 = _callToCAP1Action(cap1Addr, callTwiceNested);
        Action memory resultC2_1 = _resultCounterL2_1Action();
        Action memory resultC2_2 = _resultCounterL2_2Action();
        Action memory resultCAP1 = _resultCAP1Action();
        Action memory callToC1 = _callToCounterL1Action(counterL1, callTwiceNested);
        Action memory resultC1 = _resultCounterL1Action();

        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;
        Action memory callToC2Scoped = _callToCounterL2Action(counterL2, cap1Addr, scope0);

        entries = new ExecutionEntry[](5);

        // Entry 0: CALL to CAP1 -> CALL to CounterL2 scoped [0]
        entries[0].stateDeltas = new StateDelta[](0);
        entries[0].actionHash = keccak256(abi.encode(callToCAP1));
        entries[0].nextAction = callToC2Scoped;

        // Entry 1: RESULT(1) from CounterL2 -> RESULT(void from CAP1)
        entries[1].stateDeltas = new StateDelta[](0);
        entries[1].actionHash = keccak256(abi.encode(resultC2_1));
        entries[1].nextAction = resultCAP1;

        // Entry 2: CALL to CAP1 (same hash as entry 0) -> CALL to CounterL2 scoped [0]
        entries[2].stateDeltas = new StateDelta[](0);
        entries[2].actionHash = keccak256(abi.encode(callToCAP1));
        entries[2].nextAction = callToC2Scoped;

        // Entry 3: RESULT(2) from CounterL2 -> RESULT(void from CAP1)
        entries[3].stateDeltas = new StateDelta[](0);
        entries[3].actionHash = keccak256(abi.encode(resultC2_2));
        entries[3].nextAction = resultCAP1;

        // Entry 4: CALL to CounterL1 -> RESULT(1) from CounterL1
        entries[4].stateDeltas = new StateDelta[](0);
        entries[4].actionHash = keccak256(abi.encode(callToC1));
        entries[4].nextAction = resultC1;
    }
}

/// @title DeployL2 — Deploy CounterL2 + CallTwiceNestedAndOnce on L2
/// Outputs: COUNTER_L2, CALL_TWICE_NESTED, ALICE
contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();

        Counter counterL2 = new Counter();
        CallTwiceNestedAndOnce callTwiceNested = new CallTwiceNestedAndOnce();

        console.log("COUNTER_L2=%s", address(counterL2));
        console.log("CALL_TWICE_NESTED=%s", address(callTwiceNested));
        console.log("ALICE=%s", msg.sender);

        vm.stopBroadcast();
    }
}

/// @title Deploy — Deploy CounterL2 proxy + CounterAndProxyL1 + CounterL1 on L1
/// @dev Env: ROLLUPS, COUNTER_L2
/// Outputs: COUNTER_L2_PROXY_L1, COUNTER_AND_PROXY, COUNTER_L1
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2Addr = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();

        Rollups rollups = Rollups(rollupsAddr);

        // Proxy for CounterL2, deployed on L1
        address counterL2ProxyL1 = getOrCreateProxy(rollups, counterL2Addr, 1);

        // CounterAndProxyL1: target = CounterL2 proxy on L1
        CounterAndProxy counterAndProxy = new CounterAndProxy(Counter(counterL2ProxyL1));

        // CounterL1: simple counter on L1
        Counter counterL1 = new Counter();

        console.log("COUNTER_L2_PROXY_L1=%s", counterL2ProxyL1);
        console.log("COUNTER_AND_PROXY=%s", address(counterAndProxy));
        console.log("COUNTER_L1=%s", address(counterL1));

        vm.stopBroadcast();
    }
}

/// @title Deploy2L2 — Create CounterAndProxyL1 proxy + CounterL1 proxy on L2
/// @dev Env: MANAGER_L2, COUNTER_AND_PROXY, COUNTER_L1
/// Outputs: CAP1_PROXY_L2, COUNTER_L1_PROXY_L2
contract Deploy2L2 is Script {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterAndProxyAddr = vm.envAddress("COUNTER_AND_PROXY");
        address counterL1Addr = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        // Proxy for CounterAndProxyL1, deployed on L2
        address cap1ProxyL2 = getOrCreateProxy(manager, counterAndProxyAddr, 0);

        // Proxy for CounterL1, deployed on L2
        address counterL1ProxyL2 = getOrCreateProxy(manager, counterL1Addr, 0);

        console.log("CAP1_PROXY_L2=%s", cap1ProxyL2);
        console.log("COUNTER_L1_PROXY_L2=%s", counterL1ProxyL2);

        vm.stopBroadcast();
    }
}

/// @title ExecuteL2 — Load L2 execution table + user calls CallTwiceNestedAndOnce on L2 (local mode)
/// @dev L2 execution table (5 entries):
///   [0] hash(callToCAP1) -> CALL to CounterL2 at scope=[0]
///   [1] hash(resultC2_1) -> RESULT(void from CAP1)
///   [2] hash(callToCAP1) -> CALL to CounterL2 at scope=[0]  (same trigger hash)
///   [3] hash(resultC2_2) -> RESULT(void from CAP1)
///   [4] hash(callToC1)   -> RESULT(1 from CounterL1)
///
///   User calls CallTwiceNestedAndOnce.execute(cap1ProxyL2, counterL1ProxyL2)
///   which makes 3 proxy calls, each consumed from the table.
/// Env: MANAGER_L2, COUNTER_L2, COUNTER_AND_PROXY, COUNTER_L1, CAP1_PROXY_L2, COUNTER_L1_PROXY_L2, CALL_TWICE_NESTED
contract ExecuteL2 is Script, MultiCallNestedL2Actions {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address counterAndProxyAddr = vm.envAddress("COUNTER_AND_PROXY");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address cap1ProxyL2Addr = vm.envAddress("CAP1_PROXY_L2");
        address counterL1ProxyL2Addr = vm.envAddress("COUNTER_L1_PROXY_L2");
        address callTwiceNestedAddr = vm.envAddress("CALL_TWICE_NESTED");

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        vm.startBroadcast();

        manager.loadExecutionTable(
            _l2Entries(counterL2Addr, counterAndProxyAddr, counterL1Addr, callTwiceNestedAddr)
        );

        // User calls CallTwiceNestedAndOnce.execute(cap1ProxyL2, counterL1ProxyL2)
        CallTwiceNestedAndOnce(callTwiceNestedAddr).execute(cap1ProxyL2Addr, counterL1ProxyL2Addr);

        console.log("done");
        console.log("counterL2=%s", Counter(counterL2Addr).counter());

        vm.stopBroadcast();
    }
}

/// @title Execute — Local mode: postBatch (6 entries) + executeL2TX via L2TXBatcher on L1
/// @dev L1 execution table (6 entries):
///   Entry 0: L2TX -> CALL to CAP1                      (consumed by executeL2TX)
///   Entry 1: CALL to CounterL2 -> RESULT(1)              (consumed inside 1st reentrant call)
///   Entry 2: RESULT(void from CAP1) -> CALL to CAP1      (chains to 2nd nested call)
///   Entry 3: CALL to CounterL2 -> RESULT(2)              (consumed inside 2nd reentrant call)
///   Entry 4: RESULT(void from CAP1) -> CALL to CounterL1 (chains to simple call)
///   Entry 5: RESULT(1 from CounterL1) -> terminal         (consumed after return)
/// Env: ROLLUPS, COUNTER_L2, COUNTER_AND_PROXY, COUNTER_L1, CALL_TWICE_NESTED
contract Execute is Script, MultiCallNestedL2Actions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address counterAndProxyAddr = vm.envAddress("COUNTER_AND_PROXY");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address callTwiceNestedAddr = vm.envAddress("CALL_TWICE_NESTED");

        vm.startBroadcast();

        bytes memory rlpTx = vm.envBytes("RLP_ENCODED_TX");

        L2TXBatcher batcher = new L2TXBatcher();
        batcher.execute(
            Rollups(rollupsAddr),
            _l1Entries(counterL2Addr, counterAndProxyAddr, counterL1Addr, callTwiceNestedAddr, rlpTx),
            L2_ROLLUP_ID,
            rlpTx
        );

        console.log("done");
        console.log("counterAndProxy counter=%s", CounterAndProxy(counterAndProxyAddr).counter());
        console.log("counterAndProxy targetCounter=%s", CounterAndProxy(counterAndProxyAddr).targetCounter());
        console.log("counterL1=%s", Counter(counterL1Addr).counter());

        vm.stopBroadcast();
    }
}

/// @title ExecuteNetworkL2 — Network mode: user transaction on L2 (trigger)
/// @dev Env: CALL_TWICE_NESTED, CAP1_PROXY_L2, COUNTER_L1_PROXY_L2
contract ExecuteNetworkL2 is Script {
    function run() external view {
        address callTwiceNestedAddr = vm.envAddress("CALL_TWICE_NESTED");
        address cap1ProxyL2Addr = vm.envAddress("CAP1_PROXY_L2");
        address counterL1ProxyL2Addr = vm.envAddress("COUNTER_L1_PROXY_L2");

        bytes memory data =
            abi.encodeWithSelector(CallTwiceNestedAndOnce.execute.selector, cap1ProxyL2Addr, counterL1ProxyL2Addr);

        console.log("TARGET=%s", callTwiceNestedAddr);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

/// @title ComputeExpected — Compute expected hashes + print expected table
/// @dev Env: COUNTER_L2, COUNTER_AND_PROXY, COUNTER_L1, CALL_TWICE_NESTED, ALICE
contract ComputeExpected is ComputeExpectedBase, MultiCallNestedL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L2")) return "CounterL2";
        if (a == vm.envAddress("COUNTER_AND_PROXY")) return "CounterAndProxyL1";
        if (a == vm.envAddress("COUNTER_L1")) return "CounterL1";
        if (a == vm.envAddress("CALL_TWICE_NESTED")) return "CallTwiceNestedAndOnce";
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
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address callTwiceNestedAddr = vm.envAddress("CALL_TWICE_NESTED");
        bytes memory rlpTx = vm.envBytes("RLP_ENCODED_TX");

        // Actions (single source of truth)
        Action memory l2txAction = _l2txAction(rlpTx);
        Action memory callToCAP1 = _callToCAP1Action(counterAndProxyAddr, callTwiceNestedAddr);
        Action memory callToCounterL2 = _callToCounterL2Action(counterL2Addr, counterAndProxyAddr, new uint256[](0));
        Action memory resultC2_1 = _resultCounterL2_1Action();
        Action memory resultC2_2 = _resultCounterL2_2Action();
        Action memory resultCAP1 = _resultCAP1Action();
        Action memory callToCounterL1 = _callToCounterL1Action(counterL1Addr, callTwiceNestedAddr);
        Action memory resultC1 = _resultCounterL1Action();
        Action memory terminalResult = _terminalResultAction();

        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;
        Action memory callToCounterL2Scoped =
            _callToCounterL2Action(counterL2Addr, counterAndProxyAddr, scope0);

        // Entries (single source of truth)
        ExecutionEntry[] memory l1 =
            _l1Entries(counterL2Addr, counterAndProxyAddr, counterL1Addr, callTwiceNestedAddr, rlpTx);
        ExecutionEntry[] memory l2 =
            _l2Entries(counterL2Addr, counterAndProxyAddr, counterL1Addr, callTwiceNestedAddr);

        // Compute hashes from entries
        bytes32 l1eh0 = _entryHash(l1[0].actionHash, l1[0].nextAction);
        bytes32 l1eh1 = _entryHash(l1[1].actionHash, l1[1].nextAction);
        bytes32 l1eh2 = _entryHash(l1[2].actionHash, l1[2].nextAction);
        bytes32 l1eh3 = _entryHash(l1[3].actionHash, l1[3].nextAction);
        bytes32 l1eh4 = _entryHash(l1[4].actionHash, l1[4].nextAction);
        bytes32 l1eh5 = _entryHash(l1[5].actionHash, l1[5].nextAction);
        bytes32 l2eh0 = _entryHash(l2[0].actionHash, l2[0].nextAction);
        bytes32 l2eh1 = _entryHash(l2[1].actionHash, l2[1].nextAction);
        bytes32 l2eh2 = _entryHash(l2[2].actionHash, l2[2].nextAction);
        bytes32 l2eh3 = _entryHash(l2[3].actionHash, l2[3].nextAction);
        bytes32 l2eh4 = _entryHash(l2[4].actionHash, l2[4].nextAction);

        // L2 call hashes: 3 CrossChainCallExecuted events on L2
        // Two calls to CAP1 proxy (same hash), one call to CounterL1 proxy (different hash)
        bytes32 h_callToCAP1 = l2[0].actionHash;
        bytes32 h_callToC1 = l2[4].actionHash;

        // ── Parseable output ──
        console.log(
            string.concat(
                "EXPECTED_L1_HASHES=[",
                vm.toString(l1eh0), ",",
                vm.toString(l1eh1), ",",
                vm.toString(l1eh2), ",",
                vm.toString(l1eh3), ",",
                vm.toString(l1eh4), ",",
                vm.toString(l1eh5),
                "]"
            )
        );
        console.log(
            string.concat(
                "EXPECTED_L2_HASHES=[",
                vm.toString(l2eh0), ",",
                vm.toString(l2eh1), ",",
                vm.toString(l2eh2), ",",
                vm.toString(l2eh3), ",",
                vm.toString(l2eh4),
                "]"
            )
        );
        // No EXPECTED_L2_CALL_HASHES: L2→L1 direction (outgoing executeCrossChainCall, not incoming)

        // Summary
        console.log("");
        console.log("=== EXPECTED SUMMARY ===");
        _logEntrySummary(0, l2txAction, callToCAP1, false);
        _logEntrySummary(1, callToCounterL2, resultC2_1, false);
        _logEntrySummary(2, resultCAP1, callToCAP1, false);
        _logEntrySummary(3, callToCounterL2, resultC2_2, false);
        _logEntrySummary(4, resultCAP1, callToCounterL1, false);
        _logEntrySummary(5, resultC1, terminalResult, true);

        // ── Human-readable: L1 execution table (6 entries) ──
        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (6 entries) ===");
        _logEntry(0, l1[0].actionHash, l1[0].stateDeltas, _fmtL2TX(l2txAction), _fmtCall(callToCAP1));
        _logEntry(
            1,
            l1[1].actionHash,
            l1[1].stateDeltas,
            _fmtCall(callToCounterL2),
            _fmtResult(resultC2_1, "uint256(1)")
        );
        _logEntry(
            2,
            l1[2].actionHash,
            l1[2].stateDeltas,
            _fmtResult(resultCAP1, "(void)"),
            string.concat(_fmtCall(callToCAP1), "  (chains)")
        );
        _logEntry(
            3,
            l1[3].actionHash,
            l1[3].stateDeltas,
            string.concat(_fmtCall(callToCounterL2), "  (same hash as [1])"),
            _fmtResult(resultC2_2, "uint256(2)")
        );
        _logEntry(
            4,
            l1[4].actionHash,
            l1[4].stateDeltas,
            string.concat(_fmtResult(resultCAP1, "(void)"), "  (same hash as [2])"),
            string.concat(_fmtCall(callToCounterL1), "  (chains)")
        );
        _logEntry(
            5,
            l1[5].actionHash,
            l1[5].stateDeltas,
            _fmtResult(resultC1, "uint256(1)"),
            string.concat(_fmtResult(terminalResult, "(void)"), "  (terminal)")
        );

        // ── Human-readable: L2 execution table (5 entries) ──
        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (5 entries) ===");
        _logL2Entry(0, l2eh0, _fmtCall(callToCAP1), _fmtCall(callToCounterL2Scoped));
        _logL2Entry(1, l2eh1, _fmtResult(resultC2_1, "uint256(1)"), _fmtResult(resultCAP1, "(void)"));
        _logL2Entry(
            2,
            l2eh2,
            string.concat(_fmtCall(callToCAP1), "  (same hash as [0])"),
            _fmtCall(callToCounterL2Scoped)
        );
        _logL2Entry(3, l2eh3, _fmtResult(resultC2_2, "uint256(2)"), _fmtResult(resultCAP1, "(void)"));
        _logL2Entry(4, l2eh4, _fmtCall(callToCounterL1), _fmtResult(resultC1, "uint256(1)"));

        // ── Human-readable: L2 calls (3 calls, 2 unique hashes) ──
        console.log("");
        console.log("=== EXPECTED L2 CALLS (3 calls, 2 unique hashes) ===");
        _logL2Call(0, h_callToCAP1, callToCAP1);
        _logL2Call(1, h_callToC1, callToCounterL1);
    }
}
