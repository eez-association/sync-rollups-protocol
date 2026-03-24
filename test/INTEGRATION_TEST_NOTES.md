# Integration Test Notes & Open Questions

## What we built

4 integration test scenarios covering all cross-chain call patterns. **Every scenario executes on BOTH L1 and L2.**

| # | Flow | Direction | What it tests |
|---|------|-----------|---------------|
| 1 | Alice -> A (-> B') -> B | L1 -> L2 | Simple: L1 contract calls L2 via proxy. Phase 1: L2 executes B via `executeIncomingCrossChainCall`. Phase 2: L1 resolves via `postBatch` + proxy call. |
| 2 | Alice -> D (-> C') -> C | L2 -> L1 | Simple reverse: Phase 1: L1 executes C via `executeL2TX` + scope nav. Phase 2: L2 resolves via execution table. |
| 3 | Alice -> A' (-> A -> B') -> B | L2 -> L1 -> L2 | Nested: Phase 1: L1 runs A via `executeL2TX` (A calls B' reentrant). Phase 2: L2 runs B via scope navigation through A'. |
| 4 | Alice -> D' (-> D -> C') -> C | L1 -> L2 -> L1 | Nested: Phase 1: L2 runs D via `executeIncomingCrossChainCall` (D calls C' reentrant). Phase 2: L1 runs C via scope navigation through D'. |

## Design decisions

### Every scenario must execute on both L1 and L2

This is a core design principle. Even for nested scenarios (3 & 4), both chains must have an execution phase:
- **Scenario 3:** L1 runs A via `executeL2TX` (Phase 1), then L2 runs B via scope navigation (Phase 2)
- **Scenario 4:** L2 runs D via `executeIncomingCrossChainCall` (Phase 1), then L1 runs C via scope navigation (Phase 2)

The nested scenarios are NOT just "scope navigation on one chain" — they reflect the full cross-chain reality where the inner contract (B or C) must actually execute on its home chain.

### Why `executeL2TX` for L1 execution (Scenarios 2 & 3)?

`Rollups.sol` has no `executeIncomingCrossChainCall` (unlike `CrossChainManagerL2`). This is by design: **L1 always initiates L2 execution** — an L2 can receive execution from L1, but not the other way around. `executeL2TX` starts the L2 tx execution that interacts with L1.

How it works:
1. `postBatch` stores deferred entries with an L2TX action hash
2. `executeL2TX(rollupId, rlpEncodedTx)` builds an L2TX action, matches it
3. The matched entry's `nextAction` is a CALL → enters scope navigation
4. `_processCallAtScope` → proxy `executeOnBehalf` → actual execution

### Reentrant `executeCrossChainCall` in nested scenarios

In Scenarios 3 and 4, the inner contract (A or D) itself makes a cross-chain call during execution:
- **Scenario 3 Phase 1:** `executeL2TX` → runs A on L1 → A calls B' → this triggers a **reentrant** `executeCrossChainCall` inside the same transaction
- **Scenario 4 Phase 1:** `executeIncomingCrossChainCall` → runs D on L2 → D calls C' → this triggers a **reentrant** `executeCrossChainCall`

This means the execution table needs entries for BOTH the outer call AND the inner reentrant call. For example, Scenario 3 Phase 1 needs 3 `postBatch` entries:
1. `L2TX → CALL to A` (consumed by `executeL2TX`)
2. `CALL to B → RESULT(1)` (consumed inside the reentrant `executeCrossChainCall` when A calls B')
3. `RESULT(void from A) → terminal` (consumed after A.increment() returns)

### Sequential state deltas

When multiple entries consume L2 state (like Scenario 3 Phase 1), their state deltas must chain sequentially: S0→S1 for entry 1, S1→S2 for entry 2. `_findAndApplyExecution` checks that `currentState` matches the rollup's actual state at consumption time.

The `_etherDelta` transient storage is reset by each `_applyStateDeltas` call, so sequential entries with `etherDelta=0` work correctly even across reentrant calls.

### Void vs valued returns

- `Counter.increment()` returns `uint256` → RESULT data = `abi.encode(1)`
- `CounterAndProxy.increment()` returns void → RESULT data = `""` (empty bytes)

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
1. Alice calls proxy (A' or D') → `executeCrossChainCall` builds CALL#1 (outer, scope=[])
2. CALL#1 matches → returns CALL#2 (inner, scope=[0])
3. `_resolveScopes(CALL#2)` → `newScope([], CALL#2)` → child scope detected → `newScope([0], CALL#2)`
4. Scopes match → `_processCallAtScope` → proxy's `executeOnBehalf` → actual execution
5. RESULT matches → terminal → unwinds back to caller

## Visualizer presentation order logic

The visualizer (`visualizator/index.html`) shows steps sequentially. The order follows the **arrow direction** of each scenario, NOT a fixed "always L1 first" or "always L2 first" rule.

### Rules for determining step order

1. **Follow the arrows.** The `→` in the scenario flow tells you which chain the story starts on.
2. **Simple scenarios (S1, S2):** Show the initiating chain first, then the remote chain.
   - S1 `Alice → A (→ B') → B` [L1→L2]: L1 first (Alice calls A), then L2 (B executes)
   - S2 `Alice → D (→ C') → C` [L2→L1]: L2 first (Alice calls D), then L1 (C executes)
3. **Nested scenarios (S3, S4):** The "inner" execution (the chain in the middle of the arrows) must complete first, because its result gets pre-loaded into the "outer" chain's table. Then the "outer" chain consumes it via scope navigation.
   - S3 `Alice → A' (→ A → B') → B` [L2→L1→L2]: L1 first (A runs as inner), then L2 (Alice→A'→B as outer)
   - S4 `Alice → D' (→ D → C') → C` [L1→L2→L1]: L2 first (D runs as inner), then L1 (Alice→D'→C as outer)
4. **Within each chain phase:** setup (postBatch/loadTable) comes before execution (call/executeL2TX/executeIncoming).

### How to build future flows

For a new scenario with flow `X → Y → Z`:
1. Identify the chains: which chain does each entity (X, Y, Z) live on?
2. Identify the direction: the arrows tell you the conceptual order.
3. Determine execution phases: the "inner" cross-chain calls must execute first on their home chain, producing results that get loaded into the "outer" chain's table.
4. For each phase: first show table loading (postBatch on L1 / loadExecutionTable on L2), then show the execution that consumes those entries.
5. Show both execution tables at all times — entries appear when loaded, disappear when consumed.

## Open questions for future work

1. **Negative test cases:** Should we add tests for:
   - Wrong state delta (currentState doesn't match) → should revert with `ExecutionNotFound`
   - Wrong action hash (no matching entry) → should revert
   - Failed proof verification (set `verifier.setVerifyResult(false)`)
   - RESULT with `failed=true` → should revert with `CallExecutionFailed`

2. **ETH value transfers:** All current scenarios use `value=0`. Should we add scenarios that test:
   - `depositEther` + cross-chain calls with value
   - `etherDelta` accounting in state deltas
   - Negative ether delta (rollup sends ETH out)

3. **Deeper nesting:** Current nested tests go 2 levels deep (scope=[0]). Should we test:
   - 3+ levels of nesting (scope=[0,0])
   - Multiple sibling calls (scope=[0], scope=[1])
   - Mixed success/revert with `REVERT` and `REVERT_CONTINUE` actions

4. **Multiple rollups:** All tests use a single L2 rollup. Should we test cross-chain calls spanning 3+ rollups?

5. **Multiple entries in a batch:** Current tests post 1-2 entries per batch. Should we test batches with many entries, some immediate (actionHash=0) and some deferred?
