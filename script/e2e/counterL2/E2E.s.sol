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
//  counterL2 — Scenario 2: L2 -> L1 (simple)
//
//  Alice calls D(CounterAndProxy) on L2
//    -> D calls C'(proxy for C on L1) on L2
//    -> C' triggers managerL2.executeCrossChainCall
//    -> execution table returns RESULT(1)
//    -> D receives result, sets targetCounter=1, counter=1
//
//  Meanwhile on L1 (system posts batch):
//    postBatch stores 2 deferred entries (L2TX->CALL, RESULT->RESULT)
//    executeL2TX triggers scope navigation
//    -> D'(proxy for D on L1).executeOnBehalf(C, increment)
//    -> C(Counter on L1).increment() -> counter goes 0 -> 1
// ═══════════════════════════════════════════════════════════════════════

/// @dev Centralized action & entry definitions for the counterL2 scenario.
abstract contract CounterL2Actions is L2TXActionsBase {

    function _callAction(address counterL1, address counterAndProxyL2) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.CALL,
            rollupId: 0,
            destination: counterL1,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            failed: false,
            sourceAddress: counterAndProxyL2,
            sourceRollup: L2_ROLLUP_ID,
            scope: new uint256[](0)
        });
    }

    function _resultAction() internal pure returns (Action memory) {
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

    function _l1Entries(address counterL1, address counterAndProxyL2, bytes memory rlpEncodedTx)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        Action memory l2tx = _l2txAction(rlpEncodedTx);
        Action memory call_ = _callAction(counterL1, counterAndProxyL2);
        Action memory result = _resultAction();
        Action memory terminal = _terminalResultAction();

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-before-call");
        bytes32 s2 = keccak256("l2-state-after-scenario2");

        StateDelta[] memory deltas0 = new StateDelta[](1);
        deltas0[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s0, newState: s1, etherDelta: 0});

        StateDelta[] memory deltas1 = new StateDelta[](1);
        deltas1[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s1, newState: s2, etherDelta: 0});

        entries = new ExecutionEntry[](2);
        entries[0].stateDeltas = deltas0;
        entries[0].actionHash = keccak256(abi.encode(l2tx));
        entries[0].nextAction = call_;

        entries[1].stateDeltas = deltas1;
        entries[1].actionHash = keccak256(abi.encode(result));
        entries[1].nextAction = terminal;
    }

    function _l2Entries(address counterL1, address counterAndProxyL2)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        Action memory call_ = _callAction(counterL1, counterAndProxyL2);
        Action memory result = _resultAction();

        entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = new StateDelta[](0);
        entries[0].actionHash = keccak256(abi.encode(call_));
        entries[0].nextAction = result;
    }
}

/// @title Deploy — Deploy Counter on L1
/// @dev Env: ROLLUPS
/// Outputs: COUNTER_L1
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();

        // C: Counter on L1 (the target that will be incremented)
        Counter counterL1 = new Counter();
        console.log("COUNTER_L1=%s", address(counterL1));

        vm.stopBroadcast();
    }
}

/// @title DeployL2 — Deploy CounterAndProxy on L2 with proxy for Counter(L1)
/// @dev Env: MANAGER_L2, COUNTER_L1
/// Outputs: COUNTER_AND_PROXY_L2, COUNTER_PROXY_L2
contract DeployL2 is Script {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        // C': proxy for C(Counter on L1), deployed on L2
        address counterProxyL2 = getOrCreateProxy(manager, counterL1Addr, 0);

        // D: CounterAndProxy on L2, target = C'
        CounterAndProxy counterAndProxyL2 = new CounterAndProxy(Counter(counterProxyL2));

        console.log("COUNTER_AND_PROXY_L2=%s", address(counterAndProxyL2));
        console.log("COUNTER_PROXY_L2=%s", counterProxyL2);

        vm.stopBroadcast();
    }
}

/// @title Deploy2 — Create proxy for CounterAndProxy(L2) on L1
/// @dev Env: ROLLUPS, COUNTER_AND_PROXY_L2
/// Outputs: COUNTER_AND_PROXY_L2_PROXY_L1
contract Deploy2 is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterAndProxyL2Addr = vm.envAddress("COUNTER_AND_PROXY_L2");

        vm.startBroadcast();

        // D': proxy for D(CounterAndProxy on L2), deployed on L1
        // Needed for scope navigation: D'.executeOnBehalf(C, increment)
        Rollups rollups = Rollups(rollupsAddr);
        address counterAndProxyL2ProxyL1 = getOrCreateProxy(rollups, counterAndProxyL2Addr, 1);
        console.log("COUNTER_AND_PROXY_L2_PROXY_L1=%s", counterAndProxyL2ProxyL1);

        vm.stopBroadcast();
    }
}

/// @title ExecuteL2 — Load L2 execution table + Alice calls incrementProxy (local mode)
/// @dev Env: MANAGER_L2, COUNTER_L1, COUNTER_AND_PROXY_L2
contract ExecuteL2 is Script, CounterL2Actions {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address counterAndProxyL2Addr = vm.envAddress("COUNTER_AND_PROXY_L2");

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        vm.startBroadcast();

        manager.loadExecutionTable(_l2Entries(counterL1Addr, counterAndProxyL2Addr));

        // Alice calls D.incrementProxy() on L2
        CounterAndProxy(counterAndProxyL2Addr).incrementProxy();

        console.log("done");
        console.log("counter=%s", CounterAndProxy(counterAndProxyL2Addr).counter());
        console.log("targetCounter=%s", CounterAndProxy(counterAndProxyL2Addr).targetCounter());

        vm.stopBroadcast();
    }
}

/// @title Execute — Local mode: postBatch + executeL2TX via Batcher on L1
/// @dev Env: ROLLUPS, COUNTER_L1, COUNTER_AND_PROXY_L2
contract Execute is Script, CounterL2Actions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address counterAndProxyL2Addr = vm.envAddress("COUNTER_AND_PROXY_L2");

        vm.startBroadcast();

        bytes memory rlpTx = vm.envBytes("RLP_ENCODED_TX");

        L2TXBatcher batcher = new L2TXBatcher();
        batcher.execute(
            Rollups(rollupsAddr), _l1Entries(counterL1Addr, counterAndProxyL2Addr, rlpTx), L2_ROLLUP_ID, rlpTx
        );

        console.log("done");
        console.log("counterL1=%s", Counter(counterL1Addr).counter());

        vm.stopBroadcast();
    }
}

/// @title ExecuteNetworkL2 — Network mode: user transaction on L2 (trigger)
/// @dev Env: COUNTER_AND_PROXY_L2
/// Returns (target, value, calldata) so the runner can send via `cast send`.
contract ExecuteNetworkL2 is Script {
    function run() external view {
        address target = vm.envAddress("COUNTER_AND_PROXY_L2");
        bytes memory data = abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

/// @title ComputeExpected — Compute expected actionHashes + print expected table
/// @dev Env: COUNTER_L1, COUNTER_AND_PROXY_L2
contract ComputeExpected is ComputeExpectedBase, CounterL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L1")) return "Counter";
        if (a == vm.envAddress("COUNTER_AND_PROXY_L2")) return "CounterAndProxy";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address counterAndProxyL2Addr = vm.envAddress("COUNTER_AND_PROXY_L2");
        bytes memory rlpTx = vm.envBytes("RLP_ENCODED_TX");

        // Actions (single source of truth)
        Action memory l2txAction = _l2txAction(rlpTx);
        Action memory callAction = _callAction(counterL1Addr, counterAndProxyL2Addr);
        Action memory resultAction = _resultAction();
        Action memory terminalAction = _terminalResultAction();

        // Entries (single source of truth)
        ExecutionEntry[] memory l1 = _l1Entries(counterL1Addr, counterAndProxyL2Addr, rlpTx);
        ExecutionEntry[] memory l2 = _l2Entries(counterL1Addr, counterAndProxyL2Addr);

        // Compute hashes from entries
        bytes32 eh0 = _entryHash(l1[0].actionHash, l1[0].nextAction);
        bytes32 eh1 = _entryHash(l1[1].actionHash, l1[1].nextAction);
        bytes32 l2eh0 = _entryHash(l2[0].actionHash, l2[0].nextAction);

        // Parseable lines
        console.log("EXPECTED_L1_HASHES=[%s,%s]", vm.toString(eh0), vm.toString(eh1));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2eh0));

        // Summary
        console.log("");
        console.log("=== EXPECTED SUMMARY ===");
        _logEntrySummary(0, l2txAction, callAction, false);
        _logEntrySummary(1, resultAction, terminalAction, true);

        // ── Human-readable: L1 execution table (2 entries) ──
        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (2 entries) ===");
        _logEntry(0, l1[0].actionHash, l1[0].stateDeltas, _fmtL2TX(l2txAction), _fmtCall(callAction));
        _logEntry(
            1,
            l1[1].actionHash,
            l1[1].stateDeltas,
            _fmtResult(resultAction, "uint256(1)"),
            string.concat(_fmtResult(terminalAction, "(void)"), "  (terminal)")
        );

        // ── Human-readable: L2 execution table (1 entry) ──
        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (1 entry) ===");
        _logL2Entry(0, l2eh0, _fmtCall(callAction), _fmtResult(resultAction, "uint256(1)"));

        // No L2 calls for L2→L1 scenario
    }
}
