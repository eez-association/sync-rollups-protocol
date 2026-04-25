// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Test.sol";
import {Rollups, RollupConfig} from "../src/Rollups.sol";
import {CrossChainManagerL2} from "../src/CrossChainManagerL2.sol";
import {CrossChainProxy} from "../src/CrossChainProxy.sol";
import {Action, ActionType, ExecutionEntry, StateDelta, ProxyInfo} from "../src/ICrossChainManager.sol";
import {Counter} from "./mocks/CounterContracts.sol";
import {CallTwice, CallTwoDifferent, ConditionalCallTwice} from "./mocks/MultiCallContracts.sol";
import {MockZKVerifier, IntegrationTestBase} from "./helpers/TestBase.sol";

/// @title MultiCallIntegrationTest
/// @notice Tests for issue #256: multiple cross-chain calls in a single execution.
///
/// ┌──────────────────────────────────────────────────────────────────────────────┐
/// │  Legend                                                                      │
/// │    E  = CallTwice on L1        (calls B' twice)                             │
/// │    F  = CallTwoDifferent on L1 (calls B1' and B2')                          │
/// │    G  = ConditionalCallTwice   (calls B1' and B2', may revert)              │
/// │    B  = Counter on L2          (single counter, for CallTwice tests)        │
/// │    B1 = Counter on L2          (first counter, for two-target tests)        │
/// │    B2 = Counter on L2          (second counter, for two-target tests)       │
/// │    B' = CrossChainProxy for B  on L1                                        │
/// │    B1'= CrossChainProxy for B1 on L1                                        │
/// │    B2'= CrossChainProxy for B2 on L1                                        │
/// └──────────────────────────────────────────────────────────────────────────────┘
///
/// ┌────┬───────────────────────────────────────────┬──────────┬──────────────────┐
/// │  # │ Flow                                      │Direction │ What it tests    │
/// ├────┼───────────────────────────────────────────┼──────────┼──────────────────┤
/// │  5 │ Alice -> E (-> B' x2)  -> B               │L1 -> L2 │ Same proxy twice │
/// │  6 │ Alice -> F (-> B1',B2')-> B1,B2           │L1 -> L2 │ Two diff proxies │
/// │  7a│ Alice -> G (-> B1',B2')-> B1,B2 (ok)      │L1 -> L2 │ Conditional pass │
/// │  7b│ Alice -> G (-> B1',B2')-> B1,B2 (revert)  │L1 -> L2 │ Atomicity revert │
/// └────┴───────────────────────────────────────────┴──────────┴──────────────────┘
contract MultiCallIntegrationTest is IntegrationTestBase {
    // ── L2 contracts ──
    CrossChainManagerL2 public managerL2;

    // ── Application contracts ──
    CallTwice public callTwice;                       // E — calls same proxy twice
    CallTwoDifferent public callTwoDifferent;          // F — calls two different proxies
    ConditionalCallTwice public conditionalCallTwice;  // G — calls two proxies, may revert
    Counter public counterL2;                          // B  — single counter for CallTwice
    Counter public counterL2_A;                        // B1 — first counter for two-target tests
    Counter public counterL2_B;                        // B2 — second counter for two-target tests

    // ── Proxies ──
    address public counterProxy;     // B'  — proxy for B, on L1
    address public counterAProxy;    // B1' — proxy for B1, on L1
    address public counterBProxy;    // B2' — proxy for B2, on L1

    address public alice = makeAddr("alice");

    function setUp() public {
        // ── L1 infrastructure ──
        verifier = new MockZKVerifier();
        rollups = new Rollups(1);
        _registerDefaultProofSystem();
        rollups.createRollup(keccak256("l2-initial-state"), address(verifier), DEFAULT_VK, address(this));

        // ── L2 infrastructure ──
        managerL2 = new CrossChainManagerL2(L2_ROLLUP_ID, SYSTEM_ADDRESS);

        // ── Deploy application contracts ──
        counterL2 = new Counter();     // B
        counterL2_A = new Counter();   // B1
        counterL2_B = new Counter();   // B2
        callTwice = new CallTwice();                       // E
        callTwoDifferent = new CallTwoDifferent();          // F
        conditionalCallTwice = new ConditionalCallTwice();  // G

        // ── Deploy proxies on L1 ──
        counterProxy = rollups.createCrossChainProxy(address(counterL2), L2_ROLLUP_ID);     // B'
        counterAProxy = rollups.createCrossChainProxy(address(counterL2_A), L2_ROLLUP_ID);  // B1'
        counterBProxy = rollups.createCrossChainProxy(address(counterL2_B), L2_ROLLUP_ID);  // B2'
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Scenario 5: Alice -> E (-> B' x2) -> B      [L1 -> L2, same proxy twice]
    //
    //  Call chain:
    //    Alice calls E(CallTwice).callCounterTwice(B') on L1
    //    -> E calls B' twice (low-level)
    //    -> Each call: B'.fallback -> Rollups.executeCrossChainCall
    //    -> Two execution entries consumed (same action hash, different state deltas)
    //    -> E receives RESULT(1) and RESULT(2)
    //
    //  Meanwhile on L2:
    //    SYSTEM executes B(Counter).increment() twice via executeIncomingCrossChainCall
    //    -> B.counter goes 0 -> 1 -> 2
    //
    //  Key: Both calls produce the SAME action hash (same source, dest, data).
    //  L1 entries are differentiated by state deltas: S0->S1 for first, S1->S2 for second.
    // ═══════════════════════════════════════════════════════════════════════

    function test_Scenario5_CallTwiceSameProxy() public {
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // ════════════════════════════════════════════
        //  Phase 1: L2 — SYSTEM executes B.increment() twice
        // ════════════════════════════════════════════

        // RESULT for first call: B.counter 0->1, returns 1
        Action memory result1 = Action({
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

        // RESULT for second call: B.counter 1->2, returns 2
        Action memory result2 = Action({
            actionType: ActionType.RESULT,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(2)),
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        // L2 execution table: 2 entries (one per executeIncomingCrossChainCall)
        {
            ExecutionEntry[] memory entries = new ExecutionEntry[](2);
            entries[0].stateDeltas = new StateDelta[](0);
            entries[0].actionHash = keccak256(abi.encode(result1));
            entries[0].nextAction = result1;

            entries[1].stateDeltas = new StateDelta[](0);
            entries[1].actionHash = keccak256(abi.encode(result2));
            entries[1].nextAction = result2;

            vm.prank(SYSTEM_ADDRESS);
            managerL2.loadExecutionTable(entries);
        }

        // First call: B.counter 0 -> 1
        vm.prank(SYSTEM_ADDRESS);
        managerL2.executeIncomingCrossChainCall(
            address(counterL2),
            0,
            incrementCallData,
            address(callTwice),
            MAINNET_ROLLUP_ID,
            new uint256[](0)
        );
        assertEq(counterL2.counter(), 1, "B should be 1 after first L2 call");

        // Second call: B.counter 1 -> 2
        vm.prank(SYSTEM_ADDRESS);
        managerL2.executeIncomingCrossChainCall(
            address(counterL2),
            0,
            incrementCallData,
            address(callTwice),
            MAINNET_ROLLUP_ID,
            new uint256[](0)
        );
        assertEq(counterL2.counter(), 2, "B should be 2 after second L2 call");

        // ════════════════════════════════════════════
        //  Phase 2: L1 — Alice calls E.callCounterTwice(B')
        // ════════════════════════════════════════════
        //
        //  E calls B' twice. Each call triggers executeCrossChainCall with
        //  the SAME action hash. State deltas differentiate them:
        //    Entry 1: currentState=S0 -> consumed by first call
        //    Entry 2: currentState=S1 -> consumed by second call

        // CALL action built by executeCrossChainCall when E calls B'
        // Both calls produce the same action: same source(E), dest(B), data(increment)
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: address(counterL2),
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: address(callTwice),
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-s5-after-first");
        bytes32 s2 = keccak256("l2-state-s5-after-second");

        // postBatch: 2 deferred entries with SAME action hash, DIFFERENT state deltas
        {
            StateDelta[] memory deltas1 = new StateDelta[](1);
            deltas1[0] = StateDelta({ rollupId: L2_ROLLUP_ID, currentState: s0, newState: s1, etherDelta: 0 });

            StateDelta[] memory deltas2 = new StateDelta[](1);
            deltas2[0] = StateDelta({ rollupId: L2_ROLLUP_ID, currentState: s1, newState: s2, etherDelta: 0 });

            ExecutionEntry[] memory entries = new ExecutionEntry[](2);

            // Entry 1: CALL -> RESULT(1), state S0->S1
            entries[0].stateDeltas = deltas1;
            entries[0].actionHash = keccak256(abi.encode(callAction));
            entries[0].nextAction = result1;

            // Entry 2: CALL -> RESULT(2), state S1->S2
            entries[1].stateDeltas = deltas2;
            entries[1].actionHash = keccak256(abi.encode(callAction));
            entries[1].nextAction = result2;

            rollups.postBatch(address(verifier), entries, 0, "", "proof");
        }

        // Alice triggers: E calls B' twice -> two executeCrossChainCall resolutions
        vm.prank(alice);
        (uint256 first, uint256 second) = callTwice.callCounterTwice(counterProxy);

        // ── Final assertions ──
        assertEq(first, 1, "First call should return 1");
        assertEq(second, 2, "Second call should return 2");
        assertEq(_getRollupState(L2_ROLLUP_ID), s2, "L2 state should be S2");
        assertEq(counterL2.counter(), 2, "B should still be 2");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Scenario 6: Alice -> F (-> B1', B2') -> B1, B2  [L1 -> L2, two proxies]
    //
    //  Call chain:
    //    Alice calls F(CallTwoDifferent).callBothCounters(B1', B2') on L1
    //    -> F calls B1' then B2' (low-level)
    //    -> Each call triggers executeCrossChainCall with DIFFERENT action hashes
    //    -> F receives RESULT(1) from each
    //
    //  Meanwhile on L2:
    //    SYSTEM executes B1.increment() and B2.increment()
    //    -> B1.counter 0->1, B2.counter 0->1
    //
    //  Simpler than Scenario 5: different destinations = different action hashes.
    // ═══════════════════════════════════════════════════════════════════════

    function test_Scenario6_CallTwoDifferentProxies() public {
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // ════════════════════════════════════════════
        //  Phase 1: L2 — SYSTEM executes B1.increment() and B2.increment()
        // ════════════════════════════════════════════

        Action memory result1 = Action({
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

        // Both calls return 1 (each counter starts at 0). The RESULT actions are identical.
        {
            ExecutionEntry[] memory entries = new ExecutionEntry[](2);
            entries[0].stateDeltas = new StateDelta[](0);
            entries[0].actionHash = keccak256(abi.encode(result1));
            entries[0].nextAction = result1;

            entries[1].stateDeltas = new StateDelta[](0);
            entries[1].actionHash = keccak256(abi.encode(result1));
            entries[1].nextAction = result1;

            vm.prank(SYSTEM_ADDRESS);
            managerL2.loadExecutionTable(entries);
        }

        // B1.increment()
        vm.prank(SYSTEM_ADDRESS);
        managerL2.executeIncomingCrossChainCall(
            address(counterL2_A), 0, incrementCallData,
            address(callTwoDifferent), MAINNET_ROLLUP_ID, new uint256[](0)
        );
        assertEq(counterL2_A.counter(), 1, "B1 should be 1");

        // B2.increment()
        vm.prank(SYSTEM_ADDRESS);
        managerL2.executeIncomingCrossChainCall(
            address(counterL2_B), 0, incrementCallData,
            address(callTwoDifferent), MAINNET_ROLLUP_ID, new uint256[](0)
        );
        assertEq(counterL2_B.counter(), 1, "B2 should be 1");

        // ════════════════════════════════════════════
        //  Phase 2: L1 — Alice calls F.callBothCounters(B1', B2')
        // ════════════════════════════════════════════

        // CALL to B1: F calls B1' -> executeCrossChainCall
        Action memory callToB1 = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: address(counterL2_A),
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: address(callTwoDifferent),
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        // CALL to B2: F calls B2' -> executeCrossChainCall
        Action memory callToB2 = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: address(counterL2_B),
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: address(callTwoDifferent),
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-s6-after-B1");
        bytes32 s2 = keccak256("l2-state-s6-after-B2");

        // postBatch: 2 entries with different action hashes, sequential state deltas
        {
            StateDelta[] memory deltas1 = new StateDelta[](1);
            deltas1[0] = StateDelta({ rollupId: L2_ROLLUP_ID, currentState: s0, newState: s1, etherDelta: 0 });

            StateDelta[] memory deltas2 = new StateDelta[](1);
            deltas2[0] = StateDelta({ rollupId: L2_ROLLUP_ID, currentState: s1, newState: s2, etherDelta: 0 });

            ExecutionEntry[] memory entries = new ExecutionEntry[](2);

            entries[0].stateDeltas = deltas1;
            entries[0].actionHash = keccak256(abi.encode(callToB1));
            entries[0].nextAction = result1;

            entries[1].stateDeltas = deltas2;
            entries[1].actionHash = keccak256(abi.encode(callToB2));
            entries[1].nextAction = result1;

            rollups.postBatch(address(verifier), entries, 0, "", "proof");
        }

        // Alice triggers: F calls B1' then B2'
        vm.prank(alice);
        (uint256 a, uint256 b) = callTwoDifferent.callBothCounters(counterAProxy, counterBProxy);

        // ── Final assertions ──
        assertEq(a, 1, "Counter A result should be 1");
        assertEq(b, 1, "Counter B result should be 1");
        assertEq(_getRollupState(L2_ROLLUP_ID), s2, "L2 state should be S2");
        assertEq(counterL2_A.counter(), 1, "B1 should still be 1");
        assertEq(counterL2_B.counter(), 1, "B2 should still be 1");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Scenario 7a: Alice -> G (-> B1', B2') -> B1, B2  [conditional, no revert]
    //
    //  Same as Scenario 6 but uses ConditionalCallTwice with threshold=100.
    //  Both counters return 1, which is < 100. No revert.
    // ═══════════════════════════════════════════════════════════════════════

    function test_Scenario7a_ConditionalNoRevert() public {
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // ════════════════════════════════════════════
        //  Phase 1: L2 — SYSTEM executes B1 and B2
        // ════════════════════════════════════════════

        Action memory result1 = Action({
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

        {
            ExecutionEntry[] memory entries = new ExecutionEntry[](2);
            entries[0].stateDeltas = new StateDelta[](0);
            entries[0].actionHash = keccak256(abi.encode(result1));
            entries[0].nextAction = result1;

            entries[1].stateDeltas = new StateDelta[](0);
            entries[1].actionHash = keccak256(abi.encode(result1));
            entries[1].nextAction = result1;

            vm.prank(SYSTEM_ADDRESS);
            managerL2.loadExecutionTable(entries);
        }

        vm.prank(SYSTEM_ADDRESS);
        managerL2.executeIncomingCrossChainCall(
            address(counterL2_A), 0, incrementCallData,
            address(conditionalCallTwice), MAINNET_ROLLUP_ID, new uint256[](0)
        );

        vm.prank(SYSTEM_ADDRESS);
        managerL2.executeIncomingCrossChainCall(
            address(counterL2_B), 0, incrementCallData,
            address(conditionalCallTwice), MAINNET_ROLLUP_ID, new uint256[](0)
        );

        assertEq(counterL2_A.counter(), 1, "B1 should be 1");
        assertEq(counterL2_B.counter(), 1, "B2 should be 1");

        // ════════════════════════════════════════════
        //  Phase 2: L1 — Alice calls G with threshold=100 (no revert)
        // ════════════════════════════════════════════

        Action memory callToB1 = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: address(counterL2_A),
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: address(conditionalCallTwice),
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        Action memory callToB2 = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: address(counterL2_B),
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: address(conditionalCallTwice),
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-s7a-after-B1");
        bytes32 s2 = keccak256("l2-state-s7a-after-B2");

        {
            StateDelta[] memory deltas1 = new StateDelta[](1);
            deltas1[0] = StateDelta({ rollupId: L2_ROLLUP_ID, currentState: s0, newState: s1, etherDelta: 0 });

            StateDelta[] memory deltas2 = new StateDelta[](1);
            deltas2[0] = StateDelta({ rollupId: L2_ROLLUP_ID, currentState: s1, newState: s2, etherDelta: 0 });

            ExecutionEntry[] memory entries = new ExecutionEntry[](2);

            entries[0].stateDeltas = deltas1;
            entries[0].actionHash = keccak256(abi.encode(callToB1));
            entries[0].nextAction = result1;

            entries[1].stateDeltas = deltas2;
            entries[1].actionHash = keccak256(abi.encode(callToB2));
            entries[1].nextAction = result1;

            rollups.postBatch(address(verifier), entries, 0, "", "proof");
        }

        // threshold=100: counter B returns 1, which is < 100 -> no revert
        vm.prank(alice);
        (uint256 a, uint256 b) = conditionalCallTwice.callBothConditional(counterAProxy, counterBProxy, 100);

        // ── Final assertions ──
        assertEq(a, 1, "Counter A result should be 1");
        assertEq(b, 1, "Counter B result should be 1");
        assertEq(_getRollupState(L2_ROLLUP_ID), s2, "L2 state should be S2");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Scenario 7b: Alice -> G (-> B1', B2') -> REVERT  [conditional revert]
    //
    //  ConditionalCallTwice with threshold=1. Counter B returns 1 (>= 1),
    //  triggering require(b < 1) -> revert.
    //
    //  Tests L1 atomicity: the revert rolls back both state delta applications
    //  and both execution entry consumptions. After revert:
    //    - L2 state root unchanged (deltas not applied)
    //    - Execution entries still in table (not consumed)
    //
    //  NOTE: This tests L1 tx atomicity only. In the real system, the builder
    //  would detect the revert during simulation and not submit the batch,
    //  so L2 execution would never happen either.
    // ═══════════════════════════════════════════════════════════════════════

    function test_Scenario7b_ConditionalRevert() public {
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // No Phase 1 (L2): we only test the L1 revert behavior.
        // In the real system, the builder wouldn't submit a batch for a reverting tx.

        Action memory result1 = Action({
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

        Action memory callToB1 = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: address(counterL2_A),
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: address(conditionalCallTwice),
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        Action memory callToB2 = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: address(counterL2_B),
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: address(conditionalCallTwice),
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-s7b-after-B1");
        bytes32 s2 = keccak256("l2-state-s7b-after-B2");

        {
            StateDelta[] memory deltas1 = new StateDelta[](1);
            deltas1[0] = StateDelta({ rollupId: L2_ROLLUP_ID, currentState: s0, newState: s1, etherDelta: 0 });

            StateDelta[] memory deltas2 = new StateDelta[](1);
            deltas2[0] = StateDelta({ rollupId: L2_ROLLUP_ID, currentState: s1, newState: s2, etherDelta: 0 });

            ExecutionEntry[] memory entries = new ExecutionEntry[](2);

            entries[0].stateDeltas = deltas1;
            entries[0].actionHash = keccak256(abi.encode(callToB1));
            entries[0].nextAction = result1;

            entries[1].stateDeltas = deltas2;
            entries[1].actionHash = keccak256(abi.encode(callToB2));
            entries[1].nextAction = result1;

            rollups.postBatch(address(verifier), entries, 0, "", "proof");
        }

        bytes32 stateBefore = _getRollupState(L2_ROLLUP_ID);

        // threshold=1: counter B returns 1, which is >= 1 -> REVERT
        vm.prank(alice);
        vm.expectRevert("conditional revert: counterB >= threshold");
        conditionalCallTwice.callBothConditional(counterAProxy, counterBProxy, 1);

        // ── Verify atomicity: state rolled back ──
        assertEq(_getRollupState(L2_ROLLUP_ID), stateBefore, "L2 state should be unchanged after revert");
    }
}
