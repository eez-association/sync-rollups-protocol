# Caveats

## Edge Cases

- **Indistinguishable revert reasons when calling a proxy**: A caller (contract or EOA) cannot differentiate between a proxy call reverting because the execution table did not contain a matching entry vs. the underlying destination call actually reverting. Both cases bubble up as a revert from the proxy.

- **Opcodes that differ on cross-chain proxies**:
  - These opcodes return information about the proxy itself, not the proxied contract: `delegatecall`, `balance`, `extcodesize`, `extcodecopy`.
  - Block-state opcodes (`blocknumber`, `blockhash`, `blockgaslimit`, `chainid`, `coinbase`, …) reflect the chain the call is executing on, not the source chain — values will differ when the same logical action is observed on L1 vs L2.

- **Reverting reentrant calls must use `LookupCall`, not `NestedAction`**: All entries in `entry.nestedActions[]` must describe **successful** reentrant cross-chain calls. A reverted nested call rolls back transient storage (including `_lastNestedActionConsumed` and `_currentCallNumber`), making it impossible to distinguish "the call was made and reverted" from "the call was never made". Build any reverting reentrant call as a `LookupCall` with `failed = true` instead — `LookupCall` is content-addressed by `(crossChainCallHash, callNumber, lastNestedActionConsumed)`, so the revert is replayed deterministically without losing position in the execution stream.

- **Same-block consumption is mandatory**: Every entry posted by `postBatch` (L1) or `loadExecutionTable` (L2) must be consumed in the same block it was loaded — `executeCrossChainCall`, `executeL2TX`, and `staticCallLookup` all guard on the per-rollup `lastVerifiedBlock(rid) == block.number` (L1) or `lastLoadBlock == block.number` (L2). Entries that survive the block are silently dropped on the next load: the per-rollup queue is lazy-reset on the next batch that touches the rollup.

- **Partial transient consumption no longer drops the deferred remainder**: After the multi-prover refactor, `postBatch` always publishes each sub-batch's remainder (`entries[transientCount..]`, `lookupCalls[transientLookupCallCount..]`) to per-rollup queues unconditionally. The soundness backstop is `StateDelta.currentState` — entries whose recorded pre-state doesn't match `rollups[rid].stateRoot` at consumption time revert `StateRootMismatch`, so partial transient drains can't poison persistent consumers (the state-root check fails them naturally if they depended on transient effects).

- **Lookup call disambiguation by `(callNumber, lastNestedActionConsumed)`**: A single deferred entry may issue several STATICCALLs with the same `crossChainCallHash` at different points in its execution tree. `lookupQueue[]` (per-rollup) is matched by `(crossChainCallHash, callNumber, lastNestedActionConsumed)` — the builder must record the values of `_currentCallNumber` and `_lastNestedActionConsumed` at the exact moment each STATICCALL is issued, otherwise the lookup reverts with `ExecutionNotFound`.

- **`revertSpan` is rewritten in storage during execution**: When the call processor encounters `entry.calls[i].revertSpan != 0`, it temporarily zeroes that field in storage before self-calling `executeInContextAndRevert`, and restores it after the catch. If a nested execution path observes `entry.calls[i]` while the field is zeroed (e.g., another contract reads the public `verificationByRollup(rid).queue(uint256)` getter mid-flight), it will see the cleared value. This is intentional — the inner call must see `revertSpan == 0` to avoid recursively opening another context — but external observers should not snapshot `entry.calls` during a running batch.

- **`executeL2TX` cannot run during an active execution**: `executeL2TX(rollupId)` reverts with `L2TXNotAllowedDuringExecution` whenever `_insideExecution()` is true. L2TX entries are top-level only; reentrant calls must use the proxy path.

- **Sequential consumption is strict, per-rollup**: Entries from one batch can only be drained from the rollup whose `destinationRollupId` they target — each rollup's queue has its own cursor. Consumers route via the proxy's `originalRollupId` (or the explicit arg to `executeL2TX(rollupId)`) and increment that rollup's cursor by one per consumption. Cross-rollup state is independent — a stuck queue on one rollup doesn't block another.

- **Reverting top-level executions are expressed via `LookupCall`, not via an entry-level flag**: Top-level entries always succeed (`executeCrossChainCall` returns `entry.returnData`). A naturally-reverting top-level cross-chain call is expressed as a `LookupCall { failed: true }`, consumed via `staticCallLookup` (static context) or via the failed-reentry fallback in `_consumeNestedAction`. Naturally-reverting INNER calls inside an entry are still captured by the proxy's `.call` returning `(false, retData)` and hashed into `CALL_END`.

- **Manager handoff**: `setRollupContract(rid, newContract)` switches the per-rollup manager pointer. Subject to a same-block lockout: if any batch hit `rid`'s queue this block (`lastVerifiedBlock(rid) == block.number`), the call reverts `RollupBatchActiveThisBlock` until the next block. The same lockout applies to `setStateRoot(rid, newRoot)` — the registry blocks owner-driven state overwrites for the entire block in which a batch was posted to that rollup, to prevent state divergence within the verified window.

- **Immediate entry skip is non-fatal**: An immediate entry (`crossChainCallHash == 0` at the head of a sub-batch's transient stream) whose self-call reverts emits `ImmediateEntrySkipped(transientIdx, revertData)` and the cursor advances. It is **not** a hard error — the rest of the transient stream continues to drain from the next entry.

- **`rollupId == 0` is unpostable**: `MAINNET_ROLLUP_ID = 0` is excluded by the strict-increasing rollupIds check inside each sub-batch. Tests / scripts that need real rollups starting at id 1 can register a throwaway "burn" rollup first to get id 0 out of the way.
