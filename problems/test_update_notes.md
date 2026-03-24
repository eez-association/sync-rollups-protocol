# Test Update Notes — Contract Changes


## Questions / Observations

### 1. `test_ExecuteRemoteCall_CallExecutionFailed_WhenResultFailed` (L2 test)
The test previously expected `CallExecutionFailed` when a failed RESULT with empty `data` was returned. However, the actual behavior is that `_resolveScopes` does an assembly `revert(ptr, 0)` for failed RESULTs — producing an **empty revert**, not `CallExecutionFailed`. Changed expectation to `vm.expectRevert(bytes(""))`. Was this test always wrong, or did the old code path differ?

### 2. `postBatch` auto-consumes `actionHash==0` entries
The `executeL2TX()` loop inside `postBatch` means **all leading immediate entries are consumed during `postBatch`**, including L2TX entries that chain into scope navigation. This changes the test pattern: previously tests called `executeL2TX(rollupId, rlpTx)` separately; now everything happens inside `postBatch`. Tests that expected `executeL2TX` to revert now expect `postBatch` to revert instead.

### 3. `tmpECDSAVerifier` test immediate entry
The original test used `ActionType.CALL` as `nextAction` for an immediate entry with `actionHash==0`. In the new code, `postBatch` auto-consumes this via `executeL2TX()`, which enters scope navigation and fails (no follow-up entries). Changed to `ActionType.RESULT` to match `_immediateEntry` helper pattern. Was the CALL intentional for testing purposes, or just a placeholder?

### 4. Missing test coverage for new features
No tests exist yet for:
- `staticCallLookup()` on either manager
- `StaticCall` / `StaticSubCall` loading and matching
- `_processNStaticCalls` rolling hash verification
- `executionIndex` skip-scan behavior (skipping failed entries)
- `RollingHashMismatch`, `StaticCallNotFound`, `ProxyNotDeployed` errors

### 5. `DecodeExecutions.s.sol` stale `TxData` struct fields
The `l2txRollupId`, `l2txRlpData`, `l2txActionHash` fields and their display logic are now dead code since `L2TXExecuted()` carries no data. A full cleanup would remove these fields and simplify the display functions.
