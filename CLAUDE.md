# L1/L2 Sync Smart Contracts

Foundry-based Solidity project for L1/L2 rollup synchronization. L2 executions are verified on L1 via ZK proofs; on L2 a system address loads execution tables.

## Commands

```bash
forge build          # Compile
forge test           # Run all tests
forge test -vvv      # Verbose tests
forge fmt            # Format
```

## Core Contracts

| Contract | Role |
|---|---|
| `Rollups.sol` | L1 manager — rollup state, ZK-proven `postBatch`, cross-chain execution, scope navigation, static call lookup |
| `CrossChainManagerL2.sol` | L2 manager — system-loaded execution tables, no ZK/state deltas, static call lookup |
| `CrossChainProxy.sol` | CREATE2 proxy per (address, rollupId). STATICCALL detection via TSTORE probe; normal -> `executeCrossChainCall`, static -> `staticCallLookup`; manager -> `executeOnBehalf` |
| `ICrossChainManager.sol` | Shared interface + types (Action, StateDelta, ExecutionEntry, StaticCall, StaticSubCall, ProxyInfo) + shared errors |
| `IZKVerifier.sol` | ZK proof verification interface |

## Periphery

| Contract | Role |
|---|---|
| `Bridge.sol` | Lock-and-mint ETH/ERC20 bridging between rollups (CREATE2, `initialize()`) |
| `WrappedToken.sol` | ERC20 for bridged tokens, minted/burned by Bridge |
| `FlashLoan.sol` / `FlashLoanersNFT.sol` / `FlashLoanBridgeExecutor.sol` | DeFi mock contracts for testing |
| `tmpECDSAVerifier.sol` | Temporary ECDSA-based verifier (stands in for ZK) |

## Key Invariants

- Executions can only be consumed in the **same block** they were posted/loaded (`ExecutionNotInCurrentBlock`)
- On L1, `_etherDelta` (transient) must net to zero after state delta application (`EtherDeltaMismatch`)
- On L1, immediate entries (`actionHash == 0`) are consumed during `postBatch` via `executeL2TX()`; deferred entries are matched at consumption time by forward-scan from `executionIndex` with hard `StateRootMismatch` revert
- On L2, `_consumeExecution` matches by actionHash with forward-scan from `executionIndex` (no state deltas to verify)
- Consumed executions are tracked by `executionIndex` advancement (strict sequential ordering, no swap-and-pop)
- `ScopeReverted` on L1 carries `(nextAction, stateRoot, rollupId)` for state restoration; on L2 carries only `(nextAction)` (no rollup state to restore)
- Static call rolling hash is verified on-chain by `_processNStaticCalls`

## Execution Flow

1. **L1**: `postBatch()` verifies ZK proof, stores all entries + static calls, consumes immediate entries via `executeL2TX()` loop
2. **Entry**: User calls a `CrossChainProxy` -> fallback detects context -> normal: `executeCrossChainCall()`, static: `staticCallLookup()`
3. **Lookup**: Manager hashes the CALL action, forward-scans from `executionIndex` (skip-scan: skip failed, hard revert on non-failed non-matching), applies deltas (L1), returns `nextAction`
4. **Scoping**: If `nextAction` is a CALL, `_resolveScopes` -> `newScope()` recursively navigates via try/catch, executing through source proxies' `executeOnBehalf`
5. **Reverts**: REVERT actions trigger `ScopeReverted` error, caught by parent scope, state restored (L1), continuation via REVERT_CONTINUE lookup

## CREATE2 Proxy Addresses

- Salt: `keccak256(abi.encodePacked(originalRollupId, originalAddress))`
- Use `computeCrossChainProxyAddress(originalAddress, originalRollupId)` to predict

## Spec Maintenance

**`specs/SYNC_ROLLUPS_PROTOCOL_SPEC.md` is the authoritative protocol reference.** It MUST be kept in sync with the contracts. Whenever you make a meaningful contract change — altering an interface/ABI, changing how callers interact with the contract, modifying execution semantics, adding/removing functions or errors — update the spec. **Do NOT read the spec until after tests pass.** The workflow is: make the contract change, update tests, run tests, then read the spec and update the relevant sections. This avoids loading the large spec file into context unnecessarily.

## See Also

- `additions_to_CLAUDE.md` — pending improvement suggestions (redundant errors, etc.) for manual review
