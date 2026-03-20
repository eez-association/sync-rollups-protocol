# TODO


## Next Up
- [ ] Test with reverts and check scopes
- [ ] End and static call modes
- [ ] Check how revert can be deleted — try flatten approach
- [ ] CrossChain address — deterministic deployments?

## Integration Tests
- [ ] Static call integration test

## Research / Open Questions
- [ ] Reverts + staticcall problem
- [ ] State deltas on cross-chain — other ways? Other structs?
- [ ] L2 ScopeReverted doesn't rollback state changes (no rollup state management on L2)

## Done / Old Notes
- [] Keep a list of actions, if all consumed, optionally pay something to an address
- [] rollupID uint64
- Custom tx — all original contracts and chains we interact with
- Universal address



`Rollups.sol` `ScopeReverted` error includes `(bytes nextAction, bytes32 stateRoot, uint256 rollupId)` and `_handleScopeRevert` restores the rollup's state root after catching the revert. `CrossChainManagerL2.sol` `ScopeReverted` only carries `(bytes nextAction)` — no state restoration. This is consistent since L2 has no rollup state management, but it means L2 scope reverts don't rollback any state changes made during the reverted scope.
