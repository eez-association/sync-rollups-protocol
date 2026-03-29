---
name: create-e2e-test
description: Generate a new E2E test for cross-chain execution flows. Use this skill whenever the user asks to "create an e2e test", "add a new e2e scenario", "generate e2e for ...", describes a cross-chain call flow they want tested, mentions testing L1/L2 interactions, or wants to verify postBatch/executeIncomingCrossChainCall behavior. Also trigger when the user pastes an entry table or flow diagram and wants it turned into a runnable test.
---

# Create E2E Test

Build a complete, runnable E2E test from a scenario description. The test lives in `script/e2e/<test-name>/E2E.s.sol` and works in both local mode (two anvil instances) and network mode (real devnet).

## Workflow

### 1. Parse the scenario

Extract from the user's description:
- **Direction**: L1-starting or L2-starting? (Who initiates the first cross-chain call?)
- **Call pattern**: simple, nested, multicall, revert, or a combination
- **Contracts**: which contracts call which, and on which chain each lives
- **Expected behavior**: return values, counter increments, revert conditions

If the description is ambiguous, ask. Getting the direction wrong cascades into every entry.

### 2. Read the closest existing test and the rules

**Always read both rules files first** — they are the authoritative reference for structure and entry construction:
- `.claude/skills/create-e2e-test/rules/e2e-structure.md` — file layout, contract ordering, deploy patterns
- `.claude/skills/create-e2e-test/rules/entry-construction.md` — action fields, entry patterns, hash/scope/delta rules

Then read the closest existing test as a concrete template:

| Pattern | L1-starting | L2-starting |
|---------|-------------|-------------|
| Simple | `script/e2e/counter/E2E.s.sol` | `script/e2e/counterL2/E2E.s.sol` |
| Nested | `script/e2e/nestedCounter/E2E.s.sol` | `script/e2e/nestedCounterL2/E2E.s.sol` |
| Multicall (same target) | `script/e2e/multi-call-twice/E2E.s.sol` | -- |
| Multicall (diff targets) | `script/e2e/multi-call-two-diff/E2E.s.sol` | -- |
| Multicall + nested | `script/e2e/multi-call-nested/E2E.s.sol` | `script/e2e/multi-call-nestedL2/E2E.s.sol` |
| ETH bridge | `script/e2e/bridge/E2E.s.sol` | -- |
| Revert (terminal) | `script/e2e/revertCounter/E2E.s.sol` | `script/e2e/revertCounterL2/E2E.s.sol` |
| Revert (nested, no continue) | `script/e2e/nestedCallRevert/E2E.s.sol` | -- |
| Flash loan | `script/e2e/flash-loan/E2E.s.sol` | -- |

Also read if needed:
- `docs/EXECUTION_TABLE_SPEC.md` — the protocol specification (entry types, flow patterns, hash rules)
- `script/e2e/README.md` — E2E infrastructure overview

### 3. Design entry tables BEFORE writing code

This is the most important step. Entry construction is the hardest part of an E2E test and where most bugs come from. Work out the complete tables on paper first.

**For each chain (L1 and L2), list every entry as:**
```
[index] trigger: ACTION_TYPE(rollupId, details...)
        next:    ACTION_TYPE(rollupId, details...)
        deltas:  [{rollupId, currentState -> newState}]  (L1 only)
```

**Checklist while designing:**
1. Every action that will occur during execution has a matching entry
2. trigger->next mappings are correct (the "next" is what the contract returns/navigates to after consuming the trigger)
3. L1 state deltas chain: `newState[0] == currentState[1]`, etc.
4. L2 entries have NO state deltas (always `new StateDelta[](0)`)
5. Duplicate actionHashes are differentiated correctly (by state on L1, by insertion order on L2)
6. L2 chaining entries have a CALL as nextAction (not RESULT) — this is how execution continues on L2
7. Every chain ends with a terminal RESULT entry
8. Scope arrays are correct: `[]` on the sending chain, `[0]` (or deeper) on the receiving chain for nested calls

**Present the entry table to the user for review before writing code.** Entry bugs are much cheaper to fix in the design phase.

### 4. Create app contracts if needed

Check `test/mocks/` for existing contracts that match the scenario:
- Counter patterns -> `test/mocks/CounterContracts.sol`
- Multicall patterns -> `test/mocks/MultiCallContracts.sol`
- Other -> new file in `test/mocks/`

Prefer reusing existing contracts. Only create new ones if the scenario genuinely needs different behavior.

### 5. Write the E2E test file

Create `script/e2e/<test-name>/E2E.s.sol` with these contracts **in this exact order**:

1. **Header comment** — scenario description + ASCII flow diagram
2. **Actions base** (abstract) — single source of truth for all action builders and entry constructors. For L2-starting, extend `L2TXActionsBase`.
3. **Batcher** (L1-starting only) — wraps `postBatch` + user call in one tx. For L2-starting, use `L2TXBatcher` from `shared/E2EHelpers.sol`.
4. **Deploy contracts** — `Deploy`, `DeployL2`, `Deploy2` (and `Deploy2L2` for L2-starting). Order depends on direction — see `rules/e2e-structure.md`.
5. **ExecuteL2** — local mode L2 side
6. **Execute** — local mode L1 side
7. **ExecuteNetwork** or **ExecuteNetworkL2** — network mode
8. **ComputeExpected** — computes and logs expected entry hashes for verification

See `rules/e2e-structure.md` for the full contract specs, import conventions, and env var naming.

### 6. Verify

Run `forge build` to check compilation.

If possible, run `bash script/e2e/shared/run-local.sh script/e2e/<test-name>/E2E.s.sol` to verify the test passes end-to-end in local mode.

### 7. Mention the run-e2e skill

If the test should be part of the daily E2E run, tell the user — but don't modify `.claude/commands/run-e2e.md` without asking.

## Common pitfalls

These are the mistakes that cause the most debugging time. Check each one before considering the test done.

| Pitfall | Why it happens | How to avoid |
|---------|---------------|--------------|
| Wrong RESULT rollupId | RESULT.rollupId must match the CALL.rollupId that triggered it (protocol rule: `resultAction.rollupId = action.rollupId`) | Double-check every RESULT's rollupId against its triggering CALL |
| L2 entries with state deltas | L2 has no state tracking — deltas are always empty | Always use `new StateDelta[](0)` for L2 entries |
| Broken state chain | `currentState[N+1]` doesn't match `newState[N]` | Write out the full chain s0->s1->s2->... and verify continuity |
| Wrong scope on nested calls | Sending chain always uses `scope=[]`, receiving chain uses `scope=[0]` or deeper | Check scope rules in `entry-construction.md` |
| Missing terminal entry | Every chain must end with a RESULT. L1-starting terminals on L2 are self-referencing. L2-starting terminals on L1 use `RESULT(L2, data="")`. | Count your terminal entries per chain |
| Multiple `executeIncomingCrossChainCall` | For L1-starting multicalls, only ONE `executeIncomingCrossChainCall` — chaining handles the rest | Re-read the multicall pattern in `entry-construction.md` |
| sourceAddress is the proxy, not the original | `sourceAddress` in a CALL action is the *proxy address* on the calling chain (the immediate caller), not the original contract address | Use `computeCrossChainProxyAddress()` or the proxy address from deployment |
| Deploy order wrong | L1-starting: Deploy(L1) -> DeployL2(L2) -> Deploy2(L1). L2-starting: DeployL2(L2) -> Deploy(L1) -> Deploy2L2(L2). | Follow direction-specific order in `e2e-structure.md` |
| etherDelta doesn't sum to zero | Immediate entries' ether deltas must net to zero within a batch | Sum all etherDelta values and verify == 0 |

## References

- [E2E Structure Rules](rules/e2e-structure.md) — Always load. File structure, contracts, deploy order, import conventions.
- [Entry Construction Rules](rules/entry-construction.md) — Always load. Action fields, entry patterns per flow type, hash/scope/delta rules.

## Examples

**Example 1: L1-starting multicall to different targets**
Input: "add an e2e test where a contract on L1 calls two different L2 counters"
Output: `script/e2e/multi-call-two-diff/E2E.s.sol` — 2 L1 entries (different actionHashes, one per counter), 2 L2 entries (chained: first RESULT->CALL, second RESULT->RESULT terminal), Deploy/Execute/ComputeExpected contracts

**Example 2: L2-starting nested flow**
Input: "create a test starting from L2, contract calls L1 which nests back to L2"
Output: L2-starting test with L2TX entry + nested scope entries on L1, L2TXBatcher, ExecuteNetworkL2, scope=[0] on L2 entries for the nested call

**Example 3: Revert with continue**
Input: "test where an L1 call to L2 reverts but execution continues"
Output: REVERT + REVERT_CONTINUE action entries, state rollback on the reverted rollup, continue entry that processes after the revert
