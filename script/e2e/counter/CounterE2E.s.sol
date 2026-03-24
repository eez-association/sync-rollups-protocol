// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainProxy} from "../../../src/CrossChainProxy.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {Counter, CounterAndProxy} from "../../../test/mocks/CounterContracts.sol";

/// @notice Helper that executes postBatch + incrementProxy in a single transaction
/// @dev Needed because executeCrossChainCall requires same block as postBatch
contract Batcher {
    function execute(
        Rollups rollups,
        ExecutionEntry[] calldata entries,
        CounterAndProxy cap
    ) external {
        rollups.postBatch(entries, 0, "", "proof");
        cap.incrementProxy();
    }
}

/// @title CounterDeploy — Deploy app contracts (Counter + proxy + CounterAndProxy)
/// @dev Takes an already-deployed Rollups address.
///   forge script script/e2e/counter/CounterE2E.s.sol:CounterDeploy \
///     --rpc-url $RPC --broadcast --private-key $PK \
///     --sig "run(address)" $ROLLUPS
contract CounterDeploy is Script {
    function run(address rollupsAddr) external {
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

/// @title CounterExecute — postBatch + incrementProxy via Batcher (single tx, local mode)
///   forge script script/e2e/counter/CounterE2E.s.sol:CounterExecute \
///     --rpc-url $RPC --broadcast --private-key $PK \
///     --sig "run(address,address,address)" $ROLLUPS $COUNTER_L2 $COUNTER_AND_PROXY
contract CounterExecute is Script {
    function run(address rollupsAddr, address counterL2Addr, address counterAndProxyAddr) external {
        vm.startBroadcast();

        Batcher batcher = new Batcher();

        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: 1,
            destination: counterL2Addr,
            value: 0,
            data: incrementCallData,
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

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = stateDeltas;
        entries[0].actionHash = keccak256(abi.encode(callAction));
        entries[0].nextAction = resultAction;

        batcher.execute(Rollups(rollupsAddr), entries, CounterAndProxy(counterAndProxyAddr));

        console.log("done");
        console.log("counter=%s", CounterAndProxy(counterAndProxyAddr).counter());
        console.log("targetCounter=%s", CounterAndProxy(counterAndProxyAddr).targetCounter());

        vm.stopBroadcast();
    }
}

/// @title CounterExecuteNetwork — Send only the user transaction (network mode, no Batcher)
///   forge script script/e2e/counter/CounterE2E.s.sol:CounterExecuteNetwork \
///     --rpc-url $RPC --broadcast --private-key $PK \
///     --sig "run(address)" $COUNTER_AND_PROXY
contract CounterExecuteNetwork is Script {
    function run(address counterAndProxyAddr) external {
        vm.startBroadcast();
        CounterAndProxy(counterAndProxyAddr).incrementProxy();
        console.log("done");
        vm.stopBroadcast();
    }
}

/// @title CounterComputeExpected — Compute expected entries for verification
///   forge script script/e2e/counter/CounterE2E.s.sol:CounterComputeExpected \
///     --sig "run(address,address)" $COUNTER_L2 $COUNTER_AND_PROXY
contract CounterComputeExpected is Script {
    function run(address counterL2Addr, address counterAndProxyAddr) external pure {
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

        bytes32 hash = keccak256(abi.encode(callAction));

        // Parseable line for shell scripts
        console.log("EXPECTED_HASHES=[%s]", vm.toString(hash));

        // Human-readable expected table (shown on verify failure)
        console.log("");
        console.log("=== EXPECTED EXECUTION TABLE (1 entry) ===");
        console.log("  [0] DEFERRED  actionHash: %s", vm.toString(hash));
        _logDeltas(stateDeltas);
        console.log("      nextAction: RESULT(rollup 1, ok, data=%s)", vm.toString(resultAction.data));
    }

    function _logDeltas(StateDelta[] memory deltas) internal pure {
        for (uint256 i = 0; i < deltas.length; i++) {
            console.log(
                string.concat(
                    "      stateDelta: rollup ",
                    vm.toString(deltas[i].rollupId),
                    "  ",
                    vm.toString(deltas[i].currentState),
                    " -> ",
                    vm.toString(deltas[i].newState),
                    "  ether: ",
                    vm.toString(deltas[i].etherDelta)
                )
            );
        }
    }
}
