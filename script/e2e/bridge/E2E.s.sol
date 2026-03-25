// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {Bridge} from "../../../src/periphery/Bridge.sol";
import {_deployBridge} from "../../DeployBridge.s.sol";

/// @notice Batcher: postBatch + bridgeEther in one tx (local mode only)
contract Batcher {
    function execute(
        Rollups rollups,
        ExecutionEntry[] calldata entries,
        Bridge bridge,
        uint256 rollupId,
        address destination
    ) external payable {
        rollups.postBatch(entries, 0, "", "proof");
        bridge.bridgeEther{value: msg.value}(rollupId, destination);
    }
}

/// @title Deploy — Deploy bridge app contracts
/// @dev Env: ROLLUPS
/// Outputs: BRIDGE
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        vm.startBroadcast();

        bytes32 salt = keccak256("sync-rollups-bridge-v1");
        address bridgeAddr = _deployBridge(salt);
        Bridge(bridgeAddr).initialize(rollupsAddr, 0, msg.sender);

        console.log("BRIDGE=%s", bridgeAddr);

        vm.stopBroadcast();
    }
}

/// @title Execute — Local mode: postBatch + bridgeEther via Batcher
/// @dev Env: ROLLUPS, BRIDGE
contract Execute is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address bridgeAddr = vm.envAddress("BRIDGE");

        vm.startBroadcast();

        Batcher batcher = new Batcher();
        address destination = msg.sender;
        uint256 L2_ROLLUP_ID = 1;

        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: destination,
            value: 1 ether,
            data: "",
            failed: false,
            sourceAddress: bridgeAddr,
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        Action memory resultAction = Action({
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

        StateDelta[] memory stateDeltas = new StateDelta[](1);
        stateDeltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-bridge"),
            etherDelta: 1 ether
        });

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = stateDeltas;
        entries[0].actionHash = keccak256(abi.encode(callAction));
        entries[0].nextAction = resultAction;

        batcher.execute{value: 1 ether}(Rollups(rollupsAddr), entries, Bridge(bridgeAddr), L2_ROLLUP_ID, destination);

        console.log("done");

        vm.stopBroadcast();
    }
}

/// @title ExecuteNetwork — Network mode: user transaction only (no Batcher)
/// @dev Env: BRIDGE, DESTINATION
contract ExecuteNetwork is Script {
    function run() external {
        address bridgeAddr = vm.envAddress("BRIDGE");
        address destination = vm.envAddress("DESTINATION");
        vm.startBroadcast();
        Bridge(bridgeAddr).bridgeEther{value: 1 ether}(1, destination);
        console.log("done");
        vm.stopBroadcast();
    }
}

/// @title ComputeExpected — Compute expected actionHashes + print expected table
/// @dev Env: BRIDGE, DESTINATION
contract ComputeExpected is Script {
    function run() external view {
        address bridgeAddr = vm.envAddress("BRIDGE");
        address destination = vm.envAddress("DESTINATION");

        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: 1,
            destination: destination,
            value: 1 ether,
            data: "",
            failed: false,
            sourceAddress: bridgeAddr,
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        StateDelta[] memory stateDeltas = new StateDelta[](1);
        stateDeltas[0] = StateDelta({
            rollupId: 1,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-bridge"),
            etherDelta: 1 ether
        });

        bytes32 hash = keccak256(abi.encode(callAction));

        console.log("EXPECTED_HASHES=[%s]", vm.toString(hash));

        console.log("");
        console.log("=== EXPECTED EXECUTION TABLE (1 entry) ===");
        console.log("  [0] DEFERRED  actionHash: %s", vm.toString(hash));
        console.log(
            string.concat(
                "      stateDelta: rollup 1  ",
                vm.toString(stateDeltas[0].currentState),
                " -> ",
                vm.toString(stateDeltas[0].newState),
                "  ether: ",
                vm.toString(stateDeltas[0].etherDelta)
            )
        );
        console.log("      nextAction: RESULT(rollup 1, ok, data=0x)");
    }
}
