# Static Cross-Chain Calls

How read-only cross-chain calls are proven, loaded, and served by the sync-rollups contracts.

This document complements:
- `SYNC_ROLLUPS_PROTOCOL_SPEC.md` — overall data model and execution semantics.
- `EXECUTION_TABLE_SPEC.md` — how to build and consume the (non-static) execution table.

Static calls live in a **separate table** from the execution table. They are matched by action hash, served on demand, and are never consumed on use. This file is the reference for off-chain provers and engineers touching the proxy, manager, or prover code paths for static reads.

---

## A. Motivation

Cross-chain reads — e.g. an L1 contract wanting to call `view` functions on an L2 contract through a `CrossChainProxy` — do not modify state. Routing them through the normal execution table is both wasteful and semantically wrong:

- The execution table is one-shot (swap-and-pop on consumption); a view that is read N times would need N entries.
- Execution entries carry state deltas; a static call has none.
- A caller using `STATICCALL` must not be able to trigger state-mutating writes on the manager (pushing into storage arrays, emitting events, etc.).

The static call table is a purpose-built, read-only index. Each entry carries:

1. An `actionHash` that pins the exact CALL being served (including `isStatic = true`, `value = 0`).
2. Pre-computed `returnData` (or a revert payload, if `failed`).
3. A flat list of `StaticSubCall` dependencies — the STATICCALLs the target view function invokes through other proxies — together with a `rollingHash` that chains their replayed `(success, returnData)` tuples in order.
4. An optional set of `(rollupId, stateRoot)` pins under which the result is claimed to be valid.

Integrity rests on three checks performed at lookup time:

- The caller must be an authorized proxy, and the canonical Action rebuilt from the proxy's identity plus the incoming calldata must hash to an entry's `actionHash`.
- Every pinned state root on that entry must equal the rollup's current on-chain `stateRoot` (L1 only; L2 has no stateRoot mapping — see §F).
- If the entry lists sub-call dependencies, each one is re-executed via its source proxy under STATICCALL, and the chained `keccak256` of their `(success, returnData)` tuples must match the committed `rollingHash`.

The prover is trusted to construct the right set of pins and to enumerate every STATICCALL the target view function makes. The contract guarantees that (a) a result cannot be served if any pin diverges, and (b) if any sub-call result has changed since commit time (reorder, new intermediate state, fabricated intermediate value), the rolling-hash check rejects the entry. Under-pinning of *primary* rollups is still not detected on-chain — if a prover omits a rollup whose state influences the top-level view but whose storage is not touched by any listed sub-call, the result may be stale but the lookup will still succeed. The ZK proof over `keccak256(abi.encode(_staticCalls))` is what binds the prover to an honest pin set and an honest sub-call list — see §G.

---

## A.1 Why the sub-call list is flat (and why this is safe only for static calls)

The execution table and the static-call table serve superficially similar jobs — match an action hash, replay the outcome — but they have different shapes. The execution table is a scope tree consumed with `newScope` + try/catch for `ScopeReverted`, `REVERT_CONTINUE` lookup, per-step state-delta application, and `_etherDelta` reconciliation. The static-call table's dependency list (`StaticSubCall[] calls`) is flat and is replayed by a plain loop in `_processNStaticCalls`.

The reason for the asymmetry is the absence of state mutation on the static side:

- Regular CALLs mutate state. A child revert has to roll back a precise subset of state changes, and nested scopes need a hierarchy to navigate which deltas survive and which do not. That is what the scope tree + `REVERT_CONTINUE` + `stateDeltas` machinery exists for.
- Static calls mutate nothing. There is no state to roll back, no child scope to revert, no partial-revert bookkeeping. Individual sub-calls can legitimately revert inside the loop — the replay just folds `(false, revertBytes)` into the rolling hash and keeps going.

That is why the static table uses the flat `StaticSubCall[] calls` + `rollingHash` shape rather than a scope tree. Flattening would be unsafe for regular calls (it would discard the scope isolation that lets reverts roll back the right deltas); it is the natural shape for reads.

Practical consequences the implementation relies on:

- `staticCallLookup` and `_processNStaticCalls` are both `view`. Every sub-call is dispatched via STATICCALL, and EIP-1153 forbids `SSTORE` / `TSTORE` inside that frame — so the lookup cannot persist a disambiguation cursor or a counter.
- The prover-committed `rollingHash` is the full integrity check over the dependency chain. It subsumes what the scope tree does on the execution side, without any of its overhead.
- Because replays are side-effect-free, the same static entry can be read an unbounded number of times in the same block — there is no consumption, no swap-and-pop, no ordering dependency between readers.

Everything below describes the commitments, detections, and lookup semantics that ride on top of this choice.

---

## B. Scenario matrix

Static CALLs arise in two structurally distinct positions:

- **Top-level**: the caller hits a `CrossChainProxy` directly via `STATICCALL` from user/contract code. Nothing is on the manager's call stack above the proxy.
- **Nested**: a CALL action currently being resolved by the manager has `isStatic = true`; `_processCallAtScope` issues a STATICCALL to the source proxy. This path also covers static sub-calls performed inside an `executeL2TX` reconstruction.

Summary rule: **top-level static = lookup only; nested static = on-chain STATICCALL.**

| Origin → Destination | Position | How served | Destination-side on-chain trace |
|----------------------|----------|------------|---------------------------------|
| L1 → L2 | top-level | L1 `staticCallLookup` via proxy fallback | **none** — never executed on L2 |
| L1 → L2 | nested | L2 `_processCallAtScope` static branch, STATICCALL to source proxy | yes, on L2 |
| L2 → L1 | top-level | L2 `staticCallLookup` via proxy fallback | none — never executed on L1 |
| L2 → L1 | via `executeL2TX` | L1 `_processCallAtScope` static branch, STATICCALL to source proxy (see detail below) | yes, on L1 |
| L2 → L2 (intra-/cross-) | top-level | origin-side `staticCallLookup` | none on destination |
| L2 → L2 (intra-/cross-) | nested | destination-side `_processCallAtScope` static branch | yes, on destination |

### L2→L1 static via `executeL2TX`

The most common L2→L1 static call is not a standalone top-level lookup; it is an L2 user transaction whose execution includes a read-only cross-chain call to L1. The flow:

1. **L2 side**: the user STATICCALLs a proxy on L2. The proxy detects static context via the TSTORE probe and routes to `CrossChainManagerL2.staticCallLookup`, which matches a pre-committed `StaticCall` entry and returns the result. No execution entries consumed on L2 — the `StaticCall` table is used.
2. **L1 side**: `executeL2TX` processes the L2 transaction. Entry [0] is triggered by the L2TX action; its `nextAction` is a CALL with `isStatic = true`, targeting the L1 contract (e.g., CounterL1).
3. `_processCallAtScope` on L1 sees `isStatic == true` and calls `sourceProxy.staticcall(abi.encodeCall(executeOnBehalf, (destination, data)))`. The proxy takes the **admin path** (see §D) — `msg.sender == MANAGER` — and forwards directly to `destination.call{value: msg.value}(data)`. Because the entire frame is under STATICCALL, the EVM static flag propagates: `msg.value == 0`, the `.call` behaves as a STATICCALL, and the destination contract runs read-only on L1.
4. The destination contract (e.g., CounterL1) executes natively on L1 — no static-call table lookup involved.

Key points:
- **No `StaticCall` table on L1.** The L1 side resolves the call directly via the proxy's admin path — the destination contract runs natively on L1.
- **`StaticCall` table on L2.** The user's contract on L2 STATICCALLs the proxy → proxy detects static context via the TSTORE probe → `CrossChainManagerL2.staticCallLookup` matches the pre-committed `StaticCall` entry and returns `returnData`. No execution entries consumed on L2.
- **The proxy's admin path on L1 does NOT involve `staticCallLookup`.** The manager calls `executeOnBehalf` directly, which takes the admin path.

Consequence for observability: a top-level L1→L2 static call leaves **no trace on L2**. Tooling that reconstructs cross-chain flow from block logs alone will miss it. The origin side is observable: the `staticCalls[]` storage array is public, and the proxy's STATICCALL calldata plus `StaticCallNotFound`/`StaticCallStateRootMismatch` reverts are visible in traces.

---

## C. Data types

### `Action.isStatic`

A boolean field on `Action`. Canonical invariant on a CALL:

- `isStatic == true` ⇒ `value == 0`. A static CALL cannot transfer ETH.
- `isStatic` is part of `keccak256(abi.encode(action))`, so a static CALL and an otherwise-identical non-static CALL produce **different** action hashes.
- On every non-CALL action (RESULT, L2TX, REVERT, REVERT_CONTINUE), `isStatic` MUST be `false`.

Consequence: the static call table and the execution table are **non-overlapping index spaces**. An entry mis-placed in the wrong table will never be found.

### `RollupStateRoot`

```solidity
struct RollupStateRoot {
    uint256 rollupId;
    bytes32 stateRoot;
}
```

A single pin. `stateRoot` is the value that `rollups[rollupId].stateRoot` must equal at lookup time on L1.

### `StaticSubCall`

```solidity
struct StaticSubCall {
    address destination;   // target address on the sub-call's rollup
    bytes   data;          // calldata forwarded to destination
    address sourceAddress; // the proxy-identity making the STATICCALL (not used for hashing, used to derive sourceProxy)
    uint256 sourceRollup;  // the rollup whose proxy we STATICCALL through
}
```

A single flat STATICCALL dependency. The replay at lookup time derives the source proxy via `computeCrossChainProxyAddress(sourceAddress, sourceRollup)`, then invokes `sourceProxy.staticcall(abi.encodeCall(CrossChainProxy.executeOnBehalf, (destination, data)))`. The proxy must already be deployed — otherwise lookup reverts `ProxyNotDeployed()`.

### `StaticCall`

```solidity
struct StaticCall {
    bytes32            actionHash;   // keccak256(abi.encode(CALL)), isStatic=true, value=0
    bytes              returnData;   // pre-computed return data, OR the revert payload if failed
    bool               failed;        // if true, staticCallLookup reverts with returnData
    StaticSubCall[]    calls;         // flat list of STATICCALL dependencies the view invokes, in execution order
    bytes32            rollingHash;   // keccak-chain over (success, returnData) of `calls` replay
    RollupStateRoot[]  stateRoots;    // rollup state roots this result is valid against (L1 only)
}
```

The field order matches the on-chain struct and is what `abi.encode(_staticCalls)` in the public-inputs preimage commits to (see §G). `calls` and `rollingHash` together form the **cross-dependency integrity** check: the prover commits the exact STATICCALL chain the target view function will make, and the lookup re-runs that chain on-chain to ensure the intermediate values have not shifted since commit time. Empty `calls` (length 0) skips the replay — `rollingHash` is not consulted.

Contrast with `ExecutionEntry`:

| | `ExecutionEntry` | `StaticCall` |
|---|---|---|
| Matched by | `actionHash` + all `stateDeltas.currentState` match | `actionHash` + all `stateRoots` match (L1) + rolling-hash replay; `actionHash` + rolling-hash replay (L2) |
| Consumed on use | yes (swap-and-pop) | no |
| Carries `nextAction` | yes | no |
| Carries state deltas | yes | no — pins are read-only checks |
| Failure path | `RESULT.failed = true`, normal flow | raw revert with `returnData` bytes |

### Errors

- `StaticCallNotFound()` — no entry with the computed `actionHash`, or no entry with a compatible pin set.
- `StaticCallStateRootMismatch()` — entry matched by hash, but a pinned `(rollupId, stateRoot)` disagrees with current on-chain state (L1 only).
- `StaticCallStateRootsNotSupported()` — L2 entry carries a non-empty `stateRoots` array (L2 has no rollup stateRoot mapping; such entries would be unverifiable).
- `RollingHashMismatch()` — the replayed `keccak256`-chain over the entry's sub-call dependencies does not equal the committed `rollingHash`.
- `ProxyNotDeployed()` — a sub-call references a `(sourceAddress, sourceRollup)` whose `CrossChainProxy` has not yet been deployed at lookup time.
- `DuplicateStaticCallActionHash()` — L2 only. `loadExecutionTable` rejects the batch if two `StaticCall` entries share the same `actionHash`.

---

## D. Proxy-side detection

`CrossChainProxy` must distinguish, at fallback time, whether it is being invoked in a normal call context (route to `executeCrossChainCall`) or in a static context (route to `staticCallLookup`). It does so via a TSTORE-probe.

```solidity
uint256 transient _staticDetector;

function staticCheck() external {
    if (msg.sender == address(this)) {
        _staticDetector = 0;   // TSTORE — reverts under STATICCALL
    } else {
        _fallback();            // transparent-proxy guard
    }
}

function _fallback() internal {
    (bool success,) = address(this).call(abi.encodeCall(this.staticCheck, ()));
    // success == false  ⇒ STATICCALL context
    // success == true   ⇒ normal call context
    ...
}
```

Rationale:

- `TSTORE` reverts when nested inside a `STATICCALL` frame; `TLOAD` does not. The self-call isolates the TSTORE so its revert is caught locally instead of propagating.
- `transient` storage ensures no persistent state change across transactions.
- The `msg.sender == address(this)` guard on `staticCheck()` is the same transparent-proxy pattern used for `executeOnBehalf`: outsiders calling `staticCheck()` are routed through the fallback.

On detection:

- `success == false` (static) → STATICCALL into `MANAGER.staticCallLookup(msg.sender, msg.data)` (view).
- `success == true` (normal) → `MANAGER.call{value: msg.value}(executeCrossChainCall(msg.sender, msg.data))`.

Return data decoding is unchanged: on success, the manager's `bytes memory` return value is double-ABI-encoded, so the proxy decodes one layer before returning. On revert, the raw revert bytes are forwarded directly.

Gas footprint: one self-call + one TSTORE (~100 gas plus call overhead) per fallback entry. An OOG'd probe cannot silently mis-route — the subsequent `MANAGER.staticcall` / `.call` in the same frame also OOGs. See §H.

### Admin path vs fallback path

The proxy has two structurally distinct entry paths. Understanding which path is taken matters for reasoning about static call routing:

- **Admin path** (`msg.sender == MANAGER`): entered when the manager calls `executeOnBehalf(destination, data)` directly. The proxy forwards to `destination.call{value: msg.value}(data)` via assembly return/revert. **No TSTORE probe, no `staticCheck`, no routing to `staticCallLookup` or `executeCrossChainCall`.** This is the path used by `_processCallAtScope` for both regular and static nested calls.

  When `_processCallAtScope` has a CALL with `isStatic == true`, it invokes `sourceProxy.staticcall(abi.encodeCall(executeOnBehalf, (destination, data)))`. The proxy receives a STATICCALL, enters `executeOnBehalf`, sees `msg.sender == MANAGER`, and does `destination.call{value: msg.value}(data)`. Because the frame is under STATICCALL, the EVM static flag propagates: `msg.value == 0` and the `.call` behaves as a STATICCALL at the EVM level. Note that `executeOnBehalf` itself does not check `isStatic` — the static enforcement comes from the STATICCALL context set by `_processCallAtScope`.

- **Fallback path** (any other caller): entered when an EOA or external contract calls the proxy (either via `fallback()` or via `executeOnBehalf` with `msg.sender != MANAGER`). Goes through `_fallback()` → TSTORE probe → routes to either `executeCrossChainCall` (normal context) or `staticCallLookup` (static context). This is the path used by top-level callers hitting a proxy directly.

---

## E. Manager-side lookup

Both managers expose `staticCallLookup(address sourceAddress, bytes calldata callData) external view returns (bytes memory)`, called only by a `CrossChainProxy` that has detected a static context.

Common procedure:

1. **Freshness guard**: `lastStateUpdateBlock == block.number`, otherwise revert `ExecutionNotInCurrentBlock`. A static table is only valid in the block it was posted/loaded.
2. **Authorized-proxy guard**: `authorizedProxies[msg.sender].originalAddress != address(0)`.
3. **Canonical Action rebuild**: `isStatic = true`, `value = 0`, `rollupId = proxyInfo.originalRollupId`, `destination = proxyInfo.originalAddress`, `sourceAddress`, `sourceRollup = MAINNET_ROLLUP_ID` (L1) or `ROLLUP_ID` (L2), `data = callData`, `scope = new uint256[](0)` (see §G for the scope invariant).
4. **Hash**: `keccak256(abi.encode(action))`.
5. **Linear scan** of `staticCalls[]` for a matching `actionHash`.
6. **Per-manager pin check** (see table below).
7. **Sub-call replay**: if `sc.calls.length > 0`, run `_processNStaticCalls(sc.calls)` — for each sub-call, derive the source proxy via `computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollup)`, verify it is deployed (else revert `ProxyNotDeployed`), invoke `sourceProxy.staticcall(abi.encodeCall(executeOnBehalf, (cc.destination, cc.data)))`, and fold the result into `h = keccak256(abi.encodePacked(h, success, ret))`. If the final `h` differs from `sc.rollingHash`, revert `RollingHashMismatch`.
8. On match: if `failed`, revert with raw `returnData` bytes; else return `returnData`.
9. On no match: revert `StaticCallNotFound`.

The entry is **not removed** on use. Multiple calls in the same block that hash to the same entry all succeed.

### L1 vs L2 differences

| | L1 (`Rollups.sol`) | L2 (`CrossChainManagerL2.sol`) |
|---|---|---|
| Binding to batch | ZK proof over `keccak256(abi.encode(_staticCalls))` folded into public inputs (see §G) | System-address `loadExecutionTable` only, no proof |
| `sourceRollup` on rebuilt Action | `MAINNET_ROLLUP_ID` (0) | this chain's `ROLLUP_ID` |
| Pin check | For each `sc.stateRoots[j]`, require `rollups[sr.rollupId].stateRoot == sr.stateRoot`, else revert `StaticCallStateRootMismatch` | **`sc.stateRoots.length != 0` reverts `StaticCallStateRootsNotSupported`.** L2 has no rollup state-root mapping; pins cannot be verified there, so they are disallowed |
| Empty `stateRoots` | Valid — the entry is served unconditionally apart from the sub-call replay (prover takes responsibility; see §G) | **Required** |
| Sub-call replay (`calls` / `rollingHash`) | Runs identically — re-executes `calls[]` in order via source proxies, requires folded keccak == `rollingHash` | Runs identically |
| Ambiguity disambiguation | `(actionHash, stateRoots)`: two entries sharing `actionHash` with identical pins MUST share `returnData` by construction, so collisions are benign | **Hard-rejected at load time**: `loadExecutionTable` reverts `DuplicateStaticCallActionHash` if any two entries share the same `actionHash` |
| Entry consumed on use | No | No |

Failed entries replay their `returnData` bytes verbatim via `assembly { revert(add(returnData, 0x20), mload(returnData)) }`. The payload is **not** ABI-wrapped by the contract — the prover must pre-encode any custom-error selector or ABI structure it wants the caller to observe.

---

## F. Nested execution path

When a CALL action currently being resolved by the manager carries `isStatic = true`, the scope machinery does not hit the static call table. Instead, `_processCallAtScope` takes the static branch:

```solidity
if (action.isStatic) {
    (success, returnData) = address(sourceProxy).staticcall(
        abi.encodeCall(CrossChainProxy.executeOnBehalf, (action.destination, action.data))
    );
} else {
    (success, returnData) = address(sourceProxy).call{value: action.value}(...);
    if (action.value > 0 && success) _etherDelta -= int256(action.value);
}
```

Properties of this branch:

- `STATICCALL`, never `CALL`; no ETH moves.
- `_etherDelta` is not updated — consistent with `value == 0` invariant.
- The subsequent RESULT is built normally (`isStatic = false` on RESULT), hashed, and looked up **in the execution table**. A nested static sub-call's continuation is scheduled via `ExecutionEntry`, not `StaticCall`.

Framing: **the static call table serves entry points; the execution table serves control flow.** `staticCallLookup` is only ever called from `CrossChainProxy._fallback`; it is never invoked from inside `_processCallAtScope`. The two indexes are disjoint and used at different stages.

Note that when the entry point *is* a `staticCallLookup` hit, the lookup's own on-chain STATICCALL replay of `calls[]` is the integrity check for intra-dependency tampering: the flat sub-call list is re-executed under STATICCALL, and the rolling-hash match guarantees no intermediate result has drifted since commit. `staticCallLookup` itself stays `view` — EIP-1153 forbids `TSTORE` and `SSTORE` inside STATICCALL, so there is no room for a persisted counter or disambiguation cursor. Entry disambiguation therefore rests on `(actionHash, stateRoots)` on L1 and on load-time uniqueness on L2.

---

## G. Batch wiring

### L1 `postBatch` signature

```solidity
function postBatch(
    ExecutionEntry[] calldata entries,
    StaticCall[] calldata _staticCalls,
    uint256 blobCount,
    bytes calldata callData,
    bytes calldata proof
) external;
```

The public-inputs hash folds the static-call table through `abi.encode` directly — the same shape used for execution entries:

```solidity
publicInputsHash = keccak256(abi.encodePacked(
    blockhash(block.number - 1),
    block.timestamp,
    abi.encode(entryHashes),
    abi.encode(blobHashes),
    keccak256(callData),
    keccak256(abi.encode(_staticCalls))
));
```

Any change to the static-call set — including the ordering or contents of `calls`, the pin arrays, or the committed `rollingHash` — changes `keccak256(abi.encode(_staticCalls))` and therefore the proof. Off-chain provers MUST match Solidity's `abi.encode` of `StaticCall[]` byte-for-byte.

**Empty-table term**: with `_staticCalls.length == 0`, `keccak256(abi.encode(_staticCalls))` is the hash of the ABI encoding of an empty dynamic array, not `bytes32(0)`. Provers should not special-case empty tables.

### Table lifecycle (L1)

Inside `postBatch`:

1. Verify the proof against the public-inputs hash above.
2. `delete executions;` and `delete staticCalls;`.
3. Push each `_staticCalls[i]` into storage.
4. Set `lastStateUpdateBlock = block.number`.

Both tables live only for the block in which they were posted. `staticCallLookup` rejects any lookup outside that block via the freshness guard.

### L2 `loadExecutionTable`

```solidity
function loadExecutionTable(
    ExecutionEntry[] calldata entries,
    StaticCall[] calldata _staticCalls
) external onlySystemAddress;
```

No proof; trust comes from the system-address gate. Same delete-then-push pattern as L1; same same-block freshness guard on `staticCallLookup`. Before accepting the batch, `loadExecutionTable` runs an **O(n²) uniqueness pre-check** across `_staticCalls[i].actionHash`: any pair sharing an `actionHash` reverts the whole load with `DuplicateStaticCallActionHash`. This is necessary because L2 has no `stateRoots` disambiguator, so first-match-wins at lookup time would silently select whichever entry happened to be indexed first; rejecting at load time gives the prover an immediate, explicit failure.

---

## H. Invariants and edge cases

- **`actionHash` MUST use `isStatic = true`, `value = 0`.** Every on-chain rebuild does so; any prover-side hash that flips either field will miss the table.
- **Static-call action hashes are ALWAYS computed at root scope — `scope: new uint256[](0)` — even when the static call is nested.** On-chain, `staticCallLookup` unconditionally constructs the Action with an empty scope; a nested static lookup will still hash against the root-scope preimage. Off-chain provers MUST follow this convention when computing `StaticCall.actionHash`, otherwise the hash will not match on-chain reconstruction.
- **L2 `StaticCall.stateRoots` MUST be empty.** L2 has no rollup stateRoot mapping; non-empty entries revert `StaticCallStateRootsNotSupported()`. L1 entries MAY be empty (served unconditionally) or non-empty (each pin checked against `rollups[rollupId].stateRoot`).
- **Empty `stateRoots` on L1 means unconditional serving.** The pin loop does nothing and the entry is returned. This is a prover-side liveness/correctness trade-off: correctness now rests entirely on the ZK proof.
- **Under-pinning is not detected on-chain.** If a prover omits a rollup whose state influences the read, the result may be stale. The proof is what binds the prover to an honest pin set.
- **Over-pinning hurts liveness only.** An unnecessary pin will cause spurious `StaticCallStateRootMismatch` reverts if that rollup's state updates in the same block, but never lets through an incorrect result.
- **`failed = true` replays raw revert bytes.** The contract does not wrap them; the prover must pre-encode any error selector, error struct, or plain-string payload that the caller expects to decode.
- **Static call entries are not consumed on lookup.** Unlike execution-table entries, a matching `StaticCall` is left in place; N lookups in the same block that hash to the same entry all succeed.
- **Freshness**: `staticCallLookup` reverts `ExecutionNotInCurrentBlock` if `lastStateUpdateBlock != block.number`. Cross-block caching is not supported at the contract layer.
- **Top-level L1→L2 static leaves no destination-side on-chain footprint.** Block explorers and trace-based tooling must read the origin-side `staticCalls[]` storage array and STATICCALL calldata; there is no L2 log to correlate against.
- **Nested static sub-calls inside `executeL2TX` go through the scope machinery, not `staticCallLookup`.** Their RESULT lookups hit the execution table (see §F).
- **Non-overlapping index spaces.** Because `isStatic` is part of `actionHash`, an entry placed in the wrong table is unreachable — a useful invariant when debugging "which table should this go in?"
- **TSTORE-probe OOG behaviour is safe by construction.** If the `staticCheck()` self-call OOGs, `success == false` and the proxy routes to `MANAGER.staticcall(staticCallLookup(...))`. The self-call receives 63/64 of the remaining gas under EIP-150, so if a TSTORE (~100 gas) could not complete, the subsequent `MANAGER.staticcall` / `MANAGER.call` in the same frame cannot complete either — a mis-routed path fails loudly with an OOG rather than silently executing under the wrong entry point. No `gasleft()` guard is needed.
- **Sub-call ordering is strict.** `calls[]` MUST list the STATICCALL dependencies in the exact order the target view function invokes them. Any reorder — even swapping two independent reads — produces a different `keccak256` chain and the lookup reverts `RollingHashMismatch`. Provers MUST trace the target's execution (not derive the set from ABI/source inspection alone) to get the order right.
- **Sub-call proxies must be pre-deployed.** `_processNStaticCalls` derives each source proxy via `computeCrossChainProxyAddress(sourceAddress, sourceRollup)` and reverts `ProxyNotDeployed` if `sourceProxy.code.length == 0`. There is no auto-create path inside the static-call replay (the lookup is `view`, so it cannot `CREATE2`). Provers building entries that reference new `(address, rollupId)` pairs MUST either (a) emit a prior `createCrossChainProxy` call in the same block or (b) avoid listing sub-calls through not-yet-deployed identities.
- **L2 duplicate-actionHash rejection at load time.** `loadExecutionTable` on L2 runs an O(n²) scan over `_staticCalls[*].actionHash` and reverts `DuplicateStaticCallActionHash` on any pair collision. This replaces the silent first-match-wins behaviour the naive lookup would otherwise exhibit on L2 (which has no `stateRoots` to disambiguate). On L1, duplicates with matching `stateRoots` MUST by construction carry identical `returnData`, so no analogous load-time check is needed there.
- **Rolling-hash preimage is raw inner return data, not ABI-wrapped `bytes`.** The replay folds `h = keccak256(h ++ bool(success) ++ ret)` where `ret` is whatever the low-level `sourceProxy.staticcall(...)` returns. Because `CrossChainProxy.executeOnBehalf` uses an assembly `return` that bypasses the Solidity ABI wrapper, `ret` here is the **inner** returndata from the destination's `staticcall` — NOT an outer `abi.encode(bytes)` blob. Off-chain provers computing `rollingHash` MUST model this exactly: start with `h_0 = bytes32(0)`, then `h_i = keccak256(h_{i-1} || bool(success_i) || raw_inner_returndata_i)` — no extra length prefix, no ABI wrapping. On revert, `ret` is the raw revert bytes forwarded by the proxy's assembly fall-through.
