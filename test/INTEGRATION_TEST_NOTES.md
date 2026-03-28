# Integration Test Notes

## Legend

| Symbol | Variable Name | Contract | Chain | Type |
|--------|---------------|----------|-------|------|
| A | `counterAndProxy` | CounterAndProxy | L1 | Calls B' proxy, updates local counter |
| B | `counterL2` | Counter | L2 | Simple increment, returns new value |
| C | `counterL1` | Counter | L1 | Simple increment, returns new value |
| D | `counterAndProxyL2` | CounterAndProxy | L2 | Calls C' proxy, updates local counter |
| RC | `revertCounterL1` | RevertCounter | L1 | Always reverts on increment() |
| B' | `counterProxy` | CrossChainProxy for B | L1 | Proxy so A can call B cross-chain |
| C' | `counterProxyL2` | CrossChainProxy for C | L2 | Proxy so D can call C cross-chain |
| A' | `counterAndProxyProxyL2` | CrossChainProxy for A | L2 | Proxy for Scenario 3 |
| D' | `counterAndProxyL2ProxyL1` | CrossChainProxy for D | L1 | Proxy for Scenarios 2 & 4 |
| RC' | `revertCounterProxyL2` | CrossChainProxy for RC | L2 | Proxy for Scenario 5 |

## The 4 Scenarios

Every scenario executes on BOTH L1 and L2.

| # | Flow | Direction | What it tests |
|---|------|-----------|---------------|
| 1 | Alice -> A (-> B') -> B | L1 -> L2 | Simple: L1 contract calls L2 via proxy. Phase 1: L2 executes B via `executeIncomingCrossChainCall`. Phase 2: L1 resolves via `postBatch` + proxy call. |
| 2 | Alice -> D (-> C') -> C | L2 -> L1 | Simple reverse: Phase 1: L1 executes C via `executeL2TX` + scope nav. Phase 2: L2 resolves via execution table. |
| 3 | Alice -> A' (-> A -> B') -> B | L2 -> L1 -> L2 | Nested: Phase 1: L1 runs A via `executeL2TX` (A calls B' reentrant). Phase 2: L2 runs B via scope navigation through A'. |
| 4 | Alice -> D' (-> D -> C') -> C | L1 -> L2 -> L1 | Nested: Phase 1: L2 runs D via `executeIncomingCrossChainCall` (D calls C' reentrant). Phase 2: L1 runs C via scope navigation through D'. |
| 5 | Alice -> RC' -> RC (reverts) | L2 -> L1 | REVERT_CONTINUE: Phase 1: L1 runs RC via `executeL2TX` — RC reverts locally, REVERT_CONTINUE ensures executeL2TX succeeds (L2TX cannot end with failed RESULT). Phase 2: L2 Alice calls RC' — terminal failure (executeCrossChainCall can fail). |

## Design Decisions

### Every scenario must execute on both L1 and L2

This is a core design principle. Even for nested scenarios (3 & 4), both chains must have an execution phase:
- **Scenario 3:** L1 runs A via `executeL2TX` (Phase 1), then L2 runs B via scope navigation (Phase 2)
- **Scenario 4:** L2 runs D via `executeIncomingCrossChainCall` (Phase 1), then L1 runs C via scope navigation (Phase 2)

The nested scenarios are NOT just "scope navigation on one chain" -- they reflect the full cross-chain reality where the inner contract (B or C) must actually execute on its home chain.

### Why executeL2TX for L1 execution (Scenarios 2 & 3)?

`Rollups.sol` has no `executeIncomingCrossChainCall` (unlike `CrossChainManagerL2`). This is by design: **L1 always initiates L2 execution** -- an L2 can receive execution from L1, but not the other way around. `executeL2TX` starts the L2 tx execution that interacts with L1.

How it works:
1. `postBatch` stores deferred entries with an L2TX action hash
2. `executeL2TX(rollupId, rlpEncodedTx)` builds an L2TX action, matches it
3. The matched entry's `nextAction` is a CALL -> enters scope navigation
4. `_processCallAtScope` -> proxy `executeOnBehalf` -> actual execution

### Reentrant executeCrossChainCall in nested scenarios

In Scenarios 3 and 4, the inner contract (A or D) itself makes a cross-chain call during execution:
- **Scenario 3 Phase 1:** `executeL2TX` -> runs A on L1 -> A calls B' -> this triggers a **reentrant** `executeCrossChainCall` inside the same transaction
- **Scenario 4 Phase 1:** `executeIncomingCrossChainCall` -> runs D on L2 -> D calls C' -> this triggers a **reentrant** `executeCrossChainCall`

This means the execution table needs entries for BOTH the outer call AND the inner reentrant call. For example, Scenario 3 Phase 1 needs 3 `postBatch` entries:
1. `L2TX -> CALL to A` (consumed by `executeL2TX`)
2. `CALL to B -> RESULT(1)` (consumed inside the reentrant `executeCrossChainCall` when A calls B')
3. `RESULT(void from A) -> terminal` (consumed after A.increment() returns)

### Sequential state deltas

When multiple entries consume L2 state (like Scenario 3 Phase 1), their state deltas must chain sequentially: S0->S1 for entry 1, S1->S2 for entry 2. `_findAndApplyExecution` checks that `currentState` matches the rollup's actual state at consumption time.

The `_etherDelta` transient storage is reset by each `_applyStateDeltas` call, so sequential entries with `etherDelta=0` work correctly even across reentrant calls.

### Void vs valued returns

- `Counter.increment()` returns `uint256` -> RESULT data = `abi.encode(1)`
- `CounterAndProxy.increment()` returns void -> RESULT data = `""` (empty bytes)

The RESULT's `rollupId` comes from the CALL action's `rollupId` (the chain where the target lives), NOT from the chain where execution physically happens.

### Proxy reentrancy is safe

In Scenarios 3 and 4, the proxy (A' or D') is entered twice in the same transaction:
1. First via `fallback()` (Alice's call)
2. Then via `executeOnBehalf()` (manager's call during scope navigation)

This is safe because:
- `CrossChainProxy` has no mutable storage (only `immutable` fields)
- `fallback()` and `executeOnBehalf()` are independent entry points
- No reentrancy guards needed

### Scope navigation in Phase 2 of nested scenarios

Phase 2 uses execution table entries with `scope=[0]` to trigger scope navigation. The flow:
1. Alice calls proxy (A' or D') -> `executeCrossChainCall` builds CALL#1 (outer, scope=[])
2. CALL#1 matches -> returns CALL#2 (inner, scope=[0])
3. `_resolveScopes(CALL#2)` -> `newScope([], CALL#2)` -> child scope detected -> `newScope([0], CALL#2)`
4. Scopes match -> `_processCallAtScope` -> proxy's `executeOnBehalf` -> actual execution
5. RESULT matches -> terminal -> unwinds back to caller

## How to Build a New Integration Test

### Architecture: L1 vs L2

- **L1 (Rollups)**: Uses `postBatch()` to store deferred execution entries (ZK-proven). Entries consumed by `executeCrossChainCall()` or `executeL2TX()`.
- **L2 (CrossChainManagerL2)**: SYSTEM loads entries via `loadExecutionTable()`. Consumed by `executeCrossChainCall()` or `executeIncomingCrossChainCall()`.
- **Key difference**: L1 has `_findAndApplyExecution` (checks state deltas match on-chain state). L2 has `_consumeExecution` (no state checks, just FIFO).
- **Rollups has NO `executeIncomingCrossChainCall`**. Use `executeL2TX` as a trigger instead.

### Step 1: Define the call chain

Identify the entities and directions. Example: `Alice -> X (-> Y') -> Y` means Alice calls X on chain A, X calls Y' (proxy for Y on chain B), which resolves to Y on chain B.

### Step 2: Build execution entries

Each cross-chain call consumes one execution entry. Build entries working backwards from the innermost call:

```solidity
// 1. Build the Action that the contract will reconstruct
Action memory action = Action({
    actionType: ActionType.CALL,  // or L2TX, RESULT
    rollupId: TARGET_ROLLUP,      // where the destination lives
    destination: targetContract,
    value: 0,
    data: callData,
    failed: false,
    sourceAddress: callerContract, // who initiated the cross-chain call
    sourceRollup: SOURCE_ROLLUP,   // where the caller lives
    scope: new uint256[](0)        // [] for root, [0] for first nested, etc.
});

// 2. Hash it
bytes32 actionHash = keccak256(abi.encode(action));

// 3. Build the entry
ExecutionEntry memory entry;
entry.stateDeltas = stateDeltas; // L1 needs these; L2 uses empty
entry.actionHash = actionHash;
entry.nextAction = nextAction;   // what to do after matching
```

### Step 3: Action construction patterns

These are the patterns used by the contracts to build actions internally. Your test entries must hash to the same value.

**executeCrossChainCall (both L1 and L2)** -- called when a proxy's fallback forwards a call:
```
rollupId     = proxy.originalRollupId  (target chain)
destination  = proxy.originalAddress   (target contract)
sourceAddress = sourceAddress param    (msg.sender at proxy level)
sourceRollup  = MAINNET_ROLLUP_ID (L1) or ROLLUP_ID (L2)
scope         = [] (always empty at entry)
```

**executeL2TX (L1 only)**:
```
actionType   = L2TX
rollupId     = rollupId param
destination  = address(0)
data         = rlpEncodedTx param
sourceAddress = address(0)
sourceRollup  = MAINNET_ROLLUP_ID
scope         = []
```

**_processCallAtScope (both L1 and L2)** -- after executing via `sourceProxy.executeOnBehalf(dest, data)`:
```
RESULT.rollupId = CALL.rollupId  (same as the call it's responding to)
RESULT.data     = returnData     (raw bytes from executeOnBehalf)
RESULT.failed   = !success
```

### Step 4: State delta rules

- **L1 entries**: Need `StateDelta[]` with `currentState` matching on-chain rollup state at consumption time.
- **L2 entries**: Always `new StateDelta[](0)` (L2 manager ignores them).
- **Ether delta**: `_applyStateDeltas` checks `totalEtherDelta == _etherDelta` (transient). For no-ETH flows, both are 0.
- **`_etherDelta` resets to 0** after each `_applyStateDeltas` call.
- **Sequential entries**: When multiple entries consume L2 state in one transaction, deltas must chain: S0->S1 for entry 1, S1->S2 for entry 2.

### Step 5: Scope navigation

For a call chain like A' -> A -> B' -> B:
- CALL#1: `scope=[]` (outer call to A)
- CALL#2: `scope=[0]` (first nested call, to B)
- `newScope([], CALL#2)`: sees child scope -> recurse with `[0]`
- `newScope([0], CALL#2)`: scopes match -> `_processCallAtScope` executes

### Step 6: Wire up the test

Proxies don't have application functions -- use low-level call:
```solidity
vm.prank(alice);
(bool success,) = proxyAddress.call(incrementCallData);
assertTrue(success, "proxy call should succeed");
```

L2 execution table loading requires SYSTEM prank:
```solidity
vm.prank(SYSTEM_ADDRESS);
managerL2.loadExecutionTable(entries);
```

### Return data encoding through proxies

1. `Counter.increment()` returns `uint256(1)` -> ABI encoded as 32 bytes
2. `executeOnBehalf` returns raw bytes via assembly (no ABI wrapping)
3. `executeCrossChainCall` returns `bytes memory` (ABI function return)
4. Proxy fallback returns raw bytes via assembly (strips outer ABI layer)
5. `CounterAndProxy` decodes: `abi.decode(result, (bytes))` then `abi.decode(inner, (uint256))`

### Key constants

```
L2_ROLLUP_ID = 1
MAINNET_ROLLUP_ID = 0
SYSTEM_ADDRESS = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF
```

## Scenario Reference (Detailed Entry Structures)

### Scenario 1: Alice -> A (-> B') -> B

**Phase 1 (L2): SYSTEM executes B via executeIncomingCrossChainCall**

L2 execution table (1 entry):
```
Entry: hash(RESULT) -> RESULT (terminal, self-referencing)
  RESULT = {RESULT, rollupId=L2_ROLLUP_ID, dest=0, value=0,
            data=abi.encode(1), failed=false, source=0, sourceRollup=0, scope=[]}
```

Then SYSTEM calls:
```
managerL2.executeIncomingCrossChainCall(
    counterL2,           // dest = B
    0,                   // value
    increment(),         // data
    counterAndProxy,     // source = A
    MAINNET_ROLLUP_ID,   // sourceRollup
    []                   // scope
)
```

**Phase 2 (L1): Alice calls A, resolves from postBatch**

L1 deferred entry (1 entry):
```
Entry: hash(CALL) -> RESULT
  CALL = {CALL, rollupId=L2_ROLLUP_ID, dest=counterL2, data=increment,
          source=counterAndProxy, sourceRollup=MAINNET_ROLLUP_ID, scope=[]}
  RESULT = same as Phase 1
  stateDeltas = [{rollupId=L2, currentState=initial, newState=after, etherDelta=0}]
```

Assertions: `counterL2.counter() == 1`, `counterAndProxy.counter() == 1`, `counterAndProxy.targetCounter() == 1`

### Scenario 2: Alice -> D (-> C') -> C

**Phase 1 (L1): Execute C via executeL2TX**

postBatch entries (2 deferred):
```
Entry 1: hash(L2TX) -> CALL to C
  L2TX = {L2TX, rollupId=L2_ROLLUP_ID, dest=0, data=rlpEncodedTx, source=0, sourceRollup=MAINNET}
  CALL = {CALL, rollupId=MAINNET_ROLLUP_ID, dest=counterL1, data=increment,
          source=counterAndProxyL2, sourceRollup=L2_ROLLUP_ID, scope=[]}
  stateDeltas = [{rollupId=L2, currentState=initial, newState=after, etherDelta=0}]

Entry 2: hash(RESULT) -> RESULT (terminal)
  RESULT = {RESULT, rollupId=MAINNET_ROLLUP_ID, data=abi.encode(1), failed=false}
  stateDeltas = []
```

Execution: `postBatch` stores entries, then `executeL2TX(L2_ROLLUP_ID, rlpEncodedTx)` triggers resolution via scope navigation.

**Phase 2 (L2): Alice calls D, resolves from execution table**

L2 execution table (1 entry):
```
Entry: hash(CALL) -> RESULT
  CALL = {CALL, rollupId=MAINNET_ROLLUP_ID, dest=counterL1, data=increment,
          source=counterAndProxyL2, sourceRollup=L2_ROLLUP_ID, scope=[]}
  RESULT = {RESULT, rollupId=MAINNET_ROLLUP_ID, data=abi.encode(1), failed=false}
```

Assertions: `counterL1.counter() == 1`, `counterAndProxyL2.counter() == 1`, `counterAndProxyL2.targetCounter() == 1`

### Scenario 3: Alice -> A' (-> A -> B') -> B

**Phase 1 (L1): Execute A via executeL2TX (A calls B' reentrantly)**

postBatch entries (3 deferred):
```
Entry 1: hash(L2TX) -> CALL to A
  L2TX = {L2TX, rollupId=L2_ROLLUP_ID, dest=0, data=rlpEncodedTx, source=0, sourceRollup=MAINNET}
  CALL = {CALL, rollupId=MAINNET_ROLLUP_ID, dest=counterAndProxy, data=increment,
          source=Alice, sourceRollup=L2_ROLLUP_ID, scope=[0]}
  stateDeltas = [{rollupId=L2, currentState=S0, newState=S1, etherDelta=0}]

Entry 2: hash(CALL to B) -> RESULT(1)
  CALL = {CALL, rollupId=L2_ROLLUP_ID, dest=counterL2, data=increment,
          source=counterAndProxy, sourceRollup=MAINNET_ROLLUP_ID, scope=[]}
  RESULT = {RESULT, rollupId=L2_ROLLUP_ID, data=abi.encode(1), failed=false}
  stateDeltas = [{rollupId=L2, currentState=S1, newState=S2, etherDelta=0}]

Entry 3: hash(RESULT from A) -> RESULT (terminal)
  RESULT = {RESULT, rollupId=MAINNET_ROLLUP_ID, data=abi.encode(""), failed=false}
  stateDeltas = []
```

Note: State deltas chain S0->S1->S2. Entry 2 is consumed during the reentrant `executeCrossChainCall` when A calls B'.

**Phase 2 (L2): Alice calls A', scope navigation executes B**

L2 execution table (2 entries):
```
Entry 1: hash(CALL#1) -> CALL#2
  CALL#1 = {CALL, rollupId=MAINNET_ROLLUP_ID, dest=counterAndProxy(A), data=increment,
            source=Alice, sourceRollup=L2_ROLLUP_ID, scope=[]}
  CALL#2 = {CALL, rollupId=L2_ROLLUP_ID, dest=counterL2(B), data=increment,
            source=counterAndProxy(A), sourceRollup=MAINNET_ROLLUP_ID, scope=[0]}

Entry 2: hash(RESULT) -> RESULT (terminal)
  RESULT = {RESULT, rollupId=L2_ROLLUP_ID, data=abi.encode(1), failed=false}
```

Execution: Alice calls A' -> `executeCrossChainCall` -> CALL#1 matches -> CALL#2 with scope=[0] -> scope navigation -> `_processCallAtScope` -> A'.executeOnBehalf(B, increment) -> B.increment() returns 1 -> RESULT consumed.

### Scenario 4: Alice -> D' (-> D -> C') -> C

**Phase 1 (L2): SYSTEM executes D via executeIncomingCrossChainCall (D calls C' reentrantly)**

L2 execution table (3 entries):
```
Entry 1: hash(RESULT from C) -> RESULT(1) (terminal, for inner reentrant call)
  RESULT = {RESULT, rollupId=MAINNET_ROLLUP_ID, data=abi.encode(1), failed=false}

Entry 2: hash(CALL to C) -> same RESULT(1) (consumed when D calls C')
  CALL = {CALL, rollupId=MAINNET_ROLLUP_ID, dest=counterL1, data=increment,
          source=counterAndProxyL2, sourceRollup=L2_ROLLUP_ID, scope=[]}

Entry 3: hash(RESULT from D) -> RESULT (terminal, void return)
  RESULT = {RESULT, rollupId=L2_ROLLUP_ID, data="", failed=false}
```

Then SYSTEM calls `executeIncomingCrossChainCall(counterAndProxyL2, 0, increment, Alice, MAINNET_ROLLUP_ID, [0])`.

**Phase 2 (L1): Alice calls D', scope navigation executes C**

postBatch entries (2 deferred):
```
Entry 1: hash(CALL#1) -> CALL#2
  CALL#1 = {CALL, rollupId=L2_ROLLUP_ID, dest=counterAndProxyL2(D), data=increment,
            source=Alice, sourceRollup=MAINNET_ROLLUP_ID, scope=[]}
  CALL#2 = {CALL, rollupId=MAINNET_ROLLUP_ID, dest=counterL1(C), data=increment,
            source=counterAndProxyL2(D), sourceRollup=L2_ROLLUP_ID, scope=[0]}
  stateDeltas = [{rollupId=L2, currentState=initial, newState=after, etherDelta=0}]

Entry 2: hash(RESULT) -> RESULT (terminal)
  RESULT = {RESULT, rollupId=MAINNET_ROLLUP_ID, data=abi.encode(1), failed=false}
  stateDeltas = []
```

Execution: Alice calls D' -> `executeCrossChainCall` -> CALL#1 matches -> CALL#2 with scope=[0] -> scope navigation -> `_processCallAtScope` -> D'.executeOnBehalf(C, increment) -> C.increment() returns 1 -> RESULT consumed.

Assertions: `counterL1.counter() == 1`, L2 rollup stateRoot updated.

### Scenario 5: Alice -> RC' -> RC (reverts) — REVERT_CONTINUE

**Phase 1 (L1): Execute RC via executeL2TX — REVERT_CONTINUE (L2TX must succeed)**

postBatch entries (3 deferred):
```
Entry 0: hash(L2TX) -> CALL(RC, scope=[0])
  L2TX = {L2TX, rollupId=L2_ROLLUP_ID, dest=0, data=rlpEncodedTx, source=0, sourceRollup=MAINNET}
  CALL = {CALL, rollupId=MAINNET_ROLLUP_ID, dest=revertCounterL1, data=increment,
          source=Alice, sourceRollup=L2_ROLLUP_ID, scope=[0]}
  stateDeltas = [{rollupId=L2, currentState=S0, newState=S1, etherDelta=0}]

Entry 1: hash(RESULT(failed)) -> REVERT(scope=[0])
  RESULT = {RESULT, rollupId=MAINNET_ROLLUP_ID, data=Error("always reverts"), failed=true}
  REVERT = {REVERT, rollupId=L2_ROLLUP_ID, scope=[0]}
  stateDeltas = [{rollupId=L2, currentState=S1, newState=S2, etherDelta=0}]

Entry 2: hash(REVERT_CONTINUE) -> RESULT(ok, terminal)
  REVERT_CONTINUE = {REVERT_CONTINUE, rollupId=L2_ROLLUP_ID, failed=true}
  RESULT = {RESULT, rollupId=L2_ROLLUP_ID, data="", failed=false}
  stateDeltas = [{rollupId=L2, currentState=S2, newState=S3, etherDelta=0}]
```

Execution: `executeL2TX` -> L2TX matched -> CALL(RC, scope=[0]) -> `newScope([0])` -> RC.increment() reverts -> RESULT(failed) consumes entry 1 -> REVERT(scope=[0]) -> `_getRevertContinuation` consumes entry 2 -> `ScopeReverted(RESULT(ok), S2, L2)` -> parent catches -> `_handleScopeRevert` restores state to S2 -> terminal RESULT(ok) -> success.

L2TX cannot end with failed RESULT — REVERT_CONTINUE ensures executeL2TX succeeds. Entries [1] and [2] are consumed inside the reverting scope and rolled back by ScopeReverted. Final L2 state = S2.

**Phase 2 (L2): Alice calls RC' — terminal failure**

L2 execution table (1 entry):
```
Entry: hash(CALL) -> RESULT(failed)
  CALL = {CALL, rollupId=MAINNET_ROLLUP_ID, dest=revertCounterL1, data=increment,
          source=Alice, sourceRollup=L2_ROLLUP_ID, scope=[]}
  RESULT = {RESULT, rollupId=MAINNET_ROLLUP_ID, data=Error("always reverts"), failed=true}
```

Execution: Alice calls RC' -> `executeCrossChainCall` -> CALL consumed -> RESULT(failed) -> `_resolveScopes` -> `CallExecutionFailed` -> reverts. Terminal failure is OK for `executeCrossChainCall` (unlike L2TX).

Assertions: `revertCounterL1.counter() == 0`, L2 rollup stateRoot == S2.

## Visualizer Presentation Order

The visualizer (`visualizator/index.html`) shows steps sequentially. The order follows the **arrow direction** of each scenario, NOT a fixed "always L1 first" or "always L2 first" rule.

### Rules for determining step order

1. **Follow the arrows.** The arrows in the scenario flow tell you which chain the story starts on.
2. **Simple scenarios (S1, S2):** Show the initiating chain first, then the remote chain.
   - S1 `Alice -> A (-> B') -> B` [L1->L2]: L1 first (Alice calls A), then L2 (B executes)
   - S2 `Alice -> D (-> C') -> C` [L2->L1]: L2 first (Alice calls D), then L1 (C executes)
3. **Nested scenarios (S3, S4):** The "inner" execution (the chain in the middle of the arrows) must complete first, because its result gets pre-loaded into the "outer" chain's table. Then the "outer" chain consumes it via scope navigation.
   - S3 `Alice -> A' (-> A -> B') -> B` [L2->L1->L2]: L1 first (A runs as inner), then L2 (Alice->A'->B as outer)
   - S4 `Alice -> D' (-> D -> C') -> C` [L1->L2->L1]: L2 first (D runs as inner), then L1 (Alice->D'->C as outer)
4. **Within each chain phase:** setup (postBatch/loadTable) comes before execution (call/executeL2TX/executeIncoming).

### How to build future flows

For a new scenario with flow `X -> Y -> Z`:
1. Identify the chains: which chain does each entity (X, Y, Z) live on?
2. Identify the direction: the arrows tell you the conceptual order.
3. Determine execution phases: the "inner" cross-chain calls must execute first on their home chain, producing results that get loaded into the "outer" chain's table.
4. For each phase: first show table loading (postBatch on L1 / loadExecutionTable on L2), then show the execution that consumes those entries.
5. Show both execution tables at all times -- entries appear when loaded, disappear when consumed.

## Open Questions for Future Work

1. **Negative test cases:** Should we add tests for:
   - Wrong state delta (currentState doesn't match) -> should revert with `ExecutionNotFound`
   - Wrong action hash (no matching entry) -> should revert
   - Failed proof verification (set `verifier.setVerifyResult(false)`)
   - RESULT with `failed=true` -> should revert with `CallExecutionFailed`

2. **ETH value transfers:** All current scenarios use `value=0`. Should we add scenarios that test:
   - `depositEther` + cross-chain calls with value
   - `etherDelta` accounting in state deltas
   - Negative ether delta (rollup sends ETH out)

3. **Deeper nesting:** Current nested tests go 2 levels deep (scope=[0]). Should we test:
   - 3+ levels of nesting (scope=[0,0])
   - Multiple sibling calls (scope=[0], scope=[1])

4. **Nested cross-chain reverts (TODO):** Scenario 5 covers single-hop REVERT_CONTINUE (L2→L1, the reverting call is the leaf). The hard unsupported case is **nested cross-chain reverts**: e.g. L2 → L1 → L2 where the inner L2 call reverts, and the REVERT/REVERT_CONTINUE chain must propagate back through scope navigation across multiple chains and execution tables. Also: REVERT_CONTINUE on L2 via `executeIncomingCrossChainCall` (B calls A cross-chain, A reverts on L1, B's scope handles it on L2).

5. **Multiple rollups:** All tests use a single L2 rollup. Should we test cross-chain calls spanning 3+ rollups?

6. **Multiple entries in a batch:** Current tests post 1-2 entries per batch. Should we test batches with many entries, some immediate (actionHash=0) and some deferred?
