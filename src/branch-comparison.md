# Branch Comparison: feature/contract_updates vs feature/ongoingFlatten2

This document compares the `feature/contract_updates` branch (the older baseline) with the current `feature/ongoingFlatten2` branch (HEAD). The diff covers all files under `src/`.

---

## High-Level Summary

The `feature/contract_updates` branch used a **scope-based recursive execution model** with `ActionType` enum, `Action` structs carrying scope arrays, `newScope()` recursive calls, and `ScopeReverted` error-based revert handling. The `feature/ongoingFlatten2` branch replaces this entirely with a **flat sequential execution model** using `CrossChainCall[]` arrays, `revertSpan` for isolated revert contexts, `NestedAction[]` for reentrant calls, and a `rollingHash` for integrity verification.

---

## Structural Changes to Data Types (ICrossChainManager.sol)

### Removed

| Type | Description |
|---|---|
| `ActionType` enum | `CALL`, `RESULT`, `L2TX`, `REVERT`, `REVERT_CONTINUE` -- all removed |
| `Action.actionType` | No longer an enum-tagged union |
| `Action.failed` | Moved to `ExecutionEntry.failed` only |
| `Action.scope` | `uint256[]` scope array -- replaced by flat call model |
| `StateDelta.currentState` | Previous state root no longer stored -- ZK proof binds to it via entry hash |
| `ExecutionEntry.nextAction` | The "what to do next" field -- replaced by sequential consumption |

### Added

| Type | Description |
|---|---|
| `CrossChainCall` struct | `destination`, `value`, `data`, `sourceAddress`, `sourceRollup`, `revertSpan` |
| `NestedAction` struct | `actionHash`, `callCount`, `returnData` -- pre-computed result for reentrant calls |
| `StaticCall` struct | `actionHash`, `returnData`, `failed`, `stateRoot`, `callNumber`, `lastNestedActionConsumed` -- for static/reverting calls |
| `ExecutionEntry.calls` | `CrossChainCall[]` -- flat array of all calls |
| `ExecutionEntry.nestedActions` | `NestedAction[]` -- flat array of nested call results |
| `ExecutionEntry.callCount` | Entry-level iteration count |
| `ExecutionEntry.returnData` | Pre-computed return data (was on `Action`) |
| `ExecutionEntry.failed` | Whether the entry reverts (was on `Action`) |
| `ExecutionEntry.rollingHash` | Expected hash of all call results |

### Modified

| Type | Change |
|---|---|
| `Action` | Simplified to 6 fields: `rollupId`, `destination`, `value`, `data`, `sourceAddress`, `sourceRollup`. Used only off-chain for hash computation |
| `StateDelta` | Removed `currentState` field |
| `ProxyInfo` | Unchanged |

### Interface Changes

| Old | New |
|---|---|
| `computeCrossChainProxyAddress(addr, rollupId, domain)` | `computeCrossChainProxyAddress(addr, rollupId)` -- removed `domain` parameter |
| `newScope(scope, action)` | Removed entirely |
| -- | `staticCallLookup(sourceAddress, callData)` -- new view function |

---

## Architectural Changes in Rollups.sol (L1)

### Removed

| Component | Description |
|---|---|
| `_etherDelta` transient | Global ether delta accumulator -- replaced by per-execution `etherIn - etherOut` check |
| `newScope()` | Recursive scope navigation function |
| `_resolveScopes()` | Entry point for scope resolution |
| `_handleScopeRevert()` | Decoded `ScopeReverted` error payload |
| `_getRevertContinuation()` | Built `REVERT_CONTINUE` action and looked up next entry |
| `_processCallAtScope()` | Executed a call at the current scope, built `RESULT` action |
| `_findAndApplyExecution()` | Searched executions by `actionHash` + state root matching, swap-and-pop removal |
| `_appendToScope()` | Array append helper |
| `_scopesMatch()` | Array comparison helper |
| `_isChildScope()` | Prefix check helper |
| `ScopeReverted` error | Carried `(nextAction, stateRoot, rollupId)` |
| `CallExecutionFailed` error | Generic failure error |
| `InvalidRevertData` error | Revert data too short |
| `StateRootMismatch` error | Delta's `currentState` vs on-chain state |

### Added

| Component | Description |
|---|---|
| `StaticCall[] staticCalls` | Storage array for pre-computed static call results |
| `uint256 executionIndex` | Sequential consumption index |
| `bool transient _insideExecution` | Detects reentrant vs top-level calls |
| `uint256 transient _currentEntryIndex` | Active entry for nested action consumption |
| `uint256 transient _nestedActionIndex` | Next nested action to consume |
| `uint256 transient _currentCallIndex` | Current call position (for static call lookup) |
| `uint64 transient _nestedActionContext` | Parent context identifier |
| `bytes32 transient _rollingHash` | Hash accumulator |
| `_consumeAndExecute()` | Sequential entry consumption with ether accounting |
| `_consumeNestedAction()` | Consumes next nested action, folds position into rolling hash |
| `_applyAndExecute()` | Applies deltas, processes calls, verifies hash and ether |
| `_processCrossChainCalls()` | Flat iteration with revertSpan handling |
| `executeInContext()` | Self-call for isolated revert contexts |
| `_decodeContextResult()` | Decodes `ContextResult` error payload |
| `_computeEntryHashes()` | Extracted entry hash computation (includes `prevStates[]`) |
| `_computeActionInputHash()` | Computes action hash from individual fields (no `Action` struct) |
| `staticCallLookup()` | View function for static call results |
| `ContextResult` error | Carries `bytes32 computedHash` out of revert context |
| `RollingHashMismatch` error | Rolling hash verification failure |
| `UnexpectedContextRevert` error | Unexpected revert in `executeInContext` |
| `UnconsumedNestedActions` error | Not all nested actions consumed |
| `NoNestedActionAvailable` error | Reentrant call with no matching nested action |
| `L2TXNotAllowedDuringExecution` error | `executeL2TX` called during active execution |

### Changed

| Aspect | Old (contract_updates) | New (ongoingFlatten2) |
|---|---|---|
| **Execution lookup** | Hash-based search with state root matching + swap-and-pop | Sequential `executionIndex++` |
| **Action matching** | `keccak256(abi.encode(action))` with full `Action` struct | `keccak256(abi.encode(rollupId, destination, value, data, sourceAddress, sourceRollup))` |
| **Call execution** | Single call per `_processCallAtScope`, builds `RESULT` action, consumes next entry | Flat iteration over `calls[]`, hashes each result |
| **Revert handling** | `ScopeReverted` error carrying `(nextAction, stateRoot, rollupId)`, explicit state restoration | `revertSpan` + `executeInContext` self-call, `ContextResult` carrying rolling hash |
| **Nested calls** | Recursive `newScope()` with try/catch at each scope level | Flat `nestedActions[]` consumed sequentially via `_consumeNestedAction` |
| **Result verification** | Check `nextAction.actionType == RESULT && !nextAction.failed` | `_rollingHash == entry.rollingHash` + `entry.failed` flag |
| **postBatch public inputs** | `block.number` in hash, no `prevStates[]` in entry hash | `block.timestamp` in hash, `prevStates[]` included in entry hash |
| **postBatch immediate entries** | Any entry with `actionHash == 0` applied immediately (multiple allowed) | Only the first entry may have `actionHash == 0` |
| **Entry hash** | `stateDeltas + vks + actionHash + nextAction` | `stateDeltas + vks + prevStates + actionHash + rollingHash` |
| **Ether accounting** | Global `_etherDelta` transient accumulator, checked in `_applyStateDeltas` | Per-execution `etherIn - etherOut == totalEtherDelta`, checked in `_applyAndExecute` |
| **executeL2TX** | Takes `(rollupId, rlpEncodedTx)`, builds L2TX action, hashes it | Parameterless, checks next entry has `actionHash == bytes32(0)` |
| **CREATE2 salt** | `keccak256(block.chainid, rollupId, address)` | `keccak256(rollupId, address)` -- removed `block.chainid` |

---

## Architectural Changes in CrossChainManagerL2.sol (L2)

### Removed

| Component | Description |
|---|---|
| `mapping(bytes32 => ExecutionEntry[]) _executions` | Hash-indexed execution storage |
| `pendingEntryCount` | Counter for unconsumed entries |
| `executeIncomingCrossChainCall()` | System-only function for remote calls with scope |
| `newScope()` | Recursive scope navigation |
| `_resolveScopes()` | Scope resolution |
| `_handleScopeRevert()` | `ScopeReverted` error handling |
| `_getRevertContinuation()` | `REVERT_CONTINUE` action lookup |
| `_processCallAtScope()` | Per-call execution at scope |
| `_appendToScope()`, `_scopesMatch()`, `_isChildScope()` | Scope helpers |
| `_collectCalls()` | Call collection from state deltas |
| `ScopeReverted`, `CallExecutionFailed`, `InvalidRevertData` errors | Scope-era errors |
| `IncomingCrossChainCallExecuted` event | No longer needed without system-initiated calls |

### Added

Same additions as Rollups.sol (without ether accounting): `executions[]`, `staticCalls[]`, `executionIndex`, all transient variables, `_consumeAndExecute`, `_consumeNestedAction`, `_processCrossChainCalls`, `executeInContext`, `_decodeContextResult`, `staticCallLookup`, `_computeActionInputHash`, and corresponding errors.

### Changed

| Aspect | Old | New |
|---|---|---|
| **Storage model** | `mapping(bytes32 => ExecutionEntry[])` with swap-and-pop | `ExecutionEntry[]` with sequential index |
| **Entry loading** | Appended to hash-indexed mapping | `delete` + push to flat array |
| **Block constraint** | None (entries persisted across blocks) | `lastLoadBlock == block.number` |
| **Action construction** | Built full `Action` struct in `executeCrossChainCall` | Computes hash from individual fields |
| **loadExecutionTable** | `(ExecutionEntry[])` | `(ExecutionEntry[], StaticCall[])` |

---

## CrossChainProxy.sol Changes

| Aspect | Old | New |
|---|---|---|
| **Solidity version** | `^0.8.24` | `^0.8.28` |
| **Static call detection** | Not present | `staticCheck()` function + `_staticDetector` transient variable |
| **Fallback routing** | Always called `executeCrossChainCall` | Detects static context first; routes to `staticCallLookup` or `executeCrossChainCall` |
| **Result handling** | Separate success/revert assembly blocks | Unified `abi.decode` + single assembly switch |

---

## Other File Changes

| File | Change |
|---|---|
| `IZKVerifier.sol` | Solidity version bump `^0.8.24` to `^0.8.28` |
| `periphery/Bridge.sol` | `computeCrossChainProxyAddress` calls updated from 3 to 2 parameters (removed `block.chainid`). Solidity version bump. |
| `periphery/WrappedToken.sol` | Solidity version bump only |
| `verifier/tmpECDSAVerifier.sol` | Deleted entirely |
| `CHANGES.md` | New file documenting the flattened execution model changes |
| `ROLLING_HASH_SPEC.md` | New file documenting the rolling hash specification |

---

## Key Design Differences

### 1. Execution Model: Recursive Scopes vs Flat Sequential

The old model used a tree of `newScope()` calls where each CALL action carried a `scope` array indicating its position in the tree. The contract navigated this tree recursively, with `try/catch` at each level to handle reverts. Each call produced a `RESULT` action that was looked up in the execution table.

The new model stores all calls in a flat array. Processing is a simple `while` loop. Reentrant calls consume from a separate flat `nestedActions[]` array. Reverts use `revertSpan` to delineate isolated contexts processed via `executeInContext`.

**Impact**: Eliminates unbounded recursion depth, simplifies gas estimation, removes the need for the `ActionType` enum and the `RESULT`/`REVERT`/`REVERT_CONTINUE` action types.

### 2. State Matching: Search vs Sequential Index

The old model searched the `executions[]` array for an entry matching both `actionHash` and all `currentState` fields against on-chain state roots. This O(n * m) search (n entries, m deltas each) was necessary because execution order was determined by scope navigation.

The new model uses a simple `executionIndex++`. Entries must be consumed in the exact order they were posted. State root matching is replaced by ZK proof binding (previous state roots are included in the entry hash).

**Impact**: O(1) lookup, no swap-and-pop storage operations, deterministic execution order.

### 3. Integrity Verification: Action Chaining vs Rolling Hash

The old model verified integrity by checking that each `RESULT` action hash matched an entry in the execution table, and that the final result was a successful `RESULT`. Each step consumed one entry.

The new model accumulates a rolling hash of `(success, returnData)` for every call at every depth, plus nesting boundary markers. A single hash comparison at the end verifies the entire execution tree.

**Impact**: Stronger integrity guarantees (covers nesting structure, not just individual results), fewer storage reads (one verification instead of per-call lookups).

### 4. Ether Accounting: Global Accumulator vs Per-Execution Check

The old model used a global `_etherDelta` transient accumulator that tracked all ETH flow across the entire transaction, verified once in `_applyStateDeltas`.

The new model checks ether accounting per execution entry: `totalEtherDelta == etherIn - etherOut`, where `etherOut` is computed during call processing. This localizes the accounting to each entry.

### 5. Static Call Support

The old model had no static call support. Calls in a STATICCALL context would fail.

The new model adds `StaticCall[]` storage, proxy-level static context detection via `tstore`/`tload`, and a `staticCallLookup()` view function that matches by `(actionHash, callNumber, lastNestedActionConsumed)`.
