# Smart Contract TODOs

## 1. Failed nested actions block execution

### Problem

If a reentrant call (one that triggers `_consumeNestedAction`) reverts, the EVM rolls back all state changes in that sub-context — including the `_lastNestedActionConsumed++` increment (transient storage follows revert rules). The nested action is never consumed, so the entry-level verification `_lastNestedActionConsumed == entry.nestedActions.length` fails with `UnconsumedNestedActions`.

The current workaround is documented: "All nested actions must succeed. Failed calls should use StaticCall instead." But this pushes complexity to the off-chain precomputation, which must predict failures and route them through the static call path.

### Scenario

```
_processNCalls: executes call c0 via proxy
  → destination calls back into proxy (reentrant)
  → executeCrossChainCall → _consumeNestedAction
    → _lastNestedActionConsumed++ (now 1)
    → _processNCalls(nested.callCount) — processes nested calls
    → one of the nested calls reverts, propagating up
  → revert rolls back _lastNestedActionConsumed to 0
proxy call returns (success=false, revertData)
CALL_END hashes the failure — but nested action was NOT consumed
→ verification fails: _lastNestedActionConsumed (0) != nestedActions.length (1)
```

### Possible solutions

**A. Wrap failing calls in revertSpan (current design, off-chain)**

If the off-chain precomputation knows a call will trigger a failed reentrant call, it can wrap that call in a `revertSpan`. The `ContextResult` carries `_lastNestedActionConsumed` out of the revert context, preserving consumption state. Downside: requires off-chain prediction of which calls will fail.

**B. Add `failed` flag to NestedAction**

```solidity
struct NestedAction {
    bytes32 actionHash;
    uint256 callCount;
    bytes returnData;
    bool failed;        // if true, skip call processing
}
```

When `failed == true`, `_consumeNestedAction` would skip `_processNCalls` and hash a failure marker into the rolling hash instead. The nested action is consumed (index advances) without executing calls. The outer proxy call would still fail (the reentrant call reverts), but the consumption would have already happened before the revert propagates.

Problem: the consumption happens INSIDE the sub-context that reverts, so `_lastNestedActionConsumed++` is still rolled back. This doesn't actually solve the fundamental issue.

**C. Pre-consume before the proxy call**

Move nested action consumption to happen BEFORE the proxy call, not during it. The manager would know (from the execution entry metadata) that call N triggers nested action M, and pre-consume it:

```
for each call:
  if this call triggers a nested action:
    pre-consume nested action (advance index, hash NESTED_BEGIN/END)
  execute the call via proxy
  hash CALL_END
```

This requires a new field on `CrossChainCall` (e.g., `bool triggersNestedAction`) or a mapping from call index to nested action index. The nested action's calls would still need processing, but the consumption index advances in the outer context (not rolled back by inner revert).

Downside: changes the execution model significantly. The reentrant `executeCrossChainCall` would no longer consume nested actions — the outer loop would handle it. This breaks the current model where the destination contract's callback triggers consumption.

**D. Treat reentrant-call-that-reverts as a special revertSpan automatically**

When `_consumeNestedAction` is about to process a nested action marked as `failed`, it wraps the execution in a self-call (like `executeInContext`), carrying `_lastNestedActionConsumed` through `ContextResult`. This way the consumption survives the revert.

```solidity
if (nested.failed) {
    // self-call to isolate the revert
    try this.executeFailedNestedAction(actionHash) {}
    catch (bytes memory revertData) {
        // restore _lastNestedActionConsumed from ContextResult
    }
    return nested.returnData;
}
```

Downside: adds another self-call pattern and complexity.

**E. Accept current design — document the constraint**

The current design works correctly: the off-chain precomputation routes all potentially-failing reentrant calls through `StaticCall` lookup or wraps them in `revertSpan`. This keeps the on-chain logic simple. The constraint "nested actions must succeed" is a valid design choice that trades off-chain flexibility for on-chain simplicity.

---

## 2. `L2TXExecuted` event declared but never emitted

`Rollups.sol` declares `event L2TXExecuted(uint256 indexed entryIndex)` but `executeL2TX()` never emits it. Either emit it in `executeL2TX` or remove the declaration.

---

## 3. `staticCalls` lookup is O(n) linear scan

`staticCallLookup` iterates over the entire `staticCalls[]` array to find a match. For entries with many static calls this could be gas-expensive. Consider:
- A mapping from `keccak256(actionHash, callNumber, lastNestedActionConsumed)` to index
- Keeping the array sorted and using binary search
- Requiring static calls to be ordered so sequential lookup works

---

## 4. No `depositEther` function

The ether accounting system tracks `rollups[rollupId].etherBalance` and enforces non-negative balances, but there's no way to deposit ETH into a rollup's balance outside of state deltas in `postBatch`. Consider adding:

```solidity
function depositEther(uint256 rollupId) external payable {
    rollups[rollupId].etherBalance += msg.value;
}
```

---

## 5. No mechanism to clear a stuck execution table

If entries are posted via `postBatch` but cannot be consumed in the same block (e.g., a bug in off-chain construction), the execution table is stuck until the next `postBatch` overwrites it. Consider whether a cleanup mechanism is needed, or if the one-block lifecycle is sufficient.

---

## 6. Action struct unused on-chain

The `Action` struct in `ICrossChainManager.sol` is declared but never used by any contract function. It exists only for off-chain tooling to compute `actionHash`. Consider moving it to a separate file or adding a comment clarifying its off-chain-only purpose.
