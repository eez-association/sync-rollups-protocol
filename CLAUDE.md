# L1/L2 Sync Smart Contracts

## Project Overview

This is a Foundry-based Solidity project implementing smart contracts for L1/L2 rollup synchronization. The system allows L2 executions to be verified and executed on L1 using ZK proofs, and on L2 via system-loaded execution tables.

## Build & Test Commands

```bash
forge build          # Compile contracts
forge test           # Run all tests
forge test -vvv      # Run tests with verbose output
forge fmt            # Format code
```

## Architecture

### Core Contracts

- **Rollups.sol**: L1 contract managing rollup state roots, ZK-proven batch posting (immediate + deferred execution entries), and cross-chain call execution with scope-based nested call navigation
- **CrossChainProxy.sol**: Proxy contract deployed via CREATE2 for each (address, rollupId) pair. Forwards incoming calls to the manager via `executeCrossChainCall()` and executes outgoing calls via `executeOnBehalf()`
- **CrossChainManagerL2.sol**: L2-side contract for cross-chain execution. No ZK proofs or rollup state management — a system address loads execution tables, which are consumed by proxy calls or incoming cross-chain calls
- **IZKVerifier.sol**: Interface for external ZK proof verification

### Data Types

```solidity
enum ActionType { CALL, RESULT, L2TX, REVERT, REVERT_CONTINUE }

struct Action {
    ActionType actionType;
    uint256 rollupId;
    address destination;    // for CALL
    uint256 value;          // for CALL
    bytes data;             // callData for CALL, returnData for RESULT, rlpEncodedTx for L2TX
    bool failed;            // for RESULT
    address sourceAddress;  // for CALL - immediate caller address
    uint256 sourceRollup;   // for CALL - immediate caller's rollup ID
    uint256[] scope;        // hierarchical scope for nested call navigation
}

struct StateDelta {
    uint256 rollupId;
    bytes32 currentState;
    bytes32 newState;
    int256 etherDelta;       // Change in rollup's ETH balance
}

struct ExecutionEntry {
    StateDelta[] stateDeltas;
    bytes32 actionHash;      // bytes32(0) = immediate, otherwise deferred
    Action nextAction;
}

struct ProxyInfo {
    address originalAddress;
    uint64 originalRollupId;
}

struct RollupConfig {
    address owner;           // Can update state and verification key
    bytes32 verificationKey; // Used for ZK proof verification
    bytes32 stateRoot;       // Current state root
    uint256 etherBalance;    // ETH held by this rollup
}
```

### Key Functions (L1 - Rollups)

1. **createRollup(initialState, verificationKey, owner)**: Creates a new rollup
2. **createCrossChainProxy(originalAddress, originalRollupId)**: Deploys CrossChainProxy via CREATE2
3. **postBatch(entries, blobCount, callData, proof)**: Posts execution entries with ZK proof. Entries with `actionHash == 0` are applied immediately (state commitments); others are stored for deferred consumption. Sum of ether deltas for immediate entries must be zero.
4. **executeCrossChainCall(sourceAddress, callData)**: Executes a cross-chain call initiated by an authorized proxy
5. **executeL2TX(rollupId, rlpEncodedTx)**: Executes a pre-computed L2 transaction (permissionless)
6. **newScope(scope, action)**: Navigates scope tree for nested cross-chain calls with revert handling
7. **setStateByOwner(rollupId, newStateRoot)**: Updates state root without proof (owner only)
8. **setVerificationKey(rollupId, newVerificationKey)**: Updates verification key (owner only)
9. **transferRollupOwnership(rollupId, newOwner)**: Transfers rollup ownership (owner only)
10. **computeCrossChainProxyAddress(originalAddress, originalRollupId)**: Computes deterministic proxy address

### Key Functions (L2 - CrossChainManagerL2)

1. **loadExecutionTable(entries)**: Loads execution entries (system address only)
2. **executeCrossChainCall(sourceAddress, callData)**: Executes a cross-chain call from a local proxy
3. **executeIncomingCrossChainCall(destination, value, data, sourceAddress, sourceRollup, scope)**: Executes an incoming cross-chain call from another chain (system only)
4. **createCrossChainProxy(originalAddress, originalRollupId)**: Deploys CrossChainProxy via CREATE2

### Execution Flow

1. On L1, `postBatch()` processes execution entries with a ZK proof. Immediate entries update state; deferred entries are stored in the execution table.
2. Users call CrossChainProxy contracts, which forward to `executeCrossChainCall()` on the manager.
3. The manager builds a CALL action, looks up the matching execution by action hash and current rollup states, applies state deltas, and returns the next action.
4. If the next action is a CALL, scope navigation (`newScope()`) recursively processes nested calls through source proxies via `executeOnBehalf()`.
5. REVERT actions trigger `ScopeReverted`, restoring rollup state and continuing with a REVERT_CONTINUE action.
6. Used executions are removed from storage (swap-and-pop).

### CREATE2 Address Derivation

Proxy addresses are deterministic based on:
- Salt: `keccak256(originalRollupId, originalAddress)`
- Bytecode: CrossChainProxy creation code with constructor args (manager, originalAddress, originalRollupId)

Use `computeCrossChainProxyAddress(originalAddress, originalRollupId)` to predict addresses.

## Testing

Tests use a `MockZKVerifier` that accepts all proofs by default. Set `verifier.setVerifyResult(false)` to test proof rejection.
