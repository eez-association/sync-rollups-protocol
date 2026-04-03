# E2E Test File Structure

Every E2E test must produce entries that conform to `docs/EXECUTION_TABLE_SPEC.md`. The spec is the single source of truth — if this file and the spec disagree, the spec wins.

## Directory Layout

Each test is a single `E2E.s.sol` file in `script/e2e/<test-name>/`. No per-test shell scripts — the generic runners handle everything.

## Required Contracts (in order)

### 1. Actions Base (abstract)

Single source of truth for all action definitions and entry construction. Used by Execute, ExecuteL2, and ComputeExpected — never duplicate entry logic across contracts.

```solidity
abstract contract <TestName>Actions {
    uint256 internal constant L2_ROLLUP_ID = 1;
    uint256 internal constant MAINNET_ROLLUP_ID = 0;

    // Action builders — one per unique action
    function _callToX(...) internal pure returns (Action memory) { ... }
    function _resultFromX() internal pure returns (Action memory) { ... }

    // Entry builders
    function _l1Entries(...) internal pure returns (ExecutionEntry[] memory) { ... }
    function _l2Entries(...) internal pure returns (ExecutionEntry[] memory) { ... }
}
```

For L2-starting tests, extend `L2TXActionsBase` instead of plain abstract:
```solidity
abstract contract <TestName>Actions is L2TXActionsBase { ... }
```

`L2TXActionsBase` provides `_buildRlpEncodedTx()` and related helpers for constructing the L2TX action's RLP data.

### 2. Batcher (L1-starting only)

Wraps `postBatch` + user call in a single tx for local mode. This guarantees same-block execution.

```solidity
contract Batcher {
    function execute(
        Rollups rollups, ExecutionEntry[] calldata entries, ...app params...
    ) external returns (...) {
        rollups.postBatch(entries, 0, "", "proof");
        return app.doSomething(...);
    }
}
```

For L2-starting tests, use `L2TXBatcher` from `shared/E2EHelpers.sol` instead — it handles `postBatch` + `executeL2TX` in one tx.

### 3. Deploy Contracts

Deploy order matters — later deploys depend on earlier outputs.

**L1-starting pattern:**
1. `Deploy` (L1): Deploy app contracts on L1. Output env vars.
2. `DeployL2` (L2): Deploy app contracts + create L1 proxies on L2. Output env vars.
3. `Deploy2` (L1): Create L2 proxies on L1. Output env vars.

**L2-starting pattern:**
1. `DeployL2` (L2): Deploy app contracts on L2. Output env vars.
2. `Deploy` (L1): Deploy app contracts + create L2 proxies on L1. Output env vars.
3. `Deploy2L2` (L2): Create L1 proxies on L2. Output env vars.

Each Deploy contract:
- Reads env vars for dependencies: `vm.envAddress("NAME")`
- Uses `vm.startBroadcast()` / `vm.stopBroadcast()`
- Outputs vars via `console.log("NAME=%s", address(thing))`
- Uses `getOrCreateProxy(manager, addr, rollupId)` from E2EHelpers.sol for idempotent proxy creation

The generic runners (`run-local.sh`, `run-network.sh`) auto-discover Deploy contracts by name and run them in file order. Contracts with "L2" in the name deploy to L2 RPC, others to L1.

### 4. ExecuteL2 (local mode L2)

**L1-starting:** Loads L2 table + calls `executeIncomingCrossChainCall(...)`.
- Only ONE `executeIncomingCrossChainCall` call — chaining handles subsequent calls. This is because `executeIncomingCrossChainCall` enters `_resolveScopes` without consuming from the table, and the table's RESULT→CALL chaining drives all subsequent operations.
- Parameters: `(destination, value, data, sourceAddress, sourceRollup, scope=[])`

**L2-starting:** Loads L2 table + user calls the app contract directly.
- The user's call triggers `executeCrossChainCall` via proxy fallbacks.

### 5. Execute (local mode L1)

**L1-starting:** Creates Batcher, predicts its address for sourceAddr, calls batcher.execute().
- Predict via `vm.computeCreateAddress(msg.sender, vm.getNonce(msg.sender))`
- The predicted address is needed because the Batcher becomes `msg.sender` for the user call, which means it's the `sourceAddress` in the CALL action.

**L2-starting:** Creates L2TXBatcher, calls `batcher.execute(rollups, entries, rollupId, rlpTx)`.
- rlpTx comes from `vm.envBytes("RLP_ENCODED_TX")`

### 6. ExecuteNetwork / ExecuteNetworkL2 (network mode)

View-only contract that outputs TARGET, VALUE, CALLDATA for `cast send`. No `vm.startBroadcast()`.

**L1-starting:** `ExecuteNetwork` — user tx goes to L1.
**L2-starting:** `ExecuteNetworkL2` — user tx goes to L2. The presence of this contract name triggers L2-starting flow in the runner.

```solidity
contract ExecuteNetwork is Script {
    function run() external view {
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}
```

The tx would revert in forge's simulation (execution table not loaded yet), so we bypass forge and send via `cast send` directly. The system intercepts the tx from the mempool, constructs the matching batch, and inserts `postBatch`/`loadExecutionTable` before the user tx in the same block.

### 7. ComputeExpected

Computes and logs expected entry hashes for verification.

Must output exactly 3 lines:
```
EXPECTED_L1_HASHES=[hash1,hash2,...]
EXPECTED_L2_HASHES=[hash1,hash2,...]
EXPECTED_L2_CALL_HASHES=[hash1,...]
```

**Entry hash formula:** `keccak256(abi.encode(actionHash, keccak256(abi.encode(nextAction))))`

**L2 call hash** = the actionHash of the CALL built by `executeIncomingCrossChainCall` (L1-starting) or `executeCrossChainCall` (L2-starting). `EXPECTED_L2_CALL_HASHES` always has exactly **1 entry** — the initial cross-chain call. All subsequent calls are chained internally within that single execution tx.

Inherits `ComputeExpectedBase` for formatting helpers:
- `_entryHash(actionHash, nextAction)` — compute entry hash
- `_logEntry(idx, hash, deltas, triggerDesc, responseDesc)` — log L1 entry
- `_logL2Entry(idx, hash, triggerDesc, responseDesc)` — log L2 entry
- `_logL2Call(idx, hash, action)` — log L2 call
- `_fmtCall(action)` / `_fmtResult(action, dataDesc)` / `_fmtL2TX(action)` — format actions

Override `_name(address)` and `_funcName(bytes4)` for human-readable output in logs.

## Import Conventions

```solidity
import {Script, console} from "forge-std/Script.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {Counter, CounterAndProxy} from "../../../test/mocks/CounterContracts.sol";
import {getOrCreateProxy} from "../shared/E2EHelpers.sol";
// For L2-starting:
import {L2TXBatcher, L2TXActionsBase, getOrCreateProxy} from "../shared/E2EHelpers.sol";
```

## Environment Variable Naming

Use SCREAMING_SNAKE_CASE. Common patterns:
- `ROLLUPS` / `MANAGER_L2` — infrastructure addresses
- `COUNTER_L1` / `COUNTER_L2` — app contract addresses
- `COUNTER_AND_PROXY` / `COUNTER_AND_PROXY_L2` — compound contracts
- `*_PROXY_L1` / `*_PROXY_L2` — proxy addresses
- `ALICE` — user/caller address
- `RLP_ENCODED_TX` — for L2-starting tests

## Verification (network mode)

The generic runner uses `Verify.s.sol` contracts for post-facto verification:

| Contract | Verifies |
|----------|----------|
| `VerifyL1Batch` | `BatchPosted` events contain expected entries (subset match) |
| `VerifyL2Blocks` | `ExecutionTableLoaded` events contain expected entries |
| `VerifyL2Calls` | `IncomingCrossChainCallExecuted` events match expected hashes |

All use **subset matching** — the block can contain additional entries and the test still passes. On failure, they print the full actual execution table before reverting.

## Common Pitfalls

### Spec violations that cause `ExecutionNotFound`

These are the most common bugs — the entry exists but can't be found at runtime:

1. **Hash mismatch from wrong field**: Every field matters in `keccak256(abi.encode(action))`. A single wrong byte in `data`, `sourceAddress`, `rollupId`, or `scope` means the hash diverges. Double-check every field against the spec's action type reference.

2. **Broken state delta chain**: `currentState[N+1]` doesn't match `newState[N]`. The `_findAndApplyExecution` function checks `currentState` against the on-chain rollup state. If the chain is broken, the entry won't match even though the actionHash is correct.

3. **Wrong scope on nested calls**: The sending chain uses `scope=[]`, the receiving chain uses `scope=[0]` or deeper. Using `[0]` on the wrong side produces a different hash.

4. **sourceAddress is the proxy, not the contract**: `sourceAddress` is what the manager sees as `msg.sender` — the proxy's address on the calling chain. Not the original contract address.

### Structural bugs

5. **Multiple `executeIncomingCrossChainCall` calls**: For L1-starting multicalls, only ONE call to `executeIncomingCrossChainCall`. Chaining via RESULT→CALL handles the rest. Making multiple calls means the system would need multiple L2 txs, violating the 1-tx-per-chain rule.

6. **Missing terminal entry**: Every chain's execution must end with a RESULT nextAction. Without it, the last RESULT has no matching entry and execution reverts with `ExecutionNotFound`.

7. **L2 entries with state deltas**: L2 has no state tracking. Always `new StateDelta[](0)`.

8. **Wrong deploy order**: L1-starting: Deploy(L1) → DeployL2(L2) → Deploy2(L1). L2-starting: DeployL2(L2) → Deploy(L1) → Deploy2L2(L2). Getting this wrong means contracts reference undeployed addresses.

### Semantic bugs (test passes but is wrong)

9. **Terminal RESULT with inner data instead of outer**: In nested flows, the terminal must carry the outer call's return data, not the inner call's. If the outer call is void, terminal data is `""`. Getting this wrong means the caller receives incorrect return data.

10. **etherDelta doesn't sum to zero**: Immediate entries' ether deltas must net to zero within a batch. The contract verifies this.

11. **System address as sourceAddress on L1**: The system address should only appear on L2. On L1, cross-chain calls come from users or contracts. If you see it on L1, the sourceAddress field is wrong.
