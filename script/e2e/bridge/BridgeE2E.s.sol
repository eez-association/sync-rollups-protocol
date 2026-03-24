// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {Bridge} from "../../../src/periphery/Bridge.sol";
import {_deployBridge} from "../../DeployBridge.s.sol";

/// @notice Helper that executes postBatch + bridgeEther in a single transaction
/// @dev Needed because executeCrossChainCall requires same block as postBatch
contract BridgeBatcher {
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

/// @title BridgeDeploy — Deploy Bridge via CREATE2 and initialize with Rollups
/// @dev Takes an already-deployed Rollups address.
///   forge script script/e2e/bridge/BridgeE2E.s.sol:BridgeDeploy \
///     --rpc-url $RPC --broadcast --private-key $PK \
///     --sig "run(address)" $ROLLUPS
contract BridgeDeploy is Script {
    function run(address rollupsAddr) external {
        vm.startBroadcast();

        bytes32 salt = keccak256("sync-rollups-bridge-v1");
        address bridgeAddr = _deployBridge(salt);
        Bridge bridge = Bridge(bridgeAddr);
        bridge.initialize(rollupsAddr, 0, msg.sender);

        console.log("BRIDGE=%s", address(bridge));

        vm.stopBroadcast();
    }
}

/// @title BridgeExecute — postBatch + bridgeEther via BridgeBatcher (single tx, local mode)
///   forge script script/e2e/bridge/BridgeE2E.s.sol:BridgeExecute \
///     --rpc-url $RPC --broadcast --private-key $PK \
///     --sig "run(address,address)" $ROLLUPS $BRIDGE
contract BridgeExecute is Script {
    function run(address rollupsAddr, address bridgeAddr) external {
        vm.startBroadcast();

        BridgeBatcher batcher = new BridgeBatcher();

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

        batcher.execute{value: 1 ether}(
            Rollups(rollupsAddr),
            entries,
            Bridge(bridgeAddr),
            L2_ROLLUP_ID,
            destination
        );

        console.log("done");

        vm.stopBroadcast();
    }
}

/// @title BridgeExecuteNetwork — Send only the user transaction (network mode, no Batcher)
///   forge script script/e2e/bridge/BridgeE2E.s.sol:BridgeExecuteNetwork \
///     --rpc-url $RPC --broadcast --private-key $PK \
///     --sig "run(address,uint256,address)" $BRIDGE $L2_ROLLUP_ID $DESTINATION
contract BridgeExecuteNetwork is Script {
    function run(address bridgeAddr, uint256 rollupId, address destination) external {
        vm.startBroadcast();
        Bridge(bridgeAddr).bridgeEther{value: 1 ether}(rollupId, destination);
        console.log("done");
        vm.stopBroadcast();
    }
}

/// @title BridgeComputeExpected — Compute expected entries for verification
///   forge script script/e2e/bridge/BridgeE2E.s.sol:BridgeComputeExpected \
///     --sig "run(address,address)" $BRIDGE $DESTINATION
contract BridgeComputeExpected is Script {
    function run(address bridgeAddr, address destination) external pure {
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

        // Parseable line for shell scripts
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
                "  ether: ",
                vm.toString(stateDeltas[0].etherDelta)
            )
        );
        console.log("      nextAction: RESULT(rollup 1, ok, data=0x)");
    }
}
