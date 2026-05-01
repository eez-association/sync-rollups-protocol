# L1/L2 Sync Smart Contracts

## Project Overview

This is a Foundry-based Solidity project implementing smart contracts for L1/L2 rollup synchronization. The system allows L2 executions to be verified and executed on L1 using ZK proofs, and on L2 via system-loaded execution tables.

## Build & Test Commands

```bash
forge build          # Compile contracts
forge test           # Run all tests
forge test -vvv      # Run tests with verbose output
forge fmt            # Format code
```

## Architecture

### Core Contracts

- **Rollups.sol**: Central L1 registry. Manages per-rollup state roots, queues `ExecutionEntry`s into per-rollup queues, verifies proof-system bundles via `ProofSystemBatch[]` (multi-prover model), runs the `IMetaCrossChainReceiver` hook for in-tx consumption, and executes flat sequential cross-chain calls with rolling-hash verification. Holds no per-rollup policy — that lives in each rollup's own manager contract.
- **rollupContract/IRollup.sol** + **rollupContract/Rollup.sol**: Per-rollup manager contract. Each rollup is owned by a contract that conforms to `IRollup` (the reference implementation `Rollup.sol` bakes in `proofSystems`, `verificationKeys`, threshold, and an owner). The central `Rollups` registry calls `IRollup.rollupContractRegistered(rollupId)` once at registration and `IRollup.getVkeysFromProofSystems(address[])` per batch to fetch the vkey matrix used for verification. Manager contracts can also call `Rollups.setStateRoot(rid, newRoot)` and `Rollups.setRollupContract(rid, newContract)` for ops/handoff.
- **IProofSystem.sol**: Interface (`verify(bytes proof, bytes32 publicInputsHash) returns (bool)`) for any external proof verifier (ZK or otherwise). Multiple proof systems can attest the same batch — see `ProofSystemBatch` and threshold logic in `Rollups.sol`.
- **IMetaCrossChainReceiver.sol** (`src/interfaces/`): Callback fired on `postBatch`'s `msg.sender` (when it has code) so the sender can consume transient entries via cross-chain proxy calls in the same transaction.
- **CrossChainProxy.sol**: Proxy deployed via CREATE2 for each (address, rollupId) pair. Routes incoming calls to the manager via `executeCrossChainCall` (or `staticCallLookup` in static context, detected via a `tstore` self-call), and forwards manager-driven outbound calls via `executeOnBehalf`.
- **CrossChainManagerL2.sol**: L2-side. No proofs, no rollup registry, no state deltas — a system address loads execution tables consumed sequentially by proxy calls.

### Data Types

The protocol uses a **flat sequential execution model**: every entry contains a flat list of `CrossChainCall`s processed sequentially, with reentrant calls resolved via a parallel `NestedAction[]` table and integrity verified by a single `rollingHash` per entry.

```solidity
struct StateDelta {
    uint256 rollupId;
    bytes32 currentState;   // expected pre-state on rollupId; checked against rollups[rid].stateRoot
    bytes32 newState;       // post-execution state root
    int256  etherDelta;     // signed ETH change for this rollup
}

struct CrossChainCall {
    address targetAddress;
    uint256 value;
    bytes   data;
    address sourceAddress;
    uint256 sourceRollupId;
    uint256 revertSpan;     // 0 = normal; N>0 = force-revert state effects of next N calls
}

struct NestedAction {
    bytes32 crossChainCallHash;     // hash of the reentrant call
    uint256 callCount;              // entries from calls[] consumed inside this nested action
    bytes   returnData;             // pre-computed return value (must succeed)
}

struct ExecutionEntry {
    StateDelta[]     stateDeltas;
    bytes32          crossChainCallHash;     // bytes32(0) = immediate (L2TX or state commitment)
    uint256          destinationRollupId;    // rollup whose queue this entry is routed to
    CrossChainCall[] calls;                  // flat array of ALL calls in execution order
    NestedAction[]   nestedActions;          // sequentially consumed by reentrant calls
    uint256          callCount;              // entry-level iterations
    bytes            returnData;             // pre-computed return data for entry's top-level call
    bytes32          rollingHash;             // expected hash after all calls + nestings
}

struct LookupCall {
    bytes32          crossChainCallHash;
    uint256          destinationRollupId;
    bytes            returnData;
    bool             failed;
    uint64           callNumber;                 // _currentCallNumber at lookup time
    uint64           lastNestedActionConsumed;   // _lastNestedActionConsumed at lookup time
    CrossChainCall[] calls;                      // optional sub-calls (executed via STATICCALL)
    bytes32          rollingHash;                // expected hash of those sub-calls
}

struct ProxyInfo {
    address originalAddress;
    uint64  originalRollupId;
}

struct RollupConfig {
    address rollupContract;     // pre-deployed IRollup-conforming manager
    bytes32 stateRoot;
    uint256 etherBalance;
}

struct ProofSystemBatch {
    address[]        proofSystems;                    // sorted ascending; len >= rollupContract.threshold per rid
    uint256[]        rollupIds;                       // sorted strictly ascending; >= 1
    ExecutionEntry[] entries;                         // for the listed rollupIds
    LookupCall[]     lookupCalls;                     // for the listed rollupIds
    uint256          transientCount;
    uint256          transientLookupCallCount;
    uint256[]        blobIndices;
    bytes            callData;
    bytes[]          proof;                           // one per proofSystems entry
    bytes32          crossProofSystemInteractions;    // domain-separator for joined proofs
}
```

`ExecutionEntry` always succeeds at the top level. There is no `failed` flag — a reverting top-level call isn't an "execution," it's a lookup. Reverting cross-chain results are expressed via `LookupCall { failed: true }` consumed through `staticCallLookup` or the failed-reentry fallback in `_consumeNestedAction`. Inner naturally-reverting calls are still expressible: the proxy `.call` returns `(false, retData)` and the rolling hash captures it via `CALL_END`.

Cross-chain call hash formula (single, used everywhere):

```solidity
keccak256(abi.encode(targetRollupId, targetAddress, value, data, sourceAddress, sourceRollupId))
```

Exposed as `Rollups.computeCrossChainCallHash(...)` (`public pure`).

### Key Functions (L1 — Rollups)

1. **createRollup(address rollupContract, bytes32 initialState) → uint256 rollupId** — caller pre-deploys a manager (e.g. `Rollup.sol`) with proofSystems/threshold/owner baked in, then registers it. Registry assigns a fresh rollupId, fires `IRollup.rollupContractRegistered(rollupId)` once on the manager.
2. **createCrossChainProxy(originalAddress, originalRollupId)** — deploys a `CrossChainProxy` via CREATE2.
3. **postBatch(ProofSystemBatch[] batches)** — verifies one or more proof-system bundles in a single tx. Each sub-batch lists the proof systems, the rollupIds covered, the entries/lookupCalls, and the transient prefixes. Rolling rule: across the whole call, the leading transient prefix can immediately execute (entry 0 is run inline if its `crossChainCallHash == 0`), then `IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions()` runs if `msg.sender` has code. After the transient prefix is fully drained, the remainder publishes to the per-rollup `verificationByRollup[rid].queue`. If the prefix isn't drained cleanly, the remainder is dropped.
4. **executeCrossChainCall(sourceAddress, callData)** — entry point for proxies. Top-level call → `_consumeAndExecute` (consumes next entry from the routed rollup's queue; advances `verificationByRollup[rid].cursor`). Reentrant call (`_insideExecution() == true`) → `_consumeNestedAction`.
5. **executeL2TX(uint256 rollupId)** — permissionless. Consumes the next entry on `rollupId`'s queue, which must have `crossChainCallHash == bytes32(0)`.
6. **staticCallLookup(sourceAddress, callData)** — view. Looks up a `LookupCall` by `(crossChainCallHash, destinationRollupId, callNumber, lastNestedActionConsumed)`, scanning the transient table first then the routed rollup's `lookupQueue`. Replays cached sub-calls in static context, then either returns `returnData` or reverts with it (when `failed`).
7. **setStateRoot(uint256 rid, bytes32 newRoot)** — manager-only callback (caller must equal `rollups[rid].rollupContract`). Subject to a one-block lockout when the rollup just had a verified batch this block.
8. **setRollupContract(uint256 rid, address newContract)** — manager-only callback for handoff. Fires `rollupContractRegistered` on the new manager.
9. **computeCrossChainProxyAddress(originalAddress, originalRollupId)** — deterministic CREATE2 address. (Two parameters; no `domain` / `block.chainid`.)

### Key Functions (L2 — CrossChainManagerL2)

1. **loadExecutionTable(entries, lookupCalls)** — system-only. Wipes existing tables, loads new entries / lookup calls, sets `lastLoadBlock`.
2. **executeCrossChainCall(sourceAddress, callData)** — same shape as L1, but `sourceRollupId` in the call hash is forced to `ROLLUP_ID` (not `MAINNET_ROLLUP_ID`), and any `msg.value` is forwarded to `SYSTEM_ADDRESS` (burn). No state deltas, no ether accounting.
3. **staticCallLookup(sourceAddress, callData)** — same lookup key as L1. Scans only persistent `lookupCalls` (no transient table on L2).
4. **createCrossChainProxy(originalAddress, originalRollupId)** — same CREATE2 formula as L1.

### Multi-prover Model

A `ProofSystemBatch` carries a sorted-ascending `proofSystems` list, a sorted-ascending `rollupIds` list, and one `proof` per proof system. For each rollupId in the batch, the rollup's manager contract returns the per-PS verification keys via `getVkeysFromProofSystems(proofSystems)`; the manager rejects unknown PS or `proofSystems.length < threshold`. Verification is split into a shared public input (`sharedPublicInput`) plus a per-PS hash (`publicInputsHash[k] = H(sharedPublicInput, vk_k_for_each_rollup)`), letting different proof systems verify the same logical batch with their own vkey vectors.

### Per-Rollup Queue Model

`verificationByRollup[rid]` holds `{lastVerifiedBlock, queue, lookupQueue, cursor}`. Sub-batches push `entries`/`lookupCalls` onto their `destinationRollupId`'s queue; consumption (executeCrossChainCall, executeL2TX, staticCallLookup) pops via `cursor++`. Different rollups' queues are independent — meta-hook reentry into another rollup's queue is allowed; reentry into the same rollup is not. `setStateRoot` is locked for the rest of the block whenever a batch hit that rollup's queue earlier in the block.

### Execution Flow

1. **Verify** — `postBatch` validates each `ProofSystemBatch` (sorted invariants, vkey lookups, threshold), computes `publicInputsHash` from the entries/lookupCalls, and calls `proofSystem.verify(proof, publicInputsHash)` for each PS. After successful verification, `verificationByRollup[rid].lastVerifiedBlock = block.number` is recorded for each rollupId in the batch.
2. **Immediate prefix** — entries `[0..transientCount)` are placed in `_transientExecutions`. If `entries[0].crossChainCallHash == bytes32(0)`, it runs inline via a self-call `attemptApplyImmediate(0)` wrapped in try/catch — on revert the entry is `ImmediateEntrySkipped` and the cursor advances.
3. **Meta hook** — if `msg.sender` has code, `IMetaCrossChainReceiver.executeMetaCrossChainTransactions()` runs. The hook may consume more transient entries via cross-chain proxy calls.
4. **Deferred publish** — if the transient prefix is fully drained, `entries[transientCount..]` and `lookupCalls[transientLookupCallCount..]` are pushed to the routed rollups' `queue` / `lookupQueue`. Otherwise the remainder is dropped.
5. **Cleanup** — wipe `_transientExecutions` / `_transientLookupCalls`.
6. **Deferred consumption** — proxies / `executeL2TX` route to a specific rollup's queue. Sequential `cursor++`. The next entry's `crossChainCallHash` and `destinationRollupId` must match; mismatch reverts.
7. **Per-entry checks** — at the end of every entry execution: `_rollingHash == entry.rollingHash`, `_currentCallNumber == entry.calls.length`, `_lastNestedActionConsumed == entry.nestedActions.length`, and (L1) the L1 ether-delta invariant.

### Rolling Hash

A single `bytes32 rollingHash` per entry covers every call result and every nesting boundary. Four tagged events update the accumulator:

```
CALL_BEGIN   (1)   keccak256(prev, 0x01, callNumber)
CALL_END     (2)   keccak256(prev, 0x02, callNumber, success, retData)
NESTED_BEGIN (3)   keccak256(prev, 0x03, nestedNumber)
NESTED_END   (4)   keccak256(prev, 0x04, nestedNumber)
```

A single mismatch anywhere — wrong return data, wrong success/failure flag, missing or extra calls, incorrect nesting structure — produces a different final hash and is caught with one comparison. See `docs/SYNC_ROLLUPS_PROTOCOL_SPEC.md` §E for the full specification.

### `revertSpan`

`revertSpan > 0` is the **forced-revert** mechanism: the next `revertSpan` calls execute, succeed, and have their EVM state effects rolled back at the protocol layer. The processor self-calls `executeInContextAndRevert(revertSpan)` which always reverts with `error ContextResult(rollingHash, lastNestedActionConsumed, currentCallNumber)`. The EVM rolls back state inside the span, but the three values escape via the revert payload — the outer flow restores them so the rolling hash and counters reflect what happened inside the span.

**Use only for forced reverts.** The canonical scenario is a cross-chain call that succeeded on the destination but whose state must be discarded by the replaying side (e.g. an L2→L1 call that ran cleanly on L1 but was rolled back in L2's view). Naturally-reverting destinations need `revertSpan = 0`; the proxy `.call` already captures `(success=false, retData)` and hashes it into `CALL_END`.

**Three revert paths:**
- Top-level natural revert (immediate entry) → entry is `ImmediateEntrySkipped` (try/catch fallback in `attemptApplyImmediate`); cursor advances. For deferred entries, top-level reverts aren't expressible — the model says successful execution at top level always.
- **Reentrant** call that reverts → `LookupCall` with `failed = true`. `_consumeNestedAction` falls back to the matching cached entry and reverts with `returnData`; no cursor advances.
- Forced revert of successful call(s) → `revertSpan > 0`.

### `NestedAction` vs `LookupCall`

| Situation | Use |
|---|---|
| Reentrant call that **succeeds** | `NestedAction` |
| Reentrant call that **reverts** (caller catches with try/catch) | `LookupCall` with `failed = true` |
| Reentrant cross-chain `STATICCALL` (read-only) | `LookupCall` with `failed = false` |
| Inner natural revert of a non-reentrant call | put it in `calls[]` with `revertSpan = 0` and let `CALL_END(false, retData)` capture it |
| Successful call(s) whose state must be force-reverted | `revertSpan > 0` on the first call of the span |

Reverting reentrant calls cannot be `NestedAction` — the failed call's revert rolls back the consumption index `tstore`, making consumption silent. `LookupCall` is content-addressed by `(crossChainCallHash, destinationRollupId, callNumber, lastNestedActionConsumed)` and replays the cached revert deterministically.

### CREATE2 Address Derivation

```
salt          = keccak256(abi.encodePacked(originalRollupId, originalAddress))
bytecodeHash  = keccak256(creationCode || abi.encode(manager, originalAddress, originalRollupId))
proxyAddress  = address(uint160(uint256(keccak256(0xff || manager || salt || bytecodeHash))))
```

`computeCrossChainProxyAddress(originalAddress, originalRollupId)` takes two parameters — there is no `domain` / `block.chainid` in the salt.

## Documentation

- `docs/SYNC_ROLLUPS_PROTOCOL_SPEC.md` — formal protocol specification (data model, function specs, rolling-hash details, multi-prover model, per-rollup queue model, invariants).
- `docs/MULTI_PROVER_DESIGN.md` — design rationale for the multi-prover refactor on `feature/flatten`.
- `docs/EXECUTION_TABLE_SPEC.md` — how to build execution entries.
- `docs/CAVEATS.md` — edge cases.
- `docs/CHANGES_FROM_PREVIOUS.md` — migration notes from earlier branches.

## Testing

Tests use a `MockProofSystem` that accepts all proofs by default. Set `proofSystem.setVerifyResult(false)` to test proof rejection. Test fixtures live in `test/Base.t.sol` (single-PS happy-path setup) and integration tests deploy a per-rollup `Rollup` manager on the fly.
