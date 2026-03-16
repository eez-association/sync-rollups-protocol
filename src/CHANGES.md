# Contract Changes — Flattened Execution Model

## Summary of Changes

Replaced recursive scope-based execution with a flat, sequential execution model using `executionIndex` and `SubCall[]` with `contextDepth`.

---

## ICrossChainManager.sol — Type Changes

### ActionType
- Removed `RESULT`, `REVERT`, `REVERT_CONTINUE`
- Kept `CALL`, `L2TX`

### Action
- Removed `scope` (uint256[])
- Added `failed` (bool) and `returnData` (bytes)
- **Open question**: `failed` and `returnData` exist on both `Action` and `ExecutionEntry`. Contracts read from `ExecutionEntry`. The duplicates on `Action` are only consumed by the ZK proof hash (`abi.encode(entry.action)` in `postBatch`). Decide whether to keep both or remove from `Action`.

### StateDelta
- Removed `currentState` — no longer verified on-chain (ZK proof handles it)
- Removed `SubCall[] calls` — moved to `ExecutionEntry`

### SubCall (new)
- Flat struct: `destination`, `value`, `data`, `sourceAddress`, `sourceRollup`, `failed`, `contextDepth`
- `failed == true` opens an isolated revert context containing all subsequent subcalls with deeper `contextDepth`

### ExecutionEntry
- `stateDeltas` — array of state deltas
- `action` — the action (used for hash matching at entry points)
- `calls` — flat array of SubCalls to execute
- `returnData` — pre-computed return data
- `failed` — whether the action failed
- `returnHash` — expected hash of all call results for verification

### ICrossChainManager interface
- `computeCrossChainProxyAddress` now takes 2 params (removed `domain`/`block.chainid`)

---

## Rollups.sol (L1)

### Removed
- `_etherDelta` transient storage accumulator
- All scope navigation: `newScope`, `_resolveScopes`, `_handleScopeRevert`, `_getRevertContinuation`, `_processCallAtScope`, `_findAndApplyExecution`, `_appendToScope`, `_scopesMatch`, `_isChildScope`
- Errors: `CallExecutionFailed`, `InvalidRevertData`, `ScopeReverted`, `StateRootMismatch`
- `_applyStateDeltasAndCollectCalls` (calls now come from `entry.calls`)

### Added
- `executionIndex` state variable
- `executeInContext(SubCall[])` — external self-call for isolated revert contexts
- `_processSubCalls(SubCall[])` — iterates calls, opens contexts for failed subcalls, chains return hash
- `_decodeContextResult(bytes)` — strips selector and decodes `ContextResult` error
- `_executeCallsAndVerify(SubCall[], bytes32)` — executes calls and checks return hash
- `ContextResult` error (5 fields: `computedHash`, `etherOut`, `returnData`, `actuallyFailed`, `consumedCount`)
- `ExecutionNotInCurrentBlock` error
- `ReturnHashMismatch` error

### Changed
- `_consumeAndExecute` uses sequential `executionIndex`, reads `entry.calls`/`entry.failed`/`entry.returnData` directly
- `postBatch` uses `block.timestamp` (was `block.number`), entry hash includes `abi.encode(entry.action)` and `entry.returnHash`
- Ether accounting: per-execution `totalEtherDelta == etherIn - etherOut` check
- CREATE2 salt: removed `domain`/`block.chainid`

---

## CrossChainManagerL2.sol (L2)

### Removed
- `mapping(bytes32 => ExecutionEntry[]) _executions`
- `pendingEntryCount`
- `executeIncomingCrossChainCall`, `newScope`, all scope helpers
- Errors: `CallExecutionFailed`, `ScopeReverted`, `InvalidRevertData`
- `_collectCalls` (calls now come from `entry.calls`)

### Added
- `ExecutionEntry[] public executions` + `executionIndex`
- `lastLoadBlock` — entries must be consumed in the same block they were loaded
- `executeInContext`, `_processSubCalls`, `_decodeContextResult` (same pattern as L1, without `etherOut`)
- `ContextResult` error (4 fields, no `etherOut`)
- `ExecutionNotInCurrentBlock`, `ReturnHashMismatch` errors

### Changed
- `loadExecutionTable` deletes previous entries, resets index, stores new entries
- `executeCrossChainCall` checks `lastLoadBlock == block.number`, burns ETH to system address
- `_consumeAndExecute` uses sequential index, reads `entry.calls`/`entry.failed`/`entry.returnData` directly

---

## Open Questions

1. **Duplicate `failed`/`returnData`**: On both `Action` and `ExecutionEntry`. Contracts use `entry.failed`/`entry.returnData`. The `Action` copies are only used in `abi.encode(entry.action)` for the ZK proof hash in `postBatch`. Keep both, or remove from `Action`?

2. **`_isZeroAction` check**: Currently checks all 7 input fields of `Action` are zero/default. With `failed`/`returnData` on `Action`, should those also be checked? (Immediate entries shouldn't have failed=true or returnData set.)

3. **Bridge.sol**: Still uses 3-param `computeCrossChainProxyAddress`. Needs update when periphery contracts are touched.

4. **Tests/scripts**: All need updating to match new types. Not done yet.
