# Contracts TODO

## Add `require(action.rollupId == ROLLUP_ID)` in `_processCallAtScope`

**Where:**
- `src/CrossChainManagerL2.sol` — `_processCallAtScope()` (line ~303)
- `src/Rollups.sol` — equivalent function

**What:** Before executing a CALL at the current scope, verify the CALL's `rollupId` matches this chain's rollup ID. If a CALL targeting L2 somehow ends up being processed on L1 (or vice versa), this should revert.

**On L2:**
```solidity
require(action.rollupId == ROLLUP_ID, "CALL targets wrong rollup");
```

**On L1:** L1 manages multiple rollups, so the check would be `action.rollupId == MAINNET_ROLLUP_ID` (0) since L1 only executes calls targeting mainnet.

**Why:** Catches misrouted execution entries at runtime. Currently nothing prevents a batch from containing a CALL with the wrong rollupId — it would silently execute on the wrong chain.
