# Execution Table Specification

How to correctly build execution entries for L1 (`postBatch`) and L2 (`loadExecutionTable`).

---

## Action Types

| Type | When to use | rollupId | sourceRollup | destination | sourceAddress | data |
|------|------------|----------|--------------|-------------|---------------|------|
| **CALL** | Cross-chain call to another rollup | Target rollup (where call executes) | Caller's rollup (where call originates) | Contract being called | Address initiating the call | Calldata (selector + args) |
| **RESULT** | Return value from a CALL | Rollup that executed the CALL (= CALL's rollupId) | Always `0` | `address(0)` | `address(0)` | ABI-encoded return data |
| **L2TX** | Trigger an L2 transaction from L1 | Target L2 rollup ID | `MAINNET_ROLLUP_ID` (0) | `address(0)` | `address(0)` | RLP-encoded transaction |
| **REVERT** | Signal that a scoped call reverted | Rollup where revert happened | 0 | `address(0)` | `address(0)` | `""` |
| **REVERT_CONTINUE** | Continuation after a REVERT | Same as REVERT | 0 | `address(0)` | `address(0)` | `""` |

### CALL field rules

- `rollupId`: **always the target** — the rollup where this call will execute
- `sourceRollup`: **always the origin** — the rollup where this call was initiated
- `destination`: the contract address being called **on the target rollup**
- `sourceAddress`: the address that initiated the call **on the source rollup**
- `data`: the calldata (function selector + arguments). Can be empty for ETH transfers.
- `value`: ETH value sent with the call
- `scope`: empty `[]` for simple flows; non-empty only for reentrant cross-chain calls (see Scope section)

### RESULT field rules

- `rollupId`: **the rollup that executed the CALL** (= CALL's `rollupId`). The contract can enforce this: `require(action.rollupId == ROLLUP_ID)` in `_processCallAtScope`.
- `sourceRollup`: **always 0**
- `destination`: `address(0)`
- `sourceAddress`: `address(0)`
- `data`: ABI-encoded return data from the executed call
- `failed`: `true` if the call reverted, `false` if successful

Example: `CALL(rollupId=0, sourceRollup=1)` (L2 calling L1) produces `RESULT(rollupId=0, sourceRollup=0)` — the result was computed on rollup 0 (L1).

### L2TX field rules

- `rollupId`: the target L2 rollup ID (e.g., `1`)
- `sourceRollup`: always `MAINNET_ROLLUP_ID` (0) — L2TX is triggered from L1
- All address fields are `address(0)` — L2TX has no specific caller/destination
- `data`: RLP-encoded transaction bytes

### REVERT field rules

- `rollupId`: the rollup where the revert happened
- `scope`: **must match the scope level being reverted** — this is what triggers `ScopeReverted`. For example, `scope=[0]` reverts scope `[0]`.
- `destination`: `address(0)`
- `sourceAddress`: `address(0)`
- `sourceRollup`: `0`
- `data`: `""` (empty)
- `value`: `0`
- `failed`: `false`

A REVERT action only fires `ScopeReverted` when `scope` matches the current scope in `newScope()`. If the scope doesn't match (e.g., REVERT at `[]` while inside `newScope([0])`), execution breaks out of the current scope and the REVERT is handled at the matching level.

### REVERT_CONTINUE field rules

- `rollupId`: same as the REVERT's `rollupId`
- `failed`: **always `true`** — this is the key differentiator from other action types
- `scope`: always `[]` (empty) — continuation always happens at root level
- `destination`: `address(0)`
- `sourceAddress`: `address(0)`
- `sourceRollup`: `0`
- `data`: `""` (empty)
- `value`: `0`

REVERT_CONTINUE is looked up by `_getRevertContinuation()` inside the reverting scope, just before `ScopeReverted` is thrown. The action is deterministically constructed from `rollupId`, and its hash (`keccak256(abi.encode(action))`) is used to find the matching entry. On L1, the entry's `stateDeltas.currentState` must also match the rollup state at that moment (after any prior deltas in the reverted scope have been applied). On L2, only the action hash matters (no state deltas).

---

## Entry Structure

```solidity
struct ExecutionEntry {
    StateDelta[] stateDeltas;  // State root transitions for this step
    bytes32 actionHash;        // bytes32(0) = IMMEDIATE, otherwise hash of trigger action
    Action nextAction;         // What to do after consuming this entry
}
```

### IMMEDIATE entries (`actionHash == 0`)

Applied during `postBatch` without any trigger. Used for state commitments. Their `nextAction` is informational (not consumed).

### DEFERRED entries (`actionHash != 0`)

Stored in the execution table, consumed when the matching action hash is produced during execution. The `actionHash` is `keccak256(abi.encode(action))` of the trigger action.

### Terminal entries (self-referencing RESULT)

Every execution chain must end with a **terminal entry** where the trigger and the nextAction are the same RESULT:

```
actionHash:  keccak256(abi.encode(resultAction))
nextAction:  resultAction                         ← same action
```

When the execution produces this RESULT (e.g., after a CALL completes), its hash matches the entry's `actionHash`. The entry is consumed and returns the same RESULT as `nextAction`. Since the nextAction is a RESULT (not a CALL), execution stops — there's nothing left to resolve.

This is how the system knows the chain is done. Without a terminal entry, the last RESULT would have no matching entry and execution would revert with `ExecutionNotFound`.

Example (from L1→L2 simple):
```solidity
// Terminal entry: RESULT triggers itself
entries[1].actionHash = keccak256(abi.encode(resultAction));
entries[1].nextAction = resultAction;  // same object
```

### `executeIncomingCrossChainCall` does not consume from the table

Most entry points consume an entry: `executeCrossChainCall` builds a CALL and looks it up in the table (e.g., entry [0] in L1→L2 simple). `executeL2TX` builds an L2TX and looks it up (e.g., entry [0] in L2→L1 simple).

The exception is `executeIncomingCrossChainCall` (L2 only, system-called). It receives the call parameters directly, builds the CALL action, and enters `_resolveScopes` **without consuming any entry**. This is why the L2 table for L1→L2→L1 has no entry triggered by `CALL(L2, dest=D, from=Alice)` — that call is delivered directly by the system, not looked up from the table. Only the actions produced *inside* D's execution (nested calls, results) consume from the L2 table.

### Cross-chain action hash consistency

When the same logical action appears in both the L1 and L2 execution tables, it must have **identical hashes on both chains**. Every field matters — `actionType`, `rollupId`, `destination`, `value`, `data`, `failed`, `sourceAddress`, `sourceRollup`, `scope` — because the hash is `keccak256(abi.encode(action))` over the entire struct. If any field differs (even one byte of `data`), the hashes diverge and execution reverts with `ExecutionNotFound` on one side.

**What matches across chains:**

- **RESULT actions** always match. A RESULT represents the outcome of executing a call, and both chains must agree on it. Example: L1's `nextAction` is `RESULT(L2, data=<return>)` → L2 must have an entry triggered by the exact same RESULT.
- **Outer CALL actions** (scope `[]`) match. When `executeCrossChainCall` builds a CALL on one chain, the same CALL (same hash) appears on the other chain. Example: L2's `executeCrossChainCall` builds `CALL(MAINNET, C, from=D, sourceRollup=L2, scope=[])` → the same CALL appears in L1's table as a `nextAction` or trigger.

**What does NOT match across chains:**

- **Inner/nested CALL actions** have different scope on each chain. The `executeCrossChainCall` that produces the inner CALL always uses `scope=[]`. But the receiving chain's entry stores the inner CALL with `scope=[0]` (or deeper) for its own scope navigation. These are different hashes — each is consumed on its own chain only.

Example (L1→L2→L1):
```
L1 entry [0] next:    CALL(MAINNET, C, from=D, sourceRollup=L2, scope=[0])  ← for L1 scope nav
L2 entry [0] trigger: CALL(MAINNET, C, from=D, sourceRollup=L2, scope=[])   ← from executeCrossChainCall
                      Different hashes! Each consumed on its own chain.

L1 entry [1] trigger: RESULT(MAINNET, data=<C's return>)
L2 entry [0] next:    RESULT(MAINNET, data=<C's return>)
                      Same hash! Both chains agree on C's result.
```

The builder must simulate both chains to predict the exact return data, success/failure flags, and all other fields before constructing the tables.

---

## Transaction Model

### Per-block structure

Each block has at most:
1. **Setup tx**: `postBatch` (L1) or `loadExecutionTable` (L2) — loads the execution table
2. **Execution tx(s)**: One tx per cross-chain interaction that consumes entries

### 1-to-1 rule

Each user action produces **exactly 1 execution transaction per chain involved**:

- **L1→L2**: User calls proxy on L1 → `executeCrossChainCall` (1 tx on L1). System calls `executeIncomingCrossChainCall` on L2 (1 tx on L2). All nested calls between L1 and L2 are chained via `nextAction` within those same transactions.
- **L2→L1**: User calls proxy on L2 → `executeCrossChainCall` (1 tx on L2). System calls `executeL2TX` on L1 (1 tx on L1). All nested calls are chained via `nextAction`.

**Never** split a single cross-chain interaction into multiple execution transactions on the same chain.

---

## Flow Patterns

### L1→L2 (simple)

Alice on L1 calls a contract on L2.

**L1 execution table** (postBatch):
```
[0] DEFERRED   trigger: CALL(rollupId=L2, dest=B, from=Alice, sourceRollup=MAINNET)
                next:    RESULT(rollupId=L2, sourceRollup=0, data=<return>)
                         — state delta (L2 state transition)
```

(An IMMEDIATE entry for the initial state commit may also be included in the same batch.)

**L2 system call** (no table entry — delivered directly):
```
executeIncomingCrossChainCall(dest=B, value=0, data=<calldata>, sourceAddress=Alice, sourceRollup=MAINNET, scope=[])
```

**L2 execution table** (loadExecutionTable):
```
[0] DEFERRED   trigger: RESULT(rollupId=L2, sourceRollup=0, data=<B's return>)
                next:    RESULT(rollupId=L2, sourceRollup=0, data=<B's return>)  (terminal)
```

**L1 execution**: User calls proxy for B on L1 → `executeCrossChainCall` → consumes entry [0] → returns RESULT.

**L2 execution**: System calls `executeIncomingCrossChainCall` (see above) → builds CALL internally, enters `_resolveScopes` without consuming → executes B on L2 → RESULT consumed from table entry [0] → returns.

### L2→L1 (simple)

Alice on L2 calls a contract on L1.

**L1 execution table** (postBatch):
```
[0] DEFERRED   trigger: L2TX(rollupId=L2, data=<rlpTx>)
                next:    CALL(rollupId=MAINNET, dest=C, from=D, sourceRollup=L2)
                         — state delta (L2 state transition)
[1] DEFERRED   trigger: RESULT(rollupId=MAINNET, sourceRollup=0, data=<C's return>)
                next:    RESULT(rollupId=MAINNET, sourceRollup=0, data=<C's return>)  (terminal)
                         — state delta
```

(An IMMEDIATE entry for the initial state commit may also be included in the same batch.)

**L2 execution table** (loadExecutionTable):
```
[0] DEFERRED   trigger: CALL(rollupId=MAINNET, dest=C, from=D, sourceRollup=L2)
                next:    RESULT(rollupId=MAINNET, sourceRollup=0, data=<C's return>)
```

**L2 execution**: Alice calls D on L2 → D calls proxy for C → `executeCrossChainCall` → consumes table entry → returns RESULT.

**L1 execution**: System calls `executeL2TX(rollupId=L2, rlpTx)` → consumes entry [0] → CALL(C.increment()) executes on L1 → RESULT consumed from entry [1] → returns.

### L1→L2→L1 (nested, uses scope)

Alice on L1 calls D' (proxy for D on L2). D executes on L2 and calls C' (proxy for C on L1). C executes on L1 and returns.

**L1 execution table** (postBatch):
```
[0] DEFERRED   trigger: CALL(rollupId=L2, dest=D, from=Alice, sourceRollup=MAINNET)
                next:    CALL(rollupId=MAINNET, dest=C, from=D, sourceRollup=L2, scope=[0])
                         — state delta (L2 state transition)
[1] DEFERRED   trigger: RESULT(rollupId=MAINNET, data=<C's return>)
                next:    RESULT(rollupId=MAINNET, data=<C's return>)  (terminal)
                         — state delta
```

(An IMMEDIATE entry for the initial state commit may also be included in the same batch.)

**L2 system call** (no table entry — delivered directly):
```
executeIncomingCrossChainCall(dest=D, value=0, data=<incrementProxy>, sourceAddress=Alice, sourceRollup=MAINNET, scope=[])
```

**L2 execution table** (loadExecutionTable):
```
[0] DEFERRED   trigger: CALL(rollupId=MAINNET, dest=C, from=D, sourceRollup=L2)
                next:    RESULT(rollupId=MAINNET, data=<C's return>)
[1] DEFERRED   trigger: RESULT(rollupId=L2, data=<D's return>)
                next:    RESULT(rollupId=L2, data=<D's return>)  (terminal)
```

**L1 execution**: Alice calls D' proxy → `executeCrossChainCall` → consumes entry [0] → nextAction is CALL to C at scope `[0]` → `newScope([0])` navigates to C → C executes on L1 → RESULT consumed from entry [1] → returns.

**L2 execution**: System calls `executeIncomingCrossChainCall` (see above) → builds CALL(L2, D) internally, enters `_resolveScopes` without consuming → D executes, calls C' proxy → `executeCrossChainCall` → consumes entry [0] → returns RESULT. Then D returns → RESULT consumed from entry [1] (terminal).

**Cross-chain hash matches**:
- `RESULT(rollupId=MAINNET, data=<C's return>)` — L1 entry [1] trigger = L2 entry [0] next ✓

**Scope difference for inner CALL**: L1 entry [0] next is `CALL(MAINNET, C, scope=[0])` (scope added for L1 scope navigation). L2 entry [0] trigger is `CALL(MAINNET, C, scope=[])` (produced by L2's `executeCrossChainCall`, which always uses empty scope). Different hashes — each consumed on its own chain.

### L2→L1→L2 (nested, uses scope)

Alice on L2 calls A' (proxy for A on L1). A executes on L1 and calls B' (proxy for B on L2). B executes on L2 and returns.

**L1 execution table** (postBatch):
```
[0] DEFERRED   trigger: L2TX(rollupId=L2, data=<rlpTx>)
                next:    CALL(rollupId=MAINNET, dest=A, from=Alice, sourceRollup=L2, scope=[])
                         — state delta S0→S1
[1] DEFERRED   trigger: CALL(rollupId=L2, dest=B, from=A, sourceRollup=MAINNET, scope=[])
                next:    RESULT(rollupId=L2, data=<B's return>)
                         — state delta S1→S2
[2] DEFERRED   trigger: RESULT(rollupId=MAINNET, data=<A's return>)
                next:    RESULT(rollupId=MAINNET, data=<A's return>)  (terminal)
                         — state delta S2→S3
```

(An IMMEDIATE entry for the initial state commit may also be included in the same batch.)

**L2 execution table** (loadExecutionTable):
```
[0] DEFERRED   trigger: CALL(rollupId=MAINNET, dest=A, from=Alice, sourceRollup=L2)
                next:    CALL(rollupId=L2, dest=B, from=A, sourceRollup=MAINNET, scope=[0])
[1] DEFERRED   trigger: RESULT(rollupId=L2, data=<B's return>)
                next:    RESULT(rollupId=L2, data=<B's return>)  (terminal)
```

**L1 execution**: System calls `executeL2TX(rollupId=L2, rlpTx)` → consumes entry [0] → CALL to A at scope `[]` → A executes, calls B' proxy → reentrant `executeCrossChainCall` produces CALL to B → consumes entry [1] via `_findAndApplyExecution` → returns RESULT(B) → A completes → RESULT(A) consumed from entry [2] (terminal).

**L2 execution**: Alice calls A' proxy on L2 → `executeCrossChainCall` → consumes entry [0] → nextAction is CALL to B at scope `[0]` → `newScope([0])` processes B → B executes → RESULT consumed from entry [1] (terminal).

**Cross-chain hash matches** (same action, same hash on both chains):
- `CALL(MAINNET, A, from=Alice, sourceRollup=L2, scope=[])` — L1 entry [0] next = L2 entry [0] trigger ✓
- `RESULT(L2, data=<B's return>)` — L1 entry [1] next = L2 entry [1] trigger ✓

**Scope difference for inner CALL**: L1 entry [1] trigger is `CALL(L2, B, scope=[])` (produced by L1's reentrant `executeCrossChainCall`, which always uses empty scope). L2 entry [0] next is `CALL(L2, B, scope=[0])` (scope added for L2's own scope navigation). These are different hashes — each is consumed on its own chain only.

### Revert flow (scoped call reverts)

A scoped call can be reverted by the protocol via REVERT/REVERT_CONTINUE actions. This is different from a Solidity-level revert (see Atomicity section).

Example: `executeL2TX` triggers a CALL at scope `[0]`, the call executes successfully, but the protocol decides to revert that scope.

**L1 execution table** (postBatch):
```
[0] DEFERRED   trigger: L2TX(rollupId=X, data=<rlpTx>)
                next:    CALL(rollupId=X, dest=target, scope=[0])
                         — state delta S0→S1
[1] DEFERRED   trigger: RESULT(rollupId=X, data=<return>)
                next:    REVERT(rollupId=X, scope=[0])
                         — state delta S1→S2
[2] DEFERRED   trigger: REVERT_CONTINUE(rollupId=X, failed=true)
                next:    RESULT (final)
                         — state delta S2→S3
```

**Flow**:
1. `executeL2TX` → consumes entry [0] → CALL at scope `[0]`
2. `newScope([0])` processes the CALL → target executes → RESULT produced
3. RESULT consumes entry [1] → nextAction is REVERT at scope `[0]`
4. REVERT scope matches current scope → `_getRevertContinuation()` looks up the REVERT_CONTINUE entry [2] and encodes the continuation action
5. `revert ScopeReverted(encodedAction, stateRoot=S2, rollupId=X)` is thrown — the EVM reverts all state changes in this call frame, including entry [2]'s consumption (swap-and-pop) and its state delta application. Entry [2] remains in the table after the revert.
6. Parent `newScope([])` catches `ScopeReverted` → `_handleScopeRevert` decodes the continuation action from the revert data and restores rollup state to S2 (the stateRoot carried in the error)
7. Execution continues with the decoded continuation action's `nextAction` (final RESULT)

**Important**: Entry [2]'s `currentState` must be S2 (the state after entry [1]'s deltas) because `_getRevertContinuation` runs inside the reverting scope where those deltas are still applied. Although the EVM revert rolls back the entry consumption, the continuation action survives via the `ScopeReverted` error data. After the catch, `_handleScopeRevert` restores the rollup state to S2 — the state captured just before the revert.

**REVERT at parent scope**: A REVERT can target a scope higher than the current one. For example, REVERT at `[]` while inside `newScope([0])` — the REVERT doesn't match scope `[0]`, so execution breaks out, and it's caught at the root level.

### Same action executed multiple times

When the same proxy call happens N times in a single transaction (e.g., a contract calling B' twice), all N calls produce the same action hash. On L1, entries are differentiated by their state deltas — each entry's `currentState` must match the rollup state at the time of that specific call.

**L1 execution table** (postBatch):
```
[0] DEFERRED   trigger: CALL(rollupId=L2, dest=B, from=E, sourceRollup=MAINNET)   ← same hash
                next:    RESULT(rollupId=L2, data=<first return>)
                         — state delta S0→S1
[1] DEFERRED   trigger: CALL(rollupId=L2, dest=B, from=E, sourceRollup=MAINNET)   ← same hash
                next:    RESULT(rollupId=L2, data=<second return>)
                         — state delta S1→S2
```

First call: rollup state is S0 → matches entry [0] (currentState=S0) → applies S0→S1.
Second call: rollup state is now S1 → matches entry [1] (currentState=S1) → applies S1→S2.

**On L2**: Entries have no state deltas, so identical action hashes cannot be differentiated by state. `_consumeExecution` uses a linear scan and takes the first match. However, entries are deleted via swap-and-pop (the last entry fills the consumed slot), so ordering is not strictly preserved after the first consumption. In practice, the builder must ensure that entries with the same action hash have distinguishable `nextAction` values, or that the consumption order doesn't matter.

### Continuation (RESULT → CALL)

Normally, a RESULT ends execution (either terminal or consumed by scope navigation). But a RESULT can map to a CALL as its `nextAction` — this is a **continuation**. The continuation CALL executes immediately in the same transaction.

Used when a single `executeIncomingCrossChainCall` needs to trigger multiple sequential operations (e.g., a flash loan flow: receive tokens → claim NFT → bridge back).

**L2 execution table** (loadExecutionTable):
```
[0] DEFERRED   trigger: RESULT(rollupId=L2, data="")
                next:    CALL(rollupId=L2, dest=B, from=executor, sourceRollup=MAINNET)  ← continuation
[1] DEFERRED   trigger: CALL(rollupId=MAINNET, dest=bridge, from=B, sourceRollup=L2)
                next:    RESULT(rollupId=MAINNET, data="")
[2] DEFERRED   trigger: RESULT(rollupId=L2, data="")
                next:    RESULT(rollupId=L2, data="")  (terminal)
```

**Flow**: First call completes → RESULT consumed from entry [0] → nextAction is CALL B (continuation) → B executes, calls proxy for bridge → CALL consumed from entry [1] → B returns → RESULT consumed from entry [2] (terminal).

---

## Scope

Scope tracks nesting depth for reentrant cross-chain calls.

### When scope is empty (`[]`)

Simple flows: L1→L2 or L2→L1 with no reentrant calls. This covers most cases.

### When scope is non-empty

Only when an execution on one chain triggers **another cross-chain call** back to the other chain. Each level of reentrance adds one element to the scope array.

Example (L1→L2→L1):
- Root call: Alice on L1 calls D on L2 → scope `[]`
- D on L2 calls C on L1 (reentrant) → scope `[0]`
- If C on L1 called back to L2 again → scope `[0, 0]`

The scope array enables `newScope()` to navigate the call tree and isolate reverts per scope level.

### Sibling scopes

When multiple scoped calls happen sequentially (not nested), they use sibling scope indices: `[0]`, `[1]`, `[2]`, etc.

Example: `executeL2TX` triggers two calls — first at scope `[0]`, then at scope `[1]`.

**L1 execution table** (postBatch):
```
[0] DEFERRED   trigger: L2TX(rollupId=X, data=<rlpTx>)
                next:    CALL(rollupId=X, dest=target, data=setValue(100), scope=[0])
                         — state delta S0→S1
[1] DEFERRED   trigger: RESULT(rollupId=X, data=<return>)
                next:    CALL(rollupId=X, dest=target, data=setValue(200), scope=[1])
                         — state delta S1→S2
[2] DEFERRED   trigger: RESULT(rollupId=X, data=<return>)
                next:    RESULT (final)
                         — state delta S2→S3
```

**Flow**: `newScope([])` sees CALL at `[0]` is a child → recurses into `newScope([0])` → first CALL executes → RESULT → nextAction is CALL at `[1]` → `newScope([0])` sees `[1]` is a sibling (not child) → breaks, returns CALL at `[1]` → back in `newScope([])`, sees `[1]` is a child → recurses into `newScope([1])` → second CALL executes → RESULT → final.

Note: both entries [1] and [2] may share the same `actionHash` (same RESULT) — they're differentiated by `currentState` in their state deltas (S1 vs S2).

---

## State Deltas

```solidity
struct StateDelta {
    uint256 rollupId;      // Which rollup's state changes
    bytes32 currentState;  // Expected state root before this step
    bytes32 newState;      // State root after this step
    int256 etherDelta;     // Signed ETH change for this rollup
}
```

### State delta chaining

In multi-entry flows, state deltas chain sequentially: each entry's `currentState` must equal the previous entry's `newState`. This forms an unbroken chain: S0→S1→S2→S3.

If an entry's `currentState` doesn't match the rollup's current on-chain state at consumption time, the entry won't match and execution reverts with `ExecutionNotFound`.

### Ether bridging (etherDelta)

`etherDelta` is a signed `int256`:
- **Positive**: the rollup receives ETH (e.g., bridging ETH from L1 to L2)
- **Negative**: the rollup sends ETH
- **Zero**: no ETH movement (most common)

Example — bridging 1 ETH to L2:
```solidity
stateDeltas[0] = StateDelta({
    rollupId: L2_ROLLUP_ID,
    currentState: currentState,
    newState: newState,
    etherDelta: 1 ether  // L2 rollup receives 1 ETH
});
```

On L1, `_applyStateDeltas` verifies that the sum of all ether deltas across all state deltas in an entry matches the actual ETH flow (tracked via transient storage `_etherDelta`). `msg.value` from proxy calls adds to the accumulator; ETH **successfully** sent via CALL subtracts from it (failed calls don't decrement).

On L2, there is no ether accounting — ETH sent to `executeCrossChainCall` is burned by sending it to `SYSTEM_ADDRESS`.

---

## L2 vs L1 Entries

| | L1 (Rollups) | L2 (CrossChainManagerL2) |
|---|---|---|
| **How loaded** | `postBatch` with ZK proof | `loadExecutionTable` by SYSTEM address |
| **State deltas** | Required — `currentState` verified against on-chain rollup state | Not used — empty by convention (`new StateDelta[](0)`). The L2 contract ignores `stateDeltas` entirely. |
| **Matching logic** | `_findAndApplyExecution`: checks actionHash AND all state delta `currentState` values | `_consumeExecution`: checks actionHash only (first match wins) |
| **Ether accounting** | Verified via transient `_etherDelta` accumulator | None — ETH burned to SYSTEM_ADDRESS |
| **Same action hash** | Differentiated by `currentState` in state deltas | Consumed in insertion order (first match) |
| **Revert state restore** | `_handleScopeRevert` restores `stateRoot` from `ScopeReverted` error data | No state to restore — only continuation action matters |

### Atomicity via Solidity revert

If the calling contract reverts at the Solidity level (e.g., `require()` failure, `revert("...")"`), the entire EVM transaction reverts — all consumed entries, all state delta applications, everything rolls back. This is **different** from the protocol's REVERT action, which selectively reverts a single scope while allowing execution to continue.

This provides atomicity for multi-step operations: if any step fails unexpectedly, the whole transaction is as if it never happened.

---

## Don'ts

### Never use the system address as sourceAddress on L1

The system address (e.g., `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` in dev) should only appear on L2 (for `loadExecutionTable`, `executeIncomingCrossChainCall`). On L1, cross-chain calls come from actual users or contracts, never the system.

If you see the system address as `sourceAddress` in a `CrossChainCallExecuted` event on L1, it's a bug.

### Never split nested calls into separate transactions

If a cross-chain flow involves nested calls (e.g., L1→L2→L1), all steps must be chained via `nextAction` within the execution entries. The execution resolves in **1 transaction per chain**, not multiple separate transactions.

Wrong:
```
TX1 on L1: Alice → proxy → executeCrossChainCall (CALL to L2)
TX2 on L1: system → executeL2TX (reentrant CALL back from L2)  ← WRONG: separate tx
```

Right:
```
TX1 on L1: Alice → proxy → executeCrossChainCall
  → entry consumed, nextAction = CALL(to L2)
  → scope navigation handles reentrant CALL back from L2
  → all nested calls resolve within this single tx
```

### Never use CrossChainCall as the L2→L1 trigger on L1

For L2→L1 flows, L1 execution starts with `executeL2TX`, **not** by calling a proxy. The trigger action is `L2TX`, not `CALL`. The system must not route L2 user transactions through L1 proxies as if they were L1-initiated calls.

### Consistent rollupId semantics for CALL

- On CALL actions: `rollupId` = **target** (where the call executes), `sourceRollup` = **origin** (where the call was initiated)
- On RESULT actions: `rollupId` = **the rollup that executed** (same as the CALL's rollupId), `sourceRollup` = always 0
- On L2TX actions: `rollupId` = **target L2**, `sourceRollup` = MAINNET (0)
- Never use `rollupId` to mean "origin" — that's what `sourceRollup` is for (on CALL and L2TX only)
