# Execution Entry Construction Rules

This is the authoritative reference for building `ExecutionEntry` structs. Every E2E test must construct entries that conform to `docs/EXECUTION_TABLE_SPEC.md` — when in doubt, the spec wins.

## Action Types Reference

| Type | rollupId | destination | sourceAddress | sourceRollup | data | scope |
|------|----------|-------------|---------------|--------------|------|-------|
| CALL | Target rollup (where call executes) | Target contract | Immediate caller (proxy address on source chain) | Caller's rollup (where call originates) | Calldata (selector + args) | `[]` or `[N]` for nested |
| RESULT | Same as triggering CALL's rollupId | `address(0)` | `address(0)` | `0` | ABI-encoded return data, or `""` | `[]` |
| L2TX | Target L2 rollup ID | `address(0)` | `address(0)` | `MAINNET_ROLLUP_ID` (0) | RLP-encoded signed tx | `[]` |
| REVERT | Rollup where revert happened | `address(0)` | `address(0)` | `0` | `""` | Scope being reverted (e.g. `[0]`) |
| REVERT_CONTINUE | Same as REVERT | `address(0)` | `address(0)` | `0` | `""` | `[]` |

### Critical field rules

- **CALL.rollupId** is the TARGET, not the origin. `CALL(rollupId=L2)` means the call executes on L2.
- **CALL.sourceAddress** is the proxy address on the calling chain, not the original contract address. This is the `msg.sender` as seen by the manager's `executeCrossChainCall`.
- **RESULT.rollupId** must match the CALL.rollupId that produced it. The contract enforces: `resultAction.rollupId = action.rollupId` in `_processCallAtScope`.
- **REVERT_CONTINUE.failed** is always `true` — this distinguishes it from other action types.
- **L2TX.sourceRollup** is always `MAINNET_ROLLUP_ID` (0) — L2TX is triggered from L1.

## Entry Construction by Pattern

### Simple L1 -> L2

**L1 entries (1):**
```
[0] trigger: CALL(L2, target, from=caller, sourceRollup=MAINNET)
    next:    RESULT(L2, data=returnValue)
    deltas:  [{L2, s0→s1}]
```

**L2 entries (1):**
```
[0] trigger: RESULT(L2, data=returnValue)  [terminal, self-ref]
    next:    RESULT(L2, data=returnValue)
```

L2 execution: `executeIncomingCrossChainCall(target, 0, data, caller, MAINNET, [])`.

The L2 terminal is self-referencing because nothing follows the result — execution just ends.

---

### Simple L2 -> L1

**L1 entries (2):**
```
[0] trigger: L2TX(L2, rlpTx)
    next:    CALL(MAINNET, target, from=user, sourceRollup=L2)
    deltas:  [{L2, s0→s1}]

[1] trigger: RESULT(MAINNET, data=returnValue)
    next:    RESULT(L2, data="")  [terminal]
    deltas:  [{L2, s1→s2}]
```

**L2 entries (1):**
```
[0] trigger: CALL(MAINNET, target, from=user, sourceRollup=L2, scope=[])
    next:    RESULT(MAINNET, data=returnValue)
```

L2 execution: user calls proxy directly.

Note the terminal on L1 maps `RESULT(MAINNET, ...)` to `RESULT(L2, data="")`. The outer call on L2 was void, so the terminal carries empty data. The rollupId flips because the L2TX flow terminates back to L2.

---

### Nested L1 -> L2 -> L1

**L1 entries (2):**
```
[0] trigger: CALL(L2, CAP2, from=caller, sourceRollup=MAINNET)
    next:    CALL(MAINNET, targetL1, from=CAP2, sourceRollup=L2, scope=[0])
    deltas:  [{L2, s0→s1}]

[1] trigger: RESULT(MAINNET, data=innerReturn)
    next:    RESULT(L2, data=outerReturn)  [maps inner→outer]
    deltas:  [{L2, s1→s2}]
```

**L2 entries (2):**
```
[0] trigger: CALL(MAINNET, targetL1, from=CAP2, sourceRollup=L2, scope=[])
    next:    RESULT(MAINNET, data=innerReturn)

[1] trigger: RESULT(L2, data=outerReturn)  [terminal, self-ref]
    next:    RESULT(L2, data=outerReturn)
```

Key points:
- L1 entry [0] nextAction has `scope=[0]` — this tells L1's scope navigation to recurse.
- L2 entry [0] trigger has `scope=[]` — `executeCrossChainCall` always produces empty scope.
- These are DIFFERENT hashes (inner CALL on L1 vs L2) — each consumed on its own chain.
- L1 entry [1] maps inner RESULT to outer RESULT — the caller on L1 receives the outer call's return, not the nested call's.

---

### Nested L2 -> L1 -> L2

**L1 entries (3):**
```
[0] trigger: L2TX(L2, rlpTx)
    next:    CALL(MAINNET, CAP1, from=user, sourceRollup=L2)
    deltas:  [{L2, s0→s1}]

[1] trigger: CALL(L2, targetL2, from=CAP1, sourceRollup=MAINNET)
    next:    RESULT(L2, data=innerReturn)
    deltas:  [{L2, s1→s2}]

[2] trigger: RESULT(MAINNET, data=outerReturn)
    next:    RESULT(L2, data="")  [terminal]
    deltas:  [{L2, s2→s3}]
```

**L2 entries (2):**
```
[0] trigger: CALL(MAINNET, CAP1, from=user, sourceRollup=L2, scope=[])
    next:    CALL(L2, targetL2, from=CAP1, sourceRollup=MAINNET, scope=[0])

[1] trigger: RESULT(L2, data=innerReturn)
    next:    RESULT(MAINNET, data=outerReturn)
```

Note the L2 terminal is on L1 (entry [2]), not on L2. L2 entries just chain through the nested call and map the inner result to the outer result.

---

### Multicall (same target, N times)

**L1 entries (N):**
All share the same actionHash. Differentiated by state deltas (currentState).
```
[0] trigger: CALL(L2, target, ...), deltas: s0→s1, next: RESULT(data=1)
[1] trigger: CALL(L2, target, ...), deltas: s1→s2, next: RESULT(data=2)
...
```

**L2 entries (N, chained):**
```
[0] trigger: RESULT(data=1), next: CALL(target) [chains to next call]
[1] trigger: RESULT(data=2), next: RESULT(data=2) [terminal]
```

For L1-starting: only ONE `executeIncomingCrossChainCall` — chaining handles the rest. The first call's RESULT triggers the next CALL via the L2 table's nextAction.

---

### Multicall (different targets)

**L1 entries (N):** Different actionHashes (different targets/calldata).

**L2 entries (N, chained):**
```
[0] trigger: RESULT(data=A_return), next: CALL(targetB) [chains]
[1] trigger: RESULT(data=B_return), next: RESULT(data=B_return) [terminal]
```

Same chaining mechanism as same-target multicall, just with different actionHashes on L1.

---

### Multicall + Nested (L1-starting)

Combines multicall chaining with nested scope entries.

**L1 entries (2*nested_calls + simple_calls):**
Each nested call produces 2 entries (CALL→scoped CALL, RESULT→RESULT).
Each simple call produces 1 entry (CALL→RESULT).

**L2 entries:** Nested call entries + chaining entries + terminal.
- Nested inner calls: CALL(scope=[])→RESULT
- Chaining: RESULT(void)→CALL(next target)
- Terminal: RESULT→RESULT (self-ref)

---

## Static Call Patterns

### L1→L2 top-level static read

No ExecutionEntries on either side. One `StaticCall` entry on L1.

**L1 entries:** none
**L2 entries:** none
**L1 StaticCall table (1):**
```
StaticCall({
    actionHash: keccak256(abi.encode(Action({CALL, rollupId=L2, dest=target, value=0,
        data=selector, failed=false, isStatic=true,
        sourceAddr=<caller contract>, sourceRollup=MAINNET, scope=[]}))),
    returnData: abi.encode(<expected value>),
    failed: false, calls: [], rollingHash: 0, stateRoots: []
})
```

User STATICCALLs a proxy on L1 → proxy detects static via TSTORE probe → routes to `Rollups.staticCallLookup` → matches → returns `returnData`. L2 is uninvolved.

`sourceAddress` = the contract that STATICCALLs the proxy (the `msg.sender` the proxy sees), NOT the Batcher.

Reference: `script/e2e/staticCall/E2E.s.sol`

---

### L2→L1 static read (via executeL2TX)

Follows the L2-starting (`counterL2`) pattern but with `isStatic=true` on the L1 CALL nextAction.

**L1 entries (2):**
```
[0] trigger: L2TX(L2, rlpTx)
    next:    CALL(MAINNET, target, isStatic=true, from=callerL2, sourceRollup=L2, scope=[])
    deltas:  [{L2, s0→s1}]

[1] trigger: RESULT(MAINNET, data=returnValue)
    next:    RESULT(L2, data="")  [terminal]
    deltas:  [{L2, s1→s2}]
```

**L2 execution entries:** none

**L2 StaticCall table (1):**
```
StaticCall({
    actionHash: keccak256(abi.encode(Action({CALL, rollupId=MAINNET, dest=target, value=0,
        data=selector, failed=false, isStatic=true,
        sourceAddr=callerL2, sourceRollup=L2, scope=[]}))),
    returnData: abi.encode(<expected value>),
    failed: false, calls: [], rollingHash: 0, stateRoots: []
})
```

**No StaticCall table on L1** — the admin path resolves the call directly.

On L1, `_processCallAtScope` calls `sourceProxy.staticcall(executeOnBehalf(dest, data))`. The proxy takes the **admin path** (`msg.sender == MANAGER`) and forwards directly — no TSTORE probe, no `staticCallLookup`. The target runs natively on L1.

On L2, the user STATICCALLs the proxy → proxy detects static via TSTORE probe → routes to `CrossChainManagerL2.staticCallLookup` → matches the `StaticCall` entry → returns `returnData`. The commitment rides on the L2TX entry's proof obligation on L1.

Reference: `script/e2e/staticCallL2/E2E.s.sol`

---

### Nested static call (inside a regular CALL or executeL2TX)

When a CALL action's `nextAction` has `isStatic=true`, `_processCallAtScope` on the executing chain dispatches via STATICCALL to the source proxy's `executeOnBehalf`. This takes the **admin path** — `msg.sender == MANAGER` — and forwards directly to the destination. No `staticCallLookup` involved on the executing side. The destination runs natively under the STATICCALL flag.

**Key differences from top-level static:**
- No `StaticCall` table entry needed on the chain where scope navigation runs — the admin path resolves directly.
- The RESULT from a nested static call is built normally (`isStatic=false` on RESULT) and consumed from the **execution table**, not the static table.
- `_etherDelta` is not touched (no value transfer under STATICCALL).

**When a nested static call also crosses chains** (e.g., L1 scope navigation STATICCALLs a destination that lives on L2), the destination proxy's `executeOnBehalf` uses the admin path on the chain where it runs. If the destination needs data from the OTHER chain, that inner hop is yet another static entry — but at the admin-path level it's always a direct forward.

**All proxies must be pre-deployed before any static call executes.** In non-static flows, `_processCallAtScope` auto-creates missing proxies via `_createCrossChainProxyInternal` (CREATE2) on-the-fly. This does NOT work for static calls because STATICCALL forbids CREATE2 — the auto-create path reverts. Every proxy that will be touched during a nested static call's execution must already exist on-chain.

This applies to:
- The **source proxy** used by `_processCallAtScope` (`computeCrossChainProxyAddress(action.sourceAddress, action.sourceRollup)`).
- Any **destination proxies** the target contract calls internally — if the target view function crosses another proxy boundary, that proxy must exist too.
- Any proxies referenced by `StaticSubCall` entries in the flatten sub-call replay (`_processNStaticCalls` reverts `ProxyNotDeployed` if `sourceProxy.code.length == 0`).

**Always deploy proxies in the Deploy phase** — use `getOrCreateProxy(manager, originalAddress, originalRollupId)` for every `(address, rollupId)` pair that could be touched. The lookup is `view` and cannot CREATE2; the scope execution under STATICCALL cannot CREATE2 either.

For L2→L1 static flows via `executeL2TX`, the source proxy needed on L1 is for `(ValueReaderL2, L2_ROLLUP_ID)` — deploy it in a `Deploy2` step on L1 (see the counterL2 pattern).

Reference: `script/e2e/nestedStaticCall/E2E.s.sol`

---

## Revert Patterns

### Terminal failure (call fails, caller fails too)

```
L1: [0] trigger: CALL(...) → next: RESULT(failed=true, data=<revert data>)
L2: [0] trigger: RESULT(failed=true, ...) → next: RESULT(failed=true, ...) [terminal, self-ref]
```

Both sides see failure. `executeCrossChainCall` reverts with `CallExecutionFailed`.

**L2TX cannot end with a failed RESULT** — `executeL2TX` must not fail. If an inner call within L2TX fails, use REVERT_CONTINUE instead.

### Failed inner call without REVERT_CONTINUE (executeCrossChainCall only)

When a scoped call fails inside `executeCrossChainCall` (NOT `executeL2TX`), no state deltas were committed:
```
[0] trigger: CALL(L2, D, scope=[]) → next: CALL(MAINNET, RC, scope=[0])
[1] trigger: RESULT(MAINNET, failed=true) → next: RESULT(L2, failed=false, data="")
```

The EVM already rolled back RC's effects when it reverted. Parent continues with success.

### REVERT_CONTINUE (committed state must be undone)

Used when a scope has committed state deltas (successful cross-chain calls) that need rolling back:
```
[0] trigger: L2TX(...) → next: CALL(MAINNET, Counter, scope=[0,0])  [S0→S1]
[1] trigger: RESULT(MAINNET, ok) → next: REVERT(L2, scope=[0])     [S1→S2]
[2] trigger: REVERT_CONTINUE(L2, failed=true) → next: RESULT(L2, ok, data=3) [terminal] [S2→S3]
```

Entry [2]'s currentState must be S2 (the state after entry [1]'s deltas) because `_getRevertContinuation` runs inside the reverting scope where those deltas are still applied.

---

## State Delta Rules

1. **Chain correctly**: `newState[N] = currentState[N+1]` — every entry's currentState must match the previous entry's newState for the same rollup
2. **All deltas track L2 rollup state** for cross-chain calls (even when the call executes on L1)
3. **L2 entries have NO state deltas**: always `new StateDelta[](0)` — L2 does not track state roots
4. **Use descriptive state names**: `keccak256("l2-initial-state")`, `keccak256("l2-state-<test>-step1")`, etc.
5. **Sum of etherDelta must be zero** for immediate entries within a batch
6. **etherDelta accounting**: positive = rollup receives ETH, negative = rollup sends ETH, zero = no ETH movement

## Hash Differentiation Rules

### Same actionHash on L1
Entries with identical actionHash are differentiated by `currentState` in their state deltas. The `_findAndApplyExecution` function checks that all deltas' `currentState` match the rollup's current `stateRoot`.

### Same actionHash on L2
Entries are consumed by `_consumeExecution` in **insertion order** (linear scan, first match consumed by setting `actionHash = 0`). Insertion order in the L2 table must match execution order.

## Scope Rules

- `scope = []` (empty): root-level call, no nesting
- `scope = [0]`: first child scope (one level of nesting)
- `scope = [0, 0]`: nested within first child scope (two levels)
- `scope = [0], [1]`: sibling scopes (sequential calls at same depth)

On the **sending chain**, `executeCrossChainCall` always produces `scope=[]`.
On the **receiving chain**, the entry's nextAction CALL uses the scope for navigation (`[0]`, `[0,0]`, etc.).

These produce DIFFERENT hashes — each is consumed on its own chain only.

## Terminal Entry Rules

Every execution chain MUST end with a RESULT action (not a CALL).

**L1-starting:** Terminal on L2 is self-referencing: `trigger=RESULT(X), next=RESULT(X)`.
**L2-starting:** Terminal on L1 is: `trigger=RESULT(...), next=RESULT(L2, data="")` (the terminalResult pattern). The terminal rollupId is L2 because the outer call came from L2.

**Nested flows:** Terminal maps inner result to outer result. The trigger is the nested call's RESULT; the nextAction is the outer call's RESULT (different rollupId and/or data). Without this mapping, the caller never receives a RESULT for the outer CALL.

## RESULT rollupId Rule

The RESULT's `rollupId` matches the CALL's `rollupId` that triggered it. This is because `_processCallAtScope` builds: `resultAction.rollupId = action.rollupId`.

Example: `CALL(rollupId=0, sourceRollup=1)` (L2 calling L1) produces `RESULT(rollupId=0)` — the result was computed on rollup 0 (L1).

## Cross-Chain Hash Consistency

- **RESULT actions**: **same hash** on both chains (both agree on the outcome)
- **Outer CALL actions** (scope=[]): **same hash** on both chains (produced by `executeCrossChainCall` which always uses empty scope)
- **Inner CALL actions**: **different hashes** (scope=[0] on receiving chain, scope=[] on sending chain)

Every field matters in the hash — `keccak256(abi.encode(action))` covers the entire struct. If any field differs (even one byte of `data`), the hashes diverge and execution reverts with `ExecutionNotFound`.

## `executeIncomingCrossChainCall` Does NOT Consume From the Table

This is a common source of confusion. For L1-starting flows, the system calls `executeIncomingCrossChainCall` on L2 which builds the CALL internally and enters `_resolveScopes` **without consuming any entry**. Only the actions produced *inside* the target contract's execution (nested calls, results) consume from the L2 table.

This is why the L2 table for L1→L2 simple has no entry triggered by `CALL(L2, dest=B, from=Alice)` — that call is delivered directly by the system.

## Don'ts (from the spec)

1. **Never use the system address as sourceAddress on L1** — system address is L2-only. If it appears in a `CrossChainCallExecuted` event on L1, it's a bug.
2. **Never split nested calls into separate transactions** — all steps must chain via `nextAction` in 1 tx per chain.
3. **Never use CrossChainCall as the L2→L1 trigger on L1** — L2→L1 starts with `executeL2TX`, not a proxy call. The trigger is L2TX, not CALL.
4. **Never confuse rollupId semantics** — on CALL: rollupId=target, sourceRollup=origin. On RESULT: rollupId=the chain that executed. Never use rollupId to mean "origin".
