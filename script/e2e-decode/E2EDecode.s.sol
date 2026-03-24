// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../src/Rollups.sol";
import {CrossChainProxy} from "../../src/CrossChainProxy.sol";
import {Action, ActionType, ExecutionEntry, StaticCall, StateDelta} from "../../src/ICrossChainManager.sol";
import {IZKVerifier} from "../../src/IZKVerifier.sol";
import {Counter, CounterAndProxy} from "../../test/mocks/CounterContracts.sol";

contract MockZKVerifier is IZKVerifier {
    function verify(
        bytes calldata,
        bytes32
    ) external pure override returns (bool) {
        return true;
    }
}

/// @notice Helper that executes postBatch + incrementProxy in a single transaction
/// @dev Needed because executeCrossChainCall requires same block as postBatch
contract Batcher {
    function execute(
        Rollups rollups,
        ExecutionEntry[] calldata entries,
        CounterAndProxy cap
    ) external {
        rollups.postBatch(entries, new StaticCall[](0), 0, "", "proof");
        cap.incrementProxy();
    }
}

/// @title E2EDeploy — Deploy infra + app contracts
contract E2EDeploy is Script {
    function run() external {
        vm.startBroadcast();

        MockZKVerifier verifier = new MockZKVerifier();
        Rollups rollups = new Rollups(address(verifier), 1);
        rollups.createRollup(keccak256("l2-initial-state"), keccak256("verificationKey"), msg.sender);

        Counter counterL2 = new Counter();
        address counterProxy = rollups.createCrossChainProxy(address(counterL2), 1);
        CounterAndProxy counterAndProxy = new CounterAndProxy(Counter(counterProxy));

        console.log("ROLLUPS=%s", address(rollups));
        console.log("COUNTER_L2=%s", address(counterL2));
        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("COUNTER_AND_PROXY=%s", address(counterAndProxy));

        vm.stopBroadcast();
    }
}

/// @title E2EExecute — postBatch + incrementProxy via Batcher (single tx)
contract E2EExecute is Script {
    function run(
        address rollupsAddr,
        address counterL2Addr,
        address counterAndProxyAddr
    ) external {
        vm.startBroadcast();

        // Deploy the batcher helper
        Batcher batcher = new Batcher();

        Rollups rollups = Rollups(rollupsAddr);
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

        // Single tx: postBatch + incrementProxy
        batcher.execute(rollups, entries, CounterAndProxy(counterAndProxyAddr));

        console.log("done");
        console.log("counter=%s", CounterAndProxy(counterAndProxyAddr).counter());
        console.log("targetCounter=%s", CounterAndProxy(counterAndProxyAddr).targetCounter());

        vm.stopBroadcast();
    }
}
