# Caveats

## Edge Cases

- **Indistinguishable revert reasons when calling a proxy**: A caller (contract or EOA) cannot differentiate between a proxy call reverting because the execution was not loaded into the execution table vs. the underlying L2 call actually reverting. Both cases bubble up as a revert from the proxy.


- **Opcodes that differ on crosshcina proxies**:  
  - Those opcodes will return the actual ifno of the proxy, not the proxied contract: delegatecall, balance, extCodeSize, extCodecopy, 
  - Opcodes of blockchain state: blockGasLimit, BlokcNUmber, blockhash... might differ when jumping networks


- **L2 duplicate actionHash after scope revert**: On L2, `_consumeExecution` matches entries by `actionHash` only (no state delta check like L1's `_findAndApplyExecution`). When a scope reverts via `ScopeReverted`, the EVM rolls back entry consumption (restoring `actionHash` from `bytes32(0)` to the original value). If a subsequent call produces the same `actionHash` as a restored entry, `_consumeExecution` picks the restored entry (wrong `nextAction`) instead of the intended one.

  **Impact**: On L2, REVERT_CONTINUE → CALL patterns fail when both the pre-revert and post-revert calls produce identical RESULT actions (same `rollupId`, `data`, `failed`). The workaround is to ensure the two cross-chain calls target different contracts or produce different return data so their RESULT hashes differ.

  **Not affected**: L1 (`Rollups.sol`) uses `_findAndApplyExecution` which checks state deltas against on-chain rollup state, so entries with the same `actionHash` but different `currentState` are correctly distinguished.


## Static calls

All static-call edge cases are covered in `STATIC_CALLS.md` §H (Invariants & edge cases). See that document for the authoritative list.

