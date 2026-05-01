# Multiple-Verifier Queue Model — Design Note

> Status: design idea, not implemented. Consolidates a discussion about how `Rollups.sol`
> should track executions when multiple proof systems may post batches in the same block.

## Problem

Today `executions` is a single flat array shared across all batches in a block. With
the per-batch threshold model (each rollup verified by exactly one group), the execution
table is conceptually partitioned by **(rollup, proof-system group)**, but the on-chain
representation doesn't reflect that. Two issues fall out:

1. **No once-per-block guard for verification.** A rollup could in principle be touched
   by multiple `postBatch` calls in the same Ethereum block. We want a hard rule:
   *each rollup can be verified at most once per L1 block.*
2. **Cross-PS queue confusion.** When an action is consumed via `executeCrossChainCall`
   or `executeL2TX`, we search the whole `executions` array. With multiple proof systems
   each producing their own deferred entries, we want to look only in the queue that
   belongs to the action's destination rollup (and therefore that rollup's verifying group).

## Proposed model

### Per-rollup verification record

```solidity
struct RollupVerification {
    uint256 lastVerifiedBlock;   // L1 block at which rollup last received a verified batch
    ExecutionEntry[] queue;      // deferred entries for this rollup
    uint256 cursor;              // next entry to consume (incremental index)
}

mapping(uint256 rollupId => RollupVerification) internal verificationByRollup;
```

- On `postBatch`, for every `rollupId` in any sub-batch's `rollupIds`:
  - Require `verificationByRollup[rid].lastVerifiedBlock < block.number` — else revert
    (rollup already verified this block).
  - After verification succeeds, set `lastVerifiedBlock = block.number`.
- Deferred entries (`actionHash != 0`) are appended to the queue of **the rollup their
  destination action targets**, not to a global list.

### Per-proof-system independence

Each proof system has its own queue per rollup it covers. Because rollups are disjoint
across sub-batches (current invariant), a rollup is bound to exactly one PS group per
block, so "the rollup's queue" and "the PS group's queue for that rollup" are the same
queue — no extra dimension needed.

If we later relax disjointness, the structure generalises to:

```solidity
mapping(uint256 rollupId => mapping(address proofSystem => RollupVerification)) internal verificationByRollupAndPS;
```

For now we can stay with the simpler `rollupId -> RollupVerification` form.

### Routing actions to queues

When an action lands at the manager (CALL via proxy, L2TX, RESULT, REVERT_CONTINUE),
its `rollupId` (or destination rollup) tells us which queue to read from:

```
queue = verificationByRollup[action.rollupId].queue
cursor = verificationByRollup[action.rollupId].cursor
candidate = queue[cursor]
```

Match by `actionHash` + state-delta consistency, then advance `cursor` (logical pop).

### Stack-like consumption, list-encoded

We described it as a stack but implement as a **list with an incremental cursor**:

- Push: `queue.push(entry)` during `postBatch`.
- Pop: `cursor++` after consumption (no array `pop` / no swap-and-pop).
- Reset: when `lastVerifiedBlock` advances to a new block, the queue and cursor are
  considered empty and overwritten by the next batch.

This avoids storage churn from swap-and-pop and gives a clean "executions are a tape we
play through in order" mental model.

## Invariants this gives us

1. **Once per block per rollup.** `lastVerifiedBlock < block.number` gates `postBatch`
   per rollup, so no rollup is double-verified in a single L1 block.
2. **Per-proof-system isolation.** Each PS group's deferred entries live in their own
   per-rollup queue, addressed by destination rollup. No cross-PS interference.
3. **Cheap consumption.** Lookup is O(1) into the right queue and cursor, not a linear
   scan of all deferred entries.

## Open questions / things to decide

- **Replay across blocks.** If a queue is left non-empty at end of block, do we discard
  it or carry it forward? The current contract discards on the next `postBatch`; the
  cursor model preserves that by treating a stale `lastVerifiedBlock` as an empty queue.
- **Block-scoped `BatchUpdate` vs per-rollup record.** `batchUpdates[rid]` already
  encodes "what changed in the current block". The new `lastVerifiedBlock` would
  duplicate that. We can derive once-per-block from `batchUpdates[rid].blockNumber ==
  block.number` instead of adding a parallel field.
- **Mixed immediate + deferred entries.** Today immediate entries (`actionHash == 0`)
  apply state deltas inline and aren't queued. The new model keeps that — immediate
  entries skip the queue entirely; only deferred entries get appended.
- **Cross-rollup actions within a single execution chain.** When an action's `RESULT`
  or nested CALL targets a different rollup, the cursor must advance in *that* rollup's
  queue, not the original one. This needs careful handling in `_resolveScopes` /
  `newScope` — the lookup key for the next action is the next action's destination
  rollup, not the parent's.

## Migration sketch

1. Add `RollupVerification` struct + `verificationByRollup` mapping; remove the flat
   `executions` array.
2. In `postBatch`:
   - Per rollup in a batch: revert if `lastVerifiedBlock == block.number`.
   - After per-batch verify, set `lastVerifiedBlock = block.number` for each rollup.
   - For deferred entries, append to `verificationByRollup[destinationRollup].queue`.
3. In `_findAndApplyExecution`:
   - Replace linear scan with `queue[cursor]` lookup, gated on `actionHash` and
     state-delta match. On match, advance `cursor`.
4. Drop swap-and-pop in favour of cursor advance.
5. Decide whether to drop `lastStateUpdateBlock` (now per-rollup) or keep it as a
   coarse global flag.
