// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainProxy} from "../../../src/CrossChainProxy.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {Counter, CounterAndProxy} from "../../../test/mocks/CounterContracts.sol";

/// @notice Batcher: postBatch + incrementProxy in one tx (local mode only)
contract Batcher {
    function execute(Rollups rollups, ExecutionEntry[] calldata entries, CounterAndProxy cap) external {
        rollups.postBatch(entries, 0, "", "proof");
        cap.incrementProxy();
    }
}

/// @title Deploy — Deploy counter app contracts
/// @dev Env: ROLLUPS
/// Outputs: COUNTER_L2, COUNTER_PROXY, COUNTER_AND_PROXY
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        vm.startBroadcast();

        Rollups rollups = Rollups(rollupsAddr);
        Counter counterL2 = new Counter();
        address counterProxy = rollups.createCrossChainProxy(address(counterL2), 1);
        CounterAndProxy counterAndProxy = new CounterAndProxy(Counter(counterProxy));

        console.log("COUNTER_L2=%s", address(counterL2));
        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("COUNTER_AND_PROXY=%s", address(counterAndProxy));

        vm.stopBroadcast();
    }
}

/// @title Execute — Local mode: postBatch + incrementProxy via Batcher
/// @dev Env: ROLLUPS, COUNTER_L2, COUNTER_AND_PROXY
contract Execute is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address counterAndProxyAddr = vm.envAddress("COUNTER_AND_PROXY");

        vm.startBroadcast();

        Batcher batcher = new Batcher();
        (ExecutionEntry[] memory entries,) = _buildEntries(counterL2Addr, counterAndProxyAddr);
        batcher.execute(Rollups(rollupsAddr), entries, CounterAndProxy(counterAndProxyAddr));

        console.log("done");
        console.log("counter=%s", CounterAndProxy(counterAndProxyAddr).counter());
        console.log("targetCounter=%s", CounterAndProxy(counterAndProxyAddr).targetCounter());

        vm.stopBroadcast();
    }

    function _buildEntries(address counterL2Addr, address counterAndProxyAddr)
        internal
        pure
        returns (ExecutionEntry[] memory entries, bytes32 actionHash)
    {
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: 1,
            destination: counterL2Addr,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            failed: false,
            sourceAddress: counterAndProxyAddr,
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        Action memory resultAction = Action({
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

        StateDelta[] memory stateDeltas = new StateDelta[](1);
        stateDeltas[0] = StateDelta({
            rollupId: 1,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-scenario1"),
            etherDelta: 0
        });

        entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = stateDeltas;
        entries[0].actionHash = keccak256(abi.encode(callAction));
        entries[0].nextAction = resultAction;
        actionHash = entries[0].actionHash;
    }
}

/// @title ExecuteNetwork — Network mode: user transaction only (no Batcher)
/// @dev Env: COUNTER_AND_PROXY
contract ExecuteNetwork is Script {
    function run() external {
        address counterAndProxyAddr = vm.envAddress("COUNTER_AND_PROXY");
        vm.startBroadcast();
        CounterAndProxy(counterAndProxyAddr).incrementProxy();
        console.log("done");
        vm.stopBroadcast();
    }
}

/// @title ComputeExpected — Compute expected actionHashes + print expected table
/// @dev Env: COUNTER_L2, COUNTER_AND_PROXY
contract ComputeExpected is Script {
    function run() external view {
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address counterAndProxyAddr = vm.envAddress("COUNTER_AND_PROXY");

        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: 1,
            destination: counterL2Addr,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            failed: false,
            sourceAddress: counterAndProxyAddr,
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        StateDelta[] memory stateDeltas = new StateDelta[](1);
        stateDeltas[0] = StateDelta({
            rollupId: 1,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-scenario1"),
            etherDelta: 0
        });

        bytes32 hash = keccak256(abi.encode(callAction));

        // Parseable line
        console.log("EXPECTED_HASHES=[%s]", vm.toString(hash));

        // Human-readable expected table
        console.log("");
        console.log("=== EXPECTED EXECUTION TABLE (1 entry) ===");
        console.log("  [0] DEFERRED  actionHash: %s", vm.toString(hash));
        console.log(
            string.concat(
                "      stateDelta: rollup 1  ",
                vm.toString(stateDeltas[0].currentState),
                " -> ",
                vm.toString(stateDeltas[0].newState),
                "  ether: 0"
            )
        );
        console.log(
            "      nextAction: RESULT(rollup 1, ok, data=0x0000000000000000000000000000000000000000000000000000000000000001)"
        );
    }
}
