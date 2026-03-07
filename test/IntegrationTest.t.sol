// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Rollups, RollupConfig} from "../src/Rollups.sol";
import {CrossChainManagerL2} from "../src/CrossChainManagerL2.sol";
import {CrossChainProxy} from "../src/CrossChainProxy.sol";
import {Action, ActionType, ExecutionEntry, StateDelta, ProxyInfo} from "../src/ICrossChainManager.sol";
import {IZKVerifier} from "../src/IZKVerifier.sol";
import {Counter, CounterAndProxy} from "./mocks/CounterContracts.sol";

contract MockZKVerifier is IZKVerifier {
    function verify(bytes calldata, bytes32) external pure override returns (bool) {
        return true;
    }
}

/// @title IntegrationTest
/// @notice End-to-end test of L1 <-> L2 cross-chain call flow using Counter contracts
///
/// Flow overview:
///   L2: SYSTEM loads execution table -> executeIncomingCrossChainCall() -> CP' (proxy for CounterAndProxy)
///        -> Counter.increment() -> RESULT matched against execution table
///
///   L1: Alice -> CounterAndProxy.increment() -> Counter' (CrossChainProxy) -> Rollups.executeCrossChainCall()
///        -> looks up execution table -> returns RESULT(abi.encode(1)) -> CounterAndProxy sets targetCounter=1, counter=1
contract IntegrationTest is Test {
    // ── L1 contracts ──
    Rollups public rollups;
    MockZKVerifier public verifier;

    // ── L2 contracts ──
    CrossChainManagerL2 public managerL2;
    Counter public counterL2; // The actual Counter deployed on L2

    // ── L1 application contracts ──
    CounterAndProxy public counterAndProxy; // Deployed on L1
    address public counterProxy; // CrossChainProxy for Counter on L1 (Counter' on L1)

    // ── Constants ──
    uint256 constant L2_ROLLUP_ID = 1;
    uint256 constant MAINNET_ROLLUP_ID = 0;
    address constant SYSTEM_ADDRESS = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
    bytes32 constant DEFAULT_VK = keccak256("verificationKey");

    address public alice = makeAddr("alice");

    function setUp() public {
        // Deploy L1
        verifier = new MockZKVerifier();
        rollups = new Rollups(address(verifier), 1); // rollupCounter starts at 1

        // Create rollup for L2
        rollups.createRollup(keccak256("l2-initial-state"), DEFAULT_VK, address(this));
        // rollupId = 1 = L2_ROLLUP_ID

        // Deploy L2
        managerL2 = new CrossChainManagerL2(L2_ROLLUP_ID, SYSTEM_ADDRESS);

        // Deploy Counter on L2
        counterL2 = new Counter();

        // On L1: create CrossChainProxy for the L2 Counter (Counter')
        // This proxy represents (counterL2.address, L2_ROLLUP_ID) on L1
        counterProxy = rollups.createCrossChainProxy(address(counterL2), L2_ROLLUP_ID);

        // Deploy CounterAndProxy on L1, pointing at Counter' (the CrossChainProxy)
        counterAndProxy = new CounterAndProxy(counterProxy);
    }

    function _getRollupState(uint256 rollupId) internal view returns (bytes32) {
        (,, bytes32 stateRoot,) = rollups.rollups(rollupId);
        return stateRoot;
    }

    // ═══════════════════════════════════════════════
    //  Test: Full L1 <-> L2 cross-chain call flow
    // ═══════════════════════════════════════════════

    /// @notice Full flow: L2 executes Counter.increment() (0->1), then L1 resolves with RESULT(1).
    ///         Final L2 state: Counter.counter = 1
    ///         Final L1 state: CounterAndProxy.counter = 1, CounterAndProxy.targetCounter = 1
    function test_FullFlow_L2Execution_ThenL1Resolution() public {
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // ════════════════════════════════════════════
        //  Phase 1: L2 — SYSTEM executes Counter.increment() via CP' proxy
        // ════════════════════════════════════════════

        // After executing Counter.increment() (counter goes 0->1, returns 1),
        // _processCallAtScope builds a RESULT action.
        // The proxy (CP') calls executeOnBehalf -> Counter.increment()
        // executeOnBehalf uses raw return, so returnData = abi.encode(1)
        Action memory resultFromExecution = Action({
            actionType: ActionType.RESULT,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(1)),
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        // Load execution table on L2:
        // _processCallAtScope executes the call, builds a RESULT, hashes it, then _consumeExecution(resultHash).
        // So we load the RESULT action hash -> nextAction is the same RESULT (terminal).
        {
            StateDelta[] memory emptyDeltas = new StateDelta[](0);
            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0].stateDeltas = emptyDeltas;
            entries[0].actionHash = keccak256(abi.encode(resultFromExecution));
            entries[0].nextAction = resultFromExecution;

            vm.prank(SYSTEM_ADDRESS);
            managerL2.loadExecutionTable(entries);
        }

        // SYSTEM calls executeIncomingCrossChainCall:
        //   newScope -> _processCallAtScope -> auto-create CP' proxy
        //   -> CP'.executeOnBehalf(counterL2, increment()) -> Counter.increment() returns 1
        //   -> build RESULT -> _consumeExecution(resultHash) -> return RESULT
        vm.prank(SYSTEM_ADDRESS);
        managerL2.executeIncomingCrossChainCall(
            address(counterL2), 0, incrementCallData,
            address(counterAndProxy), MAINNET_ROLLUP_ID, new uint256[](0)
        );

        assertEq(counterL2.counter(), 1, "Counter on L2 should be 1");
        assertEq(managerL2.pendingEntryCount(), 0, "All L2 execution entries consumed");

        // ════════════════════════════════════════════
        //  Phase 2: L1 — Resolution (CounterAndProxy gets RESULT(1))
        // ════════════════════════════════════════════

        // The CALL action that executeCrossChainCall will build when CounterAndProxy calls Counter'
        Action memory l1CallAction = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: address(counterL2),
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: address(counterAndProxy),
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        bytes32 currentState = keccak256("l2-initial-state");
        bytes32 newState = keccak256("l2-state-after-increment");

        StateDelta[] memory stateDeltas = new StateDelta[](1);
        stateDeltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: currentState,
            newState: newState,
            etherDelta: 0
        });

        // Load deferred execution entry via postBatch.
        // nextAction reuses the same RESULT from L2 (same action hash = same outcome).
        ExecutionEntry[] memory l1Entries = new ExecutionEntry[](1);
        l1Entries[0].stateDeltas = stateDeltas;
        l1Entries[0].actionHash = keccak256(abi.encode(l1CallAction));
        l1Entries[0].nextAction = resultFromExecution;

        rollups.postBatch(l1Entries, 0, "", "proof");

        // Alice calls CounterAndProxy.increment() on L1
        vm.prank(alice);
        counterAndProxy.increment();

        // ── Final assertions ──
        assertEq(counterAndProxy.counter(), 1, "CP.counter should be 1");
        assertEq(counterAndProxy.targetCounter(), 1, "CP.targetCounter should be 1");
        assertEq(_getRollupState(L2_ROLLUP_ID), newState, "L2 rollup state should be updated");
        assertEq(counterL2.counter(), 1, "L2 Counter should be 1");
    }
}
