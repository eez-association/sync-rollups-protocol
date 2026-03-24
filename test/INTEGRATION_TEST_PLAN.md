# Plan: Integration Test Scenarios for Cross-Chain Calls

## Context

The existing integration test (`test/IntegrationTest.t.sol`) covers one scenario: L1-originated simple call (Alice -> A -> B' -> B). We need 3 more tests covering reverse direction (L2 -> L1) and nested cross-chain calls with scope navigation.

## Legend

- **A** = CounterAndProxy on L1 (calls a proxy target, updates local counter)
- **B** = Counter on L2 (simple increment)
- **C** = Counter on L1 (simple increment)
- **D** = CounterAndProxy on L2 (calls a proxy target, updates local counter)
- **X'** = CrossChainProxy for X

## 4 Scenarios

| # | Flow | Direction | Type |
|---|------|-----------|------|
| 1 | Alice -> A (-> B') -> B | L1 -> L2 | Simple (existing) |
| 2 | Alice -> D (-> C') -> C | L2 -> L1 | Simple (reverse) |
| 3 | Alice -> A' (-> A -> B') -> B | L2 entry -> nested L2 scope | Nested |
| 4 | Alice -> D' (-> D -> C') -> C | L1 entry -> nested L1 scope | Nested |

## Decisions

- **Scenario 4 confirmed:** Alice -> D' (-> D -> C') -> C
- **L1 execution (Scenario 2):** Use `executeL2TX` as trigger through Rollups system
- **Nested call model (Scenarios 3 & 4):** Multiple scoped entries with full scope navigation

---

## Setup Additions

**File:** `test/IntegrationTest.t.sol`

New state variables:
```solidity
Counter public counterL1;                    // C
CounterAndProxy public counterAndProxyL2;    // D
address public counterProxyL2;               // C' (proxy for C on L2)
address public counterAndProxyProxyL2;       // A' (proxy for A on L2)
address public counterAndProxyL2ProxyL1;     // D' (proxy for D on L1)
```

setUp() additions:
```solidity
// C: Counter on L1
counterL1 = new Counter();

// C': proxy for C on L2 (so L2 contracts can call L1's Counter)
counterProxyL2 = managerL2.createCrossChainProxy(address(counterL1), MAINNET_ROLLUP_ID);

// D: CounterAndProxy on L2, targeting C'
counterAndProxyL2 = new CounterAndProxy(counterProxyL2);

// A': proxy for A on L2 (for Scenario 3)
counterAndProxyProxyL2 = managerL2.createCrossChainProxy(address(counterAndProxy), MAINNET_ROLLUP_ID);

// D': proxy for D on L1 (for Scenario 4)
counterAndProxyL2ProxyL1 = rollups.createCrossChainProxy(address(counterAndProxyL2), L2_ROLLUP_ID);
```

---

## Test 2: Alice -> D (-> C') -> C (L2 calls L1, simple)

### Phase 1 — L1: Execute Counter via executeL2TX

Uses `executeL2TX` to trigger Counter.increment() on L1 through the Rollups execution system.

**postBatch entries (2 deferred):**

Entry 1: `hash(L2TX) -> CALL to C`
```
L2TX = {L2TX, rollupId=L2_ROLLUP_ID, dest=0, data=rlpEncodedTx, source=0, sourceRollup=MAINNET}
CALL = {CALL, rollupId=MAINNET_ROLLUP_ID, dest=counterL1, data=increment,
        source=counterAndProxyL2, sourceRollup=L2_ROLLUP_ID, scope=[]}
stateDeltas = [{rollupId=L2, currentState=initial, newState=after, etherDelta=0}]
```

Entry 2: `hash(RESULT) -> RESULT (terminal)`
```
RESULT = {RESULT, rollupId=MAINNET_ROLLUP_ID, data=abi.encode(1), failed=false}
stateDeltas = [] (empty)
```

**Execution flow:**
1. `rollups.postBatch([entry1, entry2], ...)` — stores deferred entries
2. `executeL2TX(L2_ROLLUP_ID, rlpEncodedTx)` — triggers resolution
3. Builds L2TX action -> `_findAndApplyExecution` -> returns CALL
4. `_resolveScopes(CALL)` -> `newScope([], CALL)` -> `_processCallAtScope`
5. Creates D' proxy on L1 (proxy for D on L2) — or reuse if exists
6. `D'.executeOnBehalf(counterL1, increment)` -> `Counter.increment()` returns 1
7. Builds RESULT -> `_findAndApplyExecution(resultHash)` -> terminal RESULT
8. Assert: `counterL1.counter() == 1`

### Phase 2 — L2: Alice calls D, resolves from execution table

**L2 execution table (1 entry):**
```
Entry: hash(CALL) -> RESULT
CALL = {CALL, rollupId=MAINNET_ROLLUP_ID, dest=counterL1, data=increment,
        source=counterAndProxyL2, sourceRollup=L2_ROLLUP_ID, scope=[]}
RESULT = {RESULT, rollupId=MAINNET_ROLLUP_ID, data=abi.encode(1), failed=false}
```

**Execution flow:**
1. `managerL2.loadExecutionTable([entry])`
2. Alice calls `counterAndProxyL2.increment()`
3. D calls C' -> `managerL2.executeCrossChainCall(D, increment)`
4. Manager builds CALL, `_consumeExecution(hash)` -> RESULT(1)
5. `_resolveScopes(RESULT)` -> already RESULT, return data
6. D processes: `targetCounter = 1, counter++`

**Assertions:**
- `counterL1.counter() == 1` (from Phase 1)
- `counterAndProxyL2.counter() == 1`
- `counterAndProxyL2.targetCounter() == 1`
- `managerL2.pendingEntryCount() == 0`

---

## Test 3: Alice -> A' (-> A -> B') -> B (nested, L2 side)

Full scope navigation on L2. A' is reentrant (called by Alice via fallback, then by manager via executeOnBehalf during scope navigation — different functions, no state conflict).

**L2 execution table (2 entries):**

Entry 1: `hash(CALL#1) -> CALL#2`
```
CALL#1 = {CALL, rollupId=MAINNET_ROLLUP_ID, dest=counterAndProxy(A), data=increment,
          source=Alice, sourceRollup=L2_ROLLUP_ID, scope=[]}
CALL#2 = {CALL, rollupId=L2_ROLLUP_ID, dest=counterL2(B), data=increment,
          source=counterAndProxy(A), sourceRollup=MAINNET_ROLLUP_ID, scope=[0]}
```

Entry 2: `hash(RESULT) -> RESULT (terminal)`
```
RESULT = {RESULT, rollupId=L2_ROLLUP_ID, data=abi.encode(1), failed=false}
```

**Execution flow:**
1. `managerL2.loadExecutionTable([entry1, entry2])`
2. Alice calls A' on L2: `address(counterAndProxyProxyL2).call(increment.selector)`
3. A'.fallback -> `managerL2.executeCrossChainCall(Alice, increment.selector)`
4. Manager builds CALL#1 -> `_consumeExecution(hash)` -> returns CALL#2
5. `_resolveScopes(CALL#2)` -> CALL -> enter scope navigation
6. `newScope([], CALL#2)`: scope=[0] is child of [] -> recurse
7. `newScope([0], CALL#2)`: scopes match -> `_processCallAtScope`
8. sourceProxy = A' (proxy for counterAndProxy on MAINNET, already exists)
9. `A'.executeOnBehalf(counterL2, increment)` -> `Counter.increment()` -> returns 1
10. Builds RESULT{rollupId=L2, data=encode(1)} -> `_consumeExecution(resultHash)` -> terminal RESULT
11. Returns up the scope chain -> returns to Alice

**Assertions:**
- `counterL2.counter() == 1` (actually executed via scope navigation)
- `managerL2.pendingEntryCount() == 0`

---

## Test 4: Alice -> D' (-> D -> C') -> C (nested, L1 side)

Full scope navigation on L1. D' is reentrant (same as A' in Scenario 3, different functions).

**postBatch entries (2 deferred):**

Entry 1: `hash(CALL#1) -> CALL#2`
```
CALL#1 = {CALL, rollupId=L2_ROLLUP_ID, dest=counterAndProxyL2(D), data=increment,
          source=Alice, sourceRollup=MAINNET_ROLLUP_ID, scope=[]}
CALL#2 = {CALL, rollupId=MAINNET_ROLLUP_ID, dest=counterL1(C), data=increment,
          source=counterAndProxyL2(D), sourceRollup=L2_ROLLUP_ID, scope=[0]}
stateDeltas for Entry 1 = [{rollupId=L2, currentState=initial, newState=after, etherDelta=0}]
```

Entry 2: `hash(RESULT) -> RESULT (terminal)`
```
RESULT = {RESULT, rollupId=MAINNET_ROLLUP_ID, data=abi.encode(1), failed=false}
stateDeltas for Entry 2 = [] (empty)
```

**Execution flow:**
1. `rollups.postBatch([entry1, entry2], ...)`
2. Alice calls D' on L1: `address(counterAndProxyL2ProxyL1).call(increment.selector)`
3. D'.fallback -> `rollups.executeCrossChainCall(Alice, increment.selector)`
4. Rollups builds CALL#1 -> `_findAndApplyExecution(hash)` -> applies L2 state delta -> returns CALL#2
5. `_resolveScopes(CALL#2)` -> CALL -> enter scope navigation
6. `newScope([], CALL#2)`: scope=[0] is child of [] -> recurse
7. `newScope([0], CALL#2)`: scopes match -> `_processCallAtScope`
8. sourceProxy = D' (proxy for counterAndProxyL2 on L2, already exists)
9. `D'.executeOnBehalf(counterL1, increment)` -> `Counter.increment()` -> returns 1
10. Builds RESULT{rollupId=MAINNET, data=encode(1)} -> `_findAndApplyExecution(resultHash)` -> terminal RESULT (empty deltas pass ether check since no ETH involved)
11. Returns up the scope chain -> returns to Alice

**Assertions:**
- `counterL1.counter() == 1` (actually executed via scope navigation)
- L2 rollup stateRoot updated to newState
- No pending execution entries

---

## Files to Modify

1. `test/IntegrationTest.t.sol` — Add setUp() variables and 3 new test functions

## Verification

```bash
forge test --match-contract IntegrationTest -vvv
```
