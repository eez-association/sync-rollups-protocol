# Sync Rollups

Smart contracts to manage synchronous rollups in Ethereum.

## Overview

Sync Rollups enables synchronous composability between based rollups sharing the same L1 sequencer. By pre-computing state transitions off-chain and loading them with ZK proofs, the protocol enables atomic cross-rollup calls that execute within a single L1 block.

This restores the synchronous execution semantics that DeFi protocols depend on—now across multiple rollups.

## Features

- **Atomic Multi-Rollup Execution**: State changes across multiple rollups happen atomically in a single transaction
- **Cross-Rollup Flash Loans**: Borrow on Rollup A, use on Rollup B, repay on A—all atomic
- **Unified Liquidity**: AMMs can source liquidity from multiple rollups
- **ZK-Verified State Transitions**: All executions are verified with ZK proofs
- **Scope-Based Nested Calls**: Hierarchical scope mechanism for nested cross-chain calls with revert handling
- **L1 + L2 Contracts**: L1 `Rollups` contract manages state and proofs; L2 `CrossChainManagerL2` handles execution without ZK overhead
- **ETH Balance Tracking**: Per-rollup ETH accounting with conservation guarantees

## Architecture

### Core Contracts

| Contract | Description |
|----------|-------------|
| `Rollups.sol` | L1 contract managing rollup state roots, proven execution tables, and cross-chain call execution. Inherits `ProofSystemRegistry` |
| `ProofSystemRegistry.sol` | Permissionless registry of proof systems — anyone can register an `IProofSystem` implementation, rollups then bind to one |
| `CrossChainProxy.sol` | Proxy contract deployed via CREATE2 for each (address, rollupId) pair. Forwards calls to the manager and executes on behalf of cross-chain callers |
| `CrossChainManagerL2.sol` | L2-side contract for cross-chain execution via pre-computed execution tables loaded by a system address (no proof verification on L2) |
| `IProofSystem.sol` | Interface for proof-verifying systems (ZK, ECDSA, etc.) |

### Data Types

```solidity
enum ActionType { CALL, RESULT, L2TX, REVERT, REVERT_CONTINUE }

struct Action {
    ActionType actionType;
    uint256 rollupId;
    address destination;    // for CALL
    uint256 value;          // for CALL
    bytes data;             // callData/returnData/rlpEncodedTx
    bool failed;            // for RESULT
    address sourceAddress;  // for CALL - immediate caller address
    uint256 sourceRollup;   // for CALL - immediate caller's rollup ID
    uint256[] scope;        // hierarchical scope for nested call navigation
}

struct StateDelta {
    uint256 rollupId;
    bytes32 currentState;
    bytes32 newState;
    int256 etherDelta;      // Change in ETH balance for this rollup
}

struct ExecutionEntry {
    StateDelta[] stateDeltas;
    bytes32 actionHash;     // bytes32(0) = immediate state commitment, otherwise deferred
    Action nextAction;
}

struct ProxyInfo {
    address originalAddress;
    uint64 originalRollupId;
}

struct RollupConfig {
    address owner;
    address proofSystem;     // the proof system this rollup is bound to
    bytes32 stateRoot;
    uint256 etherBalance;
}

// Per-rollup verification keys live in a side mapping:
//   mapping(uint256 rollupId => mapping(address proofSystem => bytes32 vkey))
```

### Execution Flow

1. **Load Phase**: Off-chain provers compute valid executions and submit them via `postBatch()` with a ZK proof. Entries with `actionHash == bytes32(0)` are applied immediately as state commitments; entries with a non-zero `actionHash` are stored in the execution table for later consumption.
2. **Execute Phase**: Users call `CrossChainProxy` contracts, which trigger `executeL2Call()` on the manager. The manager builds a CALL action, looks up the matching execution, applies state deltas, and returns the next action.
3. **Scope Navigation**: If the next action is a CALL at a deeper scope, `newScope()` recursively navigates the scope tree, executing calls through source proxies via `executeOnBehalf()`. Reverts at any scope are caught and handled via `ScopeReverted`.
4. **Cleanup**: Used executions are removed from storage (swap-and-pop).

```
User calls CrossChainProxy.someFunction()
    |-> CrossChainProxy forwards to manager.executeL2Call(sender, calldata)
        |-> Build CALL action, hash it
        |-> _findAndApplyExecution(actionHash)
            |-> Match execution by current rollup states
            |-> Apply state deltas atomically
            |-> Return nextAction
        |-> If nextAction is CALL: enter scope navigation
            |-> newScope() recursively processes nested calls
            |-> Calls executed through source proxy.executeOnBehalf()
            |-> REVERT actions trigger ScopeReverted with state rollback
        |-> Return final RESULT to caller
```

### L2 Execution (CrossChainManagerL2)

On L2, the `CrossChainManagerL2` handles cross-chain execution without ZK proofs or rollup state management:

- A **system address** loads execution tables via `loadExecutionTable()`
- Local proxy calls go through `executeCrossChainCall()`
- Remote calls from other chains go through `executeRemoteCall()` (system only)
- Scope navigation and revert handling work the same as on L1

### ETH Balance Tracking

Each rollup maintains an ETH balance held by the Rollups contract. This enables cross-rollup value transfers while maintaining conservation guarantees.

**Key Properties:**
- Cross-rollup transfers require the sum of ether deltas to be zero in `postBatch()` (for immediate entries)
- Executions can transfer ETH between rollups via `etherDelta` in StateDelta
- Outgoing CALL actions with value deduct from the source rollup's balance
- Rollup ETH balances cannot go negative

## Installation

```bash
# Clone the repository
git clone https://github.com/jbaylina/sync-rollups.git
cd sync-rollups

# Install dependencies
forge install
```

## Build & Test

```bash
# Compile contracts
forge build

# Run tests
forge test

# Run tests with verbose output
forge test -vvv

# Format code
forge fmt
```

## E2E Tests

E2E tests deploy contracts on anvil (or a live network) and execute real cross-chain flows. See [`script/e2e/README.md`](script/e2e/README.md) for full documentation.

```bash
# Local mode — starts anvil, deploys everything, executes, decodes events
bash script/e2e/counter/run-local.sh       # Simple counter increment
bash script/e2e/bridge/run-local.sh        # Bridge ETH via CREATE2
bash script/e2e/flash-loan/run-local.sh    # Multi-chain flash loan

# Network mode — deploys app to existing network, verifies post-facto
bash script/e2e/counter/run-network.sh --rpc $RPC --pk $PK --rollups $ROLLUPS
```

## Usage

### Registering a Proof System and Creating a Rollup

```solidity
Rollups rollups = new Rollups(startingRollupId);

// Anyone can register a proof system (a contract implementing IProofSystem).
rollups.registerProofSystem(IProofSystem(myVerifier));

// Each rollup is bound to one proof system at a time.
uint256 rollupId = rollups.createRollup(
    initialState,      // bytes32
    address(myVerifier),
    verificationKey,   // bytes32
    owner              // address
);

// Later the owner can swap proof systems atomically:
// rollups.setProofSystem(rollupId, newProofSystem, newVkey);
```

### Creating a CrossChainProxy

```solidity
address proxy = rollups.createCrossChainProxy(
    originalAddress,   // The L2 contract address
    originalRollupId   // The rollup ID
);
```

### Posting a Batch

```solidity
ExecutionEntry[] memory entries = new ExecutionEntry[](2);

// Immediate state commitment (actionHash == 0)
entries[0] = ExecutionEntry({
    stateDeltas: immediateDeltas,
    actionHash: bytes32(0),
    nextAction: Action(...)  // ignored for immediate entries
});

// Deferred execution (stored for later consumption)
entries[1] = ExecutionEntry({
    stateDeltas: deferredDeltas,
    actionHash: actionHash,
    nextAction: nextAction
});

// Pass the proof-system address — every touched non-mainnet rollup must be bound to it.
rollups.postBatch(address(myVerifier), entries, blobCount, callData, proof);
```

### Computing Proxy Addresses

```solidity
address proxyAddr = rollups.computeCrossChainProxyAddress(
    originalAddress,
    originalRollupId,
    domain  // chain ID where proxy will be deployed
);
```

## Key Functions

### Rollups (L1)

| Function | Description |
|----------|-------------|
| `createRollup()` | Creates a new rollup with initial state, verification key, and owner |
| `createCrossChainProxy()` | Deploys a CrossChainProxy via CREATE2 |
| `postBatch()` | Posts execution entries with ZK proof (immediate + deferred) |
| `executeL2Call()` | Executes a cross-chain call initiated by an authorized proxy |
| `executeL2TX()` | Executes a pre-computed L2 transaction (permissionless) |
| `newScope()` | Navigates scope tree for nested cross-chain calls |
| `depositEther()` | Deposits ETH to a rollup's balance |
| `computeCrossChainProxyAddress()` | Computes deterministic proxy address |
| `setStateByOwner()` | Updates state root without proof (owner only) |
| `setVerificationKey()` | Updates verification key (owner only) |
| `transferRollupOwnership()` | Transfers rollup ownership |

### CrossChainManagerL2 (L2)

| Function | Description |
|----------|-------------|
| `loadExecutionTable()` | Loads execution entries (system address only) |
| `executeCrossChainCall()` | Executes a cross-chain call from a local proxy |
| `executeRemoteCall()` | Executes a remote call from another chain (system only) |
| `createCrossChainProxy()` | Deploys a CrossChainProxy via CREATE2 |
| `computeCrossChainProxyAddress()` | Computes deterministic proxy address |

## Security Considerations

- Only authorized proxies can execute cross-chain calls via `executeL2Call()`
- `executeL2TX()` is permissionless - anyone can trigger pre-loaded L2 transactions
- Same-block protection prevents conflicts between async and sync state updates
- All L1 state transitions are verified with ZK proofs
- Rollup owners can update verification keys and transfer ownership
- ETH balance conservation: sum of ether deltas in immediate batch entries must be zero
- Rollup ETH balances cannot go negative (enforced on every state update)
- Scope reverts restore rollup state roots to pre-scope values
- On L2, only the system address can load execution tables and trigger remote calls

## License

MIT
