# E2E Tests

End-to-end tests that deploy contracts and execute cross-chain flows against real RPC endpoints (anvil or live networks).

## Directory Structure

```
script/e2e/
├── shared/
│   ├── DeployInfra.s.sol     # Rollups (L1) + CrossChainManagerL2 (L2)
│   ├── E2EBase.sh            # Shared bash utilities
│   ├── Verify.s.sol          # Post-facto verification of block events
│   ├── prepare-network.sh    # One-time devnet preparation (CREATE2 + L2 funding)
│   ├── run-local.sh          # Generic local mode runner
│   └── run-network.sh        # Generic network mode runner
├── counter/                  # L1 trigger — simplest e2e, use as template
│   └── E2E.s.sol
├── counterL2/                # L2 trigger — reverse of counter (L2 calls L1)
│   └── E2E.s.sol
├── bridge/                   # Bridge ETH e2e (uses CREATE2)
│   └── E2E.s.sol
├── multi-call-twice/         # Multi-call: same proxy called twice
│   └── E2E.s.sol
├── multi-call-two-diff/      # Multi-call: two different proxies
│   └── E2E.s.sol
└── flash-loan/               # Multi-chain flash loan e2e
    └── E2E.s.sol
```

Each test has only `E2E.s.sol`. No per-test shell scripts.

## Two Modes

### Local Mode

Starts two anvils (L1 + L2), deploys infra + app, executes via Batcher, decodes events.

```bash
bash script/e2e/shared/run-local.sh script/e2e/counter/E2E.s.sol
bash script/e2e/shared/run-local.sh script/e2e/bridge/E2E.s.sol
bash script/e2e/shared/run-local.sh script/e2e/multi-call-twice/E2E.s.sol
bash script/e2e/shared/run-local.sh script/e2e/multi-call-two-diff/E2E.s.sol
bash script/e2e/shared/run-local.sh script/e2e/flash-loan/E2E.s.sol
```

Deploy contracts with "L2" in the name deploy to L2 RPC, others to L1. Order in the file matters (dependencies).

### Network Mode

Connects to an existing devnet with a running system/sequencer. Deploys app contracts, sends the user transaction via `cast send`, then verifies that the system posted the batch on L1 and executed cross-chain calls on L2.

**Step 1: Prepare the network** (once per devnet reset). Deploys CREATE2 factories and bridges ETH to the test account on L2. Idempotent.

```bash
bash script/e2e/shared/prepare-network.sh \
    --l1-rpc $L1_RPC --l2-rpc $L2_RPC --pk $PK --rollups $ROLLUPS
```

**Step 2: Run tests.**

```bash
# L1 trigger (counter, bridge, flash-loan, multi-call-*)
bash script/e2e/shared/run-network.sh script/e2e/counter/E2E.s.sol \
    --l1-rpc $L1_RPC --l2-rpc $L2_RPC --pk $PK \
    --rollups $ROLLUPS --manager-l2 $MANAGER_L2

# L2 trigger (counterL2)
bash script/e2e/shared/run-network.sh script/e2e/counterL2/E2E.s.sol \
    --l1-rpc $L1_RPC --l2-rpc $L2_RPC --pk $PK \
    --rollups $ROLLUPS --manager-l2 $MANAGER_L2
```

**How it works:**

1. Deploy app contracts on both chains (Deploy* contracts, auto-discovered)
2. Compute expected action hashes (ComputeExpected, read-only)
3. Send user tx via `cast send` — the tx would revert in forge's simulation (execution table not loaded yet), so we bypass forge and send directly. The system intercepts the tx from the mempool, constructs the matching batch, and inserts `postBatch` before the user tx in the same block.
4. Verify L1 batch (`BatchPosted` event) — search a block range for our entries
5. Extract L2 block numbers from the L1 postBatch callData (`extract_l2_blocks_from_tx` in E2EBase.sh)
6. Verify L2 table (`ExecutionTableLoaded` event) — confirm entries were loaded
7. Verify L2 calls (`IncomingCrossChainCallExecuted` event) — confirm calls were executed
8. Print summary with all tx hashes and block numbers

Trigger chain is auto-detected: `ExecuteNetworkL2` in the .sol -> L2 trigger, `ExecuteNetwork` -> L1 trigger.

On failure, prints diagnostics: actual vs expected execution tables.

## Shared Utilities

### E2EBase.sh

Source it: `source "$(dirname "$0")/E2EBase.sh"`

| Function | Purpose |
|----------|---------|
| `extract "$output" KEY` | Parse `KEY=value` from forge script output |
| `start_anvil PORT PID_VAR` | Start anvil, store PID for cleanup |
| `deploy_infra L1_RPC PK [L2_RPC] [L2_ROLLUP_ID] [SYSTEM_ADDR]` | Deploy Rollups + optional CCManagerL2. Sets `$ROLLUPS`, `$MANAGER_L2` |
| `deploy_contracts SOL L1_RPC L2_RPC PK` | Auto-discover and run Deploy* contracts in file order |
| `get_block_from_broadcast SOL_FILE RPC_URL` | Read block number from forge broadcast JSON receipt |
| `extract_l2_blocks_from_tx TX_HASH RPC_URL` | Decode L2 block numbers from postBatch callData |
| `decode_block RPC BLOCK TARGET [LABEL]` | Run DecodeExecutions on a block |
| `ensure_create2_factory RPC LABEL PK` | Deploy CREATE2 factory if missing |
| `trace_failed_txs "$FORGE_OUTPUT" RPC` | Trace any failed txs from forge output |
| `strip_traces` | Pipe filter: strips forge EVM traces, keeps only `console.log` output |
| `_export_outputs "$output"` | Auto-export `KEY=VALUE` lines from forge output as env vars |

### DeployInfra.s.sol

| Contract | Args | Deploys |
|----------|------|---------|
| `DeployRollupsL1` | (none) | MockZKVerifier + Rollups + creates rollup ID 1 |
| `DeployManagerL2` | `(uint256 rollupId, address systemAddress)` | CrossChainManagerL2 |

### Verify.s.sol

| Contract | Args | Verifies |
|----------|------|----------|
| `VerifyL1Batch` | `(uint256 block, address rollups, bytes32[] expectedHashes)` | `BatchPosted` events contain expected entries (subset match). Outputs `L1_BATCH_TX` |
| `VerifyL2Blocks` | `(uint256[] l2Blocks, address managerL2, bytes32[] expectedHashes)` | `ExecutionTableLoaded` events contain expected entries. Outputs `L2_TABLE_TX` |
| `VerifyL2Calls` | `(uint256[] l2Blocks, address managerL2, bytes32[] expectedCallHashes)` | `IncomingCrossChainCallExecuted` events match expected hashes. Outputs `L2_CALL_TX` |

All verify with **subset matching** — the block can contain additional entries and the test still passes. On failure, they print the full actual execution table before reverting.

## Standard Contract Names

Each `E2E.s.sol` has these contracts:

| Contract | Purpose | Used in |
|----------|---------|---------|
| **Batcher** | Wraps `postBatch` + user tx in a single call (same-block guarantee) | Local mode |
| **Deploy\*** | Deploys app contracts. Outputs `KEY=VALUE` via console.log. Use `try/catch` for `createCrossChainProxy` (idempotent on re-runs) | Both modes |
| **Execute** | Constructs `ExecutionEntry[]`, deploys Batcher, executes atomically on L1 | Local mode |
| **ExecuteL2** | Loads L2 execution table + executes user call on L2 | Local mode |
| **ExecuteNetwork** | Outputs `TARGET`, `VALUE`, `CALLDATA` for `cast send` (L1 trigger). `function run() external view` | Network mode |
| **ExecuteNetworkL2** | Same as ExecuteNetwork but for L2 trigger | Network mode |
| **ComputeExpected** | Outputs `EXPECTED_L1_HASHES`, `EXPECTED_L2_HASHES`, `EXPECTED_L2_CALL_HASHES` | Network mode |

`ExecuteNetwork`/`ExecuteNetworkL2` don't use `vm.startBroadcast()` — they output calldata for `cast send` because the tx would revert in forge's simulation (execution table not loaded yet). The system intercepts the tx from the mempool.

Env vars are set automatically: the generic scripts export `ROLLUPS`, `MANAGER_L2`, and all `KEY=VALUE` outputs from the Deploy step via `_export_outputs`.

### How an ExecutionEntry is Built

```solidity
// 1. Build the CALL action (must match what executeCrossChainCall builds on-chain)
Action memory callAction = Action({
    actionType: ActionType.CALL,
    rollupId: 1,                    // destination rollup
    destination: targetContract,     // contract on the other chain
    value: 0,
    data: abi.encodeWithSelector(MyContract.myFunction.selector),
    failed: false,
    sourceAddress: callerContract,   // msg.sender as seen by the proxy
    sourceRollup: 0,
    scope: new uint256[](0)
});

// 2. Build the next action
Action memory resultAction = Action({
    actionType: ActionType.RESULT,
    rollupId: 1, destination: address(0), value: 0,
    data: abi.encode(expectedReturnValue),
    failed: false, sourceAddress: address(0), sourceRollup: 0,
    scope: new uint256[](0)
});

// 3. State deltas (L1 only — L2 uses empty deltas)
StateDelta[] memory deltas = new StateDelta[](1);
deltas[0] = StateDelta({
    rollupId: 1,
    currentState: keccak256("state-before"),
    newState: keccak256("state-after"),
    etherDelta: 0
});

// 4. Assemble
ExecutionEntry[] memory entries = new ExecutionEntry[](1);
entries[0].stateDeltas = deltas;
entries[0].actionHash = keccak256(abi.encode(callAction));
entries[0].nextAction = resultAction;
```

### Batcher Pattern (local mode)

```solidity
contract Batcher {
    function execute(Rollups rollups, ExecutionEntry[] calldata entries, MyApp app) external {
        rollups.postBatch(entries, 0, "", "proof");
        app.doSomething();
    }
}
```

Both calls in a single transaction — satisfies same-block requirement.

## Adding a New E2E Test

Use `counter/E2E.s.sol` as template (L1 trigger) or `counterL2/E2E.s.sol` (L2 trigger).

### 1. Create directory + `E2E.s.sol`

```bash
mkdir script/e2e/my-app
```

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";

contract Batcher {
    function execute(Rollups rollups, ExecutionEntry[] calldata entries, MyApp app) external {
        rollups.postBatch(entries, 0, "", "proof");
        app.doAction();
    }
}

/// @dev Env: ROLLUPS. Outputs: MY_CONTRACT
/// Use try/catch for createCrossChainProxy (idempotent on re-runs)
contract Deploy is Script {
    function run() external {
        address rollups = vm.envAddress("ROLLUPS");
        vm.startBroadcast();
        // deploy contracts, create proxies with try/catch...
        console.log("MY_CONTRACT=%s", address(myContract));
        vm.stopBroadcast();
    }
}

/// @dev Env: ROLLUPS, MY_CONTRACT
contract Execute is Script {
    function run() external {
        vm.startBroadcast();
        Batcher batcher = new Batcher();
        // build entries...
        batcher.execute(Rollups(rollups), entries, MyApp(myContract));
        vm.stopBroadcast();
    }
}

/// @dev Env: MY_CONTRACT
/// Outputs TARGET, VALUE, CALLDATA for cast send (no vm.startBroadcast).
/// The tx reverts in forge simulation — the system intercepts it from the mempool.
contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("MY_CONTRACT");
        bytes memory data = abi.encodeWithSelector(MyApp.doAction.selector);
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

/// @dev Env: MY_CONTRACT
/// Must output all three hash sets: L1 batch, L2 table, L2 calls.
contract ComputeExpected is Script {
    function run() external view {
        // build CALL action + RESULT action...
        bytes32 l1Hash = keccak256(abi.encode(callAction));
        bytes32 l2Hash = keccak256(abi.encode(resultAction));
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(l1Hash));
        // human-readable table...
    }
}
```

### 2. Run it

```bash
# Local mode
bash script/e2e/shared/run-local.sh script/e2e/my-app/E2E.s.sol

# Network mode
bash script/e2e/shared/run-network.sh script/e2e/my-app/E2E.s.sol \
    --l1-rpc $L1_RPC --l2-rpc $L2_RPC --pk $PK \
    --rollups $ROLLUPS --manager-l2 $MANAGER_L2
```

No shell scripts to write — the generic runners handle everything.

## Key Invariants

- **Same-block execution**: `postBatch`/`loadExecutionTable` and the consuming transaction must be in the same block. Local mode enforces via Batcher; network mode relies on the system.
- **actionHash matching**: `actionHash` must equal `keccak256(abi.encode(callAction))` where `callAction` matches what `executeCrossChainCall` builds on-chain.
- **State delta chaining**: `newState` of entry N must equal `currentState` of entry N+1 when both touch the same rollup.
- **L2 entries have no state deltas**: On L2, `stateDeltas` is always empty. Only L1 tracks state roots.
- **Three verification hash sets**: Every test must output `EXPECTED_L1_HASHES` (L1 batch), `EXPECTED_L2_HASHES` (L2 table), and `EXPECTED_L2_CALL_HASHES` (L2 calls) in `ComputeExpected`.
