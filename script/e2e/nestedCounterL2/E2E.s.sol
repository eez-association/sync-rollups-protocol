// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {Counter, CounterAndProxy} from "../../../test/mocks/CounterContracts.sol";

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

/// @notice Batcher: postBatch + executeL2TX in one tx (local mode only)
contract Batcher {
    function execute(Rollups rollups, ExecutionEntry[] calldata entries, uint256 rollupId, bytes calldata rlpTx)
        external
    {
        rollups.postBatch(entries, 0, "", "proof");
        rollups.executeL2TX(rollupId, rlpTx);
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
        address counterProxy;
        try rollups.createCrossChainProxy(counterL2Addr, 1) returns (address proxy) {
            counterProxy = proxy;
        } catch {
            counterProxy = rollups.computeCrossChainProxyAddress(counterL2Addr, 1);
        }

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
        address counterAndProxyProxyL2;
        try manager.createCrossChainProxy(counterAndProxyAddr, 0) returns (address proxy) {
            counterAndProxyProxyL2 = proxy;
        } catch {
            counterAndProxyProxyL2 = manager.computeCrossChainProxyAddress(counterAndProxyAddr, 0);
        }
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
contract ExecuteL2 is Script {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address counterAndProxyAddr = vm.envAddress("COUNTER_AND_PROXY");
        address counterAndProxyProxyL2Addr = vm.envAddress("COUNTER_AND_PROXY_PROXY_L2");

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);
        bytes memory incrementProxyCallData = abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);

        vm.startBroadcast();

        address alice = msg.sender;

        // CALL#1: outer call built by executeCrossChainCall when Alice calls A'
        // A' proxy has: originalAddress=CounterAndProxyL1, originalRollupId=MAINNET(0)
        Action memory callToCounterAndProxyL1 = Action({
            actionType: ActionType.CALL,
            rollupId: 0, // MAINNET
            destination: counterAndProxyAddr,
            value: 0,
            data: incrementProxyCallData,
            failed: false,
            sourceAddress: alice,
            sourceRollup: 1, // L2
            scope: new uint256[](0)
        });

        // CALL#2: inner call at scope=[0] — CounterAndProxyL1 calling CounterL2 proxy -> CounterL2
        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;

        Action memory callToCounterL2 = Action({
            actionType: ActionType.CALL,
            rollupId: 1, // L2
            destination: counterL2Addr,
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: counterAndProxyAddr, // CounterAndProxyL1
            sourceRollup: 0, // MAINNET
            scope: scope0
        });

        // RESULT from CounterL2.increment() returning 1
        Action memory resultFromCounterL2 = Action({
            actionType: ActionType.RESULT,
            rollupId: 1, // L2
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(1)),
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        // Load L2 execution table: 2 entries with scope navigation
        StateDelta[] memory emptyDeltas = new StateDelta[](0);
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);

        // Entry 0: CALL#1 (outer) -> CALL#2 (inner at scope=[0])
        entries[0].stateDeltas = emptyDeltas;
        entries[0].actionHash = keccak256(abi.encode(callToCounterAndProxyL1));
        entries[0].nextAction = callToCounterL2;

        // Entry 1: RESULT from CounterL2 -> RESULT (terminal, self-referencing)
        entries[1].stateDeltas = emptyDeltas;
        entries[1].actionHash = keccak256(abi.encode(resultFromCounterL2));
        entries[1].nextAction = resultFromCounterL2;

        manager.loadExecutionTable(entries);

        // Alice calls A' on L2 (low-level call — A' is a proxy)
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
contract Execute is Script {
    uint256 constant L2_ROLLUP_ID = 1;

    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address counterAndProxyAddr = vm.envAddress("COUNTER_AND_PROXY");
        address alice = vm.envAddress("ALICE");

        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);
        bytes memory incrementProxyCallData = abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);
        bytes memory rlpAliceTx = hex"02"; // arbitrary — represents Alice's L2 tx

        // L2TX action that executeL2TX will reconstruct
        Action memory l2txAction = Action({
            actionType: ActionType.L2TX,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: rlpAliceTx,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        // CALL to CounterAndProxyL1: source = Alice on L2
        Action memory callToCounterAndProxyL1 = Action({
            actionType: ActionType.CALL,
            rollupId: 0, // MAINNET
            destination: counterAndProxyAddr,
            value: 0,
            data: incrementProxyCallData,
            failed: false,
            sourceAddress: alice,
            sourceRollup: L2_ROLLUP_ID,
            scope: new uint256[](0)
        });

        // CALL to CounterL2: CounterAndProxyL1 calling B' -> CounterL2 (reentrant)
        Action memory callToCounterL2 = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: counterL2Addr,
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: counterAndProxyAddr, // CounterAndProxyL1
            sourceRollup: 0, // MAINNET
            scope: new uint256[](0)
        });

        // RESULT from CounterL2.increment() returning 1
        Action memory resultFromCounterL2 = Action({
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

        // RESULT from CounterAndProxyL1.incrementProxy() — void return
        Action memory resultFromCounterAndProxyL1 = Action({
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

        ExecutionEntry[] memory entries = new ExecutionEntry[](3);

        entries[0].stateDeltas = deltas0;
        entries[0].actionHash = keccak256(abi.encode(l2txAction));
        entries[0].nextAction = callToCounterAndProxyL1;

        entries[1].stateDeltas = deltas1;
        entries[1].actionHash = keccak256(abi.encode(callToCounterL2));
        entries[1].nextAction = resultFromCounterL2;

        entries[2].stateDeltas = deltas2;
        entries[2].actionHash = keccak256(abi.encode(resultFromCounterAndProxyL1));
        entries[2].nextAction = resultFromCounterAndProxyL1;

        vm.startBroadcast();

        Batcher batcher = new Batcher();
        batcher.execute(Rollups(rollupsAddr), entries, L2_ROLLUP_ID, rlpAliceTx);

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
contract ComputeExpected is ComputeExpectedBase {
    uint256 constant L2_ROLLUP_ID = 1;

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

        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);
        bytes memory incrementProxyCallData = abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);
        bytes memory rlpAliceTx = hex"02";

        // ── Actions ──

        Action memory l2txAction = Action({
            actionType: ActionType.L2TX,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: rlpAliceTx,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        Action memory callToCounterAndProxyL1 = Action({
            actionType: ActionType.CALL,
            rollupId: 0,
            destination: counterAndProxyAddr,
            value: 0,
            data: incrementProxyCallData,
            failed: false,
            sourceAddress: alice,
            sourceRollup: L2_ROLLUP_ID,
            scope: new uint256[](0)
        });

        Action memory callToCounterL2 = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: counterL2Addr,
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: counterAndProxyAddr,
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        Action memory resultFromCounterL2 = Action({
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

        Action memory resultFromCounterAndProxyL1 = Action({
            actionType: ActionType.RESULT,
            rollupId: 0,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        // ── Action hashes ──
        bytes32 h_l2tx = keccak256(abi.encode(l2txAction));
        bytes32 h_callToC2 = keccak256(abi.encode(callToCounterL2));
        bytes32 h_resultCAP1 = keccak256(abi.encode(resultFromCounterAndProxyL1));
        bytes32 h_resultC2 = keccak256(abi.encode(resultFromCounterL2));
        bytes32 h_callToCAP1 = keccak256(abi.encode(callToCounterAndProxyL1));

        // ── L1 entry hashes (3 entries) ──
        bytes32 l1eh0 = _entryHash(h_l2tx, callToCounterAndProxyL1);
        bytes32 l1eh1 = _entryHash(h_callToC2, resultFromCounterL2);
        bytes32 l1eh2 = _entryHash(h_resultCAP1, resultFromCounterAndProxyL1);

        // ── L2 entry hashes (2 entries with scope navigation) ──
        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;
        Action memory callToCounterL2Scoped = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: counterL2Addr,
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: counterAndProxyAddr,
            sourceRollup: 0,
            scope: scope0
        });

        bytes32 l2eh0 = _entryHash(h_callToCAP1, callToCounterL2Scoped);
        bytes32 l2eh1 = _entryHash(h_resultC2, resultFromCounterL2);

        // ── Parseable output ──
        console.log("EXPECTED_L1_HASHES=[%s,%s,%s]", vm.toString(l1eh0), vm.toString(l1eh1), vm.toString(l1eh2));
        console.log("EXPECTED_L2_HASHES=[%s,%s]", vm.toString(l2eh0), vm.toString(l2eh1));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(h_callToCAP1));

        // ── Human-readable: L1 execution table (3 entries) ──
        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-s3-step1");
        bytes32 s2 = keccak256("l2-state-s3-step2");
        bytes32 s3 = keccak256("l2-state-s3-step3");

        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (3 entries) ===");

        StateDelta[] memory deltas0 = new StateDelta[](1);
        deltas0[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s0, newState: s1, etherDelta: 0});
        _logEntry(0, h_l2tx, deltas0, _fmtL2TX(l2txAction), _fmtCall(callToCounterAndProxyL1));

        StateDelta[] memory deltas1 = new StateDelta[](1);
        deltas1[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s1, newState: s2, etherDelta: 0});
        _logEntry(1, h_callToC2, deltas1, _fmtCall(callToCounterL2), _fmtResult(resultFromCounterL2, "uint256(1)"));

        StateDelta[] memory deltas2 = new StateDelta[](1);
        deltas2[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s2, newState: s3, etherDelta: 0});
        _logEntry(
            2,
            h_resultCAP1,
            deltas2,
            _fmtResult(resultFromCounterAndProxyL1, "(void)"),
            string.concat(_fmtResult(resultFromCounterAndProxyL1, "(void)"), "  (terminal)")
        );

        // ── Human-readable: L2 execution table (2 entries) ──
        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (2 entries) ===");
        _logL2Entry(0, l2eh0, _fmtCall(callToCounterAndProxyL1), _fmtCall(callToCounterL2Scoped));
        _logL2Entry(
            1,
            l2eh1,
            _fmtResult(resultFromCounterL2, "uint256(1)"),
            string.concat(_fmtResult(resultFromCounterL2, "uint256(1)"), "  (terminal)")
        );

        // ── Human-readable: L2 calls (1 call) ──
        console.log("");
        console.log("=== EXPECTED L2 CALLS (1 call) ===");
        _logL2Call(0, h_callToCAP1, callToCounterAndProxyL1);
    }
}
