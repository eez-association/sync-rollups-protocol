// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Rollups, RollupConfig} from "../src/Rollups.sol";
import {CrossChainManagerL2} from "../src/CrossChainManagerL2.sol";
import {CrossChainProxy} from "../src/CrossChainProxy.sol";
import {Action, ActionType, ExecutionEntry, StateDelta, ProxyInfo} from "../src/ICrossChainManager.sol";
import {IZKVerifier} from "../src/IZKVerifier.sol";
import {Counter, CounterAndProxy} from "./mocks/CounterContracts.sol";
import {RLPTxEncoder} from "./helpers/RLPTxEncoder.sol";

contract MockZKVerifier is IZKVerifier {
    function verify(bytes calldata, bytes32) external pure override returns (bool) {
        return true;
    }
}

/// @title IntegrationTest
/// @notice End-to-end tests of L1 <-> L2 cross-chain call flows using Counter contracts
///
/// ┌──────────────────────────────────────────────────────────────────────────┐
/// │  Legend                                                                  │
/// │    A  = CounterAndProxy on L1   (calls a proxy, updates local counter)  │
/// │    B  = Counter on L2           (simple increment, returns new value)   │
/// │    C  = Counter on L1           (simple increment, returns new value)   │
/// │    D  = CounterAndProxy on L2   (calls a proxy, updates local counter)  │
/// │    X' = CrossChainProxy for X   (deployed on the OTHER chain)           │
/// └──────────────────────────────────────────────────────────────────────────┘
///
/// ┌────┬──────────────────────────────────┬──────────────┬──────────────────┐
/// │  # │ Flow                             │ Direction    │ Type             │
/// ├────┼──────────────────────────────────┼──────────────┼──────────────────┤
/// │  1 │ Alice -> A  (-> B') -> B         │ L1 -> L2     │ Simple           │
/// │  2 │ Alice -> D  (-> C') -> C         │ L2 -> L1     │ Simple (reverse) │
/// │  3 │ Alice -> A' (-> A  -> B') -> B   │ L2 -> L1 ->L2│ Nested scope     │
/// │  4 │ Alice -> D' (-> D  -> C') -> C   │ L1 -> L2 ->L1│ Nested scope     │
/// └────┴──────────────────────────────────┴──────────────┴──────────────────┘
contract IntegrationTest is Test {
    // ── L1 contracts ──
    Rollups public rollups;
    MockZKVerifier public verifier;

    // ── L2 contracts ──
    CrossChainManagerL2 public managerL2;

    // ── Application contracts (see legend) ──
    CounterAndProxy public counterAndProxy; // A  — CounterAndProxy on L1, target = B'
    Counter public counterL2;               // B  — Counter on L2
    Counter public counterL1;               // C  — Counter on L1
    CounterAndProxy public counterAndProxyL2; // D — CounterAndProxy on L2, target = C'

    // ── Proxies (see legend) ──
    address public counterProxy;              // B' — proxy for B, deployed on L1
    address public counterProxyL2;            // C' — proxy for C, deployed on L2
    address public counterAndProxyProxyL2;    // A' — proxy for A, deployed on L2
    address public counterAndProxyL2ProxyL1;  // D' — proxy for D, deployed on L1

    // ── Constants ──
    uint256 constant L2_ROLLUP_ID = 1;
    uint256 constant MAINNET_ROLLUP_ID = 0;
    address constant SYSTEM_ADDRESS = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
    bytes32 constant DEFAULT_VK = keccak256("verificationKey");
    uint256 constant TX_SIGNER_PK = 0xA11CE;

    address public alice = makeAddr("alice");

    function setUp() public {
        // ── L1 infrastructure ──
        verifier = new MockZKVerifier();
        rollups = new Rollups(address(verifier), 1);

        // Create L2 rollup (rollupId = 1 = L2_ROLLUP_ID)
        rollups.createRollup(keccak256("l2-initial-state"), DEFAULT_VK, address(this));

        // ── L2 infrastructure ──
        managerL2 = new CrossChainManagerL2(L2_ROLLUP_ID, SYSTEM_ADDRESS);

        // ── Deploy application contracts ──
        counterL2 = new Counter();   // B
        counterL1 = new Counter();   // C

        // ── Deploy proxies ──
        // B': proxy for B(Counter on L2), lives on L1 — so A can call B cross-chain
        counterProxy = rollups.createCrossChainProxy(address(counterL2), L2_ROLLUP_ID);

        // A: CounterAndProxy on L1, its target = B'
        counterAndProxy = new CounterAndProxy(Counter(counterProxy));

        // C': proxy for C(Counter on L1), lives on L2 — so D can call C cross-chain
        counterProxyL2 = managerL2.createCrossChainProxy(address(counterL1), MAINNET_ROLLUP_ID);

        // D: CounterAndProxy on L2, its target = C'
        counterAndProxyL2 = new CounterAndProxy(Counter(counterProxyL2));

        // A': proxy for A(CounterAndProxy on L1), lives on L2 — for Scenario 3
        counterAndProxyProxyL2 = managerL2.createCrossChainProxy(address(counterAndProxy), MAINNET_ROLLUP_ID);

        // D': proxy for D(CounterAndProxy on L2), lives on L1 — for Scenarios 2 & 4
        counterAndProxyL2ProxyL1 = rollups.createCrossChainProxy(address(counterAndProxyL2), L2_ROLLUP_ID);
    }

    function _getRollupState(uint256 rollupId) internal view returns (bytes32) {
        (,, bytes32 stateRoot,) = rollups.rollups(rollupId);
        return stateRoot;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Scenario 1: Alice -> A (-> B') -> B          [L1 -> L2, simple]
    //
    //  Call chain:
    //    Alice calls A(CounterAndProxy) on L1
    //    -> A calls B'(proxy for B) on L1
    //    -> B' triggers Rollups.executeCrossChainCall
    //    -> execution table returns RESULT(1)
    //    -> A receives result, sets targetCounter=1, counter=1
    //
    //  Meanwhile on L2:
    //    SYSTEM executes B(Counter).increment() via executeIncomingCrossChainCall
    //    -> B.counter goes 0 -> 1
    // ═══════════════════════════════════════════════════════════════════════

    function test_Scenario1_L1CallsL2() public {
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // ════════════════════════════════════════════
        //  Phase 1: L2 — SYSTEM executes B(Counter).increment()
        // ════════════════════════════════════════════
        //
        //  The SYSTEM pre-loads the execution table with the expected RESULT,
        //  then calls executeIncomingCrossChainCall which:
        //    1. Builds CALL action (rollupId=L2, dest=B, source=A, sourceRollup=MAINNET)
        //    2. newScope -> _processCallAtScope -> auto-creates A' proxy on L2
        //    3. A'.executeOnBehalf(B, increment) -> B.increment() returns 1
        //    4. Builds RESULT{data=abi.encode(1)} -> hash matches table entry -> consumed

        // RESULT that _processCallAtScope will build after B.increment() returns 1
        Action memory resultAction = Action({
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

        // L2 execution table: RESULT hash -> same RESULT (terminal, self-referencing)
        {
            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0].stateDeltas = new StateDelta[](0);
            entries[0].actionHash = keccak256(abi.encode(resultAction));
            entries[0].nextAction = resultAction;

            vm.prank(SYSTEM_ADDRESS);
            managerL2.loadExecutionTable(entries);
        }

        // SYSTEM triggers the actual execution on L2
        vm.prank(SYSTEM_ADDRESS);
        managerL2.executeIncomingCrossChainCall(
            address(counterL2),        // dest = B (Counter on L2)
            0,                         // value
            incrementCallData,         // data = increment()
            address(counterAndProxy),  // source = A (CounterAndProxy on L1)
            MAINNET_ROLLUP_ID,         // sourceRollup = MAINNET
            new uint256[](0)           // scope = [] (root)
        );

        assertEq(counterL2.counter(), 1, "B(Counter on L2) should be 1");

        // ════════════════════════════════════════════
        //  Phase 2: L1 — Alice calls A, resolves from execution table
        // ════════════════════════════════════════════
        //
        //  postBatch loads a deferred entry on L1. When Alice calls A.increment():
        //    1. A calls B'(proxy for B)
        //    2. B'.fallback -> Rollups.executeCrossChainCall(A, increment)
        //    3. Rollups builds CALL{rollupId=L2, dest=B, source=A, sourceRollup=MAINNET}
        //    4. _findAndApplyExecution matches entry -> applies L2 state delta -> returns RESULT
        //    5. A receives RESULT(1) -> targetCounter=1, counter=1

        // The CALL action that executeCrossChainCall will build when A calls B'
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: address(counterL2),        // B
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: address(counterAndProxy), // A
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        bytes32 currentState = keccak256("l2-initial-state");
        bytes32 newState = keccak256("l2-state-after-scenario1");

        // L1 deferred entry: CALL hash -> RESULT, with L2 state transition
        {
            StateDelta[] memory stateDeltas = new StateDelta[](1);
            stateDeltas[0] = StateDelta({
                rollupId: L2_ROLLUP_ID,
                currentState: currentState,
                newState: newState,
                etherDelta: 0
            });

            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0].stateDeltas = stateDeltas;
            entries[0].actionHash = keccak256(abi.encode(callAction));
            entries[0].nextAction = resultAction;

            rollups.postBatch(entries, 0, "", "proof");
        }

        // Alice triggers the resolution
        vm.prank(alice);
        counterAndProxy.incrementProxy();

        // ── Final assertions ──
        assertEq(counterAndProxy.counter(), 1, "A.counter should be 1");
        assertEq(counterAndProxy.targetCounter(), 1, "A.targetCounter should be 1");
        assertEq(_getRollupState(L2_ROLLUP_ID), newState, "L2 rollup state should be updated");
        assertEq(counterL2.counter(), 1, "B(Counter on L2) should still be 1");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Scenario 2: Alice -> D (-> C') -> C          [L2 -> L1, simple]
    //
    //  Call chain (reverse of Scenario 1):
    //    Alice calls D(CounterAndProxy) on L2
    //    -> D calls C'(proxy for C) on L2
    //    -> C' triggers managerL2.executeCrossChainCall
    //    -> execution table returns RESULT(1)
    //    -> D receives result, sets targetCounter=1, counter=1
    //
    //  Meanwhile on L1:
    //    executeL2TX triggers scope navigation
    //    -> D'(proxy for D on L1).executeOnBehalf(C, increment)
    //    -> C(Counter on L1).increment() -> counter goes 0 -> 1
    //
    //  NOTE: Rollups.sol has no executeIncomingCrossChainCall (unlike L2).
    //  We use executeL2TX as the L1 trigger mechanism instead.
    // ═══════════════════════════════════════════════════════════════════════

    function test_Scenario2_L2CallsL1() public {
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // ════════════════════════════════════════════
        //  Phase 1: L1 — Execute C(Counter) via executeL2TX
        // ════════════════════════════════════════════
        //
        //  Since Rollups has no executeIncomingCrossChainCall, we use executeL2TX:
        //    1. postBatch stores 2 deferred entries:
        //       - L2TX hash -> CALL{dest=C, source=D, sourceRollup=L2}
        //       - RESULT hash -> RESULT (terminal)
        //    2. executeL2TX(L2_ROLLUP_ID, rlpData) builds L2TX action, matches entry 1
        //    3. _resolveScopes(CALL) -> newScope -> _processCallAtScope
        //    4. Creates/finds D'(proxy for D) on L1
        //    5. D'.executeOnBehalf(C, increment) -> C.increment() returns 1
        //    6. Builds RESULT -> matches entry 2 -> terminal

        // Real signed L2 tx: Alice calls D(CounterAndProxy).incrementProxy() on L2
        bytes memory rlpEncodedTx = RLPTxEncoder.signedCallTx(
            address(counterAndProxyL2),
            abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            0, // alice's nonce on L2
            TX_SIGNER_PK
        );

        // L2TX action that executeL2TX will reconstruct
        Action memory l2txAction = Action({
            actionType: ActionType.L2TX,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: rlpEncodedTx,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        // CALL action: represents "D calling C through C'"
        // Same action that L2's executeCrossChainCall will build in Phase 2
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: MAINNET_ROLLUP_ID,          // C lives on MAINNET
            destination: address(counterL1),       // C
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: address(counterAndProxyL2), // D (who called C')
            sourceRollup: L2_ROLLUP_ID,                // D lives on L2
            scope: new uint256[](0)
        });

        // RESULT: what C.increment() produces (counter 0->1, returns 1)
        Action memory resultAction = Action({
            actionType: ActionType.RESULT,
            rollupId: MAINNET_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(1)),
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        bytes32 currentState = keccak256("l2-initial-state");
        bytes32 stateBeforeCall = keccak256("l2-state-before-call");
        bytes32 newState = keccak256("l2-state-after-scenario2");

        // postBatch: 2 deferred entries on L1
        {
            StateDelta[] memory deltas1 = new StateDelta[](1);
            deltas1[0] = StateDelta({
                rollupId: L2_ROLLUP_ID,
                currentState: currentState,
                newState: stateBeforeCall,
                etherDelta: 0
            });

            ExecutionEntry[] memory entries = new ExecutionEntry[](2);

            // Entry 1: L2TX hash -> CALL (triggers scope navigation to call C)
            entries[0].stateDeltas = deltas1;
            entries[0].actionHash = keccak256(abi.encode(l2txAction));
            entries[0].nextAction = callAction;

            // Entry 2: RESULT hash -> RESULT (terminal, consumed after C.increment())
            StateDelta[] memory deltas2 = new StateDelta[](1);
            deltas2[0] = StateDelta({
                rollupId: L2_ROLLUP_ID,
                currentState: stateBeforeCall,
                newState: newState,
                etherDelta: 0
            });

            entries[1].stateDeltas = deltas2;
            entries[1].actionHash = keccak256(abi.encode(resultAction));
            entries[1].nextAction = resultAction;

            rollups.postBatch(entries, 0, "", "proof");
        }

        // Trigger: executeL2TX -> L2TX matched -> CALL -> scope nav -> C.increment()
        rollups.executeL2TX(L2_ROLLUP_ID, rlpEncodedTx);

        assertEq(counterL1.counter(), 1, "C(Counter on L1) should be 1 after executeL2TX");
        assertEq(_getRollupState(L2_ROLLUP_ID), newState, "L2 state should be updated");

        // ════════════════════════════════════════════
        //  Phase 2: L2 — Alice calls D, resolves from execution table
        // ════════════════════════════════════════════
        //
        //    1. Load L2 table: CALL hash -> RESULT
        //    2. Alice calls D.increment()
        //    3. D calls C'(proxy for C) on L2
        //    4. C'.fallback -> managerL2.executeCrossChainCall(D, increment)
        //    5. Manager builds same CALL action -> hash matches -> returns RESULT(1)
        //    6. D receives RESULT -> targetCounter=1, counter=1

        // L2 execution table: CALL hash -> RESULT (same actions as Phase 1)
        {
            ExecutionEntry[] memory l2Entries = new ExecutionEntry[](1);
            l2Entries[0].stateDeltas = new StateDelta[](0);
            l2Entries[0].actionHash = keccak256(abi.encode(callAction));
            l2Entries[0].nextAction = resultAction;

            vm.prank(SYSTEM_ADDRESS);
            managerL2.loadExecutionTable(l2Entries);
        }

        // Alice triggers the resolution on L2
        vm.prank(alice);
        counterAndProxyL2.incrementProxy();

        // ── Final assertions ──
        assertEq(counterAndProxyL2.counter(), 1, "D.counter should be 1");
        assertEq(counterAndProxyL2.targetCounter(), 1, "D.targetCounter should be 1");
        assertEq(counterL1.counter(), 1, "C(Counter on L1) should still be 1");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Scenario 3: Alice -> A' (-> A -> B') -> B    [L2 -> L1 -> L2, nested]
    //
    //  Full cross-chain flow with execution on BOTH chains:
    //
    //  Phase 1 — L1 execution via executeL2TX:
    //    executeL2TX(rlpAliceTx) -> L2TX matched -> CALL to A
    //    -> _resolveScopes -> _processCallAtScope:
    //       - auto-creates proxy for Alice on L1
    //       - proxy.executeOnBehalf(A, increment) -> A.increment() runs on L1
    //       - inside A: calls B'(proxy for B) -> executeCrossChainCall (REENTRANT)
    //         -> CALL to B matched -> RESULT(1) returned -> A gets targetCounter=1
    //       - A returns (void) -> RESULT(void) matched -> terminal
    //
    //  Phase 2 — L2 execution via scope navigation:
    //    Alice calls A'(proxy for A) on L2
    //    -> executeCrossChainCall -> CALL#1 to A matched -> CALL#2 to B (nested)
    //    -> _resolveScopes -> newScope([0]) -> _processCallAtScope:
    //       - A'(proxy for A) calls executeOnBehalf(B, increment)
    //       - B.increment() runs on L2 -> counter 0->1
    //       - RESULT matched -> terminal
    //
    //  Key: A' is reentrant in Phase 2 (fallback then executeOnBehalf).
    //  Safe because CrossChainProxy has no mutable state.
    // ═══════════════════════════════════════════════════════════════════════

    function test_Scenario3_NestedL2Entry() public {
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);
        bytes memory incrementProxyCallData = abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);

        // ════════════════════════════════════════════
        //  Phase 1: L1 — executeL2TX triggers A(CounterAndProxy) on L1
        // ════════════════════════════════════════════
        //
        //  A.increment() runs on L1, internally calls B' -> reentrant executeCrossChainCall.
        //  Needs 3 entries in postBatch:
        //    Entry 1: L2TX -> CALL to A        (consumed by executeL2TX)
        //    Entry 2: CALL to B -> RESULT(1)   (consumed inside reentrant executeCrossChainCall)
        //    Entry 3: RESULT(void) -> terminal  (consumed after A returns)

        // Real signed L2 tx: Alice calls A'(proxy for CounterAndProxy).incrementProxy() on L2
        bytes memory rlpAliceTx = RLPTxEncoder.signedCallTx(
            counterAndProxyProxyL2,
            incrementProxyCallData,
            0, // alice's nonce on L2
            TX_SIGNER_PK
        );

        // L2TX action that executeL2TX will reconstruct
        Action memory l2txAction = Action({
            actionType: ActionType.L2TX,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: rlpAliceTx,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        // CALL to A: the outer call that _processCallAtScope will execute
        // source=Alice on L2 (her L2 tx triggered this)
        Action memory callToA = Action({
            actionType: ActionType.CALL,
            rollupId: MAINNET_ROLLUP_ID,               // A lives on MAINNET
            destination: address(counterAndProxy),      // A
            value: 0,
            data: incrementProxyCallData,
            failed: false,
            sourceAddress: alice,                       // Alice initiated
            sourceRollup: L2_ROLLUP_ID,                 // from L2
            scope: new uint256[](0)
        });

        // CALL to B: what A calling B' produces inside executeCrossChainCall (reentrant)
        // B' proxy has: originalAddress=counterL2, originalRollupId=L2_ROLLUP_ID
        // executeCrossChainCall builds: rollupId=L2, dest=B, source=A, sourceRollup=MAINNET
        Action memory callToB = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,                    // B lives on L2
            destination: address(counterL2),            // B
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: address(counterAndProxy),    // A (called B')
            sourceRollup: MAINNET_ROLLUP_ID,            // A is on MAINNET
            scope: new uint256[](0)
        });

        // RESULT from B.increment() returning 1
        Action memory resultFromB = Action({
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

        // RESULT from A.increment() — void return, so data is empty
        // rollupId = callToA.rollupId = MAINNET_ROLLUP_ID
        Action memory resultFromA = Action({
            actionType: ActionType.RESULT,
            rollupId: MAINNET_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-s3-step1");
        bytes32 s2 = keccak256("l2-state-s3-step2");
        bytes32 s3 = keccak256("l2-state-s3-step3");

        // postBatch: 3 deferred entries on L1 (consumed sequentially)
        {
            // Entry 1 state delta: L2 state S0 -> S1 (Alice's tx changes L2)
            StateDelta[] memory deltas1 = new StateDelta[](1);
            deltas1[0] = StateDelta({ rollupId: L2_ROLLUP_ID, currentState: s0, newState: s1, etherDelta: 0 });

            // Entry 2 state delta: L2 state S1 -> S2 (B.increment changes L2)
            StateDelta[] memory deltas2 = new StateDelta[](1);
            deltas2[0] = StateDelta({ rollupId: L2_ROLLUP_ID, currentState: s1, newState: s2, etherDelta: 0 });

            ExecutionEntry[] memory entries = new ExecutionEntry[](3);

            // Entry 1: L2TX -> CALL to A (consumed by executeL2TX)
            entries[0].stateDeltas = deltas1;
            entries[0].actionHash = keccak256(abi.encode(l2txAction));
            entries[0].nextAction = callToA;

            // Entry 2: CALL to B -> RESULT(1) (consumed inside reentrant executeCrossChainCall)
            entries[1].stateDeltas = deltas2;
            entries[1].actionHash = keccak256(abi.encode(callToB));
            entries[1].nextAction = resultFromB;

            // Entry 3 state delta: L2 state S2 -> S3 (A.increment() completing changes L2)
            StateDelta[] memory deltas3 = new StateDelta[](1);
            deltas3[0] = StateDelta({ rollupId: L2_ROLLUP_ID, currentState: s2, newState: s3, etherDelta: 0 });

            // Entry 3: RESULT(void from A) -> terminal (consumed after A.increment() returns)
            entries[2].stateDeltas = deltas3;
            entries[2].actionHash = keccak256(abi.encode(resultFromA));
            entries[2].nextAction = resultFromA;

            rollups.postBatch(entries, 0, "", "proof");
        }

        // Trigger: executeL2TX -> L2TX -> CALL to A -> A runs -> A calls B' ->
        //          reentrant executeCrossChainCall -> CALL to B resolved -> RESULT(1) ->
        //          A gets targetCounter=1, counter=1 -> RESULT(void) -> terminal
        rollups.executeL2TX(L2_ROLLUP_ID, rlpAliceTx);

        assertEq(counterAndProxy.counter(), 1, "A.counter should be 1 after L1 execution");
        assertEq(counterAndProxy.targetCounter(), 1, "A.targetCounter should be 1");
        assertEq(_getRollupState(L2_ROLLUP_ID), s3, "L2 state should be S3");

        // ════════════════════════════════════════════
        //  Phase 2: L2 — Alice calls A', scope navigation executes B on L2
        // ════════════════════════════════════════════
        //
        //  L2 execution table has 2 entries for scope navigation:
        //    Entry 1: CALL#1 (outer, to A) -> CALL#2 (inner, to B at scope=[0])
        //    Entry 2: RESULT (from B) -> RESULT (terminal)
        //
        //  Flow: Alice -> A'.fallback -> executeCrossChainCall -> CALL#1 consumed -> CALL#2
        //        -> _resolveScopes -> newScope([0]) -> _processCallAtScope
        //        -> A'.executeOnBehalf(B, increment) -> B.increment() on L2 -> 1
        //        -> RESULT consumed -> terminal

        // CALL#1: outer call built by executeCrossChainCall when Alice calls A'
        Action memory l2Call1 = Action({
            actionType: ActionType.CALL,
            rollupId: MAINNET_ROLLUP_ID,
            destination: address(counterAndProxy),     // A
            value: 0,
            data: incrementProxyCallData,
            failed: false,
            sourceAddress: alice,
            sourceRollup: L2_ROLLUP_ID,
            scope: new uint256[](0)
        });

        // CALL#2: inner call at scope=[0] — A calling B' -> B
        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;

        Action memory l2Call2 = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: address(counterL2),            // B
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: address(counterAndProxy),    // A
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: scope0
        });

        // RESULT from B.increment() — reused from Phase 1 (same action)
        {
            StateDelta[] memory emptyDeltas = new StateDelta[](0);
            ExecutionEntry[] memory l2Entries = new ExecutionEntry[](2);

            l2Entries[0].stateDeltas = emptyDeltas;
            l2Entries[0].actionHash = keccak256(abi.encode(l2Call1));
            l2Entries[0].nextAction = l2Call2;

            l2Entries[1].stateDeltas = emptyDeltas;
            l2Entries[1].actionHash = keccak256(abi.encode(resultFromB));
            l2Entries[1].nextAction = resultFromB;

            vm.prank(SYSTEM_ADDRESS);
            managerL2.loadExecutionTable(l2Entries);
        }

        // Alice calls A' on L2 (low-level call — A' is a proxy, no incrementProxy())
        vm.prank(alice);
        (bool success,) = counterAndProxyProxyL2.call(incrementProxyCallData);
        assertTrue(success, "A' call should succeed");

        // ── Final assertions ──
        assertEq(counterAndProxy.counter(), 1, "A.counter should still be 1");
        assertEq(counterAndProxy.targetCounter(), 1, "A.targetCounter should still be 1");
        assertEq(counterL2.counter(), 1, "B(Counter on L2) should be 1 (executed via L2 scope nav)");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Scenario 4: Alice -> D' (-> D -> C') -> C    [L1 -> L2 -> L1, nested]
    //
    //  Full cross-chain flow with execution on BOTH chains:
    //
    //  Phase 1 — L1 execution via scope navigation:
    //    Alice calls D'(proxy for D) on L1
    //    -> executeCrossChainCall -> CALL#1 to D matched -> CALL#2 to C (nested)
    //    -> _resolveScopes -> newScope([0]) -> _processCallAtScope:
    //       - D'(proxy for D) calls executeOnBehalf(C, increment)
    //       - C.increment() runs on L1 -> counter 0->1
    //       - RESULT matched -> terminal
    //
    //  Phase 2 — L2 execution via executeIncomingCrossChainCall:
    //    SYSTEM calls executeIncomingCrossChainCall(dest=D, source=Alice)
    //    -> newScope -> _processCallAtScope:
    //       - auto-creates proxy for Alice on L2
    //       - proxy.executeOnBehalf(D, incrementProxy) -> D.incrementProxy() runs on L2
    //       - inside D: calls C'(proxy for C) -> executeCrossChainCall (REENTRANT)
    //         -> CALL to C matched -> RESULT(1) returned -> D gets targetCounter=1
    //       - D returns (void) -> RESULT(void) matched -> terminal
    //
    //  Key: D' is reentrant in Phase 1 (fallback then executeOnBehalf).
    //  Safe because CrossChainProxy has no mutable state.
    // ═══════════════════════════════════════════════════════════════════════

    function test_Scenario4_NestedL1Entry() public {
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);
        bytes memory incrementProxyCallData = abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);

        // ════════════════════════════════════════════
        //  Phase 1: L1 — Alice calls D', scope navigation executes C on L1
        // ════════════════════════════════════════════
        //
        //  postBatch loads 2 deferred entries. When Alice calls D'(proxy for D):
        //    1. D'.fallback -> Rollups.executeCrossChainCall(Alice, incrementProxy)
        //    2. Rollups builds CALL#1{rollupId=L2, dest=D, data=incrementProxy, source=Alice}
        //    3. CALL#1 matched -> returns CALL#2{rollupId=MAINNET, dest=C, scope=[0]}
        //    4. _resolveScopes -> newScope([0]) -> _processCallAtScope
        //    5. D'.executeOnBehalf(C, increment) -> C.increment() on L1 -> returns 1
        //    6. Builds RESULT -> matched -> terminal

        // CALL to D: outer call built by executeCrossChainCall when Alice calls D'
        // D' proxy has: originalAddress=D, originalRollupId=L2_ROLLUP_ID
        Action memory callToD = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: address(counterAndProxyL2),    // D
            value: 0,
            data: incrementProxyCallData,
            failed: false,
            sourceAddress: alice,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        // CALL to C: inner nested call (D calling C' -> C)
        // C' proxy has: originalAddress=counterL1, originalRollupId=MAINNET_ROLLUP_ID
        // executeCrossChainCall builds: rollupId=MAINNET, dest=C, source=D, sourceRollup=L2
        Action memory callToC = Action({
            actionType: ActionType.CALL,
            rollupId: MAINNET_ROLLUP_ID,               // C lives on MAINNET
            destination: address(counterL1),             // C
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: address(counterAndProxyL2),   // D (called C')
            sourceRollup: L2_ROLLUP_ID,                  // D is on L2
            scope: new uint256[](0)
        });

        // RESULT from C.increment() returning 1
        Action memory resultFromC = Action({
            actionType: ActionType.RESULT,
            rollupId: MAINNET_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(1)),
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-s4-step1");
        bytes32 s2 = keccak256("l2-state-s4-step2");

        // postBatch: 2 deferred entries on L1
        {
            // Entry 1 state delta: L2 state S0 -> S1 (outer call to D changes L2)
            StateDelta[] memory deltas1 = new StateDelta[](1);
            deltas1[0] = StateDelta({
                rollupId: L2_ROLLUP_ID,
                currentState: s0,
                newState: s1,
                etherDelta: 0
            });

            // Entry 2 state delta: L2 state S1 -> S2 (after C.increment completes)
            StateDelta[] memory deltas2 = new StateDelta[](1);
            deltas2[0] = StateDelta({
                rollupId: L2_ROLLUP_ID,
                currentState: s1,
                newState: s2,
                etherDelta: 0
            });

            ExecutionEntry[] memory entries = new ExecutionEntry[](2);

            // Entry 1: CALL to D -> CALL to C at scope=[0]
            uint256[] memory scope0 = new uint256[](1);
            scope0[0] = 0;
            callToC.scope = scope0;

            entries[0].stateDeltas = deltas1;
            entries[0].actionHash = keccak256(abi.encode(callToD));
            entries[0].nextAction = callToC;

            // Reset scope for Phase 2 reuse
            callToC.scope = new uint256[](0);

            // Entry 2: RESULT from C -> RESULT (terminal)
            entries[1].stateDeltas = deltas2;
            entries[1].actionHash = keccak256(abi.encode(resultFromC));
            entries[1].nextAction = resultFromC;

            rollups.postBatch(entries, 0, "", "proof");
        }

        // Alice calls D' on L1 (low-level call — D' is a proxy)
        vm.prank(alice);
        (bool success,) = counterAndProxyL2ProxyL1.call(incrementProxyCallData);
        assertTrue(success, "D' call should succeed");

        assertEq(counterL1.counter(), 1, "C(Counter on L1) should be 1");
        assertEq(_getRollupState(L2_ROLLUP_ID), s2, "L2 state should be S2");

        // ════════════════════════════════════════════
        //  Phase 2: L2 — SYSTEM executes D(CounterAndProxy) on L2
        // ════════════════════════════════════════════
        //
        //  D.incrementProxy() runs on L2, internally calls C' -> reentrant executeCrossChainCall.
        //  Needs 2 entries in L2 execution table:
        //    Entry 1: CALL to C -> RESULT(1)    (consumed inside reentrant executeCrossChainCall)
        //    Entry 2: RESULT(void) -> terminal   (consumed after D returns)

        // RESULT from D.incrementProxy() — void return, so data is empty
        // rollupId = L2_ROLLUP_ID (from the outer CALL built by executeIncomingCrossChainCall)
        Action memory resultFromD = Action({
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

        // Load L2 execution table for Phase 2
        {
            StateDelta[] memory emptyDeltas = new StateDelta[](0);
            ExecutionEntry[] memory entries = new ExecutionEntry[](2);

            // Entry 1: CALL to C -> RESULT(1) (consumed inside reentrant executeCrossChainCall)
            entries[0].stateDeltas = emptyDeltas;
            entries[0].actionHash = keccak256(abi.encode(callToC));
            entries[0].nextAction = resultFromC;

            // Entry 2: RESULT(void from D) -> terminal (consumed after D.incrementProxy() returns)
            entries[1].stateDeltas = emptyDeltas;
            entries[1].actionHash = keccak256(abi.encode(resultFromD));
            entries[1].nextAction = resultFromD;

            vm.prank(SYSTEM_ADDRESS);
            managerL2.loadExecutionTable(entries);
        }

        // SYSTEM triggers: executeIncomingCrossChainCall -> CALL to D -> D runs ->
        //   D calls C' -> reentrant executeCrossChainCall -> CALL to C resolved -> RESULT(1) ->
        //   D gets targetCounter=1, counter=1 -> RESULT(void) -> terminal
        vm.prank(SYSTEM_ADDRESS);
        managerL2.executeIncomingCrossChainCall(
            address(counterAndProxyL2),  // dest = D (CounterAndProxy on L2)
            0,                           // value
            incrementProxyCallData,      // data = incrementProxy()
            alice,                       // source = Alice (initiated on L1)
            MAINNET_ROLLUP_ID,           // sourceRollup = MAINNET
            new uint256[](0)             // scope = [] (root)
        );

        // ── Final assertions ──
        assertEq(counterAndProxyL2.counter(), 1, "D.counter should be 1");
        assertEq(counterAndProxyL2.targetCounter(), 1, "D.targetCounter should be 1");
        assertEq(counterL1.counter(), 1, "C(Counter on L1) should still be 1");
    }
}
