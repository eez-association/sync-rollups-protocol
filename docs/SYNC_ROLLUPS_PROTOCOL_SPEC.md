# Sync-Rollups Protocol Specification

**Version**: v01.01.01.00 (merge of feature/contract_updates)
**Source**: `src/`
**Purpose**: Formal reference for implementing the Rust rollup node. Supersedes informal comments in source code.

---

## Table of Contents

- [A. Data Model](#a-data-model)
- [B. Core Protocol Functions](#b-core-protocol-functions)
- [C. Action Hash Computation](#c-action-hash-computation)
- [D. Scope Navigation](#d-scope-navigation)
- [E. Execution Entry Lifecycle](#e-execution-entry-lifecycle)
- [F. Invariants](#f-invariants)
- [G. Security Considerations](#g-security-considerations)

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
| 3 | authorizedProxies | mapping(address => ProxyInfo) | Keyed by proxy address |
| 4 | lastStateUpdateBlock | uint256 | Block number of last postBatch |
| transient | _etherDelta | int256 | EIP-1153 transient (auto-zeroed each tx); tracks net ETH flow (+=msg.value in, -=action.value out); checked against totalEtherDelta and reset to 0 after each `_applyStateDeltas` call |

`MAINNET_ROLLUP_ID = 0` is a constant, not storage.

`ZK_VERIFIER` is an immutable (no storage slot).

#### CrossChainManagerL2.sol (L2)

| Slot | Variable | Type | Notes |
|------|----------|------|-------|
| 0 | executions | ExecutionEntry[] | Dynamic array; cleared on each loadExecutionTable |
| 1 | authorizedProxies | mapping(address => ProxyInfo) | Keyed by proxy address |
| 2 | lastStateUpdateBlock | uint256 | Block number of last loadExecutionTable |

`ROLLUP_ID` and `SYSTEM_ADDRESS` are immutables (no storage slots).

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
    uint256 blobCount,
    bytes calldata callData,
    bytes calldata proof
) external
```

**Access control**: permissionless.

**Preconditions**:
- `lastStateUpdateBlock != block.number` (one batch per block)
- All immediate entries (actionHash == 0) must have all state deltas matching current on-chain state roots
- Proof must verify (see public inputs construction below)

**Public inputs construction** (exact encoding):

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
    keccak256(callData)
  )
)
```

The verifier receives `(proof, publicInputsHash)` and must return `true`.

**State transitions** (in order):

1. Delete the existing execution table: `delete executions`
2. For each entry `e` in `entries`:
   - If `e.actionHash == bytes32(0)` (immediate entry):
     - Verify `rollups[delta.rollupId].stateRoot == delta.currentState` for all deltas. Revert with `StateRootMismatch` if any mismatch.
     - Call `_applyStateDeltas(e.stateDeltas)` — updates state roots, ether balances, verifies ether accounting.
   - Else (deferred entry): `executions.push(e)`
3. `lastStateUpdateBlock = block.number`

**Postconditions**:
- `executions` contains exactly the deferred entries from this batch
- All immediate entries' state deltas have been applied to `rollups`
- `lastStateUpdateBlock == block.number`

**Events**: `BatchPosted(entries, publicInputsHash)`

**Revert conditions**:
- `StateAlreadyUpdatedThisBlock` — `lastStateUpdateBlock == block.number`
- `InvalidProof` — verifier returns false
- `StateRootMismatch` — immediate entry's `currentState` doesn't match on-chain state root
- `EtherDeltaMismatch` — sum of `etherDelta` fields in an immediate entry's state deltas doesn't equal zero (since no actual ETH moved during batch posting)
- `InsufficientRollupBalance` — applying a negative etherDelta would underflow the rollup's balance

**Note on ether accounting for immediate entries**: since `postBatch` does not transfer ETH, `_etherDelta` starts at 0. `_applyStateDeltas` checks `totalEtherDelta != _etherDelta`. For immediate entries this means the sum of all `etherDelta` fields must be exactly zero.

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
- The matching execution entry is consumed (removed via swap-and-pop)
- State deltas of that entry are applied to `rollups`
- `_etherDelta` is reset to 0 (by `_applyStateDeltas`)
- Returns the RESULT's return data

**Events**: `CrossChainCallExecuted(actionHash, msg.sender, sourceAddress, callData, msg.value)`

**Revert conditions**:
- `UnauthorizedProxy` — caller is not a registered proxy
- `ExecutionNotInCurrentBlock` — `lastStateUpdateBlock != block.number`
- `ExecutionNotFound` — no matching entry in `executions`
- `CallExecutionFailed` — scope resolution returned a failed RESULT
- `EtherDeltaMismatch` — ether accounting mismatch
- `InsufficientRollupBalance` — rollup's ETH balance would go negative

---

#### `executeL2TX`

```solidity
function executeL2TX(
    uint256 rollupId,
    bytes calldata rlpEncodedTx
) external returns (bytes memory result)
```

**Access control**: permissionless.

**Preconditions**:
- `lastStateUpdateBlock == block.number`

**State transitions**:

1. Construct L2TX action:
   ```
   action = Action{
     actionType: L2TX,
     rollupId:   rollupId,
     destination: address(0),
     value:       0,
     data:        rlpEncodedTx,
     failed:      false,
     sourceAddress: address(0),
     sourceRollup: MAINNET_ROLLUP_ID,
     scope:       []
   }
   ```
2. `currentActionHash = keccak256(abi.encode(action))`
3. `nextAction = _findAndApplyExecution(currentActionHash, action)`
4. `result = _resolveScopes(nextAction)`

**Postconditions**: same as `executeCrossChainCall` (entry consumed, deltas applied).

**Events**: `L2TXExecuted(currentActionHash, rollupId, rlpEncodedTx)`

**Revert conditions**: same as `executeCrossChainCall` minus `UnauthorizedProxy`.

---

#### `_findAndApplyExecution` (internal)

```solidity
function _findAndApplyExecution(
    bytes32 actionHash,
    Action memory action
) internal returns (Action memory nextAction)
```

**Algorithm**:

Iterate `executions[0..n)`:
1. Skip if `executions[i].actionHash != actionHash`
2. For the hash match, verify that **all** state deltas match on-chain:
   ```
   for each delta d in executions[i].stateDeltas:
     if rollups[d.rollupId].stateRoot != d.currentState: allMatch = false
   ```
3. If `allMatch`:
   a. `_applyStateDeltas(executions[i].stateDeltas)` — update state roots and ether balances
   b. Copy `nextAction = executions[i].nextAction`
   c. Swap-and-pop: if `i != executions.length - 1`, move `executions[last]` to `executions[i]`; then `executions.pop()`
   d. Emit `ExecutionConsumed(actionHash, action)`
   e. Return `nextAction`
4. If no match found: revert `ExecutionNotFound`

**Hash collision semantics**: multiple entries may share the same `actionHash` but have different `stateDeltas`. The algorithm finds the **first** entry whose `actionHash` matches AND whose state deltas all match on-chain state. This allows the builder to post multiple alternative executions for the same action under different L2 state assumptions; only the one consistent with actual on-chain state will be consumed.

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
2. If `nextAction.actionType != RESULT || nextAction.failed`: revert `CallExecutionFailed`
3. Return `nextAction.data`

---

#### `newScope`

```solidity
function newScope(
    uint256[] memory scope,
    Action memory action
) external returns (Action memory nextAction)
```

**Access control**: `msg.sender == address(this)` only (self-call for try/catch isolation).

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

**For void calls** (destination returns nothing): `returnData = ""` and `success = true`, producing `resultAction = RESULT{rollupId: action.rollupId, data: "", failed: false, ...}`.

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

**Limitation**: Currently only one rollup's state root is restored per revert. If a reverted scope touched multiple rollups (via multiple state deltas across consumed execution entries), only the rollup carried in `ScopeReverted` is rolled back. Multi-rollup state restoration on revert is not yet supported.

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

The `SYSTEM_ADDRESS` is rollup protocol-dependent (set at construction, immutable). It performs special actions: loading the execution table and executing incoming transactions from other rollups or L1.

---

#### `loadExecutionTable`

```solidity
function loadExecutionTable(ExecutionEntry[] calldata entries) external onlySystemAddress
```

**Access control**: `SYSTEM_ADDRESS` only (set at construction, immutable).

**State transitions**:
1. `delete executions`
2. For each entry: `executions.push(entry)`
3. `lastStateUpdateBlock = block.number`

**Postconditions**: `executions` contains exactly the provided entries.

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

**Critical difference from L1**: the L2 `_consumeExecution` does NOT check state delta `currentState` fields. It matches on `actionHash` alone. State deltas are present in L2 entries (they may be empty arrays) but are never verified.

**Ether handling on L2**: ETH sent to the proxy is immediately forwarded to `SYSTEM_ADDRESS`.

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

#### `_consumeExecution` (L2 internal — no state delta matching)

```solidity
function _consumeExecution(bytes32 actionHash, Action memory action) internal returns (Action memory nextAction)
```

Iterate `executions`:
1. Skip if `executions[i].actionHash != actionHash`
2. On match: `nextAction = executions[i].nextAction`; swap-and-pop; emit `ExecutionConsumed`; return.
3. If not found: revert `ExecutionNotFound`

**Key distinction from `_findAndApplyExecution` (L1)**: no state delta verification. No `_applyStateDeltas`. No ether accounting. L2 entries with non-empty stateDeltas are accepted without checking them.

---

#### `newScope` (L2 variant)

Identical algorithm to L1 `newScope`, except:
- Access control: `msg.sender == address(this)` only
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

### B.3 CrossChainProxy.sol

```solidity
constructor(address _manager, address _originalAddress, uint256 _originalRollupId)
```

All three constructor args are stored as immutables: `MANAGER`, `ORIGINAL_ADDRESS`, `ORIGINAL_ROLLUP_ID`.

#### `fallback()`

Delegates to `_fallback()`.

#### `executeOnBehalf(address destination, bytes calldata data) external payable`

- If `msg.sender == MANAGER`: directly calls `destination.call{value: msg.value}(data)`. Uses assembly to return/revert the raw bytes (no ABI wrapping).
- Otherwise: calls `_fallback()`.

#### `_fallback()` internal

```solidity
(bool success, bytes memory result) = MANAGER.call{value: msg.value}(
    abi.encodeCall(ICrossChainManager.executeCrossChainCall, (msg.sender, msg.data))
);
```

On success: decode `abi.decode(result, (bytes))` and `assembly return` the inner bytes.
On failure: `assembly revert(result, len)` — forwards raw revert data.

**Double-encoding note**: `executeCrossChainCall` returns `bytes memory`. The low-level `.call()` ABI-encodes that return value (wrapping the bytes). So `result` is double-encoded: the outer encoding is the function return ABI, the inner is the actual return data from the destination call. `abi.decode(result, (bytes))` strips the outer layer.

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

```
l2txAction = Action{
  actionType:   L2TX,
  rollupId:     rollupId,
  destination:  address(0),
  value:        0,
  data:         rlpEncodedTx,
  failed:       false,
  sourceAddress: address(0),
  sourceRollup: MAINNET_ROLLUP_ID,
  scope:         []
}
hash = keccak256(abi.encode(l2txAction))
```

### C.5 Hash for continuation CALL entries (scope=[0] actions)

When `_findAndApplyExecution` returns a CALL action as `nextAction`, this CALL itself becomes the key for the next execution entry lookup on the **other chain**. The CALL is navigated by `_resolveScopes` → `newScope` → `_processCallAtScope`, and after `executeOnBehalf` returns, a RESULT is built and its hash is used to find the next entry.

For a reentrant `executeCrossChainCall` (a contract on one chain calling a proxy for a contract on another chain), the action hash is:
```
action = Action{
  actionType:   CALL,
  rollupId:     proxyInfo.originalRollupId,
  destination:  proxyInfo.originalAddress,
  value:        msg.value,
  data:         callData,
  failed:       false,
  sourceAddress: sourceAddress,              // msg.sender to proxy
  sourceRollup: ROLLUP_ID,                   // caller's rollup ID
  scope:         []
}
```

**Key rule**: the scope field in an action used as an execution table key is always `[]` (root). Only the `nextAction` returned from a table entry can have a non-empty scope (for routing nested calls).

---

## D. Scope Navigation

### D.1 Scope Array Semantics

A scope is a `uint256[]` representing a path in a tree of nested calls. The root scope is `[]` (empty). The first child of root is `[0]`, `[1]`, etc. The first child of `[0]` is `[0, 0]`.

Scope depth correlates with call nesting: a call at scope `[0]` is "one level deep" relative to the root caller.

Scopes are used to route CALL actions to the correct `newScope` invocation level. When the builder precomputes a CALL that must execute inside a callback, that CALL is tagged with a non-empty scope (e.g., `scope=[0]`) so `newScope` at the root level navigates into the child scope before executing it.

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
Entry for CALL_B:
  actionHash = hash(CALL_B)
  nextAction = callScoped{scope: [0]}
```

Execution flow when `executeCrossChainCall` finds CALL_B's entry:
1. `_findAndApplyExecution` returns `callScoped` with `scope=[0]`
2. `_resolveScopes(callScoped)`:
   - `callScoped.actionType == CALL`
   - Call `this.newScope([], callScoped)`
3. In `newScope(scope=[], action=callScoped)`:
   - `action.scope = [0]`, `scope = []`
   - `_isChildScope([], [0]) == true` (child: length 1 > 0, no prefix conflict)
   - Build child scope: `[] ++ [0] = [0]`
   - Call `this.newScope([0], callScoped)`
4. In `newScope(scope=[0], action=callScoped)`:
   - `_scopesMatch([0], [0]) == true`
   - Call `_processCallAtScope([0], callScoped)`
   - Execute `executeOnBehalf(destination, calldata)` → returns
   - Build RESULT, hash it, call `_findAndApplyExecution`
   - Returns terminal RESULT
5. `newScope([0], ...)` returns RESULT to `newScope([], ...)`
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
- `delete executions` clears the entire previous table
- Entries with `actionHash == 0` are applied immediately (state deltas only, no storage)
- Entries with `actionHash != 0` are pushed into `executions[]`

All entries in a single batch are proven together by one ZK proof (or ECDSA signature in the dev verifier). The proof covers all entry hashes, blob hashes, and the parent block hash.

### E.2 Loading (L2)

At `loadExecutionTable` time:
- `delete executions` clears the previous table
- All provided entries are pushed into `executions[]`

No proof is required on L2; the system address's authority substitutes for proof verification.

### E.3 Consumption

Entries are consumed one at a time by `_findAndApplyExecution` (L1) or `_consumeExecution` (L2). After consumption, the entry is removed from storage using **swap-and-pop**: the consumed entry is replaced by the last entry in the array, and the array length is decremented. This is O(1) removal with no ordering guarantees.

**Implication**: the order of entries in the `executions` array has no semantic meaning. Entries are matched by (actionHash, state deltas) — not by position.

### E.4 Same-Block Restriction

On L1, executions can only be consumed in the same block as `postBatch` (`lastStateUpdateBlock == block.number`).
On L2, executions can only be consumed in the same block as `loadExecutionTable`.

If `lastStateUpdateBlock != block.number`, all execution attempts revert with `ExecutionNotInCurrentBlock`.

### E.5 Table Clearing

Each new `postBatch` or `loadExecutionTable` call deletes the entire existing table. Unconsumed entries from the previous block are silently discarded. This means every batch is self-contained.

---

## F. Invariants

### F.1 State Root Consistency

**Invariant**: `rollups[id].stateRoot` always equals the state root of the rollup's last committed block.

- Updated only by `_applyStateDeltas` (within `postBatch` or `executeCrossChainCall`)
- Updated by `setStateByOwner` (owner escape hatch, no proof)
- Never set to an arbitrary value without either a proof or owner authorization

### F.2 Ether Accounting

**Invariant**: For any set of state deltas applied atomically, `sum(etherDelta for all deltas) == _etherDelta`.

`_etherDelta` tracks the net ETH flow during one execution context:
- `+= msg.value` when ETH enters via `executeCrossChainCall`
- `-= action.value` when ETH exits via `_processCallAtScope`
- Reset to 0 after each `_applyStateDeltas`

For `postBatch` immediate entries (no ETH transferred), both sides must be zero.

For deferred entries consumed via proxy calls:
- ETH in: `_etherDelta > 0` (ETH received via proxy call)
- ETH out: `_etherDelta < 0` (scope-executed ETH transfers)
- State deltas must reflect the same net change

**Corollary**: the sum of `etherBalance` across all rollups plus the Rollups.sol contract's ETH balance is conserved (net zero, modulo direct deposits/withdrawals outside the protocol).

### F.3 Execution Table Entries Are Consumed Exactly Once

Each execution entry is matched by (actionHash, state delta verification) and removed via swap-and-pop when consumed. No entry can be consumed twice:
- On L1: state delta verification prevents re-use (the state has already advanced)
- On L2: hash-only matching, but entries are removed on consumption

If the same action occurs twice, two separate entries must exist (with different state deltas on L1).

### F.4 Proxy Determinism

**Invariant**: The address of a CrossChainProxy for (originalAddress, originalRollupId) is fully determined by:
- The manager contract address (`address(this)`)
- The CREATE2 salt: `keccak256(abi.encodePacked(originalRollupId, originalAddress))`
- The CrossChainProxy bytecode + constructor args

The same (originalAddress, originalRollupId) pair always maps to the same proxy address on the same manager. Two proxies for the same pair cannot exist (CREATE2 collision would revert).

### F.5 Same-Block Execution

All execution entries posted in a given block can only be consumed in that same block (`lastStateUpdateBlock == block.number`). This enforces the synchronous composability guarantee: the builder posts the execution table and all user calls happen within the same block.

### F.6 Execution Table Cleared Per Block

`postBatch` (L1) and `loadExecutionTable` (L2) each call `delete executions` before loading new entries. Unconsumed entries from a prior block are silently discarded. Builders must post a complete, self-consistent table each block.

---

## G. Security Considerations

### G.1 ZK Proof Verification

In production, `postBatch` verifies a ZK proof that covers:
- All entry hashes (which embed state deltas, verification keys, actionHash, nextAction)
- Blob hashes (for data availability)
- Calldata hash
- Parent block hash and timestamp

The proof guarantees that the builder correctly simulated all cross-chain interactions given the initial state roots. A malicious `postBatch` call with forged entries will fail proof verification.

**tmpECDSAVerifier** (development only): substitutes a 65-byte ECDSA signature for the ZK proof. The `signer` address is set at deployment. The signature covers `publicInputsHash` as a raw bytes32 (no EIP-191 prefix). `v` must be 27 or 28 (not 0 or 1). This verifier provides no ZK guarantees — it is solely for testing without ZK hardware.

### G.2 Reentrancy During Scope Navigation

The protocol is intentionally reentrant. `_processCallAtScope` calls external contracts (via proxies), which may call back into the manager via their own proxy fallbacks. A reentrant `executeCrossChainCall` is expected and handled by consuming a different execution entry. The swap-and-pop removal ensures the correct entry is found even during reentrancy.

The `_etherDelta` transient storage is reset by every `_applyStateDeltas` call, so nested ETH accounting contexts are sequential, not nested. Each execution entry consumption is atomic with respect to ether accounting.

### G.3 Access Control Summary

| Function | Who can call |
|----------|-------------|
| `createRollup` | Anyone |
| `postBatch` | Anyone (proof verifies authorization) |
| `executeCrossChainCall` | Registered proxies only |
| `executeL2TX` | Anyone |
| `newScope` | `address(this)` only (self-call) |
| `createCrossChainProxy` | Anyone |
| `setStateByOwner` | Rollup owner |
| `setVerificationKey` | Rollup owner |
| `transferRollupOwnership` | Rollup owner |
| L2 `loadExecutionTable` | SYSTEM_ADDRESS |
| L2 `executeIncomingCrossChainCall` | SYSTEM_ADDRESS |
| L2 `executeCrossChainCall` | Registered proxies |
| L2 `newScope` | `address(this)` |
| L2 `createCrossChainProxy` | Anyone |

### G.4 State Root Mismatch Handling

On L1, `_findAndApplyExecution` silently skips entries whose state deltas don't match current on-chain state. Only entries that are both hash-consistent AND state-consistent are consumed. This means if the L2 state is different from what the builder expected (e.g., an earlier execution changed it), the entry is skipped and `ExecutionNotFound` is ultimately thrown.

The Rust node handles this by rewinding: on `ExecutionNotFound` or `StateRootMismatch`, the current block is abandoned and re-derived from a prior block.

### G.5 Proxy Auto-Creation

Both `_processCallAtScope` on L1 and L2 auto-create the source proxy if it doesn't exist before calling `executeOnBehalf`. This means the first cross-chain call from any (address, rollupId) pair automatically deploys the proxy. Proxy addresses are deterministic, so the builder can predict them before they are deployed.

### G.6 Execution Table Ordering

The `executions` array is an unordered set from a semantic standpoint. On L1, hash+state matching is the lookup key. On L2, hash-only. The swap-and-pop removal changes array ordering. The builder must not rely on table ordering for correctness.

**Hash collisions**: Multiple entries may share the same action hash (e.g., `result_void` for the same rollup). This is safe because entries are consumed in different execution contexts and the swap-and-pop guarantees that each consumption removes exactly one entry.

### G.7 `StateAlreadyUpdatedThisBlock` Guard

Only one `postBatch` can succeed per block on L1. This is a global mutex: the entire execution table is replaced atomically with each new batch. Builders must coordinate to ensure exactly one `postBatch` per block.

### G.8 Cross-Chain Proxy Identity

A CrossChainProxy represents exactly one (originalAddress, originalRollupId) pair. When a contract on chain A calls a proxy on chain B, the proxy forwards to B's manager with `sourceAddress = msg.sender` (the contract on chain A) and `sourceRollup = B's rollupId` (on L2) or `MAINNET_ROLLUP_ID` (on L1). The resulting CALL action's `sourceAddress` and `sourceRollup` form the caller's cross-chain identity.

---

*End of specification. This document covers the `feature/contract_updates` branch as of 2026-03-21. Audit corrections applied 2026-03-26.*
