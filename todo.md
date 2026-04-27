# TODO


## Next Up
- [ ] Test with reverts and check scopes
- [ ] End and static call modes
- [ ] Check how revert can be deleted — try flatten approach
- [ ] CrossChain address — deterministic deployments?

## Integration Tests
- [ ] Static call integration test

## Transient Batch Behaviour Tests
- [ ] `transientCount >= 1` with `entries[0].actionHash == 0` — immediate entry runs, transient drained by hook, remainder lands in persistent storage
- [ ] Hook drains only part of the transient table — remainder dropped; subsequent `executeL2TX` sees no entries
- [ ] `transientCount == 0` — no immediate execution; all entries land in `executions` after hook returns; `executeL2TX` then consumes `entries[0]`
- [ ] `msg.sender` is an EOA — hook NOT fired
- [ ] `msg.sender` is a contract that implements `IMetaCrossChainReceiver` — hook fires and consumes transient entries
- [ ] Bounds: `transientCount > entries.length` reverts `TransientCountExceedsEntries`; same for `transientStaticCallCount`
- [ ] `_transientStaticCalls` is consulted before `staticCalls` in `staticCallLookup`
- [ ] Re-entrancy: nested `postBatch` during the hook must revert `StateAlreadyUpdatedThisBlock`
- [ ] Hook guard: hook not fired when transient table is fully drained by the immediate entry (no unconsumed entries remain)

## Research / Open Questions
- [ ] Reverts + staticcall problem
- [ ] State deltas on cross-chain — other ways? Other structs?

## Stale docs to update for the flatten model
- [ ] `test/INTEGRATION_TEST_NOTES.md` — scenario table still references `executeIncomingCrossChainCall`, scope navigation, and `nextAction` matching
- [ ] `visualizator/dashboard/PLAN.md` — around line 262, the `Action` struct example still has `ActionType actionType` and `uint256[] scope`

## Done / Old Notes
- [] Keep a list of actions, if all consumed, optionally pay something to an address
- [] rollupID uint64
- Custom tx — all original contracts and chains we interact with
- Universal address
