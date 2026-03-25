// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {Counter} from "../../../test/mocks/CounterContracts.sol";
import {CallTwoDifferent} from "../../../test/mocks/MultiCallContracts.sol";

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

/// @title ExecuteL2 — Load L2 table + executeIncomingCrossChainCall for both counters
/// @dev Env: MANAGER_L2, COUNTER_A, COUNTER_B, CALL_TWO_DIFF
contract ExecuteL2 is Script {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterAAddr = vm.envAddress("COUNTER_A");
        address counterBAddr = vm.envAddress("COUNTER_B");
        address callTwoDiffAddr = vm.envAddress("CALL_TWO_DIFF");

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // Both counters return 1 (each incremented once: 0→1)
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

        vm.startBroadcast();

        // Load execution table: 2 entries (same RESULT hash, consumed once per call)
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0].stateDeltas = new StateDelta[](0);
        entries[0].actionHash = keccak256(abi.encode(result1));
        entries[0].nextAction = result1;

        entries[1].stateDeltas = new StateDelta[](0);
        entries[1].actionHash = keccak256(abi.encode(result1));
        entries[1].nextAction = result1;

        manager.loadExecutionTable(entries);

        // Call 1: increment counterA (0→1)
        manager.executeIncomingCrossChainCall(
            counterAAddr, 0, incrementCallData, callTwoDiffAddr, 0, new uint256[](0)
        );
        // Call 2: increment counterB (0→1)
        manager.executeIncomingCrossChainCall(
            counterBAddr, 0, incrementCallData, callTwoDiffAddr, 0, new uint256[](0)
        );

        console.log("L2 execution complete");
        console.log("counterA=%s", Counter(counterAAddr).counter());
        console.log("counterB=%s", Counter(counterBAddr).counter());

        vm.stopBroadcast();
    }
}

/// @title Execute — Local mode: postBatch + callBothCounters via Batcher
/// @dev Env: ROLLUPS, COUNTER_A, COUNTER_B, CALL_TWO_DIFF, PROXY_A, PROXY_B
contract Execute is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterAAddr = vm.envAddress("COUNTER_A");
        address counterBAddr = vm.envAddress("COUNTER_B");
        address callTwoDiffAddr = vm.envAddress("CALL_TWO_DIFF");
        address proxyAAddr = vm.envAddress("PROXY_A");
        address proxyBAddr = vm.envAddress("PROXY_B");

        vm.startBroadcast();

        Batcher batcher = new Batcher();
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // Different destinations -> different action hashes
        Action memory callA = Action({
            actionType: ActionType.CALL,
            rollupId: 1,
            destination: counterAAddr,
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: callTwoDiffAddr,
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        Action memory callB = Action({
            actionType: ActionType.CALL,
            rollupId: 1,
            destination: counterBAddr,
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: callTwoDiffAddr,
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

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-twodiff-after-A");
        bytes32 s2 = keccak256("l2-state-twodiff-after-B");

        StateDelta[] memory deltas1 = new StateDelta[](1);
        deltas1[0] = StateDelta({rollupId: 1, currentState: s0, newState: s1, etherDelta: 0});

        StateDelta[] memory deltas2 = new StateDelta[](1);
        deltas2[0] = StateDelta({rollupId: 1, currentState: s1, newState: s2, etherDelta: 0});

        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0].stateDeltas = deltas1;
        entries[0].actionHash = keccak256(abi.encode(callA));
        entries[0].nextAction = result1;

        entries[1].stateDeltas = deltas2;
        entries[1].actionHash = keccak256(abi.encode(callB));
        entries[1].nextAction = result1;

        (uint256 a, uint256 b) = batcher.execute(
            Rollups(rollupsAddr), entries, CallTwoDifferent(callTwoDiffAddr), proxyAAddr, proxyBAddr
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
contract ComputeExpected is Script {
    function run() external view {
        address counterAAddr = vm.envAddress("COUNTER_A");
        address counterBAddr = vm.envAddress("COUNTER_B");
        address callTwoDiffAddr = vm.envAddress("CALL_TWO_DIFF");
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        Action memory callA = Action({
            actionType: ActionType.CALL,
            rollupId: 1,
            destination: counterAAddr,
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: callTwoDiffAddr,
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        Action memory callB = Action({
            actionType: ActionType.CALL,
            rollupId: 1,
            destination: counterBAddr,
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: callTwoDiffAddr,
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        bytes32 hashA = keccak256(abi.encode(callA));
        bytes32 hashB = keccak256(abi.encode(callB));

        // RESULT action (L2 execution table entries — same hash, 2 entries)
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
        bytes32 l2Hash = keccak256(abi.encode(result1));

        console.log("EXPECTED_L1_HASHES=[%s,%s]", vm.toString(hashA), vm.toString(hashB));
        console.log("EXPECTED_L2_HASHES=[%s,%s]", vm.toString(l2Hash), vm.toString(l2Hash));
        console.log("EXPECTED_L2_CALL_HASHES=[%s,%s]", vm.toString(hashA), vm.toString(hashB));

        console.log("");
        console.log("=== EXPECTED EXECUTION TABLE (2 entries, different action hashes) ===");
        console.log("  [0] DEFERRED  actionHash: %s", vm.toString(hashA));
        console.log("      nextAction: RESULT(rollup 1, ok, data=encode(1))");
        console.log("  [1] DEFERRED  actionHash: %s", vm.toString(hashB));
        console.log("      nextAction: RESULT(rollup 1, ok, data=encode(1))");
    }
}
