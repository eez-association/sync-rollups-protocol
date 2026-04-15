# Plan — Flatten static-call dependencies (replaces the simple actionHash-only lookup)

## Context

The current static-call design (landed on `feature/fix_revert_continue_tests`) uses a minimal `StaticCall{actionHash, returnData, failed, stateRoots}` record. Lookup is a linear scan by `actionHash`; the first match wins. Two problems with this shape:

1. **Ambiguity.** Two different static calls in the same block can share the same `actionHash` preimage (same `(rollupId, destination, value=0, data, sourceAddress, sourceRollup, scope=[], isStatic=true)`) but legitimately return different values — e.g. a `price()` view called twice inside a larger flow where upstream state has mutated between the two calls. The current lookup picks the first entry and silently returns stale data.
2. **No cross-dependency verification.** `returnData` is a flat pre-committed blob. If the static call internally reads state that depends on *other* static calls (e.g. `oracle.priceThrough(router)` where `router` is itself another proxy), a changed dependency is not detected — as long as each pinned `stateRoot` matches, the result is accepted verbatim. The prover can lie silently.

`feature/static_non_flatten` already sketched a stronger shape that sidesteps both: the `StaticCall` entry carries a flat list of sub-calls it makes, each one is re-executed on-chain via STATICCALL through the source proxy, the results are chained into a rolling `keccak256` hash, and the entry is only trusted if the on-chain hash matches the prover-committed one. This plan brings that idea back while keeping the two conventions we've already committed to: a **separate static-call table** (distinct from `executions`) and the **`Action.isStatic` bool**.

## Recommended approach

Port the "flatten" structure from `feature/static_non_flatten` onto the current branch, adapted to our current naming and without the heavier batch-posting / `executionIndex` refactor.

### A. `StaticCall` struct — flattened

```solidity
struct StaticSubCall {
    address destination;
    bytes   data;
    address sourceAddress;
    uint256 sourceRollup;
}

struct StaticCall {
    bytes32              actionHash;       // keccak256(abi.encode(Action{...isStatic:true, value:0, scope:[]}))
    bytes                returnData;       // pre-committed return / revert payload
    bool                 failed;            // if true, staticCallLookup reverts with returnData
    uint256              lookupIndex;       // disambiguation: Nth static call in the batch (monotonically increasing)
    StaticSubCall[]      calls;             // flat list of STATICCALL sub-calls to re-execute on-chain
    bytes32              rollingHash;       // expected keccak chain over sub-call results
    RollupStateRoot[]    stateRoots;        // pinned rollup stateRoots (L1 only; must be empty on L2)
}
```

Key additions vs. the current shape:
- `StaticSubCall[] calls` — the flat dependency list.
- `bytes32 rollingHash` — what the on-chain re-execution must produce.
- `uint256 lookupIndex` — disambiguates duplicate `actionHash` entries within the same batch. Incremented by the manager every time `staticCallLookup` is entered; the entry must match both `actionHash` AND the current counter.

### B. Disambiguation — transient counter

Add to both `Rollups` and `CrossChainManagerL2`:

```solidity
uint256 private transient _staticLookupIndex; // reset per block via the lastStateUpdateBlock gate
```

In `staticCallLookup`, after the block-freshness check:

```solidity
uint256 current = _staticLookupIndex;
_staticLookupIndex = current + 1;
```

Match: `sc.actionHash == actionHash && sc.lookupIndex == current`. This makes each static call in a transaction unambiguously tied to its position in the lookup stream, killing the "same actionHash twice" problem. Note: because `staticCallLookup` is `view` and `transient` writes from a `view` function would revert, we must drop the `view` modifier (the function already only read state before, but `view` is no longer safe with transient mutation). This is a breaking ABI change — off-chain consumers that expected `view` need to be aware.

Alternative if we must keep `view`: move the counter to a non-transient storage slot that we reset inside `postBatch` / `loadExecutionTable` (not cheap but avoids the ABI change). Default recommendation: drop `view`.

### C. Re-execute sub-calls and verify rolling hash

Port `_processNStaticCalls` from `feature/static_non_flatten`:

```solidity
function _processNStaticCalls(StaticSubCall[] storage calls) internal view returns (bytes32 h) {
    for (uint256 i = 0; i < calls.length; i++) {
        StaticSubCall storage cc = calls[i];
        address sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollup);
        if (sourceProxy.code.length == 0) revert ProxyNotDeployed();
        (bool success, bytes memory retData) = sourceProxy.staticcall(
            abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.destination, cc.data))
        );
        h = keccak256(abi.encodePacked(h, success, retData));
    }
}
```

Inside `staticCallLookup`, after match and state-root check:

```solidity
if (sc.calls.length > 0) {
    if (_processNStaticCalls(sc.calls) != sc.rollingHash) revert RollingHashMismatch();
}
```

Note: `_processNStaticCalls` is itself `view`, so if we keep `staticCallLookup` non-view (Section B), `_processNStaticCalls` can still be `view` — the nesting is fine. If we keep `staticCallLookup` `view` and the counter non-transient, everything stays `view`.

### D. Errors

Add two new errors to `ICrossChainManager`:
- `RollingHashMismatch()`
- `ProxyNotDeployed()`

Reuse:
- `StaticCallNotFound` (unchanged, now thrown when neither `actionHash` nor `lookupIndex` match)
- `StaticCallStateRootMismatch` (unchanged)
- `StaticCallStateRootsNotSupported` (unchanged — L2 still must have empty `stateRoots`)

### E. ABI encoding for `postBatch` public inputs

Current: `keccak256(abi.encode(_staticCalls))` as the trailing term in `publicInputsHash`. With the new struct shape this value shifts (new fields), so every off-chain prover that computes `publicInputsHash` must be updated. Specifically, ensure the prover's encoding includes `calls`, `rollingHash`, `lookupIndex` in the exact field order above.

Add a small inline helper `_hashStaticCall(StaticCall calldata sc) returns (bytes32)` so on-chain code uses a canonical encoding that the prover can replicate byte-for-byte.

### F. Proxy — no change required

`CrossChainProxy._fallback` already routes to `staticCallLookup` based on the TSTORE probe. The new struct and logic are transparent to the proxy.

### G. Scope invariant — unchanged

Static-call action hashes are still computed at root scope (`scope: uint256[](0)`). The flatten approach changes *what* we verify post-match (sub-call replay + rolling hash), not *how* we match.

### H. Tests & docs to update

**Tests**
- `test/StaticCall.t.sol` — grow with:
  - Flatten happy path (one outer static call with two sub-calls whose rolling hash matches)
  - `RollingHashMismatch` (same setup but one sub-call's result is tampered by changing an intermediate state)
  - `ProxyNotDeployed` (sub-call references an un-deployed source proxy)
  - Disambiguation: same `actionHash` appearing twice in the batch with different `returnData`, both served correctly in lookup order
- `test/Rollups.t.sol` ECDSA-verifier test — re-align the public-inputs preimage for the new `StaticCall` encoding

**E2E**
- `script/e2e/staticCall/E2E.s.sol` — add Flow C: a static call whose `returnData` depends on a sub-call that routes through another proxy (exercise the `calls` array end-to-end on anvil)

**Docs**
- `docs/STATIC_CALLS.md` — rewrite §C (Data types), §E (Manager-side lookup), §F (Nested execution path). Replace the simple "pre-committed blob" narrative with the flatten / rolling-hash model. Update the L1 vs L2 differences table.
- `docs/SYNC_ROLLUPS_PROTOCOL_SPEC.md` §H — update the `StaticCall` definition, the lookup pseudocode, and the error catalog.
- `docs/EXECUTION_TABLE_SPEC.md` — touch only the "Static call table" row with the new field list.

## Files to modify / create

**Modify**
- `src/ICrossChainManager.sol` — new `StaticSubCall` struct, extended `StaticCall` struct, new errors.
- `src/Rollups.sol` — extend `staticCallLookup` (counter + sub-call replay + rolling-hash check); add `_processNStaticCalls`; adjust `postBatch` public-inputs if the encoding helper changes.
- `src/CrossChainManagerL2.sol` — mirror of the above; keep the `stateRoots` rejection.
- `test/StaticCall.t.sol` — extend with the four new scenarios above.
- `test/tmpECDSAVerifier.t.sol` — re-align the public-inputs preimage.
- `script/e2e/staticCall/E2E.s.sol` — add Flow C (depends on the e2e script landing first; this plan assumes it's in place).
- `docs/STATIC_CALLS.md`, `docs/SYNC_ROLLUPS_PROTOCOL_SPEC.md`, `docs/EXECUTION_TABLE_SPEC.md` — as listed in §H.

**Create** — none.

## Risks / open questions

1. **`view` vs transient counter.** The cleanest disambiguation uses a transient counter but requires `staticCallLookup` to become non-view. The alternative (storage counter reset in `postBatch`) stays `view` but costs 20k gas per batch. Recommendation: non-view; flag for user approval because it's an interface break on the proxy's staticcall path (proxies `staticcall` the manager — that still works because `staticcall` only forbids storage writes, not `nonpayable` functions; `transient` stores are allowed in non-`view` `staticcall`ed functions as long as the caller is in a non-static context, which is the case for the proxy's non-static `.call` into the manager during `_processCallAtScope`). Double-check this EVM rule before committing.
2. **Sub-call gas / DoS.** A malicious prover could submit a `StaticCall` with thousands of `calls` entries to grief gas. Consider a `MAX_SUB_CALLS` cap per entry (e.g. 64). Document or enforce.
3. **Encoding canonicalisation.** The prover must exactly match Solidity's `abi.encode` layout for nested dynamic types. An on-chain `_hashStaticCall` helper removes ambiguity.
4. **Interaction with `ProxyInfo.originalRollupId` truncation.** If a sub-call's `sourceRollup` exceeds `uint64`, `computeCrossChainProxyAddress` still produces a deterministic address but the registered proxy's stored id is truncated. Pre-existing; mention as a caveat.

## Verification

1. `forge build` — clean.
2. `forge test --match-path test/StaticCall.t.sol -vvv` — all new and existing tests pass.
3. `forge test --no-match-path "script/**"` — regression.
4. `bash script/e2e/shared/run-local.sh script/e2e/staticCall/E2E.s.sol` — Flows A, B, C exit 0.
5. Spec review — three docs agree on the new `StaticCall` shape and the rolling-hash verification flow.
