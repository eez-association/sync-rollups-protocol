// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {Counter, CounterAndProxy} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";

/// @dev Centralized action & entry definitions for the counter scenario.
///   Single source of truth — used by Execute, ExecuteL2, and ComputeExpected.
abstract contract CounterActions {
    function _callAction(address counterL2, address counterAndProxy) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.CALL,
            rollupId: 1,
            destination: counterL2,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            failed: false,
            sourceAddress: counterAndProxy,
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

    function _l1Entries(address counterL2, address counterAndProxy)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        Action memory call_ = _callAction(counterL2, counterAndProxy);
        Action memory result = _resultAction();

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: 1,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-scenario1"),
            etherDelta: 0
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

/// @notice Batcher: postBatch + incrementProxy in one tx (local mode only)
contract Batcher {
    function execute(Rollups rollups, ExecutionEntry[] calldata entries, CounterAndProxy cap) external {
        rollups.postBatch(entries, 0, "", "proof");
        cap.incrementProxy();
    }
}

/// @title DeployL2 — Deploy counter on L2
/// Outputs: COUNTER_L2
contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();

        Counter counterL2 = new Counter();
        console.log("COUNTER_L2=%s", address(counterL2));

        vm.stopBroadcast();
    }
}

/// @title Deploy — Deploy counter app contracts on L1
/// @dev Env: ROLLUPS, COUNTER_L2
/// Outputs: COUNTER_PROXY, COUNTER_AND_PROXY
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2Addr = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();

        Rollups rollups = Rollups(rollupsAddr);

        // Try to create proxy; if it already exists (CreateCollision), compute the address
        address counterProxy;
        try rollups.createCrossChainProxy(counterL2Addr, 1) returns (address proxy) {
            counterProxy = proxy;
        } catch {
            counterProxy = rollups.computeCrossChainProxyAddress(counterL2Addr, 1);
        }

        CounterAndProxy counterAndProxy = new CounterAndProxy(Counter(counterProxy));

        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("COUNTER_AND_PROXY=%s", address(counterAndProxy));

        vm.stopBroadcast();
    }
}

/// @title ExecuteL2 — Load execution table + executeIncomingCrossChainCall on L2
/// @dev Follows integration test Scenario 1 Phase 1 pattern.
///   1. Load L2 execution table: RESULT hash -> same RESULT (terminal, self-referencing)
///   2. System calls executeIncomingCrossChainCall to execute Counter.increment() on L2
/// Env: MANAGER_L2, COUNTER_L2, COUNTER_AND_PROXY
contract ExecuteL2 is Script, CounterActions {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address counterAndProxyAddr = vm.envAddress("COUNTER_AND_PROXY");

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        vm.startBroadcast();

        manager.loadExecutionTable(_l2Entries());

        // Execute the actual counter increment on L2
        manager.executeIncomingCrossChainCall(
            counterL2Addr, 0, abi.encodeWithSelector(Counter.increment.selector), counterAndProxyAddr, 0, new uint256[](0)
        );

        console.log("done");

        vm.stopBroadcast();
    }
}

/// @title Execute — Local mode: postBatch + incrementProxy via Batcher
/// @dev Env: ROLLUPS, COUNTER_L2, COUNTER_AND_PROXY
contract Execute is Script, CounterActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address counterAndProxyAddr = vm.envAddress("COUNTER_AND_PROXY");

        vm.startBroadcast();

        Batcher batcher = new Batcher();
        batcher.execute(Rollups(rollupsAddr), _l1Entries(counterL2Addr, counterAndProxyAddr), CounterAndProxy(counterAndProxyAddr));

        console.log("done");
        console.log("counter=%s", CounterAndProxy(counterAndProxyAddr).counter());
        console.log("targetCounter=%s", CounterAndProxy(counterAndProxyAddr).targetCounter());

        vm.stopBroadcast();
    }
}

/// @title ExecuteNetwork — Network mode: user transaction only (no Batcher)
/// @dev Env: COUNTER_AND_PROXY
/// Returns (target, value, calldata) so the runner can send via `cast send`.
/// We can't use `forge script --broadcast` because the tx reverts in local simulation
/// (no execution table loaded yet). The system intercepts the tx from the mempool
/// and inserts postBatch before it in the same block.
contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("COUNTER_AND_PROXY");
        bytes memory data = abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

/// @title ComputeExpected — Compute expected actionHashes + print expected table
/// @dev Env: COUNTER_L2, COUNTER_AND_PROXY
contract ComputeExpected is ComputeExpectedBase, CounterActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L2")) return "Counter";
        if (a == vm.envAddress("COUNTER_AND_PROXY")) return "CounterAndProxy";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address counterAndProxyAddr = vm.envAddress("COUNTER_AND_PROXY");

        // Actions (single source of truth)
        Action memory callAction = _callAction(counterL2Addr, counterAndProxyAddr);
        Action memory resultAction = _resultAction();

        // Entries (single source of truth)
        ExecutionEntry[] memory l1 = _l1Entries(counterL2Addr, counterAndProxyAddr);
        ExecutionEntry[] memory l2 = _l2Entries();

        // Compute hashes from entries
        bytes32 l1Hash = _entryHash(l1[0].actionHash, l1[0].nextAction);
        bytes32 l2Hash = _entryHash(l2[0].actionHash, l2[0].nextAction);
        bytes32 callActionHash = l1[0].actionHash;

        // Parseable lines
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(callActionHash));

        // Summary
        console.log("");
        console.log("=== EXPECTED SUMMARY ===");
        _logEntrySummary(0, callAction, resultAction, false);

        // Human-readable: L1 execution table
        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (1 entry) ===");
        _logEntry(0, l1Hash, l1[0].stateDeltas, _fmtCall(callAction), _fmtResult(resultAction, "uint256(1)"));

        // Human-readable: L2 execution table
        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (1 entry) ===");
        _logL2Entry(
            0,
            l2Hash,
            _fmtResult(resultAction, "uint256(1)"),
            string.concat(_fmtResult(resultAction, "uint256(1)"), "  (terminal)")
        );

        // Human-readable: L2 calls
        console.log("");
        console.log("=== EXPECTED L2 CALLS (1 call) ===");
        _logL2Call(0, callActionHash, callAction);
    }
}
