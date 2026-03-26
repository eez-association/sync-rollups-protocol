// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {Counter, CounterAndProxy} from "../../../test/mocks/CounterContracts.sol";

// ═══════════════════════════════════════════════════════════════════════
//  nestedCounter — Scenario 4: L1 -> L2 -> L1 (nested scope)
//
//  Alice calls CounterAndProxyL2's proxy on L1 (D')
//    -> executeCrossChainCall -> CALL to CounterAndProxyL2 matched
//    -> returns CALL to CounterL1 (nested, scope=[0])
//    -> _resolveScopes -> newScope([0]) -> _processCallAtScope:
//       - D' calls executeOnBehalf(CounterL1, increment)
//       - CounterL1.increment() runs on L1 -> counter 0->1
//       - RESULT matched -> terminal
//
//  Meanwhile on L2 (system executes):
//    SYSTEM calls executeIncomingCrossChainCall(CounterAndProxyL2, incrementProxy, Alice, MAINNET, [])
//    -> CounterAndProxyL2.incrementProxy() runs on L2
//       - inside: calls CounterL1's proxy (C') -> executeCrossChainCall (REENTRANT)
//         -> CALL to CounterL1 matched -> RESULT(1) returned -> targetCounter=1
//       - returns (void) -> RESULT(void) matched -> terminal
// ═══════════════════════════════════════════════════════════════════════

/// @notice Batcher: postBatch + call CounterAndProxyL2 proxy in one tx (local mode only)
/// @dev The Batcher's address becomes the "alice" (source) for the outer CALL on L1,
///      because msg.sender inside D'.fallback = Batcher.
contract Batcher {
    function execute(Rollups rollups, ExecutionEntry[] calldata entries, address target, bytes calldata data) external {
        rollups.postBatch(entries, 0, "", "proof");
        (bool success, bytes memory ret) = target.call(data);
        if (!success) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

/// @title Deploy — Deploy CounterL1 on L1
/// @dev Env: (none)
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

/// @title DeployL2 — Deploy CounterAndProxyL2 + CounterL1 proxy on L2
/// @dev Env: MANAGER_L2, COUNTER_L1
/// Outputs: COUNTER_AND_PROXY_L2, COUNTER_PROXY_L2
contract DeployL2 is Script {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        // Proxy for CounterL1, deployed on L2
        address counterProxyL2;
        try manager.createCrossChainProxy(counterL1Addr, 0) returns (address proxy) {
            counterProxyL2 = proxy;
        } catch {
            counterProxyL2 = manager.computeCrossChainProxyAddress(counterL1Addr, 0);
        }

        // CounterAndProxyL2: target = CounterL1 proxy
        CounterAndProxy counterAndProxyL2 = new CounterAndProxy(Counter(counterProxyL2));

        console.log("COUNTER_AND_PROXY_L2=%s", address(counterAndProxyL2));
        console.log("COUNTER_PROXY_L2=%s", counterProxyL2);

        vm.stopBroadcast();
    }
}

/// @title Deploy2 — Create CounterAndProxyL2 proxy on L1
/// @dev Env: ROLLUPS, COUNTER_AND_PROXY_L2
/// Outputs: COUNTER_AND_PROXY_L2_PROXY_L1
contract Deploy2 is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterAndProxyL2Addr = vm.envAddress("COUNTER_AND_PROXY_L2");

        vm.startBroadcast();

        Rollups rollups = Rollups(rollupsAddr);
        address counterAndProxyL2ProxyL1;
        try rollups.createCrossChainProxy(counterAndProxyL2Addr, 1) returns (address proxy) {
            counterAndProxyL2ProxyL1 = proxy;
        } catch {
            counterAndProxyL2ProxyL1 = rollups.computeCrossChainProxyAddress(counterAndProxyL2Addr, 1);
        }
        console.log("COUNTER_AND_PROXY_L2_PROXY_L1=%s", counterAndProxyL2ProxyL1);

        vm.stopBroadcast();
    }
}

/// @title ExecuteL2 — Load L2 execution table + SYSTEM calls executeIncomingCrossChainCall (local mode)
/// @dev Scenario 4 Phase 2:
///   1. Load L2 table: 2 entries
///      - CALL to CounterL1 -> RESULT(1)           (consumed inside reentrant executeCrossChainCall)
///      - RESULT(void from CounterAndProxyL2) -> terminal
///   2. SYSTEM calls executeIncomingCrossChainCall(CounterAndProxyL2, incrementProxy, alice, MAINNET, [])
/// Env: MANAGER_L2, COUNTER_L1, COUNTER_AND_PROXY_L2
contract ExecuteL2 is Script {
    uint256 constant L2_ROLLUP_ID = 1;

    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address counterAndProxyL2Addr = vm.envAddress("COUNTER_AND_PROXY_L2");

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);
        bytes memory incrementProxyCallData = abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);

        vm.startBroadcast();

        address alice = msg.sender; // broadcaster = system = alice in local mode

        // CALL to CounterL1: CounterAndProxyL2 calling CounterL1 proxy -> CounterL1
        // executeCrossChainCall builds: rollupId=0, dest=CounterL1, source=CounterAndProxyL2, sourceRollup=L2
        Action memory callToCounterL1 = Action({
            actionType: ActionType.CALL,
            rollupId: 0, // MAINNET
            destination: counterL1Addr,
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: counterAndProxyL2Addr,
            sourceRollup: L2_ROLLUP_ID,
            scope: new uint256[](0)
        });

        // RESULT from CounterL1.increment() returning 1
        Action memory resultFromCounterL1 = Action({
            actionType: ActionType.RESULT,
            rollupId: 0, // MAINNET
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(1)),
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        // RESULT from CounterAndProxyL2.incrementProxy() — void return
        Action memory resultFromCounterAndProxyL2 = Action({
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

        // Load L2 execution table: 2 entries
        StateDelta[] memory emptyDeltas = new StateDelta[](0);
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);

        // Entry 0: CALL to CounterL1 -> RESULT(1) (consumed inside reentrant executeCrossChainCall)
        entries[0].stateDeltas = emptyDeltas;
        entries[0].actionHash = keccak256(abi.encode(callToCounterL1));
        entries[0].nextAction = resultFromCounterL1;

        // Entry 1: RESULT(void from CounterAndProxyL2) -> terminal
        entries[1].stateDeltas = emptyDeltas;
        entries[1].actionHash = keccak256(abi.encode(resultFromCounterAndProxyL2));
        entries[1].nextAction = resultFromCounterAndProxyL2;

        manager.loadExecutionTable(entries);

        // SYSTEM triggers CounterAndProxyL2.incrementProxy() via executeIncomingCrossChainCall
        manager.executeIncomingCrossChainCall(
            counterAndProxyL2Addr, 0, incrementProxyCallData, alice, 0, new uint256[](0)
        );

        console.log("done");
        console.log("counterAndProxyL2=%s", CounterAndProxy(counterAndProxyL2Addr).counter());
        console.log("targetCounter=%s", CounterAndProxy(counterAndProxyL2Addr).targetCounter());

        vm.stopBroadcast();
    }
}

/// @title Execute — Local mode: postBatch (2 entries) + Alice calls CounterAndProxyL2 proxy via Batcher on L1
/// @dev Scenario 4 Phase 1:
///   Entry 0: CALL to CounterAndProxyL2 -> CALL to CounterL1 at scope=[0]
///   Entry 1: RESULT from CounterL1 -> RESULT (terminal)
///
///   The Batcher calls D', so msg.sender inside D' = Batcher.
///   We predict the Batcher address via vm.computeCreateAddress to build matching entries.
/// Env: ROLLUPS, COUNTER_L1, COUNTER_AND_PROXY_L2, COUNTER_AND_PROXY_L2_PROXY_L1
contract Execute is Script {
    uint256 constant L2_ROLLUP_ID = 1;

    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address counterAndProxyL2Addr = vm.envAddress("COUNTER_AND_PROXY_L2");
        address counterAndProxyL2ProxyL1Addr = vm.envAddress("COUNTER_AND_PROXY_L2_PROXY_L1");

        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);
        bytes memory incrementProxyCallData = abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);

        vm.startBroadcast();

        // Predict Batcher address — it will be the "alice" that calls D'
        address batcherAddr = vm.computeCreateAddress(msg.sender, vm.getNonce(msg.sender));

        // CALL to CounterAndProxyL2: outer call built by executeCrossChainCall when Batcher calls D'
        Action memory callToCounterAndProxyL2 = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: counterAndProxyL2Addr,
            value: 0,
            data: incrementProxyCallData,
            failed: false,
            sourceAddress: batcherAddr, // Batcher calls D'
            sourceRollup: 0, // MAINNET
            scope: new uint256[](0)
        });

        // CALL to CounterL1: inner nested call at scope=[0]
        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;

        Action memory callToCounterL1 = Action({
            actionType: ActionType.CALL,
            rollupId: 0, // MAINNET
            destination: counterL1Addr,
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: counterAndProxyL2Addr,
            sourceRollup: L2_ROLLUP_ID,
            scope: scope0
        });

        // RESULT from CounterL1.increment() returning 1
        Action memory resultFromCounterL1 = Action({
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

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-s4-step1");
        bytes32 s2 = keccak256("l2-state-s4-step2");

        StateDelta[] memory deltas0 = new StateDelta[](1);
        deltas0[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s0, newState: s1, etherDelta: 0});

        StateDelta[] memory deltas1 = new StateDelta[](1);
        deltas1[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s1, newState: s2, etherDelta: 0});

        ExecutionEntry[] memory entries = new ExecutionEntry[](2);

        entries[0].stateDeltas = deltas0;
        entries[0].actionHash = keccak256(abi.encode(callToCounterAndProxyL2));
        entries[0].nextAction = callToCounterL1;

        entries[1].stateDeltas = deltas1;
        entries[1].actionHash = keccak256(abi.encode(resultFromCounterL1));
        entries[1].nextAction = resultFromCounterL1;

        Batcher batcher = new Batcher();
        batcher.execute(Rollups(rollupsAddr), entries, counterAndProxyL2ProxyL1Addr, incrementProxyCallData);

        console.log("done");
        console.log("counterL1=%s", Counter(counterL1Addr).counter());

        vm.stopBroadcast();
    }
}

/// @title ExecuteNetwork — Network mode: user transaction on L1 (trigger)
/// @dev Env: COUNTER_AND_PROXY_L2_PROXY_L1
contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("COUNTER_AND_PROXY_L2_PROXY_L1");
        bytes memory data = abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

/// @title ComputeExpected — Compute expected hashes + print expected table
/// @dev Env: COUNTER_L1, COUNTER_AND_PROXY_L2, ALICE
contract ComputeExpected is ComputeExpectedBase {
    uint256 constant L2_ROLLUP_ID = 1;

    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L1")) return "CounterL1";
        if (a == vm.envAddress("COUNTER_AND_PROXY_L2")) return "CounterAndProxyL2";
        if (a == vm.envAddress("ALICE")) return "Alice";
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
        address alice = vm.envAddress("ALICE");

        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);
        bytes memory incrementProxyCallData = abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);

        // ── Actions ──

        Action memory callToCounterAndProxyL2 = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: counterAndProxyL2Addr,
            value: 0,
            data: incrementProxyCallData,
            failed: false,
            sourceAddress: alice,
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        Action memory callToCounterL1 = Action({
            actionType: ActionType.CALL,
            rollupId: 0,
            destination: counterL1Addr,
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: counterAndProxyL2Addr,
            sourceRollup: L2_ROLLUP_ID,
            scope: new uint256[](0)
        });

        Action memory resultFromCounterL1 = Action({
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

        Action memory resultFromCounterAndProxyL2 = Action({
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

        // ── Action hashes ──
        bytes32 h_callToCAP2 = keccak256(abi.encode(callToCounterAndProxyL2));
        bytes32 h_callToC1 = keccak256(abi.encode(callToCounterL1));
        bytes32 h_resultC1 = keccak256(abi.encode(resultFromCounterL1));
        bytes32 h_resultCAP2 = keccak256(abi.encode(resultFromCounterAndProxyL2));

        // ── L1 entry hashes (2 entries with scope navigation) ──
        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;
        Action memory callToCounterL1Scoped = Action({
            actionType: ActionType.CALL,
            rollupId: 0,
            destination: counterL1Addr,
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: counterAndProxyL2Addr,
            sourceRollup: L2_ROLLUP_ID,
            scope: scope0
        });

        bytes32 l1eh0 = _entryHash(h_callToCAP2, callToCounterL1Scoped);
        bytes32 l1eh1 = _entryHash(h_resultC1, resultFromCounterL1);

        // ── L2 entry hashes (2 entries for reentrant execution) ──
        bytes32 l2eh0 = _entryHash(h_callToC1, resultFromCounterL1);
        bytes32 l2eh1 = _entryHash(h_resultCAP2, resultFromCounterAndProxyL2);

        // ── L2 call hash: the CALL built by executeIncomingCrossChainCall ──
        bytes32 l2CallHash = h_callToCAP2;

        // ── Parseable output ──
        console.log("EXPECTED_L1_HASHES=[%s,%s]", vm.toString(l1eh0), vm.toString(l1eh1));
        console.log("EXPECTED_L2_HASHES=[%s,%s]", vm.toString(l2eh0), vm.toString(l2eh1));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(l2CallHash));

        // ── Human-readable: L1 execution table (2 entries) ──
        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-s4-step1");
        bytes32 s2 = keccak256("l2-state-s4-step2");

        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (2 entries) ===");

        StateDelta[] memory deltas0 = new StateDelta[](1);
        deltas0[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s0, newState: s1, etherDelta: 0});
        _logEntry(0, h_callToCAP2, deltas0, _fmtCall(callToCounterAndProxyL2), _fmtCall(callToCounterL1Scoped));

        StateDelta[] memory deltas1 = new StateDelta[](1);
        deltas1[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s1, newState: s2, etherDelta: 0});
        _logEntry(
            1,
            h_resultC1,
            deltas1,
            _fmtResult(resultFromCounterL1, "uint256(1)"),
            string.concat(_fmtResult(resultFromCounterL1, "uint256(1)"), "  (terminal)")
        );

        // ── Human-readable: L2 execution table (2 entries) ──
        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (2 entries) ===");
        _logL2Entry(0, l2eh0, _fmtCall(callToCounterL1), _fmtResult(resultFromCounterL1, "uint256(1)"));
        _logL2Entry(
            1,
            l2eh1,
            _fmtResult(resultFromCounterAndProxyL2, "(void)"),
            string.concat(_fmtResult(resultFromCounterAndProxyL2, "(void)"), "  (terminal)")
        );

        // ── Human-readable: L2 calls (1 call) ──
        console.log("");
        console.log("=== EXPECTED L2 CALLS (1 call) ===");
        _logL2Call(0, l2CallHash, callToCounterAndProxyL2);
    }
}
