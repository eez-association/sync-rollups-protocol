# `postBatch` Interface Specification

A revised `postBatch` for the L1 `Rollups` contract. Same function name
as today, but the flow separates pure-L2 state transitions from
L1-initiated cross-chain calls, and uses transient storage to carry the
execution table across a sequence of reentrant L1 calls within the same
batch.

## Pseudocode

```solidity
function postBatch(
    uint256                   validatorId,   // id from ValidatorRegistry; vkeys looked up per rollup
    ExecutionEntry[] calldata entries,
    uint256                   blobCount,     // blob or callData (mutually exclusive with callData)
    bytes            calldata callData,      // blob or callData
    L1Calls[]        calldata l1callsWithExpected,
    bytes            calldata proof
) external {
    verifyProof(validatorId);

    // 1. Stage the full execution table into transient storage so that
    //    reentrant executeCrossChainCall() lookups can consume it.
    transientEntries = entries;

    // 2. Apply all pure-L2 state deltas:  State a --> State x
    applyStateDelta(stateDeltas);

    // 3. Process each expected L1 cross-chain call in order.
    foreach L1Calls {
        verifyCall(l1callsWithExpected);
        // each call might hit reentrant executions entries on the table State x --> State y

        // post-call pure-L2 deltas (finishing L2->L1 call + any trailing pure L2 txs):  State y --> State z
        applyStateDelta(stateDeltas);
    }

    // 4. Persist whatever was not consumed from the transient table.
    executions = remainingEntries(transientEntries);
}
```

## Parameters

| Name                   | Type                 | Purpose                                                                                                                                                     |
|------------------------|----------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `validatorId`          | `uint256`            | Which registered validator verifies this batch. Every non-mainnet rollup touched by a state delta must have a non-zero vkey registered under this id.       |
| `entries`              | `ExecutionEntry[]`   | Full set of pre-computed entries this batch may consume (pure L2 + deferred cross-chain).                                                                   |
| `blobCount`            | `uint256`            | Number of EIP-4844 blobs carrying the batch payload. Mutually exclusive with `callData`.                                                                    |
| `callData`             | `bytes`              | Inline alternative payload when blobs are not used.                                                                                                         |
| `l1callsWithExpected`  | `L1Calls[]`          | Ordered list of L1-initiated cross-chain calls, each with its expected inputs and tail.                                                                     |
| `proof`                | `bytes`              | Proof binding the batch payload, entries, and expected L1 calls. Format is validator-specific (ZK bytes, ECDSA signature, etc.).                            |

Exactly one of `blobCount` or `callData` must carry the batch payload.

## New Type

Only one new struct is introduced; everything else reuses the existing
`Action`, `StateDelta`, `ExecutionEntry`, `ProxyInfo`, `RollupConfig`
names from `ICrossChainManager.sol`.

```solidity
struct L1Calls {
    address      proxy;             // local CrossChainProxy that must be invoked
    bytes        expectedCallData;  // callData the proxy is expected to forward
    uint256      expectedValue;     // msg.value the proxy is expected to forward
    StateDelta[] postCallDeltas;    // pure-L2 deltas to apply after this L1 call returns
}
```

`remainingEntries(...)` is a library helper that reads the transient
slot and returns whichever `ExecutionEntry`s were not consumed by
reentrant calls; those are written back to the persistent `executions`
array.

## Execution Semantics

1. **Proof verification** — `verifyProof()` checks the ZK proof over the
   batch payload (blobs or `callData`), the declared `entries`, and the
   `l1callsWithExpected` array. The proof must bind pre-state,
   post-state, and the ordered sequence of expected L1 calls.
2. **Transient staging** — The full `entries` array is written to a
   transient slot for the duration of the top-level `postBatch()` call.
   All reentrant lookups performed by `executeCrossChainCall()` must
   read from this transient slot, not from the persistent `executions`
   array.
3. **State `a -> x`** — Pure-L2 `StateDelta`s carried on immediate
   entries (today's `actionHash == 0` case) are applied up front. These
   are the deltas that depend on nothing external to the rollup.
4. **L1 call loop** — For each element of `l1callsWithExpected`:
   - `verifyCall(...)` invokes the local proxy as specified. Because the
     proxy forwards into `executeCrossChainCall()`, and that function
     reads from transient storage, the reentry consumes matching
     `ExecutionEntry`s. This moves state `x -> y`.
   - After the call returns, `applyStateDelta(postCallDeltas)` applies
     the post-call pure-L2 deltas (the tail of the original L2->L1 flow
     plus any pure L2 txs that were ordered after it), moving state
     `y -> z`.
5. **Persist leftovers** — After the loop, `remainingEntries(...)`
   reads the transient slot and writes anything still unconsumed to the
   persistent `executions` array, so later batches or later
   `executeCrossChainCall()` invocations can consume it.

## Invariants

- `verifyProof()` must run before any state mutation.
- The transient entries slot must be cleared by the time `postBatch()`
  returns (either fully consumed or moved into persistent `executions`).
- The sum of `etherDelta` across all applied `StateDelta`s (immediate +
  post-call) plus all L1 call values must net to zero against the
  contract's own balance, as in the current `postBatch` invariant.
- `l1callsWithExpected` is processed in order; out-of-order execution
  must revert.
- Reentrant calls into `executeCrossChainCall()` during `verifyCall(...)`
  may only consume `ExecutionEntry`s that the proof committed to.

## Relation to Current `postBatch`

The current `postBatch(entries, blobCount, callData, proof)` interleaves
immediate and deferred entries in a single flat array and lets
`executeCrossChainCall()` consume deferred entries from persistent
storage across batches. The revised `postBatch`:

- Keeps `ExecutionEntry[]` as the payload type (no new wrapper struct).
- Adds `l1callsWithExpected` so L1-initiated calls are first-class batch
  inputs rather than asynchronous follow-ups.
- Uses transient storage as the primary consumption target during the
  batch, so intra-batch reentry is the common path and the persistent
  `executions` array is only written to with leftovers.

## Open Questions

- Should `entries` commit to an ordering relative to
  `l1callsWithExpected`, or should matching remain hash-based as today?
- How are REVERT / REVERT_CONTINUE actions represented inside
  `l1callsWithExpected` — as a flag on `L1Calls`, or as explicit
  `ExecutionEntry`s in the `entries` array?
- Does `remainingEntries(...)` append to the existing persistent
  `executions` array, or is persistent storage now a single "pending
  table" that must be fully consumed by a subsequent `postBatch()` call?
