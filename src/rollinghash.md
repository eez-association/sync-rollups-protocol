# Rolling Hash Specification

## Overview

Every `ExecutionEntry` contains a `rollingHash` field. This single hash covers **all** call results **and** nesting structure for the entire entry, including nested actions at any depth. It is verified once at the entry level after all calls complete:

```
require(_rollingHash == entry.rollingHash)
```

This single check transitively verifies:
- Every call result (success/failure + return data) at every level
- The exact nesting structure (which calls belong to which nested action)
- The order of all operations

---

## The 4 Tag Constants

```solidity
uint8 internal constant CALL_BEGIN = 1;
uint8 internal constant CALL_END = 2;
uint8 internal constant NESTED_BEGIN = 3;
uint8 internal constant NESTED_END = 4;
```

---

## Transient Variable Roles

| Variable | Type | Role in Hash Computation |
|---|---|---|
| `_rollingHash` | bytes32 | The accumulator. Initialized to `bytes32(0)` at entry start. Updated at every tagged event. |
| `_currentCallNumber` | uint256 | 1-indexed global call counter. Incremented before each call executes. Used in `CALL_BEGIN` and `CALL_END` hashes. Also doubles as the `_insideExecution()` check (`!= 0`). |
| `_lastNestedActionConsumed` | uint256 | Sequential nested action consumption counter. Used to compute the 1-indexed `nestedNumber` for `NESTED_BEGIN` and `NESTED_END` hashes. Also used by `staticCallLookup` to disambiguate phases. |
| `_currentEntryIndex` | uint256 | Identifies the active entry in `executions[]`. Not directly hashed, but determines which `calls[]` and `nestedActions[]` arrays are read from storage. |

---

## Hash Formulas

### CALL_BEGIN

Hashed **before** a call executes, after incrementing `_currentCallNumber`:

```
_rollingHash = keccak256(abi.encodePacked(
    _rollingHash,       // bytes32
    CALL_BEGIN,         // uint8(1)
    _currentCallNumber  // uint256 (1-indexed)
))
```

### CALL_END

Hashed **after** a call completes:

```
_rollingHash = keccak256(abi.encodePacked(
    _rollingHash,       // bytes32
    CALL_END,           // uint8(2)
    _currentCallNumber, // uint256 (same as CALL_BEGIN)
    success,            // bool
    retData             // bytes
))
```

### NESTED_BEGIN

Hashed when `_consumeNestedAction` is called, **before** processing the nested action's calls:

```
nestedNumber = _lastNestedActionConsumed  // already incremented, so this is 1-indexed
_rollingHash = keccak256(abi.encodePacked(
    _rollingHash,       // bytes32
    NESTED_BEGIN,       // uint8(3)
    nestedNumber        // uint256 (1-indexed)
))
```

### NESTED_END

Hashed **after** the nested action's calls complete:

```
_rollingHash = keccak256(abi.encodePacked(
    _rollingHash,       // bytes32
    NESTED_END,         // uint8(4)
    nestedNumber        // uint256 (same as NESTED_BEGIN)
))
```

---

## Revert Span Handling

Revert spans use `executeInContext` (a self-call that always reverts) to isolate state changes while preserving execution progress through the `ContextResult` error.

### ContextResult Error

```solidity
error ContextResult(
    bytes32 rollingHash,
    uint256 lastNestedActionConsumed,
    uint256 currentCallNumber
);
```

Three values are carried out of the reverted context:

- `rollingHash` -- the accumulated hash including all calls inside the revert context
- `lastNestedActionConsumed` -- how far the nested action index advanced inside the context
- `currentCallNumber` -- the global call counter after the context's calls

### Mechanism

```
// Before self-call: _rollingHash = H, _currentCallNumber = N, _lastNestedActionConsumed = M
//
// 1. Clear revertSpan in storage so inner sees normal call:
//    entry.calls[_currentCallNumber].revertSpan = 0
//
// 2. Self-call: this.executeInContext(revertSpan)
//    Inside the self-call (same transient storage via tload):
//      _processNCalls(revertSpan) -- advances _currentCallNumber, _lastNestedActionConsumed, _rollingHash
//      revert ContextResult(_rollingHash, _lastNestedActionConsumed, _currentCallNumber)
//
// 3. Revert rolls back ALL transient storage to pre-self-call values:
//    _rollingHash = H, _currentCallNumber = N, _lastNestedActionConsumed = M
//
// 4. Catch: decode ContextResult -> (H', M', N')
//    _rollingHash = H'
//    _lastNestedActionConsumed = M'
//    _currentCallNumber = N'
//
// 5. Restore revertSpan in storage:
//    entry.calls[savedCallNumber].revertSpan = revertSpan
```

### Why This Works

1. `tload` works inside a reverting self-call -- transient variables are readable.
2. The self-call shares the same transient storage, so `_rollingHash` starts from the current accumulated value.
3. The `revert` rolls back all state changes (including transient storage writes), but the `ContextResult` payload escapes via the revert data.
4. The caller extracts all three values and restores them, bridging the gap across the revert boundary.
5. Storage changes (clearing/restoring `revertSpan`) are handled by the caller, outside the self-call.

---

## Static Call Disambiguation

Static calls (read-only calls or calls whose revert needs to be replayed) are looked up from the `staticCalls[]` table, not executed.

### Identification Key

A static call is matched by:

```
(actionHash, callNumber, lastNestedActionConsumed)
```

Where:
- `actionHash` -- identifies what call is being made
- `callNumber` -- `uint64(_currentCallNumber)` -- the 1-indexed global call number
- `lastNestedActionConsumed` -- `uint64(_lastNestedActionConsumed)` -- the consumption counter

These two counters together identify a unique "phase" of execution:

- `callNumber` increases monotonically with each call processed
- `lastNestedActionConsumed` increases monotonically with each nested action consumed
- Together they form a coordinate that advances forward and never repeats

### Multiple Phases Within One Call

A single call can have multiple "phases" separated by nested action consumptions:

```
Call #1 executes:
  STATICCALL -> matched by (actionHash, callNum=1, lastNA=0)
  triggers nested action #1 -> _lastNestedActionConsumed becomes 1
  STATICCALL -> matched by (actionHash, callNum=1, lastNA=1)  <- different phase
```

Note: `_currentCallNumber` may also advance during the nested action's inner calls, so the actual `callNum` for the second STATICCALL depends on whether the nested action had calls.

---

## Worked Hash Chain Example

### Setup

```
entry.calls = [c0, c1, c2, c3, c4]    callCount = 3
entry.nestedActions = [{actionHash=H_nested, callCount=2, returnData=0xaa}]
entry.rollingHash = <expected final hash>
```

The entry has 5 calls in the flat array. Entry-level processes 3 iterations: c0, c3, c4. But c0 triggers a reentrant call that consumes nestedActions[0], which processes c1 and c2.

### Step-by-step

```
_rollingHash = 0x0
_currentCallNumber = 0
_lastNestedActionConsumed = 0

--- Entry-level _processNCalls(3), iteration 0 ---

Read entry.calls[0] = c0
_currentCallNumber++ -> 1
hash(CALL_BEGIN, 1):
  _rollingHash = keccak256(0x0, uint8(1), uint256(1))           -> H1

Execute c0 via proxy. During execution, destination calls back:
  executeCrossChainCall -> _insideExecution() == true (callNum=1 != 0)
  _consumeNestedAction(H_nested):
    idx = _lastNestedActionConsumed++ -> idx=0, counter becomes 1
    nestedActions[0].actionHash == H_nested  -> OK
    nestedNumber = 0 + 1 = 1

    hash(NESTED_BEGIN, 1):
      _rollingHash = keccak256(H1, uint8(3), uint256(1))        -> H2

    _processNCalls(2):  // nested action's callCount

      Read entry.calls[1] = c1
      _currentCallNumber++ -> 2
      hash(CALL_BEGIN, 2):
        _rollingHash = keccak256(H2, uint8(1), uint256(2))      -> H3
      Execute c1 via proxy. Succeeds with retData_1.
      hash(CALL_END, 2):
        _rollingHash = keccak256(H3, uint8(2), uint256(2), true, retData_1)  -> H4

      Read entry.calls[2] = c2
      _currentCallNumber++ -> 3
      hash(CALL_BEGIN, 3):
        _rollingHash = keccak256(H4, uint8(1), uint256(3))      -> H5
      Execute c2 via proxy. Succeeds with retData_2.
      hash(CALL_END, 3):
        _rollingHash = keccak256(H5, uint8(2), uint256(3), true, retData_2)  -> H6

    hash(NESTED_END, 1):
      _rollingHash = keccak256(H6, uint8(4), uint256(1))        -> H7

    return nestedActions[0].returnData (0xaa)

c0's proxy call returns (destination got 0xaa from the nested action).
Proxy call for c0 succeeds with retData_0.
hash(CALL_END, 1):
  _rollingHash = keccak256(H7, uint8(2), uint256(1), true, retData_0)  -> H8

--- Entry-level _processNCalls(3), iteration 1 ---

Read entry.calls[3] = c3
_currentCallNumber++ -> 4
hash(CALL_BEGIN, 4):
  _rollingHash = keccak256(H8, uint8(1), uint256(4))            -> H9
Execute c3 via proxy. Succeeds with retData_3.
hash(CALL_END, 4):
  _rollingHash = keccak256(H9, uint8(2), uint256(4), true, retData_3)  -> H10

--- Entry-level _processNCalls(3), iteration 2 ---

Read entry.calls[4] = c4
_currentCallNumber++ -> 5
hash(CALL_BEGIN, 5):
  _rollingHash = keccak256(H10, uint8(1), uint256(5))           -> H11
Execute c4 via proxy. Succeeds with retData_4.
hash(CALL_END, 5):
  _rollingHash = keccak256(H11, uint8(2), uint256(5), true, retData_4)  -> H12

--- Verification ---

_rollingHash (H12) == entry.rollingHash                          -> pass
_currentCallNumber (5) == entry.calls.length (5)                 -> pass
_lastNestedActionConsumed (1) == entry.nestedActions.length (1)  -> pass

_currentCallNumber = 0   // reset so _insideExecution() returns false
```

### Hash Chain Summary

```
H0  = 0x0
H1  = hash(H0,  CALL_BEGIN,  callNum=1)
H2  = hash(H1,  NESTED_BEGIN, nestedNum=1)
H3  = hash(H2,  CALL_BEGIN,  callNum=2)
H4  = hash(H3,  CALL_END,   callNum=2, true, retData_1)
H5  = hash(H4,  CALL_BEGIN,  callNum=3)
H6  = hash(H5,  CALL_END,   callNum=3, true, retData_2)
H7  = hash(H6,  NESTED_END,  nestedNum=1)
H8  = hash(H7,  CALL_END,   callNum=1, true, retData_0)
H9  = hash(H8,  CALL_BEGIN,  callNum=4)
H10 = hash(H9,  CALL_END,   callNum=4, true, retData_3)
H11 = hash(H10, CALL_BEGIN,  callNum=5)
H12 = hash(H11, CALL_END,   callNum=5, true, retData_4)

Verify: H12 == entry.rollingHash
```

---

## Verification Summary

After execution completes for an entry, the following checks are performed:

| Check | L1 | L2 | Error on Failure |
|---|---|---|---|
| `_rollingHash == entry.rollingHash` | Yes | Yes | `RollingHashMismatch` |
| `_currentCallNumber == entry.calls.length` | Yes | Yes | `UnconsumedCalls` |
| `_lastNestedActionConsumed == entry.nestedActions.length` | Yes | Yes | `UnconsumedNestedActions` |
| `totalEtherDelta == etherIn - etherOut` | Yes | No | `EtherDeltaMismatch` |
| Rollup balance non-negative | Yes | No | `InsufficientRollupBalance` |

The rolling hash verification is the primary integrity check. Because it chains every call result and every nesting boundary with unique tags, a single mismatch at any point in the execution tree causes the final hash to differ, catching:

- Wrong call results (different return data or success/failure)
- Wrong nesting structure (nested action at wrong position)
- Missing or extra calls
- Reordered operations
- Incorrect call numbering
