# Caveats

## Edge Cases

- **One deterministic consumption order — no alternative/candidate entries in the persistent queues**: each rollup's `executionQueue` (and the L2 `executions` table) encodes exactly ONE valid consumption order. A persistent entry that reverts mid-execution (`StateRootMismatch`, `RollingHashMismatch`, …) reverts the whole consuming transaction WITHOUT advancing the cursor — it blocks the queue rather than being skipped, so publishing several candidate entries and letting "whichever succeeds" apply does NOT work in the persistent path. The ONE exception is the IMMEDIATE prefix: `attemptApplyImmediate` wraps each immediate entry in try/catch, so a reverting candidate emits `ImmediateEntrySkipped` and the cursor still advances — alternatives gated by `StateDelta.currentState` CAN be stacked there, and only the one matching the live root applies.

- **Indistinguishable revert reasons when calling a proxy**: A caller (contract or EOA) cannot differentiate between a proxy call reverting because the execution table did not contain a matching entry vs. the underlying destination call actually reverting. Both cases bubble up as a revert from the proxy.

- **Opcodes that differ on cross-chain proxies**:
  - These opcodes return information about the proxy itself, not the proxied contract: `delegatecall`, `balance`, `extcodesize`, `extcodecopy`.
  - Block-state opcodes (`blocknumber`, `blockhash`, `blockgaslimit`, `chainid`, `coinbase`, …) reflect the chain the call is executing on, not the source chain — values will differ when the same logical action is observed on L1 vs L2.
