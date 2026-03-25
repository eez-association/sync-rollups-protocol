# E2E Tests

End-to-end tests that deploy contracts and execute cross-chain flows against real RPC endpoints (anvil or live networks).

## Directory Structure

```
script/e2e/
├── shared/
│   ├── DeployInfra.s.sol     # Rollups (L1) + CrossChainManagerL2 (L2)
│   ├── E2EBase.sh            # Shared bash utilities
│   ├── Verify.s.sol          # Post-facto verification of block events
│   ├── run-local.sh          # Generic local mode runner
│   └── run-network.sh        # Generic network mode runner
├── counter/                  # Simplest e2e — use as template
│   └── E2E.s.sol
├── bridge/                   # Bridge ETH e2e (uses CREATE2)
│   └── E2E.s.sol
├── multi-call-twice/         # Multi-call: same proxy called twice
│   └── E2E.s.sol
├── multi-call-two-diff/      # Multi-call: two different proxies
│   └── E2E.s.sol
├── multi-call/               # Multi-call (original, manual use only)
│   └── E2E.s.sol
└── flash-loan/               # Multi-chain flash loan e2e
    └── E2E.s.sol

script/deployment/
└── flash-loan/               # Multi-chain deployment scripts
    ├── DeployFlashLoan.s.sol  # Deploy contracts (used by deploy-app.sh)
    ├── deploy-app.sh          # Multi-step cross-chain deployment
    └── README.md
```

Each test has only `E2E.s.sol`. No per-test shell scripts. Multi-chain tests (flash-loan) have a `deploy-app.sh` in `script/deployment/<test-name>/`.

## Two Modes

### Local Mode

Starts anvil(s), deploys infra + app, executes via Batcher, decodes events.

```bash
bash script/e2e/shared/run-local.sh script/e2e/counter/E2E.s.sol
bash script/e2e/shared/run-local.sh script/e2e/bridge/E2E.s.sol
bash script/e2e/shared/run-local.sh script/e2e/multi-call-twice/E2E.s.sol
bash script/e2e/shared/run-local.sh script/e2e/multi-call-two-diff/E2E.s.sol
bash script/e2e/shared/run-local.sh script/e2e/flash-loan/E2E.s.sol   # auto-detects multi-chain
```

Multi-chain is auto-detected when `deploy-app.sh` exists in `script/deployment/<test-name>/`. In that case, two anvils are started and infra is deployed on both chains.

### Network Mode

Connects to an existing network. Deploys only app contracts, sends user transaction, verifies post-facto.

```bash
# Single-chain
bash script/e2e/shared/run-network.sh script/e2e/counter/E2E.s.sol \
    --rpc $RPC --pk $PK --rollups $ROLLUPS

# Multi-chain
bash script/e2e/shared/run-network.sh script/e2e/flash-loan/E2E.s.sol \
    --l1-rpc $L1_RPC --l2-rpc $L2_RPC --pk $PK \
    --rollups $ROLLUPS --manager-l2 $MANAGER_L2
```

The user transaction may revert if run against a network without a system (e.g. plain anvil) — this is expected and reported clearly. The verify step checks whether the system posted the batch.

On verify failure, prints both:
- **Actual execution table** — entries found in the block
- **Expected execution table** — entries the test expected to find

## Shared Utilities

### E2EBase.sh

Source it: `source "$(dirname "$0")/E2EBase.sh"`

| Function | Purpose |
|----------|---------|
| `extract "$output" KEY` | Parse `KEY=value` from forge script output |
| `start_anvil PORT PID_VAR` | Start anvil, store PID for cleanup |
| `deploy_infra L1_RPC PK [L2_RPC] [L2_ROLLUP_ID] [SYSTEM_ADDR]` | Deploy Rollups + optional CCManagerL2. Sets `$ROLLUPS`, `$MANAGER_L2` |
| `decode_block RPC BLOCK TARGET [LABEL]` | Run DecodeExecutions on a block |
| `ensure_create2_factory RPC LABEL PK` | Deploy CREATE2 factory if missing |
| `strip_traces` | Pipe filter: strips forge EVM traces, keeps only `console.log` output |
| `_export_outputs "$output"` | Auto-export `KEY=VALUE` lines from forge output as env vars |

### DeployInfra.s.sol

| Contract | Args | Deploys |
|----------|------|---------|
| `DeployRollupsL1` | (none) | MockZKVerifier + Rollups + creates rollup ID 1 |
| `DeployManagerL2` | `(uint256 rollupId, address systemAddress)` | CrossChainManagerL2 |

### Verify.s.sol

| Contract | Args | Checks |
|----------|------|--------|
| `VerifyL1Batch` | `(uint256 block, address rollups, bytes32[] expectedHashes)` | `BatchPosted` events contain expected entries (subset match) |
| `ExtractL2Blocks` | `(uint256 block, address rollups)` | Reads postBatch tx callData, outputs L2 block numbers |
| `VerifyL2Blocks` | `(uint256[] l2Blocks, address managerL2, bytes32[] expectedHashes)` | Tries each L2 block for `ExecutionTableLoaded` events containing expected entries |

All verify with **subset matching** — the block can contain additional entries and the test still passes. On failure, they print the full actual execution table before reverting.

## Standard Contract Names

Each `E2E.s.sol` has these contracts, all using `function run() external` with args from env vars:

| Contract | Purpose | Used in |
|----------|---------|---------|
| **Batcher** | Wraps `postBatch` + user tx in a single call (same-block guarantee) | Local mode |
| **Deploy** | Deploys app contracts. Reads `ROLLUPS`. Outputs `KEY=VALUE` via console.log | Both modes |
| **Execute** | Constructs `ExecutionEntry[]`, deploys Batcher, executes atomically | Local mode |
| **ExecuteNetwork** | Sends only the user transaction (no Batcher) | Network mode |
| **ComputeExpected** | Outputs `EXPECTED_HASHES=[...]` + human-readable expected table | Network mode |

Multi-chain tests additionally have **ExecuteL2** (local L2 execution).

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

### Batcher Pattern

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

Use counter as template.

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
contract Deploy is Script {
    function run() external {
        address rollups = vm.envAddress("ROLLUPS");
        vm.startBroadcast();
        // deploy contracts, create proxies...
        console.log("MY_CONTRACT=%s", address(myContract));
        vm.stopBroadcast();
    }
}

/// @dev Env: ROLLUPS, MY_CONTRACT
contract Execute is Script {
    function run() external {
        address rollups = vm.envAddress("ROLLUPS");
        address myContract = vm.envAddress("MY_CONTRACT");
        vm.startBroadcast();
        Batcher batcher = new Batcher();
        // build entries...
        batcher.execute(Rollups(rollups), entries, MyApp(myContract));
        console.log("done");
        vm.stopBroadcast();
    }
}

/// @dev Env: MY_CONTRACT
contract ExecuteNetwork is Script {
    function run() external {
        address myContract = vm.envAddress("MY_CONTRACT");
        vm.startBroadcast();
        MyApp(myContract).doAction();
        console.log("done");
        vm.stopBroadcast();
    }
}

/// @dev Env: MY_CONTRACT
contract ComputeExpected is Script {
    function run() external view {
        address myContract = vm.envAddress("MY_CONTRACT");
        // build same CALL action as Execute...
        bytes32 hash = keccak256(abi.encode(callAction));
        console.log("EXPECTED_HASHES=[%s]", vm.toString(hash));
        console.log("");
        console.log("=== EXPECTED EXECUTION TABLE (1 entry) ===");
        console.log("  [0] DEFERRED  actionHash: %s", vm.toString(hash));
        // print stateDeltas, nextAction...
    }
}
```

### 2. Run it

```bash
bash script/e2e/shared/run-local.sh script/e2e/my-app/E2E.s.sol
bash script/e2e/shared/run-network.sh script/e2e/my-app/E2E.s.sol --rpc $RPC --pk $PK --rollups $ROLLUPS
```

No shell scripts to write — the generic runners handle everything.

## Key Invariants

- **Same-block execution**: `postBatch`/`loadExecutionTable` and the consuming transaction must be in the same block. Local mode enforces via Batcher; network mode relies on the system.
- **actionHash matching**: `actionHash` must equal `keccak256(abi.encode(callAction))` where `callAction` matches what `executeCrossChainCall` builds on-chain.
- **State delta chaining**: `newState` of entry N must equal `currentState` of entry N+1 when both touch the same rollup.
- **L2 entries have no state deltas**: On L2, `stateDeltas` is always empty. Only L1 tracks state roots.

## Multi-Chain E2E

For tests spanning L1 and L2:

1. Create a `deploy-app.sh` for multi-step cross-chain deployment (see flash-loan). Output all addresses as `KEY=VALUE` lines.
2. Add `ExecuteL2` contract to `E2E.s.sol` for the L2 execution phase.
3. The generic scripts auto-detect multi-chain from `deploy-app.sh` and handle L2 execution + verification.
4. Network mode extracts L2 block numbers from the L1 postBatch callData via `ExtractL2Blocks`, then verifies each L2 block with `VerifyL2Blocks`.
