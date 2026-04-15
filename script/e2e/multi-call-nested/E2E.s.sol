// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {getOrCreateProxy} from "../shared/E2EHelpers.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {ICrossChainManager} from "../../../src/ICrossChainManager.sol";
import {Action, ActionType, ExecutionEntry, StateDelta, StaticCall} from "../../../src/ICrossChainManager.sol";
import {Counter, CounterAndProxy} from "../../../test/mocks/CounterContracts.sol";
import {CallTwiceNestedAndOnce} from "../../../test/mocks/MultiCallContracts.sol";

// ═══════════════════════════════════════════════════════════════════════
//  multi-call-nested — L1-starting multicall with nested cross-chain calls
//
//  CallTwiceNestedAndOnce (on L1) makes 3 cross-chain calls:
//    1. CounterAndProxyL2' proxy (L1->L2->L1 nested) — CAP2 on L2 calls CounterL1' back to L1
//    2. Same proxy again (second nested call)
//    3. CounterL2' proxy (simple L1->L2 call)
//
//  L1 side (Execute):
//    Batcher posts 5 entries + calls app.execute(nestedProxy, simpleProxy)
//    - 1st call to nestedProxy: CALL to CAP2 matched -> returns CALL to CounterL1 scope=[0]
//      -> newScope resolves: CAP2' proxy calls CounterL1.increment() on L1
//      -> RESULT(1) matched -> returns RESULT(void) (terminal for 1st call)
//    - 2nd call to nestedProxy: same CALL hash, different state -> CALL to CounterL1 scope=[0]
//      -> newScope resolves: CounterL1.increment() again -> counter 1->2
//      -> RESULT(2) matched -> returns RESULT(void) (terminal for 2nd call)
//    - 3rd call to simpleProxy: CALL to CounterL2 matched -> RESULT(1) returned
//
//  L2 side (ExecuteL2):
//    System loads 5 entries + calls executeIncomingCrossChainCall once.
//    Chaining handles all 3 calls automatically via nextAction=CALL.
// ═══════════════════════════════════════════════════════════════════════

/// @dev Centralized action & entry definitions for the multi-call-nested scenario.
///   Single source of truth — used by Execute, ExecuteL2, and ComputeExpected.
abstract contract MultiCallNestedActions {
    uint256 internal constant L2_ROLLUP_ID = 1;
    uint256 internal constant MAINNET_ROLLUP_ID = 0;

    // ── Action builders ──

    function _callToCAP2(address cap2Addr, address sourceAddr) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: cap2Addr,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            failed: false,
            isStatic: false,
            sourceAddress: sourceAddr,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });
    }

    function _callToCounterL1(address counterL1, address cap2Addr, uint256[] memory scope)
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
            isStatic: false,
            sourceAddress: cap2Addr,
            sourceRollup: L2_ROLLUP_ID,
            scope: scope
        });
    }

    function _resultCounterL1_1() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: MAINNET_ROLLUP_ID,
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

    function _resultCounterL1_2() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: MAINNET_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(2)),
            failed: false,
            isStatic: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    function _resultCAP2() internal pure returns (Action memory) {
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

    function _callToCounterL2(address counterL2, address sourceAddr) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: counterL2,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            failed: false,
            isStatic: false,
            sourceAddress: sourceAddr,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });
    }

    function _resultCounterL2() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: L2_ROLLUP_ID,
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

    // ── L1 entries (5 entries) ──

    function _l1Entries(address counterL1, address cap2Addr, address counterL2, address sourceAddr)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;

        Action memory callCAP2 = _callToCAP2(cap2Addr, sourceAddr);
        Action memory callC1Scoped = _callToCounterL1(counterL1, cap2Addr, scope0);
        Action memory resC1_1 = _resultCounterL1_1();
        Action memory resC1_2 = _resultCounterL1_2();
        Action memory resCAP2 = _resultCAP2();
        Action memory callCL2 = _callToCounterL2(counterL2, sourceAddr);
        Action memory resCL2 = _resultCounterL2();

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-mcn-step1");
        bytes32 s2 = keccak256("l2-state-mcn-step2");
        bytes32 s3 = keccak256("l2-state-mcn-step3");
        bytes32 s4 = keccak256("l2-state-mcn-step4");
        bytes32 s5 = keccak256("l2-state-mcn-step5");

        entries = new ExecutionEntry[](5);

        // Entry 0: s0->s1, trigger=hash(callToCAP2), next=callToCounterL1Scoped
        StateDelta[] memory d0 = new StateDelta[](1);
        d0[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s0, newState: s1, etherDelta: 0});
        entries[0].stateDeltas = d0;
        entries[0].actionHash = keccak256(abi.encode(callCAP2));
        entries[0].nextAction = callC1Scoped;

        // Entry 1: s1->s2, trigger=hash(resultCounterL1_1), next=resultCAP2
        StateDelta[] memory d1 = new StateDelta[](1);
        d1[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s1, newState: s2, etherDelta: 0});
        entries[1].stateDeltas = d1;
        entries[1].actionHash = keccak256(abi.encode(resC1_1));
        entries[1].nextAction = resCAP2;

        // Entry 2: s2->s3, trigger=hash(callToCAP2) [same hash], next=callToCounterL1Scoped
        StateDelta[] memory d2 = new StateDelta[](1);
        d2[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s2, newState: s3, etherDelta: 0});
        entries[2].stateDeltas = d2;
        entries[2].actionHash = keccak256(abi.encode(callCAP2));
        entries[2].nextAction = callC1Scoped;

        // Entry 3: s3->s4, trigger=hash(resultCounterL1_2), next=resultCAP2
        StateDelta[] memory d3 = new StateDelta[](1);
        d3[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s3, newState: s4, etherDelta: 0});
        entries[3].stateDeltas = d3;
        entries[3].actionHash = keccak256(abi.encode(resC1_2));
        entries[3].nextAction = resCAP2;

        // Entry 4: s4->s5, trigger=hash(callToCounterL2), next=resultCounterL2
        StateDelta[] memory d4 = new StateDelta[](1);
        d4[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s4, newState: s5, etherDelta: 0});
        entries[4].stateDeltas = d4;
        entries[4].actionHash = keccak256(abi.encode(callCL2));
        entries[4].nextAction = resCL2;
    }

    // ── L2 entries (5 entries, no state deltas) ──

    function _l2Entries(address counterL1, address cap2Addr, address counterL2, address sourceAddr)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        // On L2, executeCrossChainCall always builds with scope=[]
        Action memory callC1Unscoped = _callToCounterL1(counterL1, cap2Addr, new uint256[](0));
        Action memory resC1_1 = _resultCounterL1_1();
        Action memory resC1_2 = _resultCounterL1_2();
        Action memory resCAP2 = _resultCAP2();
        Action memory callCAP2 = _callToCAP2(cap2Addr, sourceAddr);
        Action memory callCL2 = _callToCounterL2(counterL2, sourceAddr);
        Action memory resCL2 = _resultCounterL2();

        entries = new ExecutionEntry[](5);

        // Entry 0: trigger=hash(callToCounterL1Unscoped), next=resultCounterL1_1
        entries[0].stateDeltas = new StateDelta[](0);
        entries[0].actionHash = keccak256(abi.encode(callC1Unscoped));
        entries[0].nextAction = resC1_1;

        // Entry 1: trigger=hash(resultCAP2), next=callToCAP2 [chains to 2nd call]
        entries[1].stateDeltas = new StateDelta[](0);
        entries[1].actionHash = keccak256(abi.encode(resCAP2));
        entries[1].nextAction = callCAP2;

        // Entry 2: trigger=hash(callToCounterL1Unscoped) [same hash], next=resultCounterL1_2
        entries[2].stateDeltas = new StateDelta[](0);
        entries[2].actionHash = keccak256(abi.encode(callC1Unscoped));
        entries[2].nextAction = resC1_2;

        // Entry 3: trigger=hash(resultCAP2) [same hash], next=callToCounterL2 [chains to 3rd call]
        entries[3].stateDeltas = new StateDelta[](0);
        entries[3].actionHash = keccak256(abi.encode(resCAP2));
        entries[3].nextAction = callCL2;

        // Entry 4: trigger=hash(resultCounterL2), next=resultCounterL2 [terminal, self-ref]
        entries[4].stateDeltas = new StateDelta[](0);
        entries[4].actionHash = keccak256(abi.encode(resCL2));
        entries[4].nextAction = resCL2;
    }
}

/// @notice Batcher: postBatch + CallTwiceNestedAndOnce.execute in one tx (local mode only)
/// @dev sourceAddr = CallTwiceNestedAndOnce (app calls proxies, so msg.sender in proxy = app).
contract Batcher {
    function execute(
        Rollups rollups,
        ExecutionEntry[] calldata entries,
        CallTwiceNestedAndOnce app,
        address nestedProxy,
        address simpleProxy
    ) external returns (uint256) {
        rollups.postBatch(entries, new StaticCall[](0), 0, "", "proof");
        return app.execute(nestedProxy, simpleProxy);
    }
}

/// @title Deploy — Deploy CounterL1 + CallTwiceNestedAndOnce on L1
/// @dev Env: (none)
/// Outputs: COUNTER_L1, CALL_TWICE_NESTED, ALICE
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();

        Counter counterL1 = new Counter();
        CallTwiceNestedAndOnce app = new CallTwiceNestedAndOnce();

        console.log("COUNTER_L1=%s", address(counterL1));
        console.log("CALL_TWICE_NESTED=%s", address(app));
        console.log("ALICE=%s", msg.sender);

        vm.stopBroadcast();
    }
}

/// @title DeployL2 — Deploy CounterAndProxyL2 + CounterL2 + CounterL1 proxy on L2
/// @dev Env: MANAGER_L2, COUNTER_L1
/// Outputs: COUNTER_AND_PROXY_L2, COUNTER_L2, COUNTER_L1_PROXY_L2
contract DeployL2 is Script {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        // Proxy for CounterL1, deployed on L2 (rollupId=0 = mainnet)
        address counterL1ProxyL2 = getOrCreateProxy(ICrossChainManager(address(manager)), counterL1Addr, 0);

        // CounterAndProxyL2: target = CounterL1 proxy on L2
        CounterAndProxy counterAndProxyL2 = new CounterAndProxy(Counter(counterL1ProxyL2));

        // CounterL2: simple counter on L2
        Counter counterL2 = new Counter();

        console.log("COUNTER_AND_PROXY_L2=%s", address(counterAndProxyL2));
        console.log("COUNTER_L2=%s", address(counterL2));
        console.log("COUNTER_L1_PROXY_L2=%s", counterL1ProxyL2);

        vm.stopBroadcast();
    }
}

/// @title Deploy2 — Create CounterAndProxyL2 proxy + CounterL2 proxy on L1
/// @dev Env: ROLLUPS, COUNTER_AND_PROXY_L2, COUNTER_L2
/// Outputs: CAP2_PROXY_L1, COUNTER_L2_PROXY_L1
contract Deploy2 is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterAndProxyL2Addr = vm.envAddress("COUNTER_AND_PROXY_L2");
        address counterL2Addr = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();

        Rollups rollups = Rollups(rollupsAddr);

        // Proxy for CounterAndProxyL2, deployed on L1 (rollupId=1)
        address cap2ProxyL1 = getOrCreateProxy(ICrossChainManager(address(rollups)), counterAndProxyL2Addr, 1);

        // Proxy for CounterL2, deployed on L1 (rollupId=1)
        address counterL2ProxyL1 = getOrCreateProxy(ICrossChainManager(address(rollups)), counterL2Addr, 1);

        console.log("CAP2_PROXY_L1=%s", cap2ProxyL1);
        console.log("COUNTER_L2_PROXY_L1=%s", counterL2ProxyL1);

        vm.stopBroadcast();
    }
}

/// @title ExecuteL2 — Load L2 execution table + SYSTEM calls executeIncomingCrossChainCall (local mode)
/// @dev Env: MANAGER_L2, COUNTER_L1, COUNTER_AND_PROXY_L2, COUNTER_L2, CALL_TWICE_NESTED
///
/// L2 execution table (5 entries, chained):
///   [0] hash(callToCounterL1Unscoped) -> RESULT(1)
///   [1] hash(resultCAP2) -> callToCAP2 [chains to 2nd call]
///   [2] hash(callToCounterL1Unscoped) -> RESULT(2) [same hash, 2nd consumption]
///   [3] hash(resultCAP2) -> callToCounterL2 [chains to 3rd call]
///   [4] hash(resultCounterL2) -> resultCounterL2 [terminal]
///
/// Single executeIncomingCrossChainCall. Chaining handles all 3 calls automatically.
contract ExecuteL2 is Script, MultiCallNestedActions {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address counterAndProxyL2Addr = vm.envAddress("COUNTER_AND_PROXY_L2");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address callTwiceNestedAddr = vm.envAddress("CALL_TWICE_NESTED");

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        vm.startBroadcast();

        manager.loadExecutionTable(
            _l2Entries(counterL1Addr, counterAndProxyL2Addr, counterL2Addr, callTwiceNestedAddr),
            new StaticCall[](0)
        );

        // SYSTEM triggers CounterAndProxyL2.incrementProxy() via executeIncomingCrossChainCall
        // sourceAddress = CallTwiceNestedAndOnce addr on L1
        manager.executeIncomingCrossChainCall(
            counterAndProxyL2Addr,
            0,
            abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            callTwiceNestedAddr,
            0,
            new uint256[](0)
        );

        console.log("done");
        console.log("counterAndProxyL2.counter=%s", CounterAndProxy(counterAndProxyL2Addr).counter());
        console.log("counterAndProxyL2.targetCounter=%s", CounterAndProxy(counterAndProxyL2Addr).targetCounter());
        console.log("counterL2.counter=%s", Counter(counterL2Addr).counter());

        vm.stopBroadcast();
    }
}

/// @title Execute — Local mode: postBatch (5 entries) + CallTwiceNestedAndOnce.execute via Batcher on L1
/// @dev Env: ROLLUPS, COUNTER_L1, COUNTER_AND_PROXY_L2, COUNTER_L2, CAP2_PROXY_L1, COUNTER_L2_PROXY_L1, CALL_TWICE_NESTED
///      sourceAddr = CallTwiceNestedAndOnce because it's the contract that calls the proxies
///      (Batcher calls app.execute, app calls proxy, so msg.sender in proxy = app)
contract Execute is Script, MultiCallNestedActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address counterAndProxyL2Addr = vm.envAddress("COUNTER_AND_PROXY_L2");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address cap2ProxyL1Addr = vm.envAddress("CAP2_PROXY_L1");
        address counterL2ProxyL1Addr = vm.envAddress("COUNTER_L2_PROXY_L1");
        address callTwiceNestedAddr = vm.envAddress("CALL_TWICE_NESTED");

        vm.startBroadcast();

        Batcher batcher = new Batcher();

        // sourceAddr = CallTwiceNestedAndOnce (it calls the proxies, so msg.sender in proxy = app)
        uint256 result = batcher.execute(
            Rollups(rollupsAddr),
            _l1Entries(counterL1Addr, counterAndProxyL2Addr, counterL2Addr, callTwiceNestedAddr),
            CallTwiceNestedAndOnce(callTwiceNestedAddr),
            cap2ProxyL1Addr,
            counterL2ProxyL1Addr
        );

        console.log("done");
        console.log("counterL1=%s", Counter(counterL1Addr).counter());
        console.log("simpleResult=%s", result);

        vm.stopBroadcast();
    }
}

/// @title ExecuteNetwork — Network mode: user transaction on L1 (trigger)
/// @dev Env: CALL_TWICE_NESTED, CAP2_PROXY_L1, COUNTER_L2_PROXY_L1
contract ExecuteNetwork is Script {
    function run() external view {
        address callTwiceNestedAddr = vm.envAddress("CALL_TWICE_NESTED");
        address cap2ProxyL1Addr = vm.envAddress("CAP2_PROXY_L1");
        address counterL2ProxyL1Addr = vm.envAddress("COUNTER_L2_PROXY_L1");

        bytes memory data =
            abi.encodeWithSelector(CallTwiceNestedAndOnce.execute.selector, cap2ProxyL1Addr, counterL2ProxyL1Addr);

        console.log("TARGET=%s", callTwiceNestedAddr);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

/// @title ComputeExpected — Compute expected hashes + print expected table
/// @dev Env: COUNTER_L1, COUNTER_AND_PROXY_L2, COUNTER_L2, CALL_TWICE_NESTED
contract ComputeExpected is ComputeExpectedBase, MultiCallNestedActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L1")) return "CounterL1";
        if (a == vm.envAddress("COUNTER_AND_PROXY_L2")) return "CounterAndProxyL2";
        if (a == vm.envAddress("COUNTER_L2")) return "CounterL2";
        if (a == vm.envAddress("CALL_TWICE_NESTED")) return "CallTwiceNestedAndOnce";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == CounterAndProxy.incrementProxy.selector) return "incrementProxy";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address counterAndProxyL2Addr = vm.envAddress("COUNTER_AND_PROXY_L2");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address callTwiceNestedAddr = vm.envAddress("CALL_TWICE_NESTED");

        // sourceAddr = CallTwiceNestedAndOnce (it calls the proxies, so msg.sender in proxy = app)
        // In network mode: user calls app.execute() -> app calls proxy -> sourceAddr = app
        // In local mode: batcher calls app.execute() -> app calls proxy -> sourceAddr = app
        Action memory callCAP2 = _callToCAP2(counterAndProxyL2Addr, callTwiceNestedAddr);
        Action memory callC1Unscoped = _callToCounterL1(counterL1Addr, counterAndProxyL2Addr, new uint256[](0));
        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;
        Action memory callC1Scoped = _callToCounterL1(counterL1Addr, counterAndProxyL2Addr, scope0);
        Action memory resC1_1 = _resultCounterL1_1();
        Action memory resC1_2 = _resultCounterL1_2();
        Action memory resCAP2 = _resultCAP2();
        Action memory callCL2 = _callToCounterL2(counterL2Addr, callTwiceNestedAddr);
        Action memory resCL2 = _resultCounterL2();

        // Entries (single source of truth) — both L1 and L2 use callTwiceNestedAddr as sourceAddr
        ExecutionEntry[] memory l1 =
            _l1Entries(counterL1Addr, counterAndProxyL2Addr, counterL2Addr, callTwiceNestedAddr);
        ExecutionEntry[] memory l2 =
            _l2Entries(counterL1Addr, counterAndProxyL2Addr, counterL2Addr, callTwiceNestedAddr);

        // Compute hashes from entries
        bytes32 l1eh0 = _entryHash(l1[0].actionHash, l1[0].nextAction);
        bytes32 l1eh1 = _entryHash(l1[1].actionHash, l1[1].nextAction);
        bytes32 l1eh2 = _entryHash(l1[2].actionHash, l1[2].nextAction);
        bytes32 l1eh3 = _entryHash(l1[3].actionHash, l1[3].nextAction);
        bytes32 l1eh4 = _entryHash(l1[4].actionHash, l1[4].nextAction);

        bytes32 l2eh0 = _entryHash(l2[0].actionHash, l2[0].nextAction);
        bytes32 l2eh1 = _entryHash(l2[1].actionHash, l2[1].nextAction);
        bytes32 l2eh2 = _entryHash(l2[2].actionHash, l2[2].nextAction);
        bytes32 l2eh3 = _entryHash(l2[3].actionHash, l2[3].nextAction);
        bytes32 l2eh4 = _entryHash(l2[4].actionHash, l2[4].nextAction);

        // L2 call hash: the CALL built by executeIncomingCrossChainCall = hash of callToCAP2
        bytes32 l2CallHash = l1[0].actionHash;

        // Parseable lines
        console.log(
            string.concat(
                "EXPECTED_L1_HASHES=[",
                vm.toString(l1eh0), ",",
                vm.toString(l1eh1), ",",
                vm.toString(l1eh2), ",",
                vm.toString(l1eh3), ",",
                vm.toString(l1eh4), "]"
            )
        );
        console.log(
            string.concat(
                "EXPECTED_L2_HASHES=[",
                vm.toString(l2eh0), ",",
                vm.toString(l2eh1), ",",
                vm.toString(l2eh2), ",",
                vm.toString(l2eh3), ",",
                vm.toString(l2eh4), "]"
            )
        );
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(l2CallHash));

        // Summary
        console.log("");
        console.log("=== EXPECTED SUMMARY ===");
        _logEntrySummary(0, callCAP2, callC1Scoped, false);
        _logEntrySummary(1, resC1_1, resCAP2, false);
        _logEntrySummary(2, callCAP2, callC1Scoped, false);
        _logEntrySummary(3, resC1_2, resCAP2, false);
        _logEntrySummary(4, callCL2, resCL2, false);

        // Human-readable: L1 execution table (5 entries)
        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (5 entries) ===");
        _logEntry(0, l1eh0, l1[0].stateDeltas, _fmtCall(callCAP2), _fmtCall(callC1Scoped));
        _logEntry(
            1,
            l1eh1,
            l1[1].stateDeltas,
            _fmtResult(resC1_1, "uint256(1)"),
            string.concat(_fmtResult(resCAP2, "(void)"), "  (terminal for 1st nested)")
        );
        _logEntry(
            2,
            l1eh2,
            l1[2].stateDeltas,
            string.concat(_fmtCall(callCAP2), "  (same hash, 2nd consumption)"),
            _fmtCall(callC1Scoped)
        );
        _logEntry(
            3,
            l1eh3,
            l1[3].stateDeltas,
            _fmtResult(resC1_2, "uint256(2)"),
            string.concat(_fmtResult(resCAP2, "(void)"), "  (terminal for 2nd nested)")
        );
        _logEntry(4, l1eh4, l1[4].stateDeltas, _fmtCall(callCL2), _fmtResult(resCL2, "uint256(1)"));

        // Human-readable: L2 execution table (5 entries)
        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (5 entries) ===");
        _logL2Entry(0, l2eh0, _fmtCall(callC1Unscoped), _fmtResult(resC1_1, "uint256(1)"));
        _logL2Entry(
            1,
            l2eh1,
            _fmtResult(resCAP2, "(void)"),
            string.concat(_fmtCall(callCAP2), "  (chains to 2nd call)")
        );
        _logL2Entry(
            2,
            l2eh2,
            string.concat(_fmtCall(callC1Unscoped), "  (same hash, 2nd consumption)"),
            _fmtResult(resC1_2, "uint256(2)")
        );
        _logL2Entry(
            3,
            l2eh3,
            string.concat(_fmtResult(resCAP2, "(void)"), "  (same hash, 2nd consumption)"),
            string.concat(_fmtCall(callCL2), "  (chains to 3rd call)")
        );
        _logL2Entry(
            4,
            l2eh4,
            _fmtResult(resCL2, "uint256(1)"),
            string.concat(_fmtResult(resCL2, "uint256(1)"), "  (terminal)")
        );

        // Human-readable: L2 calls (1 call)
        console.log("");
        console.log("=== EXPECTED L2 CALLS (1 call) ===");
        _logL2Call(0, l2CallHash, callCAP2);
    }
}
