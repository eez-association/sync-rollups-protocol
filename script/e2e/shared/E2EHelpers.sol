// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Rollups} from "../../../src/Rollups.sol";
import {Action, ActionType, ExecutionEntry, ICrossChainManager} from "../../../src/ICrossChainManager.sol";

/// @notice Idempotent proxy creation — returns existing proxy if already deployed.
function getOrCreateProxy(ICrossChainManager manager, address originalAddress, uint256 originalRollupId)
    returns (address proxy)
{
    try manager.createCrossChainProxy(originalAddress, originalRollupId) returns (address p) {
        proxy = p;
    } catch {
        proxy = manager.computeCrossChainProxyAddress(originalAddress, originalRollupId);
    }
}

/// @notice Batcher for L2TX scenarios: postBatch + executeL2TX in one tx (local mode only).
///         Ensures both calls happen in the same block (same-block requirement).
contract L2TXBatcher {
    function execute(
        Rollups rollups,
        address proofSystem,
        ExecutionEntry[] calldata entries,
        uint256 rollupId,
        bytes calldata rlpTx
    ) external {
        rollups.postBatch(proofSystem, entries, 0, "", "proof");
        rollups.executeL2TX(rollupId, rlpTx);
    }
}

/// @dev Shared base for e2e scenarios that start with an L2TX action.
abstract contract L2TXActionsBase {
    uint256 internal constant L2_ROLLUP_ID = 1;
    uint256 internal constant MAINNET_ROLLUP_ID = 0;

    function _l2txAction(bytes memory rlpEncodedTx) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.L2TX,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: rlpEncodedTx,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });
    }

    /// @dev Spec C.6: Terminal RESULT for L2TX flows.
    ///   rollupId = L2_ROLLUP_ID, data = "", failed = false.
    function _terminalResultL2Tx() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }
}
