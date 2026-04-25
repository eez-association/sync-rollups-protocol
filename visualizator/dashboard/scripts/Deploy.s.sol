// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups, RollupConfig} from "src/Rollups.sol";
import {CrossChainManagerL2} from "src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "src/ICrossChainManager.sol";
import {IProofSystem} from "src/IProofSystem.sol";
import {Counter, CounterAndProxy} from "test/mocks/CounterContracts.sol";

contract MockZKVerifier is IProofSystem {
    function verify(bytes calldata, bytes32) external pure override returns (bool) {
        return true;
    }
}

// ═══════════════════════════════════════════════════════════════
// Stage 1: Deploy L2 base infrastructure (ManagerL2 + Counter B)
// Run on L2 chain with deployer key
// ═══════════════════════════════════════════════════════════════
contract DeployL2Base is Script {
    function run() external {
        vm.startBroadcast();

        address systemAddress = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
        CrossChainManagerL2 managerL2 = new CrossChainManagerL2(1, systemAddress);
        Counter counterL2 = new Counter(); // B

        vm.stopBroadcast();

        console.log("MANAGER_L2=%s", address(managerL2));
        console.log("COUNTER_L2=%s", address(counterL2));
    }
}

// ═══════════════════════════════════════════════════════════════
// Stage 2: Deploy L1 infrastructure
// Needs COUNTER_L2 env var (from stage 1)
// Run on L1 chain with deployer key
// ═══════════════════════════════════════════════════════════════
contract DeployL1 is Script {
    function run() external {
        address counterL2Addr = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();

        MockZKVerifier verifier = new MockZKVerifier();
        Rollups rollups = new Rollups(1);
        uint256 validatorId = rollups.registerProofSystem(IProofSystem(address(verifier)));

        // Create L2 rollup (rollupId = 1)
        uint256[] memory ids = new uint256[](1);
        ids[0] = validatorId;
        bytes32[] memory vks = new bytes32[](1);
        vks[0] = keccak256("verificationKey");
        rollups.createRollup(keccak256("l2-initial-state"), ids, vks, msg.sender);

        Counter counterL1 = new Counter(); // C

        // B': proxy for B on L1 (uses B's real L2 address)
        address counterProxy = rollups.createCrossChainProxy(counterL2Addr, 1);

        // A: CounterAndProxy on L1, targets B'
        CounterAndProxy counterAndProxy = new CounterAndProxy(Counter(counterProxy));

        vm.stopBroadcast();

        console.log("ROLLUPS=%s", address(rollups));
        console.log("COUNTER_L1=%s", address(counterL1));
        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("COUNTER_AND_PROXY=%s", address(counterAndProxy));
    }
}

// ═══════════════════════════════════════════════════════════════
// Stage 3: Deploy L2 application contracts
// Needs COUNTER_L1 env var (from stage 2)
// Run on L2 chain with deployer key
// ═══════════════════════════════════════════════════════════════
contract DeployL2Apps is Script {
    function run() external {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address managerL2Addr = vm.envAddress("MANAGER_L2");

        CrossChainManagerL2 managerL2 = CrossChainManagerL2(payable(managerL2Addr));

        vm.startBroadcast();

        // C': proxy for C on L2 (uses C's real L1 address)
        address counterProxyL2 = managerL2.createCrossChainProxy(counterL1Addr, 0);

        // D: CounterAndProxy on L2, targets C'
        CounterAndProxy counterAndProxyL2 = new CounterAndProxy(Counter(counterProxyL2));

        vm.stopBroadcast();

        console.log("COUNTER_PROXY_L2=%s", counterProxyL2);
        console.log("COUNTER_AND_PROXY_L2=%s", address(counterAndProxyL2));
    }
}

// ═══════════════════════════════════════════════════════════════
// Stage 4: Scenario 1 — L2 Phase (SYSTEM operations)
// Loads execution table + executes incoming cross-chain call
// Run on L2 chain as SYSTEM (--sender SYSTEM --unlocked)
// Needs: MANAGER_L2, COUNTER_L2, COUNTER_AND_PROXY
// ═══════════════════════════════════════════════════════════════
contract Scenario1_L2 is Script {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address counterAndProxyAddr = vm.envAddress("COUNTER_AND_PROXY");

        CrossChainManagerL2 managerL2 = CrossChainManagerL2(payable(managerL2Addr));
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // The RESULT action that _processCallAtScope will build after B.increment() returns 1
        // This is the EXACT same construction as the integration test
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

        // Load execution table: RESULT hash -> RESULT (terminal, self-referencing)
        {
            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0].stateDeltas = new StateDelta[](0);
            entries[0].actionHash = keccak256(abi.encode(resultAction));
            entries[0].nextAction = resultAction;

            managerL2.loadExecutionTable(entries);
        }

        // Execute incoming cross-chain call (B.increment() on L2)
        // This builds CALL{rollupId=1, dest=B, src=A, srcRollup=0}
        // -> newScope -> _processCallAtScope -> auto-creates A' proxy
        // -> A'.executeOnBehalf(B, increment()) -> B.counter = 1
        // -> Builds RESULT -> matches table entry -> consumed
        managerL2.executeIncomingCrossChainCall(
            counterL2Addr,           // dest = B (Counter on L2)
            0,                       // value
            incrementCallData,       // data = increment()
            counterAndProxyAddr,     // source = A (CounterAndProxy on L1)
            0,                       // sourceRollup = MAINNET (0)
            new uint256[](0)         // scope = [] (root)
        );

        vm.stopBroadcast();

        // Verify
        uint256 bCounter = Counter(counterL2Addr).counter();
        console.log("B.counter=%d (expected 1)", bCounter);
        require(bCounter == 1, "B.counter should be 1");
    }
}

// ═══════════════════════════════════════════════════════════════
// Stage 5: Scenario 1 — L1 Phase (deployer operations)
// Posts batch + Alice calls A.increment()
// Run on L1 chain with deployer key
// Needs: ROLLUPS, COUNTER_L2, COUNTER_AND_PROXY
// ═══════════════════════════════════════════════════════════════
contract Scenario1_L1 is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address counterAndProxyAddr = vm.envAddress("COUNTER_AND_PROXY");

        Rollups rollups = Rollups(payable(rollupsAddr));
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // CALL action: what executeCrossChainCall will build when A calls B'
        // EXACT same construction as integration test
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: 1,                        // B lives on L2 (rollupId=1)
            destination: counterL2Addr,          // B
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: counterAndProxyAddr,  // A (caller of B')
            sourceRollup: 0,                     // A is on MAINNET (0)
            scope: new uint256[](0)
        });

        // RESULT action (same as L2 phase)
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

        bytes32 currentState = keccak256("l2-initial-state");
        bytes32 newState = keccak256("l2-state-after-increment");

        vm.startBroadcast();

        // Post batch: 1 deferred entry (CALL hash -> RESULT) with L2 state delta
        {
            StateDelta[] memory stateDeltas = new StateDelta[](1);
            stateDeltas[0] = StateDelta({
                rollupId: 1,
                currentState: currentState,
                newState: newState,
                etherDelta: 0
            });

            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0].stateDeltas = stateDeltas;
            entries[0].actionHash = keccak256(abi.encode(callAction));
            entries[0].nextAction = resultAction;

            // Validator id 1 (first validator registered in Stage 2)
            rollups.postBatch(1, entries, 0, "", "proof");
        }

        // Alice (= deployer) calls A.increment()
        // -> A calls B' -> executeCrossChainCall -> CALL built -> matches entry -> RESULT returned
        CounterAndProxy(counterAndProxyAddr).increment();

        vm.stopBroadcast();

        // Verify
        uint256 aCounter = CounterAndProxy(counterAndProxyAddr).counter();
        uint256 aTarget = CounterAndProxy(counterAndProxyAddr).targetCounter();
        console.log("A.counter=%d (expected 1)", aCounter);
        console.log("A.targetCounter=%d (expected 1)", aTarget);
        require(aCounter == 1, "A.counter should be 1");
        require(aTarget == 1, "A.targetCounter should be 1");
    }
}
