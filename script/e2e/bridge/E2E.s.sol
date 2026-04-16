// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta, StaticCall} from "../../../src/ICrossChainManager.sol";
import {Bridge} from "../../../src/periphery/Bridge.sol";
import {_deployBridge, _computeBridgeAddress} from "../../DeployBridge.s.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";

/// @dev Centralized action & entry definitions for the bridge scenario.
abstract contract BridgeActions {
    function _callAction(address destination, address bridge) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.CALL,
            rollupId: 1,
            destination: destination,
            value: 1 ether,
            data: "",
            failed: false,
            isStatic: false,
            sourceAddress: bridge,
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
            data: "",
            failed: false,
            isStatic: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    function _l1Entries(address destination, address bridge)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        Action memory call_ = _callAction(destination, bridge);
        Action memory result = _resultAction();

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: 1,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-bridge"),
            etherDelta: 1 ether
        });

        entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = keccak256(abi.encode(call_));
        entries[0].nextAction = result;
    }

    function _l2Entries() internal pure returns (ExecutionEntry[] memory entries) {
        Action memory result = _resultAction();

        entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = new StateDelta[](0);
        entries[0].actionHash = keccak256(abi.encode(result));
        entries[0].nextAction = result;
    }
}

/// @notice Batcher: postBatch + bridgeEther in one tx (local mode only)
contract Batcher {
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

/// @title Deploy — Deploy bridge app contracts on L1
/// @dev Env: ROLLUPS
/// Outputs: BRIDGE, DESTINATION
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        vm.startBroadcast();

        bytes32 salt = keccak256("sync-rollups-bridge-v1");
        address bridgeAddr = _computeBridgeAddress(salt);
        if (bridgeAddr.code.length == 0) {
            bridgeAddr = _deployBridge(salt);
            Bridge(bridgeAddr).initialize(rollupsAddr, 0, msg.sender);
        }

        console.log("BRIDGE=%s", bridgeAddr);
        console.log("DESTINATION=%s", msg.sender);

        vm.stopBroadcast();
    }
}

/// @title ExecuteL2 — Load L2 execution table + executeIncomingCrossChainCall for bridge
/// @dev Env: MANAGER_L2, BRIDGE, DESTINATION
/// The bridge CALL sends ETH to destination on L2. On L2, the system executes this via
/// executeIncomingCrossChainCall, which creates a proxy for the bridge and sends ETH.
contract ExecuteL2 is Script, BridgeActions {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address bridgeAddr = vm.envAddress("BRIDGE");
        address destination = vm.envAddress("DESTINATION");

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        vm.startBroadcast();

        manager.loadExecutionTable(_l2Entries(), new StaticCall[](0));

        // Execute: system sends 1 ETH to destination via proxy for bridge
        manager.executeIncomingCrossChainCall{value: 1 ether}(
            destination, 1 ether, "", bridgeAddr, 0, new uint256[](0)
        );

        console.log("L2 execution complete");

        vm.stopBroadcast();
    }
}

/// @title Execute — Local mode: postBatch + bridgeEther via Batcher
/// @dev Env: ROLLUPS, BRIDGE
contract Execute is Script, BridgeActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address bridgeAddr = vm.envAddress("BRIDGE");

        vm.startBroadcast();

        Batcher batcher = new Batcher();
        address destination = msg.sender;

        batcher.execute{value: 1 ether}(
            Rollups(rollupsAddr), _l1Entries(destination, bridgeAddr), Bridge(bridgeAddr), 1, destination
        );

        console.log("done");

        vm.stopBroadcast();
    }
}

/// @title ExecuteNetwork — Network mode: user transaction only (no Batcher)
/// @dev Env: BRIDGE, DESTINATION
/// Returns (target, value, calldata) so the runner can send via `cast send`.
/// We can't use `forge script --broadcast` because the tx reverts in local simulation
/// (no execution table loaded yet). The system intercepts the tx from the mempool
/// and inserts postBatch before it in the same block.
contract ExecuteNetwork is Script {
    function run() external view {
        address bridgeAddr = vm.envAddress("BRIDGE");
        address destination = vm.envAddress("DESTINATION");
        bytes memory data = abi.encodeWithSelector(Bridge.bridgeEther.selector, 1, destination);
        console.log("TARGET=%s", bridgeAddr);
        console.log("VALUE=1000000000000000000");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

/// @title ComputeExpected — Compute expected actionHashes + print expected table
/// @dev Env: BRIDGE, DESTINATION
contract ComputeExpected is ComputeExpectedBase, BridgeActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("BRIDGE")) return "Bridge";
        if (a == vm.envAddress("DESTINATION")) return "Destination";
        return _shortAddr(a);
    }

    function run() external view {
        address bridgeAddr = vm.envAddress("BRIDGE");
        address destination = vm.envAddress("DESTINATION");

        // Actions (single source of truth)
        Action memory callAction = _callAction(destination, bridgeAddr);
        Action memory resultAction = _resultAction();

        // Entries (single source of truth)
        ExecutionEntry[] memory l1 = _l1Entries(destination, bridgeAddr);
        ExecutionEntry[] memory l2 = _l2Entries();

        // Compute hashes from entries
        bytes32 l1EntryHash = _entryHash(l1[0].actionHash, l1[0].nextAction);
        bytes32 l2EntryHash = _entryHash(l2[0].actionHash, l2[0].nextAction);
        bytes32 callHash = l1[0].actionHash;

        // Parseable lines
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1EntryHash));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2EntryHash));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(callHash));

        // Summary
        console.log("");
        console.log("=== EXPECTED SUMMARY ===");
        _logEntrySummary(0, callAction, resultAction, false);

        // L1 execution table
        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (1 entry) ===");
        _logEntry(0, l1EntryHash, l1[0].stateDeltas, _fmtCall(callAction), _fmtResult(resultAction, "(void)"));

        // L2 execution table
        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (1 entry) ===");
        _logL2Entry(
            0,
            l2EntryHash,
            _fmtResult(resultAction, "(void)"),
            string.concat(_fmtResult(resultAction, "(void)"), "  (terminal)")
        );

        // L2 calls
        console.log("");
        console.log("=== EXPECTED L2 CALLS (1 call) ===");
        _logL2Call(0, callHash, callAction);
    }
}
