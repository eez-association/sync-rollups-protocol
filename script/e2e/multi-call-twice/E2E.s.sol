// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainProxy} from "../../../src/CrossChainProxy.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {Counter} from "../../../test/mocks/CounterContracts.sol";
import {CallTwice} from "../../../test/mocks/MultiCallContracts.sol";

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

/// @title Deploy — Deploy counter + CallTwice + proxy
/// @dev Env: ROLLUPS
/// Outputs: COUNTER_A, CALL_TWICE, PROXY_A
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        vm.startBroadcast();

        Rollups rollups = Rollups(rollupsAddr);
        Counter counterA = new Counter();
        CallTwice callTwice = new CallTwice();
        address proxyA = rollups.createCrossChainProxy(address(counterA), 1);

        console.log("COUNTER_A=%s", address(counterA));
        console.log("CALL_TWICE=%s", address(callTwice));
        console.log("PROXY_A=%s", proxyA);

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
contract ExecuteNetwork is Script {
    function run() external {
        address callTwiceAddr = vm.envAddress("CALL_TWICE");
        address proxyAAddr = vm.envAddress("PROXY_A");
        vm.startBroadcast();
        CallTwice(callTwiceAddr).callCounterTwice(proxyAAddr);
        console.log("done");
        vm.stopBroadcast();
    }
}

/// @title ComputeExpected — Compute expected hashes for CallTwice scenario
/// @dev Env: COUNTER_A, CALL_TWICE
contract ComputeExpected is Script {
    function run() external view {
        address counterAAddr = vm.envAddress("COUNTER_A");
        address callTwiceAddr = vm.envAddress("CALL_TWICE");
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

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

        bytes32 hash = keccak256(abi.encode(callAction));

        // Same hash repeated for 2 entries
        console.log("EXPECTED_HASHES=[%s,%s]", vm.toString(hash), vm.toString(hash));

        console.log("");
        console.log("=== EXPECTED EXECUTION TABLE (2 entries, same action hash) ===");
        console.log("  [0] DEFERRED  actionHash: %s", vm.toString(hash));
        console.log("      nextAction: RESULT(rollup 1, ok, data=encode(1))");
        console.log("  [1] DEFERRED  actionHash: %s", vm.toString(hash));
        console.log("      nextAction: RESULT(rollup 1, ok, data=encode(2))");
    }
}
