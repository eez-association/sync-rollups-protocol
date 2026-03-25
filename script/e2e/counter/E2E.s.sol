// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {Counter, CounterAndProxy} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";

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
contract ExecuteL2 is Script {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address counterAndProxyAddr = vm.envAddress("COUNTER_AND_PROXY");

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        // RESULT that _processCallAtScope will build after Counter.increment() returns 1
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

        vm.startBroadcast();

        // Load execution table: RESULT hash -> same RESULT (terminal, self-referencing)
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = new StateDelta[](0);
        entries[0].actionHash = keccak256(abi.encode(resultAction));
        entries[0].nextAction = resultAction;

        manager.loadExecutionTable(entries);

        // Execute the actual counter increment on L2
        manager.executeIncomingCrossChainCall(
            counterL2Addr,          // dest = Counter on L2
            0,                      // value
            abi.encodeWithSelector(Counter.increment.selector), // data = increment()
            counterAndProxyAddr,    // source = CounterAndProxy on L1
            0,                      // sourceRollup = MAINNET
            new uint256[](0)        // scope = [] (root)
        );

        console.log("done");

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
contract ComputeExpected is ComputeExpectedBase {
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

        // RESULT action (L2 execution table entry)
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

        bytes32 hash = keccak256(abi.encode(callAction));
        bytes32 l2Hash = keccak256(abi.encode(resultAction));

        // Parseable lines
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(hash));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(hash));

        // Human-readable: L1 execution table
        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (1 entry) ===");
        _logEntry(0, hash, stateDeltas, _fmtCall(callAction), _fmtResult(resultAction, "uint256(1)"));

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
        _logL2Call(0, hash, callAction);
    }
}
