# Sync-Rollups Protocol Specification

**Version**: feature/contract_updates branch
**Source**: `contracts/sync-rollups/src/`
**Purpose**: Formal reference for implementing the Rust rollup node. Supersedes informal comments in source code.

---

## Table of Contents

- [A. Data Model](#a-data-model)
- [B. Core Protocol Functions](#b-core-protocol-functions)
- [C. Action Hash Computation](#c-action-hash-computation)
- [D. Scope Navigation](#d-scope-navigation)
- [E. Execution Entry Lifecycle](#e-execution-entry-lifecycle)
- [F. Cross-Chain Call Flows](#f-cross-chain-call-flows)
- [G. Bridge Protocol](#g-bridge-protocol)
- [H. Invariants](#h-invariants)
- [I. Security Considerations](#i-security-considerations)

---

## A. Data Model

### A.1 Enumerations

```solidity
enum ActionType {
    CALL,            // 0 — a cross-chain call to execute on the destination rollup
    RESULT,          // 1 — the outcome (success + return data, or failure) of a CALL
    L2TX,            // 2 — a pre-computed RLP-encoded L2 transaction (permissionless trigger)
    REVERT,          // 3 — signals that a scope-level execution failed; triggers state rollback
    REVERT_CONTINUE  // 4 — continuation looked up after a REVERT has been handled
}
```

### A.2 Core Structs

#### Action

The unit of cross-chain work. Every interaction in the execution table is described by one Action.

```solidity
struct Action {
    ActionType actionType;   // kind of action
    uint256    rollupId;     // target rollup (0 = L1 mainnet)
    address    destination;  // contract to call (CALL) or address(0) (RESULT/L2TX/REVERT*)
    uint256    value;        // ETH to send with CALL; 0 otherwise
    bytes      data;         // calldata (CALL), return data (RESULT), RLP tx (L2TX), or "" (REVERT*)
    bool       failed;       // false for CALL/L2TX; success flag for RESULT; true for REVERT*
    address    sourceAddress;// immediate caller identity (CALL only); address(0) otherwise
    uint256    sourceRollup; // caller's rollup ID (CALL only); 0 otherwise
    uint256[]  scope;        // hierarchical nesting path (see §D); empty for root-level actions
}
```

Field semantics by ActionType:

| Field | CALL | RESULT | L2TX | REVERT | REVERT_CONTINUE |
|-------|------|--------|------|--------|-----------------|
| rollupId | destination rollup | rollup that was called | rollup of tx | rollup that reverted | rollup that reverted |
| destination | callee address | address(0) | address(0) | address(0) | address(0) |
| value | ETH sent | 0 | 0 | 0 | 0 |
| data | calldata | return bytes | RLP-encoded tx | "" | "" |
| failed | false | !success | false | true | true |
| sourceAddress | caller address | address(0) | address(0) | address(0) | address(0) |
| sourceRollup | caller's rollupId | 0 | MAINNET_ROLLUP_ID | 0 | 0 |
| scope | target scope path | [] | [] | target scope | [] |

#### StateDelta

Describes a single rollup's state transition caused by executing one action.

```solidity
struct StateDelta {
    uint256 rollupId;      // which rollup's state changes
    bytes32 currentState;  // expected pre-execution state root (must match on-chain)
    bytes32 newState;      // post-execution state root
    int256  etherDelta;    // signed change in rollup's ETH balance (positive = deposit, negative = withdrawal)
}
```

#### ExecutionEntry

One row in the execution table. Links an action hash to the state transitions it causes and the next action to execute after it.

```solidity
struct ExecutionEntry {
    StateDelta[] stateDeltas; // state transitions when this entry is consumed
    bytes32      actionHash;  // keccak256(abi.encode(action)) that triggers consumption
                              // bytes32(0) = immediate (applied at postBatch time)
    Action       nextAction;  // what to do after this entry is consumed
}
```

#### StaticSubCall

Describes a single sub-call to execute in static context during rolling hash verification.

```solidity
struct StaticSubCall {
    address destination;    // target address to call
    bytes   data;           // calldata for the call
    address sourceAddress;  // caller identity (determines source proxy)
    uint256 sourceRollup;   // caller's rollup ID (determines source proxy)
}
```

#### StaticCall

Pre-computed result for a static (read-only) cross-chain call or a call whose revert needs to be replayed. Loaded via `postBatch` (L1) or `loadExecutionTable` (L2).

```solidity
struct StaticCall {
    bytes32        actionHash;     // keccak256(abi.encode(CALL action)) with value=0
    bytes          returnData;     // pre-computed return data (or revert payload if failed)
    bool           failed;         // if true, staticCallLookup reverts with returnData
    uint256        executionIndex; // disambiguates: the executionIndex at the time of this static call
    StaticSubCall[] calls;         // sub-calls to execute in static context
    bytes32        rollingHash;    // expected hash of all sub-call results (verified on-chain)
}
```

Field semantics:

| Field | Purpose |
|-------|---------|
| actionHash | Identifies which cross-chain call this result belongs to. Computed as `keccak256(abi.encode(action))` where the action has `value=0` (ETH cannot be sent in STATICCALL). |
| returnData | The pre-computed return data. Returned to the caller on success, or used as revert payload if `failed == true`. |
| failed | If true, `staticCallLookup` reverts with `returnData` instead of returning it. Used for calls whose revert needs to be replayed. |
| executionIndex | The value of `executionIndex` at the moment this static call occurs during execution. Used for disambiguation when the same `actionHash` appears at different execution points. |
| calls | Sub-calls to execute in static context. If non-empty, `_processNStaticCalls` runs them and verifies the result hash matches `rollingHash`. |
| rollingHash | Expected hash of all sub-call results. Verified on-chain by `_processNStaticCalls`. |

**Note**: An older design (`problems/static-call-flatten2-reference.md`) used `callNumber` + `lastNestedActionConsumed` for disambiguation. The current implementation uses `executionIndex` instead.

#### ProxyInfo

Identity stored for each authorized CrossChainProxy.

```solidity
struct ProxyInfo {
    address originalAddress;    // the address this proxy represents on its home rollup
    uint64  originalRollupId;   // the home rollup ID
}
```

#### RollupConfig (L1 only)

Per-rollup configuration on the Rollups.sol contract.

```solidity
struct RollupConfig {
    address owner;            // can call setStateByOwner and setVerificationKey
    bytes32 verificationKey;  // used in ZK proof public inputs construction
    bytes32 stateRoot;        // current committed state root
    uint256 etherBalance;     // ETH held on behalf of this rollup (wei)
}
```

### A.3 Storage Layout

#### Rollups.sol (L1)

| Slot | Variable | Type | Notes |
|------|----------|------|-------|
| 0 | rollupCounter | uint256 | Next rollup ID to assign; constructor sets startingRollupId |
| 1 | rollups | mapping(uint256 => RollupConfig) | Keyed by rollupId |
| 2 | executions | ExecutionEntry[] | Dynamic array; cleared on each postBatch |
| 3 | executionIndex | uint256 | Index of the next execution entry to consume; reset to 0 on each postBatch |
| 4 | staticCalls | StaticCall[] | Dynamic array of pre-computed static call results; cleared on each postBatch |
| 5 | authorizedProxies | mapping(address => ProxyInfo) | Keyed by proxy address |
| 6 | lastStateUpdateBlock | uint256 | Block number of last postBatch |
| transient | _etherDelta | int256 | EIP-1153 transient; tracks ETH flow within one executeCrossChainCall context |

`MAINNET_ROLLUP_ID = 0` is a constant, not storage.

`ZK_VERIFIER` is an immutable (no storage slot).

#### CrossChainManagerL2.sol (L2)

| Slot | Variable | Type | Notes |
|------|----------|------|-------|
| 0 | executions | ExecutionEntry[] | Dynamic array; cleared on each loadExecutionTable |
| 1 | executionIndex | uint256 | Index of the next execution entry to consume; reset to 0 on each loadExecutionTable |
| 2 | staticCalls | StaticCall[] | Dynamic array of pre-computed static call results; cleared on each loadExecutionTable |
| 3 | authorizedProxies | mapping(address => ProxyInfo) | Keyed by proxy address |
| 4 | lastStateUpdateBlock | uint256 | Block number of last loadExecutionTable |

`ROLLUP_ID` and `SYSTEM_ADDRESS` are immutables (no storage slots).

### A.4 Shared Interface (ICrossChainManager)

The following errors and functions are defined in the `ICrossChainManager` interface, shared between L1 (`Rollups`) and L2 (`CrossChainManagerL2`):

**Errors**:
- `UnauthorizedProxy()` — caller is not an authorized proxy
- `OnlySelf()` — only self-calls allowed (e.g., `newScope` recursive calls)
- `ExecutionNotFound()` — no matching execution entry for the action hash
- `CallExecutionFailed()` — cross-chain call resolved to a non-RESULT action
- `InvalidRevertData()` — revert data from a child scope is too short to decode
- `ExecutionNotInCurrentBlock()` — execution attempted in a different block than the last state update
- `StaticCallNotFound()` — no matching static call entry
- `RollingHashMismatch()` — static sub-call results don't match the expected rolling hash
- `ProxyNotDeployed()` — a static sub-call references a proxy that hasn't been deployed yet

**Functions**:
- `executeCrossChainCall(address sourceAddress, bytes calldata callData) external payable returns (bytes memory)`
- `staticCallLookup(address sourceAddress, bytes calldata callData) external view returns (bytes memory)`
- `createCrossChainProxy(address originalAddress, uint256 originalRollupId) external returns (address)`
- `computeCrossChainProxyAddress(address originalAddress, uint256 originalRollupId) external view returns (address)`
- `newScope(uint256[] memory scope, Action memory action) external returns (Action memory)`

**Note**: `ScopeReverted` remains contract-specific. On L1 it carries `(bytes nextAction, bytes32 stateRoot, uint256 rollupId)` for state restoration. On L2 it carries only `(bytes nextAction)` (no rollup state to restore).

---

## B. Core Protocol Functions

### B.1 Rollups.sol (L1)

---

#### `createRollup`

```solidity
function createRollup(
    bytes32 initialState,
    bytes32 verificationKey,
    address owner
) external returns (uint256 rollupId)
```

**Access control**: permissionless — any caller.

**Preconditions**: none.

**State transitions**:
- `rollupId = rollupCounter`
- `rollupCounter += 1`
- `rollups[rollupId] = RollupConfig(owner, verificationKey, initialState, etherBalance=0)`

**Postconditions**:
- `rollups[rollupId].stateRoot == initialState`
- `rollups[rollupId].etherBalance == 0`
- `rollupCounter == old(rollupCounter) + 1`

**Events**: `RollupCreated(rollupId, owner, verificationKey, initialState)`

**Revert conditions**: none.

---

#### `postBatch`

```solidity
function postBatch(
    ExecutionEntry[] calldata entries,
    StaticCall[] calldata _staticCalls,
    uint256 blobCount,
    bytes calldata callData,
    bytes calldata proof
) external
```

**Access control**: permissionless.

**Preconditions**:
- `lastStateUpdateBlock != block.number` (one batch per block)
- Proof must verify (see public inputs construction below)

**Public inputs construction** (computed by `_buildPublicInputsHash` helper):

```
For each entry i:
  vks[j] = rollups[entries[i].stateDeltas[j].rollupId].verificationKey  for j in stateDeltas

  entryHashes[i] = keccak256(
    abi.encodePacked(
      abi.encode(entries[i].stateDeltas),
      abi.encode(vks),
      entries[i].actionHash,
      abi.encode(entries[i].nextAction)
    )
  )

blobHashes[i] = blobhash(i)  for i in 0..blobCount

publicInputsHash = keccak256(
  abi.encodePacked(
    blockhash(block.number - 1),
    block.timestamp,
    abi.encode(entryHashes),
    abi.encode(blobHashes),
    keccak256(callData),
    keccak256(abi.encode(_staticCalls))
  )
)
```

Static calls ARE included in the public inputs hash via `keccak256(abi.encode(_staticCalls))`. This ensures the ZK proof covers the static call data.

The verifier receives `(proof, publicInputsHash)` and must return `true`.

**State transitions** (in order):

1. Build `publicInputsHash = _buildPublicInputsHash(entries, _staticCalls, blobCount, callData)`
2. Verify proof
3. Delete previous tables: `delete executions`, `delete staticCalls`, `executionIndex = 0`
4. Store all entries: for each entry `e`, `executions.push(e)` (including immediate entries)
5. Store all static calls: for each static call `sc`, `staticCalls.push(sc)`
6. `lastStateUpdateBlock = block.number` (set BEFORE the immediate entry loop, so `executeL2TX()` can pass its block check)
7. Apply immediate entries via while loop: `while (executionIndex < executions.length && executions[executionIndex].actionHash == bytes32(0)) { executeL2TX(); }` — calls the public `executeL2TX()` function which internally calls `_findAndApplyExecution(bytes32(0), _l2TxAction())`
8. `emit BatchPosted(entries, publicInputsHash)`

**Key change from previous design**: ALL entries are now stored in the `executions` array first (including immediates). Immediate entries are then consumed via the while loop by calling `executeL2TX()`. This means the execution table always contains the full set of entries; consumed entries are tracked by `executionIndex` rather than removed.

**Postconditions**:
- `executions` contains ALL entries from this batch (both immediate and deferred)
- `executionIndex` points past the last consumed immediate entry
- All immediate entries' state deltas have been applied to `rollups`
- `staticCalls` contains all provided static call entries
- `lastStateUpdateBlock == block.number`

**Events**: `BatchPosted(entries, publicInputsHash)`

**Revert conditions**:
- `StateAlreadyUpdatedThisBlock` — `lastStateUpdateBlock == block.number`
- `InvalidProof` — verifier returns false
- `StateRootMismatch` — an immediate entry's `currentState` doesn't match on-chain state root (thrown by `_findAndApplyExecution`)
- `EtherDeltaMismatch` — ether accounting mismatch during immediate entry application
- `InsufficientRollupBalance` — applying a negative etherDelta would underflow the rollup's balance
- `ExecutionNotFound` — while loop encounters a non-failed non-matching entry (should not happen with correct builder output)

**Note on ether accounting for immediate entries**: since `postBatch` does not transfer ETH, `_etherDelta` starts at 0. `_applyStateDeltas` checks `totalEtherDelta != _etherDelta`. For immediate entries this means the sum of all `etherDelta` fields must be exactly zero.

**Data availability via `blobCount` and `callData`**: The `blobCount` and `callData` parameters serve as the data availability (DA) channels for the batch. The full L2 transaction data (RLP-encoded user transactions, execution traces, etc.) is published through one or both of these channels:
- **Blobs** (`blobCount`): EIP-4844 blobs attached to the `postBatch` transaction. The contract reads blob hashes via `blobhash(i)` for `i in 0..blobCount` and includes them in the public inputs.
- **Calldata** (`callData`): Arbitrary data passed inline. Its hash `keccak256(callData)` is included in the public inputs.

The ZK proof guarantees that the execution entries are a correct derivation from this published data. The contract itself never interprets the raw L2 transactions — it only consumes the pre-computed execution entries. External observers (nodes, indexers) can reconstruct the full L2 state by reading the blob/calldata from the `postBatch` transaction.

---

#### `executeCrossChainCall`

```solidity
function executeCrossChainCall(
    address sourceAddress,
    bytes calldata callData
) external payable returns (bytes memory result)
```

**Access control**: only authorized proxies (`authorizedProxies[msg.sender].originalAddress != address(0)`).

**Preconditions**:
- `authorizedProxies[msg.sender]` is populated (caller is a registered proxy)
- `lastStateUpdateBlock == block.number` (executions can only be consumed in the posting block)

**Parameters**:
- `sourceAddress`: the `msg.sender` of the original call to the proxy (the caller's on-chain identity)
- `callData`: the original calldata forwarded by the proxy

**State transitions**:

1. Read proxy identity: `proxyRollupId = proxyInfo.originalRollupId`, `proxyOriginalAddr = proxyInfo.originalAddress`
2. If `msg.value > 0`: `_etherDelta += int256(msg.value)` (track ETH received)
3. Construct CALL action:
   ```
   action = Action{
     actionType: CALL,
     rollupId:   proxyRollupId,       // rollup the proxy represents
     destination: proxyOriginalAddr,  // the original address on that rollup
     value:       msg.value,
     data:        callData,
     failed:      false,
     sourceAddress: sourceAddress,    // who called the proxy
     sourceRollup: MAINNET_ROLLUP_ID, // always L1 (this is the L1 contract)
     scope:       []                  // always root scope for proxy-initiated calls
   }
   ```
4. `actionHash = keccak256(abi.encode(action))`
5. `nextAction = _findAndApplyExecution(actionHash, action)` — match in table, apply deltas, consume
6. `result = _resolveScopes(nextAction)` — if nextAction is CALL, navigate scopes; assert RESULT

**Postconditions**:
- The matching execution entry is consumed (`executionIndex` advanced past it)
- State deltas of that entry are applied to `rollups`
- `_etherDelta` is reset to 0 (by `_applyStateDeltas`)
- Returns the RESULT's return data

**Events**: `CrossChainCallExecuted(actionHash, msg.sender, sourceAddress, callData, msg.value)`

**Revert conditions**:
- `UnauthorizedProxy` — caller is not a registered proxy
- `ExecutionNotInCurrentBlock` — `lastStateUpdateBlock != block.number`
- `ExecutionNotFound` — no matching entry in `executions`
- `CallExecutionFailed` — scope resolution returned a non-RESULT action
- `StateRootMismatch` — matching actionHash found but state roots don't match
- `EtherDeltaMismatch` — ether accounting mismatch
- `InsufficientRollupBalance` — rollup's ETH balance would go negative

**Note on failed RESULTs**: If the final RESULT has `failed == true`, the contract reverts with the raw return data from `nextAction.data` (assembly revert), preserving the original revert reason. It does NOT revert with `CallExecutionFailed`.

---

#### `executeL2TX`

```solidity
function executeL2TX() public returns (bytes memory result)
```

**Access control**: permissionless. Also called internally by `postBatch` for immediate entries (hence `public` visibility).

**Preconditions**:
- `lastStateUpdateBlock == block.number`

**State transitions**:

1. `_l2TxAction()` returns a generic zeroed-out L2TX action:
   ```
   action = Action{
     actionType: L2TX,
     rollupId:   0,
     destination: address(0),
     value:       0,
     data:         "",
     failed:      false,
     sourceAddress: address(0),
     sourceRollup: 0,
     scope:       []
   }
   ```
2. `nextAction = _findAndApplyExecution(bytes32(0), action)` — always matches entries with `actionHash == bytes32(0)` using positional matching via `executionIndex`
3. `emit L2TXExecuted()` (empty event, no parameters)
4. `result = _resolveScopes(nextAction)`

**Key change from previous design**: `executeL2TX` is now parameterless. L2TX entries always have `actionHash == bytes32(0)`. The matching is positional — `_findAndApplyExecution` scans forward from `executionIndex` and matches the next entry with `actionHash == 0`. The `_l2TxAction()` return value is only used for the `ExecutionConsumed` event.

**Data availability**: The actual L2 transaction data (RLP-encoded transactions, calldata, etc.) is NOT passed as a parameter to `executeL2TX`. Instead, it is published via the `postBatch` call's data availability channels: either as EIP-4844 blob data (referenced by `blobCount` and verified via `blobhash()` in the public inputs) or as `callData` passed directly in the `postBatch` calldata. The ZK proof covers this data through the `publicInputsHash`, which includes both `keccak256(callData)` and the blob hashes. This means the L2 transaction content is available on-chain (blobs or calldata) and proven correct, but the on-chain execution itself only needs the pre-computed execution entries — the contract does not interpret the raw L2 transactions.

**Postconditions**: same as `executeCrossChainCall` (entry consumed via `executionIndex` advancement, deltas applied).

**Events**: `L2TXExecuted()` — empty, no parameters. (Previously was `L2TXExecuted(actionHash, rollupId, rlpEncodedTx)`.)

**Revert conditions**: same as `executeCrossChainCall` minus `UnauthorizedProxy`.

---

#### `_findAndApplyExecution` (internal)

```solidity
function _findAndApplyExecution(
    bytes32 actionHash,
    Action memory action
) internal returns (Action memory nextAction)
```

**Algorithm (forward-scan from `executionIndex` with skip-scan)**:

```
for i from executionIndex to executions.length - 1:
  if executions[i].actionHash != actionHash:
    if executions[i].nextAction.failed:
      continue                     // skip-scan: skip failed/reverted entries
    else:
      revert ExecutionNotFound()   // hard revert: non-failed non-matching entry

  // Matching actionHash found — verify state roots (hard revert on mismatch)
  for each delta d in executions[i].stateDeltas:
    if rollups[d.rollupId].stateRoot != d.currentState:
      revert StateRootMismatch()   // hard revert, no soft skip

  _applyStateDeltas(executions[i].stateDeltas)
  nextAction = executions[i].nextAction
  executionIndex = i + 1

  emit ExecutionConsumed(actionHash, action)
  return nextAction

revert ExecutionNotFound()
```

**Key behavioral changes from previous algorithm**:
1. **No swap-and-pop**: entries stay in the array. Position is tracked by `executionIndex`, which advances past consumed entries.
2. **Sequential ordering enforced**: entries must be in the exact consumption order. A non-failed, non-matching entry causes an immediate hard revert.
3. **Skip-scan for failed entries**: entries whose `nextAction.failed == true` and whose `actionHash` does not match are silently skipped. This allows the builder to include entries for alternative execution paths (e.g., reverted branches) that may not be consumed.
4. **Hard revert on state root mismatch**: when an `actionHash` matches, ALL state deltas must match current on-chain state. There is no soft skip to try the next entry.
5. **Positional disambiguation**: multiple entries with the same `actionHash` are disambiguated by position in the array, not by state delta matching.

---

#### `_applyStateDeltas` (internal)

```solidity
function _applyStateDeltas(StateDelta[] memory deltas) internal
```

1. Initialize `totalEtherDelta = 0`
2. For each delta `d`:
   - `rollups[d.rollupId].stateRoot = d.newState`
   - `totalEtherDelta += d.etherDelta`
   - If `d.etherDelta < 0`: subtract `|etherDelta|` from `rollups[d.rollupId].etherBalance`; revert `InsufficientRollupBalance` if underflow
   - If `d.etherDelta > 0`: add to `rollups[d.rollupId].etherBalance`
   - Emit `L2ExecutionPerformed(d.rollupId, d.currentState, d.newState)`
3. Check `totalEtherDelta == _etherDelta`; revert `EtherDeltaMismatch` if not
4. Reset `_etherDelta = 0`

---

#### `_resolveScopes` (internal)

```solidity
function _resolveScopes(Action memory nextAction) internal returns (bytes memory result)
```

1. If `nextAction.actionType == CALL`:
   - Call `this.newScope([], nextAction)` via external self-call (for try/catch isolation)
   - On success: `nextAction = retAction`
   - On `ScopeReverted` catch: `nextAction = _handleScopeRevert(revertData)`
2. If `nextAction.actionType != RESULT`: revert `CallExecutionFailed`
3. If `nextAction.failed`: assembly revert with `nextAction.data` (raw revert data, preserving original revert reason — does NOT revert with `CallExecutionFailed`)
4. Return `nextAction.data`

---

#### `newScope`

```solidity
function newScope(
    uint256[] memory scope,
    Action memory action
) external returns (Action memory nextAction)
```

**Access control**: `msg.sender == address(this)` only (self-call for try/catch isolation). Reverts with `OnlySelf()` if violated.

**Algorithm** (loop until break):

```
nextAction = action
while true:
  if nextAction.actionType == CALL:
    if _isChildScope(scope, nextAction.scope):
      // Target is deeper than current scope — recurse
      newScopeArr = scope ++ [nextAction.scope[scope.length]]
      try this.newScope(newScopeArr, nextAction):
        nextAction = retAction
      catch ScopeReverted:
        nextAction = _handleScopeRevert(revertData)
    else if _scopesMatch(scope, nextAction.scope):
      // At target scope — execute
      (_, nextAction) = _processCallAtScope(scope, nextAction)
    else:
      // Action belongs to parent/sibling scope — return to caller
      break
  else if nextAction.actionType == REVERT:
    if _scopesMatch(scope, nextAction.scope):
      // This scope reverts — look up continuation and propagate
      rollupId = nextAction.rollupId
      stateRoot = rollups[rollupId].stateRoot
      continuation = _getRevertContinuation(rollupId)
      revert ScopeReverted(abi.encode(continuation), stateRoot, rollupId)
    else:
      break
  else:  // RESULT or other
    break
return nextAction
```

**Scope comparison helpers**:

- `_scopesMatch(a, b)`: `a.length == b.length` and `a[i] == b[i]` for all i
- `_isChildScope(current, target)`: `target.length > current.length` and `target[0..current.length] == current[0..current.length]`
- `_appendToScope(scope, element)`: returns new array `scope ++ [element]`

---

#### `_processCallAtScope` (internal)

```solidity
function _processCallAtScope(
    uint256[] memory currentScope,
    Action memory action
) internal returns (uint256[] memory scope, Action memory nextAction)
```

1. Compute source proxy address: `sourceProxy = computeCrossChainProxyAddress(action.sourceAddress, action.sourceRollup)`
2. If proxy not registered: `_createCrossChainProxyInternal(action.sourceAddress, action.sourceRollup)`
3. Execute the call through the source proxy:
   ```solidity
   (bool success, bytes memory returnData) = address(sourceProxy).call{value: action.value}(
       abi.encodeCall(CrossChainProxy.executeOnBehalf, (action.destination, action.data))
   );
   ```
4. If `action.value > 0 && success`: `_etherDelta -= int256(action.value)` (track ETH sent out)
5. Build RESULT action:
   ```
   resultAction = Action{
     actionType: RESULT,
     rollupId:   action.rollupId,
     destination: address(0),
     value:       0,
     data:        returnData,
     failed:      !success,
     sourceAddress: address(0),
     sourceRollup:  0,
     scope:         []
   }
   ```
6. `resultHash = keccak256(abi.encode(resultAction))`
7. `nextAction = _findAndApplyExecution(resultHash, resultAction)`
8. Return `(currentScope, nextAction)`

**Critical note on the RESULT hash**: the `data` field of the RESULT action is the exact return bytes from the proxy call. Since `executeOnBehalf` uses inline assembly `return(result, len)`, the return data is the raw bytes from `destination.call(data)`. The hash depends on the exact return value. The builder must simulate the call to predict this.

**For void calls** (destination returns nothing): `returnData = ""` and `success = true`, producing `resultAction = RESULT{rollupId: action.rollupId, data: "", failed: false, ...}`. This is the `result_void(rollupId)` pattern used throughout the flash loan flows.

---

#### `_handleScopeRevert` (internal, Rollups.sol variant)

```solidity
function _handleScopeRevert(bytes memory revertData) internal returns (Action memory nextAction)
```

1. Revert if `revertData.length <= 4`
2. Strip 4-byte selector (via assembly pointer arithmetic)
3. Decode: `(bytes actionBytes, bytes32 stateRoot, uint256 rollupId) = abi.decode(stripped, (bytes, bytes32, uint256))`
4. Restore rollup state: `rollups[rollupId].stateRoot = stateRoot`
5. Return `abi.decode(actionBytes, (Action))`

**Note**: This restores the **pre-revert state root** of the affected rollup, undoing the state changes within the reverted scope. The `ScopeReverted` error carries both the continuation action and the state to restore.

---

#### `_getRevertContinuation` (internal)

```solidity
function _getRevertContinuation(uint256 rollupId) internal returns (Action memory nextAction)
```

Constructs:
```
revertContinueAction = Action{
  actionType: REVERT_CONTINUE,
  rollupId:   rollupId,
  destination: address(0),
  value:       0,
  data:        "",
  failed:      true,
  sourceAddress: address(0),
  sourceRollup:  0,
  scope:         []
}
```

Then: `revertHash = keccak256(abi.encode(revertContinueAction))` and `_findAndApplyExecution(revertHash, ...)`.

---

#### `createCrossChainProxy`

```solidity
function createCrossChainProxy(
    address originalAddress,
    uint256 originalRollupId
) external returns (address proxy)
```

**Access control**: permissionless.

Delegates to `_createCrossChainProxyInternal`.

---

#### `_createCrossChainProxyInternal` (internal)

```solidity
function _createCrossChainProxyInternal(
    address originalAddress,
    uint256 originalRollupId
) internal returns (address proxy)
```

1. `salt = keccak256(abi.encodePacked(originalRollupId, originalAddress))`
2. Deploy `new CrossChainProxy{salt: salt}(address(this), originalAddress, originalRollupId)` via CREATE2
3. `authorizedProxies[proxy] = ProxyInfo(originalAddress, uint64(originalRollupId))`
4. Emit `CrossChainProxyCreated(proxy, originalAddress, originalRollupId)`

---

#### `computeCrossChainProxyAddress`

```solidity
function computeCrossChainProxyAddress(
    address originalAddress,
    uint256 originalRollupId
) public view returns (address)
```

Returns:
```
salt = keccak256(abi.encodePacked(originalRollupId, originalAddress))
bytecodeHash = keccak256(
    abi.encodePacked(
        type(CrossChainProxy).creationCode,
        abi.encode(address(this), originalAddress, originalRollupId)
    )
)
address(uint160(uint256(keccak256(abi.encodePacked(
    bytes1(0xff),
    address(this),   // deployer = Rollups contract
    salt,
    bytecodeHash
)))))
```

---

#### `staticCallLookup`

```solidity
function staticCallLookup(address sourceAddress, bytes calldata callData) external view returns (bytes memory result)
```

**Access control**: only authorized proxies. Called by `CrossChainProxy` when it detects a `STATICCALL` context.

**Preconditions**:
- `lastStateUpdateBlock == block.number` (same-block restriction enforced)
- `authorizedProxies[msg.sender].originalAddress != address(0)`

**Algorithm**:
1. Read proxy identity from `authorizedProxies[msg.sender]`
2. Build a CALL action with `value=0`, proxy's identity fields, and `sourceRollup = MAINNET_ROLLUP_ID`
3. Compute `actionHash = keccak256(abi.encode(action))`
4. Read `currentExecIdx = executionIndex`
5. Linear scan over `staticCalls[]`:
   - Match on `(sc.actionHash == actionHash && sc.executionIndex == currentExecIdx)`
   - If sub-calls present (`sc.calls.length > 0`): call `_processNStaticCalls(sc.calls)`, verify computed hash matches `sc.rollingHash` (revert `RollingHashMismatch` if not)
   - If `sc.failed`: assembly revert with `sc.returnData` (replays the original revert)
   - Otherwise: return `sc.returnData`
6. If no match: revert `StaticCallNotFound`

---

#### `_processNStaticCalls` (internal, view)

```solidity
function _processNStaticCalls(StaticSubCall[] storage calls) internal view returns (bytes32 computedHash)
```

Executes sub-calls in static context and computes a rolling hash of results:
1. For each sub-call `cc`:
   - `sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollup)`
   - If `sourceProxy.code.length == 0`: revert `ProxyNotDeployed` (cannot CREATE2 in static context)
   - `(success, retData) = sourceProxy.staticcall(abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.destination, cc.data)))`
   - `computedHash = keccak256(abi.encodePacked(computedHash, success, retData))`
2. Return `computedHash`

Rolling hash starts from `bytes32(0)` and chains `keccak256(prevHash ++ success ++ retData)` over all calls.

---

#### `_l2TxAction` (internal, pure)

```solidity
function _l2TxAction() internal pure returns (Action memory)
```

Returns an L2TX action with all fields zeroed except `actionType`:
```
Action{actionType: L2TX, rollupId: 0, destination: address(0), value: 0, data: "", failed: false, sourceAddress: address(0), sourceRollup: 0, scope: []}
```

Used as the `action` parameter in `_findAndApplyExecution` calls for L2TX and immediate entries. The action itself is not hashed for matching (`actionHash` is always `bytes32(0)`) — it is only used for the `ExecutionConsumed` event.

---

#### `_buildPublicInputsHash` (internal, view)

```solidity
function _buildPublicInputsHash(
    ExecutionEntry[] calldata entries,
    StaticCall[] calldata _staticCalls,
    uint256 blobCount,
    bytes calldata callData
) internal view returns (bytes32)
```

Extracted from `postBatch` to avoid stack-too-deep (6 calldata parameters). Implements the public inputs hash construction documented in the `postBatch` section, including `keccak256(abi.encode(_staticCalls))`.

---

#### Owner management functions

```solidity
function setStateByOwner(uint256 rollupId, bytes32 newStateRoot) external onlyRollupOwner(rollupId)
function setVerificationKey(uint256 rollupId, bytes32 newVerificationKey) external onlyRollupOwner(rollupId)
function transferRollupOwnership(uint256 rollupId, address newOwner) external onlyRollupOwner(rollupId)
```

All guarded by `rollups[rollupId].owner == msg.sender`. No proof required. No `StateAlreadyUpdatedThisBlock` check.

`setStateByOwner` does NOT update `lastStateUpdateBlock` — it is an escape hatch, not a batch post.

---

### B.2 CrossChainManagerL2.sol (L2)

The L2 contract mirrors the L1 contract's execution logic but is simpler: no ZK proofs, no rollup registry, no ether balance tracking. A privileged system address loads the execution table; the same scope navigation machinery executes entries.

---

#### `loadExecutionTable`

```solidity
function loadExecutionTable(ExecutionEntry[] calldata entries, StaticCall[] calldata _staticCalls) external onlySystemAddress
```

**Access control**: `SYSTEM_ADDRESS` only (set at construction, immutable).

**State transitions**:
1. `delete executions`
2. `delete staticCalls`
3. `executionIndex = 0`
4. For each entry: `executions.push(entry)`
5. For each static call: `staticCalls.push(sc)`
6. `lastStateUpdateBlock = block.number`

**Postconditions**: `executions` contains exactly the provided entries. `staticCalls` contains the provided static call entries. `executionIndex == 0`.

**Events**: `ExecutionTableLoaded(entries)`

**Revert conditions**: `Unauthorized` if caller is not `SYSTEM_ADDRESS`.

---

#### `executeCrossChainCall` (L2 variant)

```solidity
function executeCrossChainCall(
    address sourceAddress,
    bytes calldata callData
) external payable returns (bytes memory result)
```

**Access control**: only registered proxies.

**Preconditions**:
- `authorizedProxies[msg.sender].originalAddress != address(0)`
- `lastStateUpdateBlock == block.number`

**State transitions**:

1. Construct CALL action:
   ```
   action = Action{
     actionType: CALL,
     rollupId:   proxyInfo.originalRollupId,  // the rollup the proxy represents
     destination: proxyInfo.originalAddress,
     value:       msg.value,
     data:        callData,
     failed:      false,
     sourceAddress: sourceAddress,
     sourceRollup: ROLLUP_ID,                 // this L2's rollup ID
     scope:       []
   }
   ```
2. If `msg.value > 0`: forward ETH to `SYSTEM_ADDRESS` via `SYSTEM_ADDRESS.call{value: msg.value}("")`. Revert `EtherTransferFailed` if this fails.
3. `actionHash = keccak256(abi.encode(action))`
4. `nextAction = _consumeExecution(actionHash, action)` — no state delta matching on L2
5. `result = _resolveScopes(nextAction)`

**Critical difference from L1**: the L2 `_consumeExecution` does NOT check state delta `currentState` fields. It matches on `actionHash` with sequential ordering (forward-scan from `executionIndex`). State deltas are present in L2 entries (they may be empty arrays) but are never verified.

**Ether handling on L2**: ETH sent to the proxy is immediately forwarded to `SYSTEM_ADDRESS` (conceptually "burned" on the L2 side — the system bridge tracks accounting separately).

**Events**: `CrossChainCallExecuted(actionHash, msg.sender, sourceAddress, callData, msg.value)`

---

#### `executeIncomingCrossChainCall`

```solidity
function executeIncomingCrossChainCall(
    address destination,
    uint256 value,
    bytes calldata data,
    address sourceAddress,
    uint256 sourceRollup,
    uint256[] calldata scope
) external payable onlySystemAddress returns (bytes memory result)
```

**Access control**: `SYSTEM_ADDRESS` only.

**Preconditions**: `lastStateUpdateBlock == block.number`

**State transitions**:

1. Construct CALL action:
   ```
   action = Action{
     actionType: CALL,
     rollupId:   ROLLUP_ID,       // always this L2's rollup ID
     destination: destination,
     value:       value,
     data:        data,
     failed:      false,
     sourceAddress: sourceAddress,
     sourceRollup: sourceRollup,
     scope:       scope
   }
   ```
2. Compute `actionHash = keccak256(abi.encode(action))`
3. Emit `IncomingCrossChainCallExecuted(actionHash, destination, value, data, sourceAddress, sourceRollup, scope)`
4. Return `_resolveScopes(action)` — NOTE: passes the action directly, NOT the result of `_consumeExecution`. The action itself is the trigger; scope navigation will call `_processCallAtScope` which calls `_consumeExecution` on the RESULT.

**Important**: `executeIncomingCrossChainCall` does NOT consume an execution entry for the incoming CALL itself. It directly calls `_resolveScopes(action)`, which calls `newScope([], action)`, which calls `_processCallAtScope`, which executes the call and then looks up the RESULT entry in `_consumeExecution`. The incoming CALL action has no entry in the execution table — only its RESULT does.

**Events**: `IncomingCrossChainCallExecuted(...)`

---

#### `_consumeExecution` (L2 internal — forward-scan with skip-scan, no state delta matching)

```solidity
function _consumeExecution(bytes32 actionHash, Action memory action) internal returns (Action memory nextAction)
```

**Algorithm (forward-scan from `executionIndex` with skip-scan)**:

```
for i from executionIndex to executions.length - 1:
  if executions[i].actionHash != actionHash:
    if executions[i].nextAction.failed:
      continue                     // skip-scan: skip failed/reverted entries
    else:
      revert ExecutionNotFound()   // hard revert: non-failed non-matching entry

  nextAction = executions[i].nextAction
  executionIndex = i + 1

  emit ExecutionConsumed(actionHash, action)
  return nextAction

revert ExecutionNotFound()
```

**Key distinction from `_findAndApplyExecution` (L1)**: no state delta verification. No `_applyStateDeltas`. No ether accounting. The sequential ordering and skip-scan behavior are identical to L1.

---

#### `_resolveScopes` (L2 variant)

Identical to L1 `_resolveScopes`, including the two-step failed check:
1. If `nextAction.actionType != RESULT`: revert `CallExecutionFailed`
2. If `nextAction.failed`: assembly revert with `nextAction.data`
3. Return `nextAction.data`

---

#### `newScope` (L2 variant)

Identical algorithm to L1 `newScope`, except:
- Access control: `msg.sender == address(this)` only. Reverts with `OnlySelf()` if violated.
- `_getRevertContinuation` on L2 does not pass `stateRoot` in the revert (L2 `ScopeReverted` only carries `bytes nextAction`)
- `_handleScopeRevert` on L2 decodes only `(bytes actionBytes)` — no state restoration

---

#### `_processCallAtScope` (L2 variant)

Identical to L1 variant except:
- Uses `_createProxyInternal` (L2 version)
- Calls `_consumeExecution` (not `_findAndApplyExecution`) on RESULT
- No `_etherDelta` tracking

---

#### `createCrossChainProxy` (L2)

Same logic as L1: permissionless, deploys via CREATE2, same salt and bytecode hash formula.

---

#### `staticCallLookup` (L2)

Identical to the L1 version except:
- Uses `ROLLUP_ID` (this L2's rollup ID) instead of `MAINNET_ROLLUP_ID` when computing the action hash's `sourceRollup` field
- Enforces same-block restriction: `lastStateUpdateBlock == block.number`

---

#### `_processNStaticCalls` (L2)

Identical to the L1 version. Includes `ProxyNotDeployed` check.

---

### B.3 CrossChainProxy.sol

```solidity
constructor(address _manager, address _originalAddress, uint256 _originalRollupId)
```

All three constructor args are stored as immutables: `MANAGER`, `ORIGINAL_ADDRESS`, `ORIGINAL_ROLLUP_ID`.

**Transient storage**: `uint256 private transient _staticDetector` — dummy variable used to detect `STATICCALL` context via a TSTORE probe.

#### `fallback()`

Delegates to `_fallback()`.

#### `staticCheck() external`

Detects `STATICCALL` context via TSTORE:
- If `msg.sender == address(this)` (self-call): sets `_staticDetector = 0`. In a `STATICCALL` context, TSTORE is disallowed and this reverts. In normal context, it succeeds.
- Otherwise: routes through `_fallback()` (transparent proxy pattern — external callers cannot abuse this function).

#### `executeOnBehalf(address destination, bytes calldata data) external payable`

- If `msg.sender == MANAGER`: directly calls `destination.call{value: msg.value}(data)`. Uses assembly to return/revert the raw bytes (no ABI wrapping).
- Otherwise: calls `_fallback()`.

#### `_fallback()` internal

```solidity
// 1. STATICCALL detection via self-call probe
(bool notStaticCall,) = address(this).call(abi.encodeCall(this.staticCheck, ()));

// 2. Route based on context
if (notStaticCall) {
    // Normal context — state-changing execution path
    (success, result) = MANAGER.call{value: msg.value}(
        abi.encodeCall(ICrossChainManager.executeCrossChainCall, (msg.sender, msg.data))
    );
} else {
    // Static context — read-only lookup for pre-computed result
    (success, result) = MANAGER.staticcall(
        abi.encodeCall(ICrossChainManager.staticCallLookup, (msg.sender, msg.data))
    );
}

// 3. Decode and return/revert
if (success) result = abi.decode(result, (bytes));
assembly { switch success case 0 { revert(...) } default { return(...) } }
```

**STATICCALL detection**: The self-call to `staticCheck()` attempts a `TSTORE` (transient store). In a `STATICCALL` context, the EVM disallows `TSTORE`, so the self-call reverts (`notStaticCall = false`). In normal context, `TSTORE` succeeds (`notStaticCall = true`). Note: `TLOAD` does NOT revert in static context — only `TSTORE` does.

**OOG safety**: If the self-call runs out of gas, `notStaticCall` is also `false`. This is safe: if 63/64 of remaining gas can't cover a single TSTORE (~100 gas), the subsequent MANAGER call will also revert due to insufficient gas. This is a liveness concern (false failure), not a safety concern (incorrect state mutation).

**Double-encoding note**: Both `executeCrossChainCall` and `staticCallLookup` return `bytes memory`. The low-level `.call()` / `.staticcall()` ABI-encodes that return value (wrapping the bytes). So `result` is double-encoded: the outer encoding is the function return ABI, the inner is the actual return data. `abi.decode(result, (bytes))` strips the outer layer. On revert, raw revert data is not ABI-wrapped, so it is forwarded directly.

---

## C. Action Hash Computation

Every action hash is computed as:

```solidity
bytes32 actionHash = keccak256(abi.encode(action));
```

where `action` is a complete `Action` struct with all fields set. `abi.encode` encodes the struct with full ABI type encoding (including dynamic arrays for `scope` and `data`).

### C.1 Hash in `executeCrossChainCall` (proxy → L1/L2 trigger perspective)

```
action = Action{
  actionType:   CALL,
  rollupId:     proxyInfo.originalRollupId,
  destination:  proxyInfo.originalAddress,
  value:        msg.value,
  data:         callData,                   // original calldata from the proxy
  failed:       false,
  sourceAddress: sourceAddress,             // msg.sender of the original call to the proxy
  sourceRollup: MAINNET_ROLLUP_ID (L1)
                or ROLLUP_ID (L2),
  scope:        []
}
hash = keccak256(abi.encode(action))
```

The builder computes this hash by simulating the call from the user's perspective: it knows which proxy will be called (determines `destination` and `rollupId`), who called the proxy (`sourceAddress`), what calldata was sent, and the value.

### C.2 Hash for RESULT (after `executeOnBehalf` returns)

```
resultAction = Action{
  actionType:   RESULT,
  rollupId:     action.rollupId,   // same as the CALL
  destination:  address(0),
  value:        0,
  data:         returnData,         // exact bytes returned by destination.call(data)
  failed:       !success,           // false if call succeeded
  sourceAddress: address(0),
  sourceRollup:  0,
  scope:         []
}
hash = keccak256(abi.encode(resultAction))
```

The builder must simulate the destination call to determine `returnData` and `success`. The `data` field is the exact ABI-decoded return value (raw bytes from `destination.call(data)` — NOT the `executeOnBehalf` return, which uses assembly to bypass ABI encoding).

### C.3 Hash for REVERT_CONTINUE

```
revertContinueAction = Action{
  actionType:   REVERT_CONTINUE,
  rollupId:     rollupId,      // the rollup that triggered the REVERT
  destination:  address(0),
  value:        0,
  data:         "",
  failed:       true,
  sourceAddress: address(0),
  sourceRollup:  0,
  scope:         []
}
hash = keccak256(abi.encode(revertContinueAction))
```

### C.4 Hash for L2TX

L2TX entries always use `actionHash == bytes32(0)`. The `_l2TxAction()` helper returns a generic zeroed-out action:

```
l2txAction = Action{
  actionType:   L2TX,
  rollupId:     0,
  destination:  address(0),
  value:        0,
  data:         "",
  failed:       false,
  sourceAddress: address(0),
  sourceRollup: 0,
  scope:         []
}
// actionHash is always bytes32(0) — matching is positional via executionIndex, not content-based
```

**Key change from previous design**: L2TX entries no longer have unique hashes based on `rollupId` and `rlpEncodedTx`. The new design relies entirely on sequential ordering: `_findAndApplyExecution(bytes32(0), _l2TxAction())` scans from `executionIndex` and matches the next entry with `actionHash == 0`.

**Where the L2 transaction data lives**: The full L2 transaction content (RLP-encoded transactions, user calldata, etc.) is published through `postBatch`'s data availability parameters — either inside EIP-4844 blobs (referenced by `blobCount`) or in the `callData` field passed to `postBatch`. Both channels are committed into the `publicInputsHash` (blob hashes via `blobhash()`, calldata via `keccak256(callData)`) and covered by the ZK proof. The on-chain contract never interprets raw L2 transactions; it only consumes the pre-computed execution entries that the prover derived from them.

### C.5 Hash for continuation CALL entries (flash loan / scope=[0] actions)

When `_findAndApplyExecution` returns a CALL action as `nextAction`, this CALL itself becomes the key for the next execution entry lookup on the **other chain**. For example, in the L1 flash loan, after consuming CALL#2 (executorL2 claimAndBridgeBack), the `nextAction` is `callReturnScoped` (scope=[0]). This CALL is then navigated by `_resolveScopes` → `newScope` → `_processCallAtScope`, and after `executeOnBehalf` returns, a RESULT is built and its hash is used to find the next entry.

For an L2-side reentrant `executeCrossChainCall` (Bridge_L2 calling proxy for Bridge_L1), the action hash is:
```
action = Action{
  actionType:   CALL,
  rollupId:     proxyInfo.originalRollupId,  // e.g., MAINNET_ROLLUP_ID for Bridge_L1 proxy
  destination:  proxyInfo.originalAddress,   // Bridge_L1
  value:        msg.value,
  data:         callData,                    // receiveTokens(...)
  failed:       false,
  sourceAddress: sourceAddress,              // Bridge_L2 (msg.sender to proxy)
  sourceRollup: ROLLUP_ID,                   // L2's rollup ID
  scope:         []
}
```

**Key rule**: the scope field in an action used as an execution table key is always `[]` (root). Only the `nextAction` returned from a table entry can have a non-empty scope (for routing nested calls).

---

## D. Scope Navigation

### D.1 Scope Array Semantics

A scope is a `uint256[]` representing a path in a tree of nested calls. The root scope is `[]` (empty). The first child of root is `[0]`, `[1]`, etc. The first child of `[0]` is `[0, 0]`.

Scope depth correlates with call nesting: a call at scope `[0]` is "one level deep" relative to the root caller.

Scopes are used to route CALL actions to the correct `newScope` invocation level. When the builder precomputes a CALL that must execute inside a callback (e.g., `claimAndBridgeBack` returns a CALL to `receiveTokens` on L1), that CALL is tagged with `scope=[0]` so `newScope` at the root level navigates into the `[0]` child before executing it.

### D.2 `_resolveScopes` Entry Point

```
_resolveScopes(nextAction):
  if nextAction.actionType == CALL:
    try this.newScope([], nextAction):
      nextAction = retAction
    catch ScopeReverted:
      nextAction = _handleScopeRevert(revertData)
  assert nextAction.actionType == RESULT && !nextAction.failed
  return nextAction.data
```

The root scope `[]` is always passed to the initial `newScope` call.

### D.3 `newScope` Loop Logic

At each scope level `S`, `newScope` loops over actions:

```
given action A:
  if A is CALL:
    if A.scope is a child of S:      // A.scope starts with S and is longer
      recurse: newScope(S ++ [A.scope[S.length]], A)
    if A.scope == S:                 // exact match
      execute: _processCallAtScope(S, A)
    if A.scope is parent/sibling:    // neither child nor equal
      return A to caller
  if A is REVERT:
    if A.scope == S:
      look up REVERT_CONTINUE, revert ScopeReverted(continuation, stateRoot, rollupId)
    else:
      return A to caller
  if A is RESULT:
    return A to caller (scope navigation complete at this level)
```

The loop continues as long as the scope navigation produces more work at level `S`. A RESULT or a CALL at a parent scope breaks the loop.

### D.4 Example: scope=[0] Navigation

Builder posts entry:
```
Entry for CALL#2:
  actionHash = hash(callClaimAndBridge)
  nextAction = callReturnScoped{scope: [0]}
```

Execution flow when `executeCrossChainCall` finds CALL#2's entry:
1. `_findAndApplyExecution` returns `callReturnScoped` with `scope=[0]`
2. `_resolveScopes(callReturnScoped)`:
   - `callReturnScoped.actionType == CALL`
   - Call `this.newScope([], callReturnScoped)`
3. In `newScope(scope=[], action=callReturnScoped)`:
   - `action.scope = [0]`, `scope = []`
   - `_isChildScope([], [0]) == true` (child: length 1 > 0, no prefix conflict)
   - Build child scope: `[] ++ [0] = [0]`
   - Call `this.newScope([0], callReturnScoped)`
4. In `newScope(scope=[0], action=callReturnScoped)`:
   - `_scopesMatch([0], [0]) == true`
   - Call `_processCallAtScope([0], callReturnScoped)`
   - Execute `executeOnBehalf(bridgeL1, retReceiveTokensCalldata)` → returns void
   - Build RESULT, hash it, call `_findAndApplyExecution`
   - Returns RESULT(L2, void) terminal
5. `newScope([0], ...)` returns RESULT(L2, void) to `newScope([], ...)`
6. `newScope([], ...)` sees RESULT → breaks, returns RESULT
7. `_resolveScopes` asserts RESULT is not failed → returns data

### D.5 Revert Handling

When `_processCallAtScope` executes `executeOnBehalf` and the call succeeds, but the builder had precomputed a `REVERT` action as nextAction:

1. `_findAndApplyExecution(resultHash)` finds an entry whose `nextAction` is `REVERT{scope: S}`
2. The REVERT propagates up: `newScope` at scope `S` catches it
3. At the matching scope, `_getRevertContinuation` looks up `REVERT_CONTINUE` in the table
4. `ScopeReverted(continuation, stateRoot, rollupId)` is thrown
5. The parent `newScope` catches it via try/catch and calls `_handleScopeRevert`
6. `_handleScopeRevert` restores `rollups[rollupId].stateRoot = stateRoot` and returns continuation

This implements cross-chain atomic revert: the rollup state is rolled back to its pre-revert value, and execution continues with the REVERT_CONTINUE path (which may execute cleanup logic or skip remaining steps).

---

## E. Execution Entry Lifecycle

### E.1 Posting (L1)

At `postBatch` time:
- `delete executions` and `delete staticCalls` clear the previous tables; `executionIndex = 0`
- ALL entries are stored via `executions.push(entry)` (including immediate entries with `actionHash == 0`)
- All static calls are stored via `staticCalls.push(sc)`
- `lastStateUpdateBlock = block.number` is set BEFORE the immediate entry loop
- Immediate entries (leading entries with `actionHash == 0`) are consumed via a while loop that calls `executeL2TX()`

All entries in a single batch are proven together by one ZK proof (or ECDSA signature in the dev verifier). The proof covers all entry hashes, static call hashes, blob hashes, calldata hash, parent block hash, and timestamp.

### E.2 Loading (L2)

At `loadExecutionTable` time:
- `delete executions` and `delete staticCalls` clear the previous tables; `executionIndex = 0`
- All entries are pushed into `executions[]`
- All static calls are pushed into `staticCalls[]`
- `lastStateUpdateBlock = block.number`

No proof is required on L2; the system address's authority substitutes for proof verification.

### E.3 Consumption

Entries are consumed one at a time by `_findAndApplyExecution` (L1) or `_consumeExecution` (L2). Consumption advances `executionIndex` past the consumed entry (`executionIndex = i + 1`). Entries are NOT removed from the array — they remain in storage but are logically consumed because `executionIndex` has moved past them.

**Sequential ordering is enforced**: entries must be consumed in the order they appear in the array. A non-failed, non-matching entry ahead of the expected entry causes an immediate `ExecutionNotFound` revert. Failed entries (where `nextAction.failed == true`) with non-matching action hashes are skipped (skip-scan).

**Implication**: the order of entries in the `executions` array has strong semantic meaning. The builder MUST arrange entries in the exact order they will be consumed during execution. This replaces the previous unordered design.

### E.4 Same-Block Restriction

On L1, executions can only be consumed in the same block as `postBatch` (`lastStateUpdateBlock == block.number`).
On L2, executions can only be consumed in the same block as `loadExecutionTable`.

If `lastStateUpdateBlock != block.number`, all execution attempts revert with `ExecutionNotInCurrentBlock`.

Static call lookups (`staticCallLookup`) also enforce the same-block restriction.

### E.5 Table Clearing

Each new `postBatch` or `loadExecutionTable` call deletes `executions`, `staticCalls`, and resets `executionIndex` to 0. Unconsumed entries from the previous block are silently discarded. This means every batch is self-contained.

---

## F. Cross-Chain Call Flows

### F.1 Simple L1→L2 ETH Deposit

**Setup**: Alice bridges 1 ETH from L1 to her address on L2.

**L1 execution table entry (posted by builder in same block)**:

```
Entry 0 (deferred):
  actionHash = hash(CALL{
    actionType: CALL,
    rollupId:   L2_ROLLUP_ID,
    destination: alice,         // proxy's originalAddress = alice
    value:       1 ether,
    data:        "",            // empty — ETH transfer to EOA
    failed:      false,
    sourceAddress: bridgeL1,   // bridge called proxy
    sourceRollup: MAINNET_ROLLUP_ID,
    scope:       []
  })
  stateDeltas: [{rollupId: L2, current: S0, new: S1, etherDelta: +1 ether}]
  nextAction: RESULT{rollupId: L2, data: "", failed: false, scope: []}
```

**L1 call sequence**:
1. Alice → `bridgeL1.bridgeEther{value: 1 ether}(L2_ROLLUP_ID, alice)`
2. Bridge: `proxy = _getOrDeployProxy(alice, L2_ROLLUP_ID)`
3. Bridge: `proxy.call{value: 1 ether}("")` → `CrossChainProxy.fallback()`
4. Proxy: `Rollups.executeCrossChainCall{value: 1 ether}(bridgeL1, "")`
5. Rollups builds the CALL action (using proxy identity and msg context), computes hash
6. `_findAndApplyExecution`: finds Entry 0, applies delta (L2 state S0→S1, etherBalance +1 ether), etherDelta=+1 ether matches `_etherDelta`
7. Returns RESULT (terminal) → `_resolveScopes` returns ""

**L2 execution** (system call, separate block):
1. SYSTEM loads execution table with entry for RESULT hash
2. SYSTEM → `managerL2.executeIncomingCrossChainCall{value: 1 ether}(alice, 1 ether, "", bridgeL1, MAINNET, [])`
3. `_resolveScopes(action)` → `newScope([], action)` → `_processCallAtScope`
4. Proxy for (bridgeL1, MAINNET) is auto-created
5. `proxy.executeOnBehalf{value: 1 ether}(alice, "")` → `alice.call{value: 1 ether}("")` → alice receives ETH
6. RESULT{data:"", failed:false} consumed from table → terminal

---

### F.2 Simple L2→L1 ERC20 Withdrawal

**Setup**: Alice on L2 burns 100 wrapped tokens to receive 100 native tokens on L1.

**L2 execution table entry**:
```
Entry 0 (L2):
  actionHash = hash(CALL{
    rollupId:   MAINNET_ROLLUP_ID,
    destination: bridgeL1,
    value:       0,
    data:        receiveTokens(token, MAINNET, alice, 100e18, ..., L2_ROLLUP_ID),
    failed:      false,
    sourceAddress: bridgeL2,
    sourceRollup: L2_ROLLUP_ID,
    scope:       []
  })
  nextAction: RESULT{rollupId: MAINNET, data: "", failed: false, scope: []}
```

**L2 call sequence**:
1. Alice → `bridgeL2.bridgeTokens(wrappedToken, 100e18, MAINNET_ROLLUP_ID, alice)`
2. Bridge: burns wrapped tokens via `WrappedToken.burn(alice, 100e18)`
3. Bridge: `proxy = _getOrDeployProxy(bridgeL1, MAINNET_ROLLUP_ID)` (bridgeL2._bridgeAddress() = bridgeL1 if canonical set)
4. Bridge: `proxy.call(receiveTokensCalldata)` → `CrossChainProxy.fallback()`
5. Proxy: `managerL2.executeCrossChainCall(bridgeL2, receiveTokensCalldata)`
6. Manager builds CALL action (rollupId=MAINNET, sourceRollup=L2)
7. `_consumeExecution`: finds Entry 0, returns `RESULT{MAINNET, void}`
8. `_resolveScopes(RESULT{MAINNET, void})` → already RESULT, not failed → returns ""

**L1 execution** (system call, same or next block):
1. SYSTEM loads table with entry for RESULT hash (or L2TX entry pointing to CALL)
2. SYSTEM → `rollups.executeL2TX(L2_ROLLUP_ID, rlpData)` (or `executeIncomingCrossChainCall`)
3. L2TX matches entry → nextAction = CALL{bridgeL1, receiveTokens, sourceAddress=bridgeL2, sourceRollup=L2}
4. `_resolveScopes` → `newScope([], CALL)` → `_processCallAtScope`
5. Proxy for (bridgeL2, L2) auto-created
6. `proxy.executeOnBehalf(bridgeL1, receiveTokensCalldata)` → `bridgeL1.receiveTokens(...)`
7. `onlyBridgeProxy(L2)`: checks proxy for (`_bridgeAddress()=bridgeL2`, L2) == msg.sender ✓
8. `originalRollupId == rollupId` (MAINNET) → releases locked tokens to alice
9. RESULT consumed → terminal

---

### F.3 L1→L2 Flash Loan (Multi-Call Continuation)

**Overview** (L1-initiated, confirmed correct and tested):
```
Alice → executor.execute() → FlashLoan.flashLoan() → onFlashLoan:
  CALL A (L1→L2): bridgeL1.bridgeTokens → proxy(bridgeL1,MAINNET on L1) → executeCrossChainCall
                  matches L1 Entry 0: hash(callForward) → result_L2_void (terminal)
  CALL B (L1→L2): executorL2Proxy.call(claimAndBridgeBack) → proxy(executorL1,MAINNET on L1) → executeCrossChainCall
                  matches L1 Entry 1: hash(callClaimAndBridge) → callReturnScoped{scope:[0]}
                  → _resolveScopes: newScope([]) → isChild([0]) → newScope([0]) → _processCallAtScope
                    → proxy(bridgeL2,L2).executeOnBehalf(bridgeL1, retReceiveTokens)
                    → bridgeL1.receiveTokens releases 10k tokens to executorL1
                    RESULT{MAINNET,void} → matches L1 Entry 2 → result_L2_void (terminal)
  executor repays flash loan (has 10k tokens back)
```

**L1 execution table** (3 deferred entries, posted in same block as executor.execute()):

```
L1 Entry 0:
  actionHash = hash(callForward) where callForward = CALL{
    rollupId: L2, destination: bridgeL2, data: fwdReceiveTokens(...),
    sourceAddress: bridgeL1, sourceRollup: MAINNET, scope: []
  }
  stateDeltas: [{rollupId: L2, current: S0, new: S1, etherDelta: 0}]
  nextAction:  result_L2_void = RESULT{rollupId: L2, data: "", failed: false, scope: []}

L1 Entry 1:
  actionHash = hash(callClaimAndBridge) where callClaimAndBridge = CALL{
    rollupId: L2, destination: executorL2, data: claimAndBridgeBack(...),
    sourceAddress: executorL1, sourceRollup: MAINNET, scope: []
  }
  stateDeltas: [{rollupId: L2, current: S1, new: S2, etherDelta: 0}]
  nextAction:  callReturnScoped = CALL{
    rollupId: MAINNET, destination: bridgeL1, data: retReceiveTokens(...),
    sourceAddress: bridgeL2, sourceRollup: L2, scope: [0]
  }

L1 Entry 2:
  actionHash = hash(result_MAINNET_void) where result_MAINNET_void = RESULT{
    rollupId: MAINNET, data: "", failed: false, scope: []
  }
  stateDeltas: [{rollupId: L2, current: S2, new: S3, etherDelta: 0}]
  nextAction:  result_L2_void
```

**Action hash notes for L1 entries** (all hashes are from the **direct call perspective** since the user calls proxies on L1 directly):
- Entry 0 actionHash: `callForward.rollupId = L2` because the proxy called is `proxy(bridgeL1, L2)` — wait, actually the proxy called is for `(bridgeL2, L2_ROLLUP_ID)` since Bridge_L1 calls `_getOrDeployProxy(bridgeL1._bridgeAddress(), L2_ROLLUP_ID)` and `_bridgeAddress()` returns bridgeL2 (the canonical bridge on L2). So `proxyInfo.originalRollupId = L2`, `proxyInfo.originalAddress = bridgeL2`. `sourceAddress = bridgeL1` (msg.sender to the proxy). `sourceRollup = MAINNET` (set by `executeCrossChainCall`).

**L2 execution table** (3 entries, loaded by system call in same block):

```
L2 Entry 0:
  actionHash = hash(result_L2_void)  -- first match consumed when receiveTokens returns void
  stateDeltas: []
  nextAction:  callB = CALL{
    rollupId: L2, destination: executorL2, data: claimAndBridgeBack(...),
    sourceAddress: executorL1, sourceRollup: MAINNET, scope: []
  }

L2 Entry 1:
  actionHash = hash(callBridgeReturn) where callBridgeReturn = CALL{
    rollupId: MAINNET, destination: bridgeL1, data: retReceiveTokens(...),
    sourceAddress: bridgeL2, sourceRollup: L2, scope: []   // key is UNSCOPED
  }
  stateDeltas: []
  nextAction:  result_MAINNET_void = RESULT{rollupId: MAINNET, data: "", ...}

L2 Entry 2:
  actionHash = hash(result_L2_void)   // same hash as Entry 0 — second match
  stateDeltas: []
  nextAction:  result_L2_void         // terminal self-reference
```

**Important**: L2 Entry 1 `actionHash = hash(callBridgeReturn)` where `callBridgeReturn` has `scope=[]` (root), NOT `scope=[0]`. The `scope` field in an action hash key is always `[]`. The scope-tagged version (`callReturnScoped` with `scope=[0]`) only appears as a `nextAction` in L1 Entry 1.

**L2 system call**:
```
managerL2.executeIncomingCrossChainCall(
  bridgeL2, 0, fwdReceiveTokensCalldata, bridgeL1, MAINNET, []
)
```

Flow:
1. Builds CALL{L2, bridgeL2, 0, fwdCalldata, bridgeL1, MAINNET, []}
2. `_resolveScopes(action)` → `newScope([], action)` → `_processCallAtScope`
3. Creates/uses proxy(bridgeL1, MAINNET), calls `bridgeL2.receiveTokens(...)` → mints 10k wrapped to executorL2
4. Builds RESULT{L2, data:"", failed:false} → `_consumeExecution(hash(result_L2_void))` → finds L2 Entry 0 → nextAction = callB
5. `newScope([], callB)`:
   - `callB.scope = []`, `scope = []` → `_scopesMatch([], []) == true`
   - `_processCallAtScope([], callB)`: proxy(executorL1, MAINNET), calls `executorL2.claimAndBridgeBack(...)`
     - Inside `claimAndBridgeBack`: calls `bridge.bridgeTokens(wrappedToken, balance, MAINNET, executorL1)`
       - Bridge burns wrapped tokens
       - Bridge calls proxy(bridgeL1, MAINNET) → reentrant `executeCrossChainCall(bridgeL2, receiveTokensCalldata)`
       - Manager builds CALL{MAINNET, bridgeL1, retCalldata, bridgeL2, L2, []}
       - `_consumeExecution(hash(callBridgeReturn))` → finds L2 Entry 1 → nextAction = result_MAINNET_void
       - `_resolveScopes(result_MAINNET_void)` → already RESULT → returns ""
     - `claimAndBridgeBack` returns void → success
     - Builds RESULT{L2, data:"", failed:false} → `_consumeExecution(hash(result_L2_void))` → finds L2 Entry 2 → nextAction = result_L2_void
6. `result_L2_void.actionType == RESULT` → `newScope` breaks → returns result_L2_void
7. `_resolveScopes` asserts success → done

**L1 call sequence** (within `executor.onFlashLoan`):

**Step 1** — `bridge.bridgeTokens(token, 10k, L2, executorL2)`:
- Bridge locks tokens
- Bridge: `proxy = _getOrDeployProxy(_bridgeAddress(), L2)` → proxy(bridgeL1, L2) since bridgeL1._bridgeAddress() = bridgeL1
- Proxy → `executeCrossChainCall(bridgeL1, fwdCalldata)` with `_etherDelta=0`
- Builds `callForward`, finds L1 Entry 0, applies S0→S1, returns `result_L2_void`
- `_resolveScopes(result_L2_void)` → already RESULT → done. ETH accounting: `totalEtherDelta=0 == _etherDelta=0` ✓

**Step 2** — `executorL2Proxy.call(claimAndBridgeBack calldata)` → proxy fallback:
- Proxy → `executeCrossChainCall(executor, claimAndBridgeBackCalldata)`
- Builds `callClaimAndBridge`, finds L1 Entry 1, applies S1→S2, returns `callReturnScoped{scope:[0]}`
- `_resolveScopes(callReturnScoped)`:
  - `this.newScope([], callReturnScoped)`
  - In `newScope([], callReturnScoped)`:
    - `callReturnScoped.scope = [0]`, `scope = []`
    - `_isChildScope([], [0]) = true`
    - Build child scope `[0]`, call `this.newScope([0], callReturnScoped)`
  - In `newScope([0], callReturnScoped)`:
    - `_scopesMatch([0], [0]) = true`
    - `_processCallAtScope([0], callReturnScoped)`:
      - proxy for (bridgeL2, L2) created/used
      - `proxy.executeOnBehalf(bridgeL1, retReceiveTokensCalldata)` called
      - `bridgeL1.receiveTokens(token, MAINNET, executorL1, 10k, ..., L2)`:
        - `onlyBridgeProxy(L2)`: checks proxy for (bridgeL2, L2) == msg.sender ✓
        - `originalRollupId(MAINNET) == rollupId(MAINNET)` → releases 10k tokens to `executorL1`
      - Returns void
      - Builds `result_MAINNET_void`, finds L1 Entry 2, applies S2→S3, returns `result_L2_void`
    - `result_L2_void.actionType == RESULT` → loop breaks, returns `result_L2_void`
  - `newScope([])` receives RESULT from child → loop breaks → returns `result_L2_void`
- `_resolveScopes` asserts success → returns ""

**Step 3** — `IERC20(token).safeTransfer(flashLoanPool, 10k)`:
- Executor now holds 10k tokens (released in step 2) → repays flash loan ✓

**Final state**: S3 on L2, 10k tokens returned to FlashLoan, NFT claimed by `executorL2`.

---

### F.4 L2→L1 Reverse Flash Loan (Multi-Call Continuation)

**Status**: VERIFIED WORKING. L2 tx: status 1 (block 19). L1 trigger 1: status 1, 306k gas. L1 trigger 2: status 1, 401k gas. All 3 nodes converge on same state root.

**Overview** (L2-initiated):

Alice calls `reverseExecutorL2.execute()` on L2. This borrows 10k wrapped tokens from `FlashLoanL2Reverse`, then makes two L2→L1 cross-chain calls via proxies, triggering execution on L1. The net result is: L1 receives native tokens (from the forward bridge), claims an NFT, and bridges tokens back to L2 — where the flash loan is repaid within the same L2 transaction via scope navigation.

The flow is fundamentally different from F.3 in an important way:
- **In F.3** (L1→L2): the user triggers on L1, cross-chain execution happens on L2 (L2 execution table is consumed by `executeIncomingCrossChainCall`).
- **In F.4** (L2→L1): the user triggers on L2 (L2 execution table consumed by `executeCrossChainCall` via proxy fallback), and the scope navigation with nested delivery happens on L1 (L1 execution table consumed by builder trigger txs).

#### Execution architecture

L2 side: ReverseExecutorL2 makes two proxy calls. The first call (bridgeTokens) returns `RESULT(L1, void)` directly. The second call (claimAndBridgeBack) returns `callReturn{scope=[0]}`, which triggers scope navigation on L2 — `_processCallAtScope` calls `proxy(Bridge_L1, MAINNET).executeOnBehalf(Bridge_L2, retReceiveTokens)`, executing `Bridge_L2.receiveTokens` which MINTS wrapped tokens back to the executor. This is how the flash loan is repaid within the same L2 tx. The L2 table has 3 entries total.

L1 side: The builder posts the L1 execution table with 5 entries and sends two trigger transactions (one per L2 proxy call detected). The L1 entries implement nested delivery (scope=[0]) to actually execute the calls.

#### Why nested delivery is required on L1

When Bridge_L2 calls `proxy(bridgeL1, MAINNET)` on L2, the L2 proxy executes `executeCrossChainCall` which consumes an L2 entry returning `RESULT(L1, void)`. This signals "the L2 side is done". But the actual L1-side execution (Bridge_L1.receiveTokens releasing tokens to ReverseExecutorL1) has NOT happened yet — that must be triggered separately by the builder on L1.

The builder detects this L2 proxy call and sends a trigger tx to L1 targeting `proxy(Bridge_L2, L2_ROLLUP_ID)` (the proxy on L1 that represents Bridge_L2). This trigger hits `Rollups.executeCrossChainCall`, which matches L1 Entry 0. The `nextAction` of Entry 0 is a nested `delivery_CALL` with `scope=[0]`, which causes `_resolveScopes` → `newScope([])` → `newScope([0])` → `_processCallAtScope` to actually call `Bridge_L1.receiveTokens(...)`. This releases the native tokens to ReverseExecutorL1.

Without the nested delivery (if Entry 0 returned `RESULT(L1,void)` directly), `Rollups.executeCrossChainCall` would consume the entry and return, but `Bridge_L1.receiveTokens` would never be called and the tokens would never arrive.

#### Why scope navigation is required on L2

The flash loan pattern requires that tokens RETURN within the same transaction via scope navigation. When `ReverseExecutorL2.onFlashLoan` burns wrapped tokens (via `bridgeTokens`), those tokens must be minted back before `onFlashLoan` returns so the flash loan repayment succeeds.

L2 Entry 1 (claimAndBridgeBack) returns `callReturn{scope=[0]}` instead of `RESULT(L1, void)`. The `_resolveScopes` machinery on L2 processes this call: `newScope([]) → newScope([0]) → _processCallAtScope([0], callReturn)`. This calls `proxy(Bridge_L1, MAINNET).executeOnBehalf(Bridge_L2, retReceiveTokens)`, which invokes `Bridge_L2.receiveTokens`. Since `originalRollupId (MAINNET=0) != rollupId (L2)`, this is a foreign token and `receiveTokens` MINTS wrapped tokens to `reverseExecutorL2`. Flash loan repaid.

This is the exact mirror of how L1→L2 flash loan (F.3) works on L1: scope navigation returns tokens within the same tx. Both chains have `_resolveScopes`, `newScope`, `_processCallAtScope`, and `executeOnBehalf`.

#### L2 execution table

Three entries — two for L2→L1 proxy calls, one for scope resolution. The second call uses scope navigation to mint tokens back for flash loan repayment.

**How each L2 entry works**: When ReverseExecutorL2 calls `proxy.call(...)` on L2, the proxy fallback invokes `managerL2.executeCrossChainCall(sourceAddress, callData)`. The manager builds a CALL action from the proxy's stored identity and matches it against the L2 execution table. For Entry 0, the next action is `RESULT(L1, void)` which terminates immediately. For Entry 1, the next action is `callReturn{scope=[0]}` which triggers scope navigation to mint tokens.

```
L2 Entry 0 (forward bridge — terminal):
  actionHash = hash(CALL{
    actionType: CALL,
    rollupId:   MAINNET_ROLLUP_ID,     // proxy represents something on L1
    destination: bridgeL1,             // proxy's originalAddress (Bridge_L1)
    value:       0,
    data:        receiveTokens(token, MAINNET, reverseExecutorL1, 10k, ..., L2),
    failed:      false,
    sourceAddress: bridgeL2,           // msg.sender to the proxy = Bridge_L2
    sourceRollup: L2_ROLLUP_ID,        // ROLLUP_ID from executeCrossChainCall on L2
    scope:       []
  })
  stateDeltas: []
  nextAction:  result_L1_void = RESULT{rollupId: MAINNET, data: "", failed: false, scope: []}

L2 Entry 1 (claim and bridge back — scope navigation):
  actionHash = hash(CALL{
    actionType: CALL,
    rollupId:   MAINNET_ROLLUP_ID,     // proxy represents something on L1
    destination: reverseExecutorL1,    // proxy's originalAddress
    value:       0,
    data:        claimAndBridgeBack(token, nft, bridgeL1, L2, reverseExecutorL2),
    failed:      false,
    sourceAddress: reverseExecutorL2,  // msg.sender to the proxy
    sourceRollup: L2_ROLLUP_ID,
    scope:       []
  })
  stateDeltas: []
  nextAction:  callReturn = CALL{
    actionType:   CALL,
    rollupId:     L2_ROLLUP_ID,         // executes on L2 (scope navigation is L2-local)
    destination:  bridgeL2,             // actual target: Bridge_L2.receiveTokens
    value:        0,
    data:         retReceiveTokens(token, MAINNET, reverseExecutorL2, 10k, ..., MAINNET),
    failed:       false,
    sourceAddress: bridgeL1,            // proxy(Bridge_L1, MAINNET) will be the caller
    sourceRollup: MAINNET_ROLLUP_ID,
    scope:        [0]                   // scope navigation: forces _processCallAtScope
  }

L2 Entry 2 (scope resolution after callReturn):
  // After _processCallAtScope(scope=[0], callReturn) returns, it builds
  // RESULT{rollupId: callReturn.rollupId = L2_ROLLUP_ID, data:"", failed:false} = result_void(L2)
  actionHash = hash(RESULT{
    actionType: RESULT,
    rollupId:   L2_ROLLUP_ID,
    destination: address(0),
    value:      0,
    data:       "",
    failed:     false,
    sourceAddress: address(0),
    sourceRollup: 0,
    scope:      []
  })
  stateDeltas: []
  nextAction:  result_L1_void           // terminal
```

**Note on L2 entry action hash construction**: `executeCrossChainCall` on L2 always sets `sourceRollup = ROLLUP_ID` (this L2's ID). The `rollupId` field comes from `proxyInfo.originalRollupId` (= `MAINNET_ROLLUP_ID = 0` for proxies representing L1 contracts). `destination` comes from `proxyInfo.originalAddress`.

For L2 Entry 0: Bridge_L2 calls `proxy(bridgeL1, MAINNET)` on L2 (deployed by `_getOrDeployProxy(bridgeL1, MAINNET)` inside `bridgeL2.bridgeTokens`). So `proxyInfo.originalRollupId = 0`, `proxyInfo.originalAddress = bridgeL1`, `sourceAddress = msg.sender to proxy = bridgeL2`.

For L2 Entry 1: ReverseExecutorL2 calls `proxy(reverseExecutorL1, MAINNET)` on L2. So `proxyInfo.originalRollupId = 0`, `proxyInfo.originalAddress = reverseExecutorL1`, `sourceAddress = reverseExecutorL2`.

For L2 Entry 2: the `callReturn` in Entry 1 is a CALL with `rollupId = L2_ROLLUP_ID`. When `_processCallAtScope` executes it and the call returns void, it builds `RESULT{rollupId: L2_ROLLUP_ID, ...}`. The hash of this RESULT is the actionHash for Entry 2.

#### L1 execution table

Five deferred entries, posted by builder via `postBatch` before (or in the same block as) the L2 trigger.

The L1 entry `actionHash` values are computed from the **trigger perspective** — i.e., the action that `Rollups.executeCrossChainCall` builds when the builder sends a trigger tx to a proxy on L1.

When the builder sends a trigger tx targeting `proxy(Bridge_L2, L2_ROLLUP_ID)` on L1 (the proxy that represents Bridge_L2), `Rollups.executeCrossChainCall` computes:
```
action = CALL{
  rollupId:      L2_ROLLUP_ID,          // proxy.originalRollupId
  destination:   Bridge_L2,             // proxy.originalAddress
  value:         0,
  data:          fwdReceiveTokensCalldata,
  sourceAddress: builder_address,       // msg.sender to the proxy = builder
  sourceRollup:  MAINNET_ROLLUP_ID (0), // always 0 on L1
  scope:         []
}
```

This is the trigger action hash for L1 Entry 0. The `nextAction` is the delivery CALL that actually executes `Bridge_L1.receiveTokens`.

```
L1 Entry 0 (forward bridge trigger → nested delivery):
  actionHash = hash(CALL{
    actionType:   CALL,
    rollupId:     L2_ROLLUP_ID,          // proxy's originalRollupId
    destination:  bridgeL2,              // proxy's originalAddress (Bridge_L2)
    value:        0,
    data:         receiveTokens(token, MAINNET, reverseExecutorL1, 10k, ..., L2),
    failed:       false,
    sourceAddress: builder_address,      // builder sent trigger tx to proxy
    sourceRollup: MAINNET_ROLLUP_ID,     // sourceRollup is always 0 on L1
    scope:        []
  })
  stateDeltas: [{rollupId: L2, current: S0, new: S1, etherDelta: 0}]
  nextAction:  delivery_A = CALL{
    actionType:   CALL,
    rollupId:     MAINNET_ROLLUP_ID,     // executes on L1 (scope navigation is L1-local)
    destination:  bridgeL1,              // actual target: Bridge_L1.receiveTokens
    value:        0,
    data:         receiveTokens(token, MAINNET, reverseExecutorL1, 10k, ..., L2),
    failed:       false,
    sourceAddress: bridgeL2,             // proxy(bridgeL2, L2) will be the caller
    sourceRollup: L2_ROLLUP_ID,
    scope:        [0]                    // nested delivery: forces _processCallAtScope
  }

L1 Entry 0b (delivery scope resolution):
  actionHash = hash(RESULT{
    actionType: RESULT,
    rollupId:   MAINNET_ROLLUP_ID,       // result_void(0) = RESULT{rollupId:0, ...}
    destination: address(0),
    value:      0,
    data:       "",
    failed:     false,
    sourceAddress: address(0),
    sourceRollup: 0,
    scope:      []
  })
  stateDeltas: []
  nextAction:  result_L1_void            // terminal

L1 Entry 1 (claim trigger → execution call):
  actionHash = hash(CALL{
    actionType:   CALL,
    rollupId:     L2_ROLLUP_ID,          // proxy's originalRollupId
    destination:  reverseExecutorL2,     // proxy's originalAddress
    value:        0,
    data:         claimAndBridgeBack(token, nft, bridgeL1, L2, reverseExecutorL2),
    failed:       false,
    sourceAddress: builder_address,
    sourceRollup: MAINNET_ROLLUP_ID,
    scope:        []
  })
  stateDeltas: [{rollupId: L2, current: S1, new: S2, etherDelta: 0}]
  nextAction:  execution_B = CALL{
    actionType:   CALL,
    rollupId:     MAINNET_ROLLUP_ID,     // executes on L1
    destination:  reverseExecutorL1,     // actual target: ReverseExecutorL1.claimAndBridgeBack
    value:        0,
    data:         claimAndBridgeBack(token, nft, bridgeL1, L2, reverseExecutorL2),
    failed:       false,
    sourceAddress: reverseExecutorL2,    // proxy(reverseExecutorL2, L2) will be the caller
    sourceRollup: L2_ROLLUP_ID,
    scope:        [0]                    // nested execution
  }

L1 Entry 1b (bridge return trip — reentrant):
  // Inside ReverseExecutorL1.claimAndBridgeBack, Bridge_L1.bridgeTokens is called.
  // Bridge_L1 calls proxy(Bridge_L2, L2_ROLLUP_ID) on L1 → reentrant executeCrossChainCall.
  // Rollups computes:
  //   rollupId = L2_ROLLUP_ID   (proxy.originalRollupId)
  //   destination = Bridge_L2   (proxy.originalAddress)
  //   sourceAddress = Bridge_L1 (msg.sender to proxy = Bridge_L1, inside bridgeTokens)
  //   sourceRollup = 0          (L1)
  //   data = retReceiveTokens calldata
  actionHash = hash(CALL{
    actionType:   CALL,
    rollupId:     L2_ROLLUP_ID,
    destination:  bridgeL2,
    value:        0,
    data:         receiveTokens(token, MAINNET, reverseExecutorL2, 10k, ..., MAINNET),
    failed:       false,
    sourceAddress: bridgeL1,             // Bridge_L1 called proxy(Bridge_L2, L2)
    sourceRollup: MAINNET_ROLLUP_ID,
    scope:        []
  })
  stateDeltas: [{rollupId: L2, current: S2, new: S3, etherDelta: 0}]
  nextAction:  result_L1_void

L1 Entry 2 (scope resolution after claimAndBridgeBack):
  // After _processCallAtScope(scope=[0], execution_B) returns, it builds
  // RESULT{rollupId: execution_B.rollupId = 0, data:"", failed:false} = result_void(0)
  // Same hash as L1 Entry 0b. Entry 0b is consumed first (during Entry 0's scope).
  // By the time Entry 2 is needed, executionIndex has advanced past Entry 0b.
  actionHash = hash(result_L1_void)     // same hash as Entry 0b, consumed second
  stateDeltas: []
  nextAction:  result_L1_void
```

**receiveTokens calldata for L1 Entry 1b** (the return trip): When `ReverseExecutorL1.claimAndBridgeBack` calls `Bridge_L1.bridgeTokens(token, balance, L2_ROLLUP_ID, reverseExecutorL2)`:
- `token` is the native L1 token
- `wrappedTokenInfo[token]` is empty (token is native on L1), so `originalToken = token`, `originalRollupId = L1_ROLLUP_ID = 0`
- `destinationAddress = reverseExecutorL2`
- `sourceRollupId = rollupId = 0` (L1 is the source)
- Therefore: `receiveTokens(token, 0 /*originRollupId=MAINNET*/, reverseExecutorL2, balance, name, symbol, decimals, 0 /*sourceRollupId=MAINNET*/)`

Note the distinction from the forward leg: `sourceRollupId = MAINNET (0)` because Bridge_L1 (on L1, rollupId=0) is sending.

#### Step-by-step execution

**L2 execution** (user triggers):

1. Alice → `reverseExecutorL2.execute()` → `flashLoanL2.flashLoan(wrapped, 10k)` → `onFlashLoan`
2. `bridgeL2.bridgeTokens(wrapped, 10k, MAINNET, reverseExecutorL1)`:
   - Burns 10k wrapped tokens from ReverseExecutorL2
   - `bridgeProxy = _getOrDeployProxy(bridgeL1, MAINNET)` (bridgeL2._bridgeAddress() = bridgeL1)
   - `bridgeProxy.call(fwdReceiveTokensCalldata)` → proxy fallback
   - Proxy → `managerL2.executeCrossChainCall(bridgeL2, fwdCalldata)`
   - Manager builds CALL{MAINNET, bridgeL1, fwdCalldata, bridgeL2, L2, []}
   - `_consumeExecution(hash(L2 Entry 0))` → finds Entry 0 → nextAction = `result_L1_void`
   - `_resolveScopes(result_L1_void)` → already RESULT, not failed → returns ""
3. `reverseExecutorL1Proxy.call(claimAndBridgeBack calldata)` → proxy fallback:
   - proxy = `proxy(reverseExecutorL1, MAINNET)` (pre-deployed by ReverseExecutorL2 constructor)
   - Proxy → `managerL2.executeCrossChainCall(reverseExecutorL2, claimCalldata)`
   - Manager builds CALL{MAINNET, reverseExecutorL1, claimCalldata, reverseExecutorL2, L2, []}
   - `_consumeExecution(hash(L2 Entry 1))` → finds Entry 1 → nextAction = `callReturn{scope:[0]}`
   - `_resolveScopes(callReturn)`:
     - `callReturn.actionType == CALL` → `this.newScope([], callReturn)`
     - In `newScope(scope=[], action=callReturn)`:
       - `callReturn.scope = [0]`, `scope = []`
       - `_isChildScope([], [0]) == true`
       - Build child scope: `[] ++ [0] = [0]`
       - Call `this.newScope([0], callReturn)`
     - In `newScope(scope=[0], action=callReturn)`:
       - `_scopesMatch([0], [0]) == true`
       - `_processCallAtScope([0], callReturn)`:
         - `sourceProxy = proxy(bridgeL1, MAINNET_ROLLUP_ID)` on L2 (auto-created if needed)
         - `proxy.executeOnBehalf(bridgeL2, retReceiveTokensCalldata)`:
           - `bridgeL2.receiveTokens(token, MAINNET, reverseExecutorL2, 10k, ..., MAINNET)`:
             - `onlyBridgeProxy(MAINNET)`: proxy for (bridgeL1, MAINNET) == msg.sender ✓
             - `originalRollupId (MAINNET=0) != rollupId (L2)` → foreign token
             - Mints wrapped tokens to `reverseExecutorL2` ✓
         - Returns void
         - Builds `result_void(L2_ROLLUP_ID)`, `_consumeExecution(hash(result_L2_void))` → finds L2 Entry 2 → nextAction = `result_L1_void`
       - `result_L1_void.actionType == RESULT` → loop breaks → returns `result_L1_void`
     - `newScope([])` receives RESULT from child → loop breaks → returns `result_L1_void`
   - `_resolveScopes` asserts success → returns ""
4. Repayment: `IERC20(wrappedToken).safeTransfer(flashLoanPool, 10k)` — succeeds because scope navigation in step 3 minted 10k wrapped tokens back to `reverseExecutorL2`.

**Flash loan repayment**: The scope navigation in step 3 solves the repayment problem atomically within the same L2 transaction. When `_processCallAtScope` calls `Bridge_L2.receiveTokens`, it mints wrapped tokens to `reverseExecutorL2` inside the same `onFlashLoan` call. By the time step 4 runs, `reverseExecutorL2` holds the minted tokens and can repay the flash loan. No cross-block dependency. Verified working: L2 tx status 1.

**L1 execution** (builder trigger txs, same L1 block as postBatch):

**Trigger 1** — Builder → `proxy(Bridge_L2, L2_ROLLUP_ID).call(fwdReceiveTokensCalldata)`:
- Proxy fallback → `Rollups.executeCrossChainCall(builder_address, fwdReceiveTokensCalldata)`
- Builds CALL{L2, bridgeL2, fwdCalldata, builder, 0, []} — matches L1 Entry 0
- `_findAndApplyExecution`: state S0→S1, returns delivery_A{scope:[0]}
- `_resolveScopes(delivery_A)`:
  - delivery_A.actionType == CALL → `this.newScope([], delivery_A)`
  - `delivery_A.scope = [0]`, `scope = []` → isChildScope([], [0]) → `this.newScope([0], delivery_A)`
  - `_scopesMatch([0], [0])` → `_processCallAtScope([0], delivery_A)`:
    - `sourceProxy = proxy(bridgeL2, L2_ROLLUP_ID)` on L1 (auto-created if needed)
    - `proxy.executeOnBehalf(bridgeL1, fwdReceiveTokensCalldata)`:
      - `bridgeL1.receiveTokens(token, MAINNET, reverseExecutorL1, 10k, ..., L2)`:
        - `onlyBridgeProxy(L2)`: msg.sender = proxy(bridgeL2, L2) = manager.computeProxy(bridgeL2, L2) ✓
        - `originalRollupId (MAINNET=0) == rollupId (0)` → releases 10k native tokens to `reverseExecutorL1` ✓
      - Returns void
    - Builds `result_void(MAINNET)`, finds L1 Entry 0b (consumed), returns `result_L1_void`
  - `newScope([0])` returns RESULT → loop breaks → returns to `newScope([])`
  - `newScope([])` sees RESULT → breaks → returns RESULT
- `_resolveScopes` asserts success → done

**Trigger 2** — Builder → `proxy(ReverseExecutorL2, L2_ROLLUP_ID).call(claimAndBridgeBackCalldata)`:
- Proxy fallback → `Rollups.executeCrossChainCall(builder_address, claimAndBridgeBackCalldata)`
- Builds CALL{L2, reverseExecutorL2, claimCalldata, builder, 0, []} — matches L1 Entry 1
- `_findAndApplyExecution`: state S1→S2, returns execution_B{scope:[0]}
- `_resolveScopes(execution_B)`:
  - execution_B.actionType == CALL → `this.newScope([], execution_B)`
  - `execution_B.scope = [0]` → `this.newScope([0], execution_B)`
  - `_processCallAtScope([0], execution_B)`:
    - `sourceProxy = proxy(reverseExecutorL2, L2_ROLLUP_ID)` on L1 (auto-created if needed)
    - `proxy.executeOnBehalf(reverseExecutorL1, claimAndBridgeBackCalldata)`:
      - `reverseExecutorL1.claimAndBridgeBack(token, nft, bridgeL1, L2, reverseExecutorL2)`:
        1. `nft.claim()` — NFT minted to ReverseExecutorL1
        2. `IERC20(token).forceApprove(bridgeL1, balance)`
        3. `Bridge_L1.bridgeTokens(token, balance, L2_ROLLUP_ID, reverseExecutorL2)`:
           - Token is native on L1 → locked in Bridge_L1
           - `bridgeProxy = _getOrDeployProxy(bridgeL1, L2_ROLLUP_ID)` → proxy(bridgeL1, L2) on L1
           - `bridgeProxy.call(retReceiveTokensCalldata)` → proxy fallback
           - REENTRANT: Proxy → `Rollups.executeCrossChainCall(bridgeL1, retReceiveTokensCalldata)`
           - Builds CALL{L2, bridgeL2, retCalldata, bridgeL1, 0, []} — matches L1 Entry 1b
           - `_findAndApplyExecution`: state S2→S3, returns `result_L1_void`
           - `_resolveScopes(result_L1_void)` → already RESULT → returns ""
      - Returns void
    - Builds `result_void(MAINNET)`, finds L1 Entry 2 (consumed), returns `result_L1_void`
  - RESULT → done

**L1 Entry 0b vs Entry 2 hash collision**: Both have `hash(result_L1_void) = hash(RESULT{rollupId:0, data:"", failed:false, scope:[]})`. This is safe because of sequential consumption order: Entry 0b appears earlier in the array than Entry 2. When Trigger 1's scope resolution consumes Entry 0b, `executionIndex` advances past it. When Trigger 2 later needs the same hash, the scan starts from the updated `executionIndex` and finds Entry 2.

**Final state**: S3 on L2 (from L1 Entry 1b), 10k native tokens locked in Bridge_L1, NFT claimed by ReverseExecutorL1, 10k wrapped tokens minted to reverseExecutorL2 (via L2 scope navigation), flash loan repaid.

#### L2 scope navigation vs L1 return trip

The token minting that enables flash loan repayment happens via **L2 scope navigation** (L2 Entry 1 → callReturn{scope:[0]} → Bridge_L2.receiveTokens → mint), NOT via a separate L1-driven return trip. This is the key architectural insight: the `callReturn` in L2 Entry 1 causes `_processCallAtScope` to call `proxy(Bridge_L1, MAINNET).executeOnBehalf(Bridge_L2, retReceiveTokens)` directly on L2, within the same transaction as the user's `execute()` call.

On L1, the `retReceiveTokens` call in L1 Entry 1b is consumed during the reentrant `executeCrossChainCall` inside `Bridge_L1.bridgeTokens`. This records the state delta (S2→S3) for L1 accounting purposes but does not trigger a separate L2 delivery — the L2 side already handled token minting through scope navigation.

#### Entry count summary

| Layer | Entries | Purpose |
|-------|---------|---------|
| L2 table | 3 | Entry 0 (bridgeTokens → RESULT terminal), Entry 1 (claimAndBridgeBack → callReturn scope nav), Entry 2 (scope resolution) |
| L1 table | 5 | Entry 0 (trigger→delivery), Entry 0b (delivery resolution), Entry 1 (trigger→execution), Entry 1b (bridge return reentrant), Entry 2 (scope exit) |

---

### F.5 Entry Naming Summary

For any multi-step cross-chain interaction, the pattern is:

| Entry | actionHash | stateDeltas | nextAction | Notes |
|-------|-----------|-------------|------------|-------|
| Forward leg | hash(CALL_A) | pre→post_A | RESULT terminal or CALL_B | Applied when CALL_A proxy is triggered |
| Continuation | hash(CALL_B) | post_A→post_B | CALL_C with scope=[0] or RESULT | Applied when CALL_B proxy is triggered |
| Scope exit | hash(RESULT) | post_B→post_C | RESULT terminal | Applied after scope=[0] call completes |

On L2 (no state delta verification), entries have empty `stateDeltas` arrays.

**L1→L2 flash loan (F.3)** uses 3 L1 entries and 3 L2 entries.
**L2→L1 reverse flash loan (F.4)** uses 3 L2 entries and 5 L1 entries.

The asymmetry in L1 entry count is because:
- In F.3, scope navigation and nested execution happen on L2 (single system call)
- In F.4, scope navigation and nested delivery/execution happen on L1 (two builder trigger txs)

---

## G. Bridge Protocol

### G.1 Deployment Model

Bridge is deployed via CREATE2 with no constructor args, so the same bytecode produces the same address on every chain. Chain-specific state is set via `initialize()` after deployment:

```solidity
function initialize(address _manager, uint256 _rollupId, address _admin) external
```

- Can only be called once (`manager == address(0)` guard)
- Sets `manager`, `rollupId`, `admin`

`canonicalBridgeAddress` can be set by admin after initialization. This overrides the default of `address(this)` for cross-chain proxy lookups when bridges are at different addresses across chains (test scenario).

### G.2 `_bridgeAddress()`

```solidity
function _bridgeAddress() internal view returns (address) {
    address canonical = canonicalBridgeAddress;
    return canonical != address(0) ? canonical : address(this);
}
```

Used as the `originalAddress` when creating cross-chain proxies for the bridge itself. In production (same CREATE2 address on all chains), `canonicalBridgeAddress` is zero and `address(this)` is used. In tests where bridges are at different addresses, `canonicalBridgeAddress` is set to the counterpart address.

### G.3 `bridgeEther` (outbound ETH)

```solidity
function bridgeEther(uint256 _rollupId, address destinationAddress) external payable
```

1. Guard: `msg.value > 0`
2. `proxy = _getOrDeployProxy(destinationAddress, _rollupId)` — proxy for the recipient's address on destination rollup
3. `proxy.call{value: msg.value}("")` — triggers `executeCrossChainCall` on the manager with empty calldata and ETH value
4. Emit `EtherBridged`

The empty calldata means the CALL action built by `executeCrossChainCall` will have `data=""`. The destination on the other rollup receives ETH via `proxy.executeOnBehalf(destinationAddress, "")` which calls `destinationAddress.call{value: amount}("")`.

### G.4 `bridgeTokens` (outbound ERC20)

```solidity
function bridgeTokens(address token, uint256 amount, uint256 _rollupId, address destinationAddress) external
```

1. Guards: `amount > 0`, `token != address(0)`
2. Look up `wrappedTokenInfo[token]`:
   - If `info.originalToken != address(0)` (token is a WrappedToken):
     - Burn: `WrappedToken(token).burn(msg.sender, amount)`
     - `originalToken = info.originalToken`, `originalRollupId = info.originalRollupId`
   - Else (native token):
     - Lock: `IERC20(token).safeTransferFrom(msg.sender, address(this), amount)`
     - `originalToken = token`, `originalRollupId = rollupId`
3. `bridgeProxy = _getOrDeployProxy(_bridgeAddress(), _rollupId)` — proxy for the bridge itself on destination
4. `bridgeProxy.call(abi.encodeCall(receiveTokens, (originalToken, originalRollupId, destinationAddress, amount, name, symbol, decimals, rollupId)))` → triggers `executeCrossChainCall` on manager
5. Emit `TokensBridged`

### G.5 `receiveTokens` (inbound)

```solidity
function receiveTokens(
    address originalToken,
    uint256 originalRollupId,
    address to,
    uint256 amount,
    string calldata name,
    string calldata symbol,
    uint8 tokenDecimals,
    uint256 sourceRollupId
) external onlyBridgeProxy(sourceRollupId)
```

**Access control**: `onlyBridgeProxy(sourceRollupId)` — verifies that `msg.sender == manager.computeCrossChainProxyAddress(_bridgeAddress(), sourceRollupId)`. This ensures only the bridge's proxy from the source chain can call this function.

1. If `originalRollupId == rollupId` (token is native to this chain):
   - `IERC20(originalToken).safeTransfer(to, amount)` — release locked tokens
   - Emit `TokensReleased`
2. Else (token is foreign to this chain):
   - `_getOrDeployWrapped(originalToken, originalRollupId, name, symbol, decimals)` — deploy WrappedToken via CREATE2 if needed
   - `WrappedToken(wrapped).mint(to, amount)` — mint wrapped tokens
   - Emit `WrappedTokensMinted`

### G.6 WrappedToken

Deployed by Bridge via CREATE2:
```
salt = keccak256(abi.encodePacked(originalToken, originalRollupId))
WrappedToken{salt: salt}(name, symbol, decimals, address(this))
```

Only the Bridge can mint or burn. The Bridge's address is stored as `immutable BRIDGE`.

`wrappedTokens[salt] → address` maps (originalToken, originalRollupId) to WrappedToken address.
`wrappedTokenInfo[wrappedAddr] → TokenInfo` reverse-maps WrappedToken address back to (originalToken, originalRollupId).

This bidirectional mapping allows `bridgeTokens` to detect wrapped tokens and trace them back to their origin.

---

## H. Invariants

### H.1 State Root Consistency

**Invariant**: `rollups[id].stateRoot` always equals the state root of the rollup's last committed block.

- Updated only by `_applyStateDeltas` (within `postBatch` or `executeCrossChainCall`)
- Updated by `setStateByOwner` (owner escape hatch, no proof)
- Never set to an arbitrary value without either a proof or owner authorization

### H.2 Ether Accounting

**Invariant**: For any set of state deltas applied atomically, `sum(etherDelta for all deltas) == _etherDelta`.

`_etherDelta` tracks the net ETH flow during one execution context:
- `+= msg.value` when ETH enters via `executeCrossChainCall`
- `-= action.value` when ETH exits via `_processCallAtScope`
- Reset to 0 after each `_applyStateDeltas`

For `postBatch` immediate entries (no ETH transferred), both sides must be zero.

For deferred entries consumed via proxy calls:
- ETH in: `_etherDelta > 0` (bridged-in ETH)
- ETH out: `_etherDelta < 0` (scope-executed ETH transfers)
- State deltas must reflect the same net change

**Corollary**: the sum of `etherBalance` across all rollups plus the Rollups.sol contract's ETH balance is conserved (net zero, modulo direct deposits/withdrawals outside the protocol).

### H.3 Execution Table Entries Are Consumed Exactly Once

Each execution entry is consumed by advancing `executionIndex` past it. No entry can be consumed twice:
- On L1: `executionIndex` has advanced past the entry, and state delta verification prevents re-use (the state has already advanced)
- On L2: `executionIndex` has advanced past the entry, so it cannot be reached again by the forward scan

If the same action occurs twice, two separate entries must exist in the correct consumption order (disambiguated by position).

### H.4 Proxy Determinism

**Invariant**: The address of a CrossChainProxy for (originalAddress, originalRollupId) is fully determined by:
- The manager contract address (`address(this)`)
- The CREATE2 salt: `keccak256(abi.encodePacked(originalRollupId, originalAddress))`
- The CrossChainProxy bytecode + constructor args

The same (originalAddress, originalRollupId) pair always maps to the same proxy address on the same manager. Two proxies for the same pair cannot exist (CREATE2 collision would revert).

### H.5 Same-Block Execution

All execution entries and static call entries posted in a given block can only be consumed/queried in that same block (`lastStateUpdateBlock == block.number`). This enforces the synchronous composability guarantee: the builder posts the execution table and all user calls happen within the same block.

### H.6 Execution Table Cleared Per Block

`postBatch` (L1) and `loadExecutionTable` (L2) each call `delete executions`, `delete staticCalls`, and reset `executionIndex = 0` before loading new entries. Unconsumed entries from a prior block are silently discarded. Builders must post a complete, self-consistent table each block.

### H.7 Static Call Rolling Hash Verification

**Invariant**: For any `StaticCall` entry with non-empty `calls`, the rolling hash computed by re-executing all sub-calls in static context must match the pre-computed `rollingHash` field. This is verified on-chain by `_processNStaticCalls` within `staticCallLookup`.

This ensures that the sub-call results observed by the protocol match what the builder pre-computed. If any sub-call produces different results than expected (e.g., due to state changes), `RollingHashMismatch` is thrown.

---

## I. Security Considerations

### I.1 ZK Proof Verification

In production, `postBatch` verifies a ZK proof that covers:
- All entry hashes (which embed state deltas, verification keys, actionHash, nextAction)
- Blob hashes (for data availability)
- Calldata hash
- Parent block hash and timestamp

The proof guarantees that the builder correctly simulated all cross-chain interactions given the initial state roots. A malicious `postBatch` call with forged entries will fail proof verification.

**tmpECDSAVerifier** (development only): substitutes a 65-byte ECDSA signature for the ZK proof. The `signer` address is set at deployment. The signature covers `publicInputsHash` as a raw bytes32 (no EIP-191 prefix). `v` must be 27 or 28 (not 0 or 1). This verifier provides no ZK guarantees — it is solely for testing without ZK hardware.

### I.2 Reentrancy During Scope Navigation

The protocol is intentionally reentrant. `_processCallAtScope` calls external contracts (via proxies), which may call back into the manager via their own proxy fallbacks. For example, in the reverse flash loan:
- Trigger 2 executes `claimAndBridgeBack` via scope navigation on L1
- Inside `claimAndBridgeBack`, `bridge.bridgeTokens` calls `proxy(bridgeL1, L2)` → reentrant `executeCrossChainCall` on L1

This reentrant call is expected and handled by consuming a different execution entry (Entry 1b, not Entry 1). The sequential scan from `executionIndex` handles reentrancy correctly: each reentrant call to `_findAndApplyExecution` advances `executionIndex` past the consumed entry. When the outer call resumes after the reentrant call returns, it continues from the already-advanced `executionIndex`, finding the next expected entry.

The `_etherDelta` transient storage is reset by every `_applyStateDeltas` call, so nested ETH accounting contexts are sequential, not nested. Each execution entry consumption is atomic with respect to ether accounting.

### I.3 Access Control Summary

| Function | Who can call |
|----------|-------------|
| `createRollup` | Anyone |
| `postBatch` | Anyone (proof verifies authorization) |
| `executeCrossChainCall` | Registered proxies only |
| `executeL2TX` | Anyone (also called internally by `postBatch`) |
| `staticCallLookup` | Registered proxies only |
| `newScope` | `address(this)` only (self-call) |
| `createCrossChainProxy` | Anyone |
| `setStateByOwner` | Rollup owner |
| `setVerificationKey` | Rollup owner |
| `transferRollupOwnership` | Rollup owner |
| L2 `loadExecutionTable` | SYSTEM_ADDRESS |
| L2 `executeIncomingCrossChainCall` | SYSTEM_ADDRESS |
| L2 `executeCrossChainCall` | Registered proxies |
| L2 `staticCallLookup` | Registered proxies |
| L2 `newScope` | `address(this)` |
| L2 `createCrossChainProxy` | Anyone |
| `Bridge.initialize` | Anyone (once) |
| `Bridge.setCanonicalBridgeAddress` | Admin |
| `Bridge.bridgeEther` / `bridgeTokens` | Anyone |
| `Bridge.receiveTokens` | `onlyBridgeProxy(sourceRollupId)` |
| `WrappedToken.mint` / `burn` | Bridge only |

### I.4 State Root Mismatch Handling

On L1, `_findAndApplyExecution` performs a HARD REVERT on state root mismatch. When a matching `actionHash` is found, ALL state deltas' `currentState` fields must match the on-chain state roots. If ANY mismatch is found, `StateRootMismatch` is thrown immediately. There is no soft skip to try the next entry.

The only skip mechanism is the skip-scan for failed entries: if an entry's `actionHash` does not match AND `nextAction.failed == true`, the entry is skipped. This allows the builder to include entries for alternative execution paths (e.g., entries for reverted branches) that will be skipped if the non-reverted path is taken first.

The Rust node handles `ExecutionNotFound` or `StateRootMismatch` by rewinding: the current block is abandoned and re-derived from a prior block.

### I.5 Proxy Auto-Creation

Both `_processCallAtScope` on L1 and L2 auto-create the source proxy if it doesn't exist before calling `executeOnBehalf`. This means the first cross-chain call from any (address, rollupId) pair automatically deploys the proxy. Proxy addresses are deterministic, so the builder can predict them before they are deployed.

**Note**: `_processNStaticCalls` (used in static context) cannot auto-create proxies (CREATE2 is forbidden in STATICCALL). Instead, it checks `sourceProxy.code.length > 0` and reverts with `ProxyNotDeployed` if the proxy doesn't exist. All proxies referenced by static call sub-calls must be deployed before the static call lookup runs.

### I.6 Execution Table Ordering

The `executions` array has STRICT SEQUENTIAL ORDERING. On both L1 and L2, entries are consumed by scanning forward from `executionIndex`. The builder MUST order entries in the exact consumption order. Non-failed entries that appear before the expected entry (with a different `actionHash`) cause a hard `ExecutionNotFound` revert.

**Builder constraint**: The builder must simulate the complete execution flow (including reentrancy and scope navigation) to determine the exact consumption order, then arrange entries in that order.

**Hash collision in F.4**: L1 Entries 0b and 2 both have `hash(result_L1_void)`. This is safe because of sequential consumption: Entry 0b appears earlier in the array and is consumed first (during Trigger 1's scope resolution). When Trigger 2 needs the same hash, `executionIndex` has already advanced past Entry 0b, so the scan finds Entry 2.

### I.7 `StateAlreadyUpdatedThisBlock` Guard

Only one `postBatch` can succeed per block on L1. This is a global mutex: the entire execution table is replaced atomically with each new batch. Builders must coordinate to ensure exactly one `postBatch` per block.

### I.8 Cross-Chain Proxy Identity

A CrossChainProxy represents exactly one (originalAddress, originalRollupId) pair. When a contract on chain A calls a proxy on chain B, the proxy forwards to B's manager with `sourceAddress = msg.sender` (the contract on chain A) and `sourceRollup = B's rollupId` (on L2) or `MAINNET_ROLLUP_ID` (on L1). The resulting CALL action's `sourceAddress` and `sourceRollup` form the caller's cross-chain identity.

`onlyBridgeProxy` in Bridge.sol uses this identity: it expects the call to come from the proxy representing the bridge itself (`_bridgeAddress()`) on the source rollup. This prevents arbitrary contracts from calling `receiveTokens` directly.

### I.9 STATICCALL Detection in CrossChainProxy

The proxy detects static context via a self-call to `staticCheck()` that attempts TSTORE. In a `STATICCALL` context, TSTORE is disallowed and the self-call reverts, signaling static context. The self-call can also fail due to out-of-gas. If the self-call runs out of gas, the proxy incorrectly concludes it is in a static context and routes to `staticCallLookup` (a view function). However, if 63/64 of remaining gas can't cover a single TSTORE (~100 gas), the subsequent MANAGER call will also revert due to insufficient gas. This is a liveness concern (false failure) rather than a safety concern (incorrect state mutation).

---

## Appendix: Key Hash Values from Reference Implementation

From `contracts/sync-rollups/script/flash-loan-test/ExecuteFlashLoan.s.sol` (L1→L2 flash loan, confirmed correct):

```
result_L2_void = Action{RESULT, rollupId=1, dest=0, value=0, data="", failed=false, src=0, srcRollup=0, scope=[]}
hash(result_L2_void) = keccak256(abi.encode(result_L2_void))
```

This hash appears in both L2 Entry 0 and L2 Entry 2 (two entries share the same hash). Entry 0 is consumed first because it appears earlier in the array (sequential ordering). The two entries have different `nextAction` fields.

The `CLAUDE.md` file documents canonical entry hash values as:
- Entry 0 (result_L2_void → callB): `0x7cee89f0...`
- Entry 1 (callBridgeReturn → result_MAINNET_void): `0xe690f92b...`

These values are computed from the actual contract addresses deployed in the devnet environment.

### Canonical Reference Scripts

- **L1→L2 flash loan**: `contracts/sync-rollups/script/flash-loan-test/ExecuteFlashLoan.s.sol` — **confirmed correct and tested**
- **L2→L1 reverse flash loan (L1 entries)**: `contracts/sync-rollups/script/flash-loan-reverse/ExecuteReverseFlashLoan.s.sol` — **KNOWN INCORRECT, DO NOT USE AS REFERENCE**. The Solidity script has three errors:
  1. Uses execution perspective hashes (sourceAddress=bridgeL2/reverseExecutorL2) instead of trigger perspective hashes (sourceAddress=builder). L1 `Rollups.executeCrossChainCall` computes the trigger hash from the proxy call, where `sourceAddress = msg.sender to the proxy = builder_address`.
  2. Uses only 3 L1 entries without nested delivery. Without nested delivery, `executeCrossChainCall` consumes the entry and returns, but `Bridge_L1.receiveTokens` is never called.
  3. Does not include `executeOnBehalf` wrapper stripping from data field. When `_processCallAtScope` calls `proxy.executeOnBehalf(dest, data)`, the proxy uses assembly to return raw bytes. The trigger calldata passed to the L1 proxy must NOT include the `executeOnBehalf` wrapper.

  The production Rust implementation in `crates/based-rollup/src/table_builder.rs:build_l2_to_l1_continuation_entries` is the correct reference. It uses 5 L1 entries with nested delivery and trigger perspective hashes. Additionally, the Rust implementation constructs 3 L2 entries (not 2) including scope navigation for flash loan repayment via `callReturn{scope=[0]}`.

  The Solidity script needs updating when it is used for testing. The Rust implementation is verified working (all 3 nodes converge, L1 triggers succeed, L2 flash loan repaid).

---

*End of specification. This document covers the `feature/contract_updates` branch as of 2026-03-24. Updated to include: static call subsystem, execution index (skip-scan), executeL2TX simplification, error consolidation in ICrossChainManager, STATICCALL detection in CrossChainProxy. F.4 verified 2026-03-21.*
