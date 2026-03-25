// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {Counter} from "../../../test/mocks/CounterContracts.sol";
import {CallTwice} from "../../../test/mocks/MultiCallContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";

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
contract ExecuteL2 is Script {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterAAddr = vm.envAddress("COUNTER_A");
        address callTwiceAddr = vm.envAddress("CALL_TWICE");

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // CALL action: chained second call to counterA (no scope — same level)
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: 1,
            destination: counterAAddr,
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: callTwiceAddr,
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        // RESULT_1: first call returns 1 (counter 0→1)
        Action memory result1 = Action({
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

        // RESULT_2: second call returns 2 (counter 1→2, terminal)
        Action memory result2 = Action({
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

        vm.startBroadcast();

        // Load chained execution table
        // Entry 0: consumed after counterA returns 1 → chains to CALL(counterA again)
        // Entry 1: consumed after counterA returns 2 → terminal
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0].stateDeltas = new StateDelta[](0);
        entries[0].actionHash = keccak256(abi.encode(result1));
        entries[0].nextAction = callAction;

        entries[1].stateDeltas = new StateDelta[](0);
        entries[1].actionHash = keccak256(abi.encode(result2));
        entries[1].nextAction = result2;

        manager.loadExecutionTable(entries);

        // Single call: chaining handles the second invocation
        manager.executeIncomingCrossChainCall(
            counterAAddr, 0, incrementCallData, callTwiceAddr, 0, new uint256[](0)
        );

        console.log("L2 execution complete");
        console.log("counter=%s", Counter(counterAAddr).counter());

        vm.stopBroadcast();
    }
}

/// @title Execute — Local mode: postBatch + callCounterTwice via Batcher
/// @dev Env: ROLLUPS, COUNTER_A, CALL_TWICE, PROXY_A
contract Execute is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterAAddr = vm.envAddress("COUNTER_A");
        address callTwiceAddr = vm.envAddress("CALL_TWICE");
        address proxyAAddr = vm.envAddress("PROXY_A");

        vm.startBroadcast();

        Batcher batcher = new Batcher();
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // Both calls produce the SAME action: same source(CallTwice), dest(counterA), data(increment)
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: 1,
            destination: counterAAddr,
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: callTwiceAddr,
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        Action memory result1 = Action({
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

        Action memory result2 = Action({
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

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-multicall-after-first");
        bytes32 s2 = keccak256("l2-state-multicall-after-second");

        // 2 entries with SAME action hash, DIFFERENT state deltas
        StateDelta[] memory deltas1 = new StateDelta[](1);
        deltas1[0] = StateDelta({rollupId: 1, currentState: s0, newState: s1, etherDelta: 0});

        StateDelta[] memory deltas2 = new StateDelta[](1);
        deltas2[0] = StateDelta({rollupId: 1, currentState: s1, newState: s2, etherDelta: 0});

        bytes32 actionHash = keccak256(abi.encode(callAction));

        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0].stateDeltas = deltas1;
        entries[0].actionHash = actionHash;
        entries[0].nextAction = result1;

        entries[1].stateDeltas = deltas2;
        entries[1].actionHash = actionHash;
        entries[1].nextAction = result2;

        (uint256 first, uint256 second) = batcher.execute(
            Rollups(rollupsAddr), entries, CallTwice(callTwiceAddr), proxyAAddr
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
contract ComputeExpected is ComputeExpectedBase {
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

        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // L1 CALL action (used for L1 entries — rollupId=1 as seen from L1)
        Action memory callAction = _mkCall(1, counterAAddr, incrementCallData, callTwiceAddr, 0, new uint256[](0));

        // L2 CALL action: chained second call (rollupId=1, no scope)
        Action memory l2CallAction = _mkCall(1, counterAAddr, incrementCallData, callTwiceAddr, 0, new uint256[](0));

        // RESULT actions
        Action memory result1 = _mkResult(1, abi.encode(uint256(1)));
        Action memory result2 = _mkResult(1, abi.encode(uint256(2)));

        // L1 entries: same action hash, different state deltas and results
        bytes32 actionHash = keccak256(abi.encode(callAction));
        bytes32 l1Entry1 = _entryHash(actionHash, result1);
        bytes32 l1Entry2 = _entryHash(actionHash, result2);

        // L2 entries: chained — RESULT_1 → CALL(again), RESULT_2 → terminal
        bytes32 result1Hash = keccak256(abi.encode(result1));
        bytes32 result2Hash = keccak256(abi.encode(result2));
        bytes32 l2Entry0 = _entryHash(result1Hash, l2CallAction);
        bytes32 l2Entry1 = _entryHash(result2Hash, result2);

        // L2 call hash: what executeIncomingCrossChainCall emits
        // The system builds a CALL with rollupId=1 on L2
        bytes32 l2CallHash = keccak256(abi.encode(l2CallAction));

        console.log("EXPECTED_L1_HASHES=[%s,%s]", vm.toString(l1Entry1), vm.toString(l1Entry2));
        console.log("EXPECTED_L2_HASHES=[%s,%s]", vm.toString(l2Entry0), vm.toString(l2Entry1));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(l2CallHash));

        // ── L1 execution table ──
        {
            bytes32 s0 = keccak256("l2-initial-state");
            bytes32 s1 = keccak256("l2-state-multicall-after-first");
            bytes32 s2 = keccak256("l2-state-multicall-after-second");

            StateDelta[] memory deltas1 = new StateDelta[](1);
            deltas1[0] = StateDelta({rollupId: 1, currentState: s0, newState: s1, etherDelta: 0});

            StateDelta[] memory deltas2 = new StateDelta[](1);
            deltas2[0] = StateDelta({rollupId: 1, currentState: s1, newState: s2, etherDelta: 0});

            console.log("");
            console.log("=== EXPECTED L1 EXECUTION TABLE (2 entries, same action hash) ===");
            _logEntry(0, l1Entry1, deltas1, _fmtCall(callAction), _fmtResult(result1, "uint256(1)"));
            _logEntry(
                1,
                l1Entry2,
                deltas2,
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
            string.concat(_fmtCall(l2CallAction), "  (chains to 2nd call)")
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
        _logL2Call(0, l2CallHash, l2CallAction);
    }

    function _mkCall(
        uint256 rollupId,
        address dest,
        bytes memory data,
        address src,
        uint256 srcRollup,
        uint256[] memory scope
    ) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: dest,
            value: 0,
            data: data,
            failed: false,
            sourceAddress: src,
            sourceRollup: srcRollup,
            scope: scope
        });
    }

    function _mkResult(uint256 rollupId, bytes memory data) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: data,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }
}
