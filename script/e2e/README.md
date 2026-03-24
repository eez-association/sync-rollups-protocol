# E2E Tests

End-to-end tests that deploy contracts and execute cross-chain flows against real RPC endpoints (anvil or live networks).

## Directory Structure

```
script/e2e/
├── shared/
│   ├── DeployInfra.s.sol     # Rollups (L1) + CrossChainManagerL2 (L2)
│   ├── E2EBase.sh            # Shared bash utilities
│   └── Verify.s.sol          # Post-facto verification of block events
├── counter/                  # Simplest e2e — use as template
│   ├── CounterE2E.s.sol
│   ├── run-local.sh
│   └── run-network.sh
├── bridge/                   # Bridge ETH e2e (uses CREATE2)
│   ├── BridgeE2E.s.sol
│   ├── run-local.sh
│   └── run-network.sh
└── flash-loan/               # Multi-chain flash loan e2e
    ├── DeployFlashLoan.s.sol
    ├── ExecuteFlashLoan.s.sol
    ├── deploy-app.sh
    ├── run-local.sh
    └── run-network.sh
```

## Two Modes

### Local Mode (`run-local.sh`)

Deploys everything on local anvil. Uses a **Batcher** contract to ensure `postBatch` + user transaction land in the same block (required by the `ExecutionNotInCurrentBlock` invariant).

```
Start anvil → Deploy infra → Deploy app → Execute via Batcher → Decode events
```

Run from project root:
```bash
bash script/e2e/counter/run-local.sh
bash script/e2e/bridge/run-local.sh
bash script/e2e/flash-loan/run-local.sh
```

### Network Mode (`run-network.sh`)

Connects to an existing network where Rollups (and optionally CrossChainManagerL2) are already deployed. Deploys only the app contracts, sends the user transaction, then verifies post-facto that the system posted the expected entries in the same block.

**No Batcher needed** — the system/sequencer handles batch posting atomically.

```
Deploy app → Compute expected entries → Execute user tx → Verify block events
```

The user transaction may revert if run against a network without a system (e.g. plain anvil) — this is expected and reported clearly. The verify step then checks whether the system posted the batch.

On verify failure, prints both:
- **Actual execution table** — entries found in the block
- **Expected execution table** — entries the test expected to find

```bash
bash script/e2e/counter/run-network.sh --rpc $RPC --pk $PK --rollups $ROLLUPS
bash script/e2e/bridge/run-network.sh  --rpc $RPC --pk $PK --rollups $ROLLUPS
bash script/e2e/flash-loan/run-network.sh \
    --l1-rpc $L1_RPC --l2-rpc $L2_RPC --pk $PK \
    --rollups $ROLLUPS --manager-l2 $MANAGER_L2 --l2-rollup-id 1
```

## Shared Utilities

### E2EBase.sh

Source it in your shell scripts: `source "$(dirname "$0")/../shared/E2EBase.sh"`

| Function | Purpose |
|----------|---------|
| `extract "$output" KEY` | Parse `KEY=value` from forge script output |
| `start_anvil PORT PID_VAR` | Start anvil, store PID for cleanup |
| `deploy_infra L1_RPC PK [L2_RPC] [L2_ROLLUP_ID] [SYSTEM_ADDR]` | Deploy Rollups on L1 + optional CCManagerL2 on L2. Sets `$ROLLUPS` and `$MANAGER_L2` |
| `decode_block RPC BLOCK TARGET [LABEL]` | Run DecodeExecutions on a block |
| `ensure_create2_factory RPC LABEL PK` | Deploy CREATE2 factory if missing |
| `strip_traces` | Pipe filter: strips forge EVM traces, keeps only `console.log` output |

### DeployInfra.s.sol

| Contract | Args | Deploys |
|----------|------|---------|
| `DeployRollupsL1` | (none) | MockZKVerifier + Rollups + creates rollup ID 1 |
| `DeployManagerL2` | `(uint256 rollupId, address systemAddress)` | CrossChainManagerL2 |

### Verify.s.sol

| Contract | Args | Checks |
|----------|------|--------|
| `VerifyL1Batch` | `(uint256 block, address rollups, bytes32[] expectedHashes)` | `BatchPosted` events contain expected entries (subset match) |
| `VerifyL2Table` | `(uint256 block, address managerL2, bytes32[] expectedHashes)` | `ExecutionTableLoaded` events contain expected entries (subset match) |

Both verify with **subset matching** — the block can contain additional entries from other users and the test still passes. On failure, they print the full actual execution table before reverting.

## Anatomy of an E2E Test

Each e2e test has one `.s.sol` file with these contracts:

| Contract | Purpose | Used in |
|----------|---------|---------|
| **Batcher** | Wraps `postBatch` + user tx in a single call (same-block guarantee) | Local mode only |
| **Deploy** | Deploys app contracts, takes Rollups address as arg | Both modes |
| **Execute** | Constructs `ExecutionEntry[]`, deploys Batcher, executes atomically | Local mode only |
| **ExecuteNetwork** | Sends only the user transaction (no Batcher) | Network mode only |
| **ComputeExpected** | Computes expected actionHashes + prints expected entries table | Network mode only |

### How an ExecutionEntry is Built

```solidity
// 1. Build the CALL action (what executeCrossChainCall will construct on-chain)
Action memory callAction = Action({
    actionType: ActionType.CALL,
    rollupId: 1,                    // destination rollup
    destination: targetContract,     // contract being called on the other chain
    value: 0,                       // ETH value
    data: abi.encodeWithSelector(...), // calldata
    failed: false,
    sourceAddress: callerContract,   // msg.sender as seen by the proxy
    sourceRollup: 0,                // caller's rollup
    scope: new uint256[](0)         // [] for root scope
});

// 2. Build the next action (what happens after the CALL is consumed)
Action memory resultAction = Action({
    actionType: ActionType.RESULT,
    rollupId: 1,
    destination: address(0),
    value: 0,
    data: abi.encode(expectedReturnValue),
    failed: false,
    sourceAddress: address(0),
    sourceRollup: 0,
    scope: new uint256[](0)
});

// 3. Build state deltas (L1 only — L2 uses empty deltas)
StateDelta[] memory deltas = new StateDelta[](1);
deltas[0] = StateDelta({
    rollupId: 1,
    currentState: keccak256("state-before"),
    newState: keccak256("state-after"),
    etherDelta: 0
});

// 4. Assemble the entry
ExecutionEntry memory entry;
entry.stateDeltas = deltas;
entry.actionHash = keccak256(abi.encode(callAction));
entry.nextAction = resultAction;
```

### How the Batcher Pattern Works

```solidity
contract Batcher {
    function execute(Rollups rollups, ExecutionEntry[] calldata entries, MyApp app) external {
        rollups.postBatch(entries, 0, "", "proof");  // posts entries to L1
        app.doSomething();                           // triggers cross-chain call
    }
}
```

Both calls happen in a single transaction, satisfying the same-block requirement. Deployed inline during the execute script.

## Adding a New E2E Test

Use the counter test as a template. Here are the steps:

### 1. Create the directory

```bash
mkdir script/e2e/my-app
```

### 2. Create `MyAppE2E.s.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
// import your app contracts...

// Batcher: wraps postBatch + your user action in one tx
contract MyAppBatcher {
    function execute(Rollups rollups, ExecutionEntry[] calldata entries, MyApp app) external {
        rollups.postBatch(entries, 0, "", "proof");
        app.doAction();
    }
}

// Deploy: deploys your app contracts (takes pre-deployed Rollups address)
contract MyAppDeploy is Script {
    function run(address rollupsAddr) external {
        vm.startBroadcast();
        // Deploy your contracts, create proxies...
        // console.log("MY_CONTRACT=%s", address(myContract));
        vm.stopBroadcast();
    }
}

// Execute (local mode): constructs entries + executes via Batcher
contract MyAppExecute is Script {
    function run(address rollupsAddr, address myContractAddr) external {
        vm.startBroadcast();

        MyAppBatcher batcher = new MyAppBatcher();

        // Build your CALL action (must match what executeCrossChainCall builds on-chain)
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: 1,
            destination: myContractAddr,
            value: 0,
            data: abi.encodeWithSelector(MyContract.myFunction.selector),
            failed: false,
            sourceAddress: msg.sender,  // whoever calls the proxy
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        // Build the result action
        Action memory resultAction = Action({
            actionType: ActionType.RESULT,
            rollupId: 1,
            destination: address(0),
            value: 0,
            data: "",  // or abi.encode(returnValue)
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        // Build state deltas
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: 1,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-my-action"),
            etherDelta: 0
        });

        // Assemble entry
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = keccak256(abi.encode(callAction));
        entries[0].nextAction = resultAction;

        // Execute atomically
        batcher.execute(Rollups(rollupsAddr), entries, MyApp(myContractAddr));
        console.log("done");

        vm.stopBroadcast();
    }
}

// ExecuteNetwork (network mode): only sends the user transaction
contract MyAppExecuteNetwork is Script {
    function run(address myContractAddr) external {
        vm.startBroadcast();
        MyApp(myContractAddr).doAction();
        console.log("done");
        vm.stopBroadcast();
    }
}

// ComputeExpected: computes expected hashes + prints expected entries
contract MyAppComputeExpected is Script {
    function run(address myContractAddr) external pure {
        // Build the same CALL action as Execute
        Action memory callAction = Action({ /* ... same as above ... */ });

        bytes32 hash = keccak256(abi.encode(callAction));

        // Parseable line (shell scripts extract this)
        console.log("EXPECTED_HASHES=[%s]", vm.toString(hash));

        // Human-readable table (shown on verify failure)
        console.log("");
        console.log("=== EXPECTED EXECUTION TABLE (1 entry) ===");
        console.log("  [0] DEFERRED  actionHash: %s", vm.toString(hash));
        // print stateDeltas, nextAction...
    }
}
```

### 3. Create `run-local.sh`

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../shared/E2EBase.sh"

RPC="http://localhost:8545"

start_anvil 8545 ANVIL_PID
deploy_infra "$RPC" "$PK"

echo "====== Deploy App ======"
DEPLOY_OUTPUT=$(forge script script/e2e/my-app/MyAppE2E.s.sol:MyAppDeploy \
    --rpc-url "$RPC" --broadcast --private-key "$PK" \
    --sig "run(address)" "$ROLLUPS" 2>&1)
MY_CONTRACT=$(extract "$DEPLOY_OUTPUT" "MY_CONTRACT")

echo "====== Execute ======"
forge script script/e2e/my-app/MyAppE2E.s.sol:MyAppExecute \
    --rpc-url "$RPC" --broadcast --private-key "$PK" \
    --sig "run(address,address)" "$ROLLUPS" "$MY_CONTRACT" 2>&1

BLOCK=$(cast block-number --rpc-url "$RPC")
decode_block "$RPC" "$BLOCK" "$ROLLUPS"

echo "====== Done ======"
```

### 4. Create `run-network.sh`

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../shared/E2EBase.sh"

# Parse --rpc, --pk, --rollups args...

# 1. Deploy app
DEPLOY_OUTPUT=$(forge script script/e2e/my-app/MyAppE2E.s.sol:MyAppDeploy \
    --rpc-url "$RPC" --broadcast --private-key "$PK" \
    --sig "run(address)" "$ROLLUPS" 2>&1)
MY_CONTRACT=$(extract "$DEPLOY_OUTPUT" "MY_CONTRACT")

# 2. Compute expected entries
COMPUTE_OUTPUT=$(forge script script/e2e/my-app/MyAppE2E.s.sol:MyAppComputeExpected \
    --sig "run(address)" "$MY_CONTRACT" 2>&1)
EXPECTED_HASHES=$(extract "$COMPUTE_OUTPUT" "EXPECTED_HASHES")

# 3. Execute user transaction (may revert if no system — that's expected)
EXEC_OUTPUT=$(forge script script/e2e/my-app/MyAppE2E.s.sol:MyAppExecuteNetwork \
    --rpc-url "$RPC" --broadcast --private-key "$PK" \
    --sig "run(address)" "$MY_CONTRACT" 2>&1) \
    && echo "Transaction succeeded" || echo "Transaction reverted (expected — system posts batch separately)"
BLOCK=$(cast block-number --rpc-url "$RPC")

# 4. Verify
VERIFY_OUTPUT=$(forge script script/e2e/shared/Verify.s.sol:VerifyL1Batch \
    --rpc-url "$RPC" \
    --sig "run(uint256,address,bytes32[])" "$BLOCK" "$ROLLUPS" "$EXPECTED_HASHES" 2>&1) \
    && VERIFY_OK=true || VERIFY_OK=false

if $VERIFY_OK; then
    echo "$VERIFY_OUTPUT" | grep "PASS"
else
    # Show actual table (from verify) + expected table (from compute)
    echo "$VERIFY_OUTPUT" | strip_traces
    echo "$COMPUTE_OUTPUT" | sed -n '/=== EXPECTED/,$ p'
    exit 1
fi
```

## Key Invariants

- **Same-block execution**: `postBatch`/`loadExecutionTable` and the consuming transaction must be in the same block. Local mode enforces this via Batcher; network mode relies on the system.
- **actionHash matching**: The `actionHash` in the `ExecutionEntry` must equal `keccak256(abi.encode(callAction))` where `callAction` is what `executeCrossChainCall` builds on-chain. If these don't match, the execution lookup fails.
- **State delta chaining**: When multiple entries touch the same rollup, `newState` of entry N must equal `currentState` of entry N+1.
- **L2 entries have no state deltas**: On L2, `stateDeltas` is always an empty array. Only L1 tracks state roots.

## Multi-Chain E2E (Flash Loan Pattern)

For tests spanning L1 and L2:

1. Create a `deploy-app.sh` that handles multi-step cross-chain deployment (see flash-loan example)
2. In `run-local.sh`, start two anvils and call `deploy_infra` with both RPCs
3. Execute L2 phase first (load tables), then L1 phase (post batch)
4. In network mode, verify both chains at the **same block number**: call `VerifyL1Batch` against L1 RPC and `VerifyL2Table` against L2 RPC with the same block
