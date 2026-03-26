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
[0] IMMEDIATE  — state commit
[1] DEFERRED   trigger: CALL(rollupId=L2, dest=B, from=Alice, sourceRollup=MAINNET)
                next:    RESULT(rollupId=L2, sourceRollup=0, data=<return>)
```

**L2 execution table** (loadExecutionTable):
```
[0] DEFERRED   trigger: RESULT(rollupId=L2, sourceRollup=0, data=<B's return>)
                next:    RESULT(rollupId=L2, sourceRollup=0, data=<B's return>)  (terminal)
```

**L1 execution**: User calls proxy for B on L1 → `executeCrossChainCall` → consumes entry [1] → returns RESULT.

**L2 execution**: System calls `executeIncomingCrossChainCall(dest=B, sourceAddress=Alice, sourceRollup=MAINNET)` → executes B on L2 → RESULT consumed from table → returns.

### L2→L1 (simple)

Alice on L2 calls a contract on L1.

**L1 execution table** (postBatch):
```
[0] IMMEDIATE  — state commit
[1] DEFERRED   trigger: L2TX(rollupId=L2, data=<rlpTx>)
                next:    CALL(rollupId=MAINNET, dest=C, from=D, sourceRollup=L2)
[2] DEFERRED   trigger: RESULT(rollupId=MAINNET, sourceRollup=0, data=<C's return>)
                next:    RESULT(rollupId=MAINNET, sourceRollup=0, data=<C's return>)  (terminal)
```

**L2 execution table** (loadExecutionTable):
```
[0] DEFERRED   trigger: CALL(rollupId=MAINNET, dest=C, from=D, sourceRollup=L2)
                next:    RESULT(rollupId=MAINNET, sourceRollup=0, data=<C's return>)
```

**L2 execution**: Alice calls D on L2 → D calls proxy for C → `executeCrossChainCall` → consumes table entry → returns RESULT.

**L1 execution**: System calls `executeL2TX(rollupId=L2, rlpTx)` → consumes entry [1] → CALL(C.increment()) executes on L1 → RESULT consumed from entry [2] → returns.

### L1→L2→L1 (nested, uses scope)

Alice on L1 calls D on L2, D calls C on L1 (reentrant cross-chain).

This requires **scope** because the L2 execution triggers another cross-chain call back to L1. See Scope section.

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
