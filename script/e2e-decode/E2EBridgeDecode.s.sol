// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../src/Rollups.sol";
import {Action, ActionType, ExecutionEntry, StaticCall, StateDelta} from "../../src/ICrossChainManager.sol";
import {IZKVerifier} from "../../src/IZKVerifier.sol";
import {Bridge} from "../../src/periphery/Bridge.sol";
import {_deployBridge} from "../DeployBridge.s.sol";

contract MockZKVerifier is IZKVerifier {
    function verify(
        bytes calldata,
        bytes32
    ) external pure override returns (bool) {
        return true;
    }
}

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
        rollups.postBatch(entries, new StaticCall[](0), 0, "", "proof");
        bridge.bridgeEther{value: msg.value}(rollupId, destination);
    }
}

/// @title E2EBridgeDeploy — Deploy infra + bridge contracts
contract E2EBridgeDeploy is Script {
    function run() external {
        vm.startBroadcast();

        MockZKVerifier verifier = new MockZKVerifier();
        Rollups rollups = new Rollups(address(verifier), 1);
        rollups.createRollup(keccak256("l2-initial-state"), keccak256("verificationKey"), msg.sender);

        bytes32 salt = keccak256("sync-rollups-bridge-v1");
        address bridgeAddr = _deployBridge(salt);
        Bridge bridge = Bridge(bridgeAddr);
        bridge.initialize(address(rollups), 0, msg.sender);

        console.log("ROLLUPS=%s", address(rollups));
        console.log("BRIDGE=%s", address(bridge));

        vm.stopBroadcast();
    }
}

/// @title E2EBridgeExecute — postBatch + bridgeEther via BridgeBatcher (single tx)
contract E2EBridgeExecute is Script {
    function run(
        address rollupsAddr,
        address bridgeAddr
    ) external {
        vm.startBroadcast();

        BridgeBatcher batcher = new BridgeBatcher();

        address destination = msg.sender;
        uint256 L2_ROLLUP_ID = 1;

        // CALL that executeCrossChainCall will build when bridge calls proxy for (destination, L2)
        // proxy.originalAddress = destination, proxy.originalRollupId = L2
        // sourceAddress = bridgeAddr (bridge is msg.sender to proxy)
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

        // Single tx: postBatch + bridgeEther
        batcher.execute{
            value: 1 ether
        }(Rollups(rollupsAddr), entries, Bridge(bridgeAddr), L2_ROLLUP_ID, destination);

        console.log("done");

        vm.stopBroadcast();
    }
}
