// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {Bridge} from "../../../src/periphery/Bridge.sol";
import {_deployBridge, _computeBridgeAddress} from "../../DeployBridge.s.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";

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
contract ExecuteL2 is Script {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address bridgeAddr = vm.envAddress("BRIDGE");
        address destination = vm.envAddress("DESTINATION");

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        // RESULT: empty return from ETH transfer to destination
        Action memory resultAction = Action({
            actionType: ActionType.RESULT,
            rollupId: 1,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        vm.startBroadcast();

        // Load execution table: 1 entry (RESULT hash -> same RESULT, terminal)
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = new StateDelta[](0);
        entries[0].actionHash = keccak256(abi.encode(resultAction));
        entries[0].nextAction = resultAction;
        manager.loadExecutionTable(entries);

        // Execute: system sends 1 ETH to destination via proxy for bridge
        manager.executeIncomingCrossChainCall{value: 1 ether}(
            destination, // destination on L2
            1 ether,     // value
            "",          // data (empty for ETH transfer)
            bridgeAddr,  // sourceAddress = Bridge on L1
            0,           // sourceRollup = MAINNET
            new uint256[](0) // scope = root
        );

        console.log("L2 execution complete");

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
contract ComputeExpected is ComputeExpectedBase {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("BRIDGE")) return "Bridge";
        if (a == vm.envAddress("DESTINATION")) return "Destination";
        return _shortAddr(a);
    }

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

        // RESULT action (L2 execution table entry)
        Action memory resultAction = Action({
            actionType: ActionType.RESULT,
            rollupId: 1,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        bytes32 hash = keccak256(abi.encode(callAction));
        bytes32 l2Hash = keccak256(abi.encode(resultAction));

        // L1 batch verification
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(hash));
        // L2 execution table verification
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        // L2 call verification (same hash — the CALL to L2)
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(hash));

        // ── Human-readable output ──
        console.log("");

        // L1 execution table
        console.log("=== EXPECTED L1 EXECUTION TABLE (1 entry) ===");
        _logEntry(0, hash, stateDeltas, _fmtCall(callAction), _fmtResult(resultAction, "(void)"));

        // L2 execution table
        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (1 entry) ===");
        _logL2Entry(
            0,
            l2Hash,
            _fmtResult(resultAction, "(void)"),
            string.concat(_fmtResult(resultAction, "(void)"), "  (terminal)")
        );

        // L2 calls
        console.log("");
        console.log("=== EXPECTED L2 CALLS (1 call) ===");
        _logL2Call(0, hash, callAction);
    }
}
