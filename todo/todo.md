# TODO

## Next Up
- [ ] static call table,  also reverts?¿
- [ ] State deltas on L2?¿
- [ ] L2 `_consumeExecution` duplicate actionHash after scope revert — entries restored by EVM undo are indistinguishable from new entries with the same hash. Consider adding state-delta-like checks or sequence counters to `CrossChainManagerL2` so REVERT_CONTINUE → CALL works for identical-result cross-chain calls (see CAVEATS.md)
- Add gas into actions
- add transient storage to ahve account abstraction ( much chepaer) and normal approach

## Done / Old Notes
- Keep a list of actions, if all consumed, optionally pay something to an address
- rollupID uint64
- Custom tx — all original contracts and chains we interact with
- Universal address, access list transaction!

`Rollups.sol` `ScopeReverted` error includes `(bytes nextAction, bytes32 stateRoot, uint256 rollupId)` and `_handleScopeRevert` restores the rollup's state root after catching the revert. `CrossChainManagerL2.sol` `ScopeReverted` only carries `(bytes nextAction)` — no state restoration. This is consistent since L2 has no rollup state management, but it means L2 scope reverts don't rollback any state changes made during the reverted scope.
