// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {Counter} from "../../../test/mocks/CounterContracts.sol";
import {CallTwoDifferent} from "../../../test/mocks/MultiCallContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";

/// @dev Centralized action & entry definitions for the multi-call-two-diff scenario.
///   Single source of truth — used by Execute, ExecuteL2, and ComputeExpected.
abstract contract MultiCallTwoDiffActions {
    function _callAction(address counter, address callTwoDiff) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.CALL,
            rollupId: 1,
            destination: counter,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            failed: false,
            sourceAddress: callTwoDiff,
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    function _resultAction() internal pure returns (Action memory) {
        return Action({
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
    }

    function _l1Entries(address counterA, address counterB, address callTwoDiff)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        Action memory callA = _callAction(counterA, callTwoDiff);
        Action memory callB = _callAction(counterB, callTwoDiff);
        Action memory result = _resultAction();

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-twodiff-after-A");
        bytes32 s2 = keccak256("l2-state-twodiff-after-B");

        StateDelta[] memory deltas1 = new StateDelta[](1);
        deltas1[0] = StateDelta({rollupId: 1, currentState: s0, newState: s1, etherDelta: 0});

        StateDelta[] memory deltas2 = new StateDelta[](1);
        deltas2[0] = StateDelta({rollupId: 1, currentState: s1, newState: s2, etherDelta: 0});

        entries = new ExecutionEntry[](2);
        entries[0].stateDeltas = deltas1;
        entries[0].actionHash = keccak256(abi.encode(callA));
        entries[0].nextAction = result;

        entries[1].stateDeltas = deltas2;
        entries[1].actionHash = keccak256(abi.encode(callB));
        entries[1].nextAction = result;
    }

    function _l2Entries(address counterB, address callTwoDiff)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        Action memory callB = _callAction(counterB, callTwoDiff);
        Action memory result = _resultAction();

        entries = new ExecutionEntry[](2);
        entries[0].stateDeltas = new StateDelta[](0);
        entries[0].actionHash = keccak256(abi.encode(result));
        entries[0].nextAction = callB;

        entries[1].stateDeltas = new StateDelta[](0);
        entries[1].actionHash = keccak256(abi.encode(result));
        entries[1].nextAction = result;
    }
}

/// @notice Batcher: postBatch + callBothCounters in one tx
contract Batcher {
    function execute(
        Rollups rollups,
        ExecutionEntry[] calldata entries,
        CallTwoDifferent app,
        address counterAProxy,
        address counterBProxy
    ) external returns (uint256 a, uint256 b) {
        rollups.postBatch(entries, 0, "", "proof");
        (a, b) = app.callBothCounters(counterAProxy, counterBProxy);
    }
}

/// @title DeployL2 — Deploy both Counters on L2
/// @dev Outputs: COUNTER_A, COUNTER_B
contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterA = new Counter();
        Counter counterB = new Counter();
        console.log("COUNTER_A=%s", address(counterA));
        console.log("COUNTER_B=%s", address(counterB));
        vm.stopBroadcast();
    }
}

/// @title Deploy — Deploy CallTwoDifferent + proxies on L1
/// @dev Env: ROLLUPS, COUNTER_A, COUNTER_B
/// Outputs: CALL_TWO_DIFF, PROXY_A, PROXY_B
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterAAddr = vm.envAddress("COUNTER_A");
        address counterBAddr = vm.envAddress("COUNTER_B");

        vm.startBroadcast();

        Rollups rollups = Rollups(rollupsAddr);
        CallTwoDifferent callTwoDiff = new CallTwoDifferent();

        // Try to create proxies; if they already exist (CreateCollision), compute the addresses
        address proxyA;
        try rollups.createCrossChainProxy(counterAAddr, 1) returns (address p) {
            proxyA = p;
        } catch {
            proxyA = rollups.computeCrossChainProxyAddress(counterAAddr, 1);
        }

        address proxyB;
        try rollups.createCrossChainProxy(counterBAddr, 1) returns (address p) {
            proxyB = p;
        } catch {
            proxyB = rollups.computeCrossChainProxyAddress(counterBAddr, 1);
        }

        console.log("CALL_TWO_DIFF=%s", address(callTwoDiff));
        console.log("PROXY_A=%s", proxyA);
        console.log("PROXY_B=%s", proxyB);

        vm.stopBroadcast();
    }
}

/// @title ExecuteL2 — Load L2 table + executeIncomingCrossChainCall (chained)
/// @dev Env: MANAGER_L2, COUNTER_A, COUNTER_B, CALL_TWO_DIFF
///
/// L2 execution table (2 entries, chained):
///   [0] hash(RESULT_1) → CALL(counterB)       ← result of A chains to calling B
///   [1] hash(RESULT_1) → RESULT_1 (terminal)   ← result of B is terminal
///
/// Both entries share the same actionHash (hash of RESULT(1)) because both calls
/// return the same result. Entry 0 is consumed first (chains), entry 1 second (terminal).
///
/// 1 executeIncomingCrossChainCall (for counterA). Chaining handles counterB.
contract ExecuteL2 is Script, MultiCallTwoDiffActions {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterAAddr = vm.envAddress("COUNTER_A");
        address counterBAddr = vm.envAddress("COUNTER_B");
        address callTwoDiffAddr = vm.envAddress("CALL_TWO_DIFF");

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        vm.startBroadcast();

        manager.loadExecutionTable(_l2Entries(counterBAddr, callTwoDiffAddr));

        // Single call: increment counterA (0→1). Chaining handles counterB.
        manager.executeIncomingCrossChainCall(
            counterAAddr, 0, abi.encodeWithSelector(Counter.increment.selector), callTwoDiffAddr, 0, new uint256[](0)
        );

        console.log("L2 execution complete");
        console.log("counterA=%s", Counter(counterAAddr).counter());
        console.log("counterB=%s", Counter(counterBAddr).counter());

        vm.stopBroadcast();
    }
}

/// @title Execute — Local mode: postBatch + callBothCounters via Batcher
/// @dev Env: ROLLUPS, COUNTER_A, COUNTER_B, CALL_TWO_DIFF, PROXY_A, PROXY_B
contract Execute is Script, MultiCallTwoDiffActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterAAddr = vm.envAddress("COUNTER_A");
        address counterBAddr = vm.envAddress("COUNTER_B");
        address callTwoDiffAddr = vm.envAddress("CALL_TWO_DIFF");
        address proxyAAddr = vm.envAddress("PROXY_A");
        address proxyBAddr = vm.envAddress("PROXY_B");

        vm.startBroadcast();

        Batcher batcher = new Batcher();

        (uint256 a, uint256 b) = batcher.execute(
            Rollups(rollupsAddr),
            _l1Entries(counterAAddr, counterBAddr, callTwoDiffAddr),
            CallTwoDifferent(callTwoDiffAddr),
            proxyAAddr,
            proxyBAddr
        );

        console.log("done");
        console.log("counterA=%s", a);
        console.log("counterB=%s", b);

        vm.stopBroadcast();
    }
}

/// @title ExecuteNetwork — Network mode: user transaction only
/// @dev Env: CALL_TWO_DIFF, PROXY_A, PROXY_B
/// Returns (target, value, calldata) so the runner can send via `cast send`.
contract ExecuteNetwork is Script {
    function run() external view {
        address callTwoDiffAddr = vm.envAddress("CALL_TWO_DIFF");
        address proxyAAddr = vm.envAddress("PROXY_A");
        address proxyBAddr = vm.envAddress("PROXY_B");
        bytes memory data = abi.encodeWithSelector(CallTwoDifferent.callBothCounters.selector, proxyAAddr, proxyBAddr);
        console.log("TARGET=%s", callTwoDiffAddr);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

/// @title ComputeExpected — Compute expected hashes for TwoDifferent scenario
/// @dev Env: COUNTER_A, COUNTER_B, CALL_TWO_DIFF
contract ComputeExpected is ComputeExpectedBase, MultiCallTwoDiffActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_A")) return "CounterA";
        if (a == vm.envAddress("COUNTER_B")) return "CounterB";
        if (a == vm.envAddress("CALL_TWO_DIFF")) return "CallTwoDifferent";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterAAddr = vm.envAddress("COUNTER_A");
        address counterBAddr = vm.envAddress("COUNTER_B");
        address callTwoDiffAddr = vm.envAddress("CALL_TWO_DIFF");

        // Actions (single source of truth)
        Action memory callA = _callAction(counterAAddr, callTwoDiffAddr);
        Action memory callB = _callAction(counterBAddr, callTwoDiffAddr);
        Action memory result1 = _resultAction();

        // Entries (single source of truth)
        ExecutionEntry[] memory l1 = _l1Entries(counterAAddr, counterBAddr, callTwoDiffAddr);
        ExecutionEntry[] memory l2 = _l2Entries(counterBAddr, callTwoDiffAddr);

        // Compute hashes from entries
        bytes32 l1HashA = _entryHash(l1[0].actionHash, l1[0].nextAction);
        bytes32 l1HashB = _entryHash(l1[1].actionHash, l1[1].nextAction);
        bytes32 l2Hash0 = _entryHash(l2[0].actionHash, l2[0].nextAction);
        bytes32 l2Hash1 = _entryHash(l2[1].actionHash, l2[1].nextAction);
        bytes32 callAHash = l1[0].actionHash;

        // Parseable lines
        console.log("EXPECTED_L1_HASHES=[%s,%s]", vm.toString(l1HashA), vm.toString(l1HashB));
        console.log("EXPECTED_L2_HASHES=[%s,%s]", vm.toString(l2Hash0), vm.toString(l2Hash1));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(callAHash));

        // Summary
        console.log("");
        console.log("=== EXPECTED SUMMARY ===");
        _logEntrySummary(0, callA, result1, false);
        _logEntrySummary(1, callB, result1, false);

        // Human-readable: L1 execution table
        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (2 entries, different targets) ===");
        _logEntry(0, l1HashA, l1[0].stateDeltas, _fmtCall(callA), _fmtResult(result1, "uint256(1)"));
        _logEntry(1, l1HashB, l1[1].stateDeltas, _fmtCall(callB), _fmtResult(result1, "uint256(1)"));

        // Human-readable: L2 execution table
        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (2 entries, chained) ===");
        _logL2Entry(
            0,
            l2Hash0,
            _fmtResult(result1, "uint256(1)"),
            string.concat(_fmtCall(callB), "  (chains to counterB)")
        );
        _logL2Entry(
            1,
            l2Hash1,
            _fmtResult(result1, "uint256(1)"),
            string.concat(_fmtResult(result1, "uint256(1)"), "  (terminal)")
        );

        // Human-readable: L2 calls
        console.log("");
        console.log("=== EXPECTED L2 CALLS (1 call) ===");
        _logL2Call(0, callAHash, callA);
    }
}
