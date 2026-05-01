// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

// ═══════════════════════════════════════════════════════════════════════
//  OBSOLETE — kept until manual cleanup.
//
//  This decoder was tightly coupled to the pre-multi-prover event shapes:
//    - BatchPosted: previously carried the full ExecutionEntry[] payload;
//      post-refactor it carries only the sub-batch count, so decoding
//      entries from logs is no longer possible without supplemental tx
//      input decoding.
//    - ExecutionConsumed: previously (bytes32 actionHash, uint256 entryIndex);
//      post-refactor (bytes32 indexed crossChainCallHash, uint256 indexed rollupId,
//      uint256 indexed cursor).
//    - L2TXExecuted: previously (uint256 entryIndex); post-refactor
//      (uint256 indexed rollupId, uint256 indexed cursor).
//    - ExecutionEntry shape: `actionHash` → `crossChainCallHash`,
//      `failed` removed, `destinationRollupId` added.
//    - StaticCall struct removed; replaced by LookupCall.
//
//  TODO(user-decision): rewrite against the new ABI by decoding the
//  postBatch transaction input rather than the BatchPosted event, since the
//  on-chain event no longer carries entries. The new SIG constants are:
//    SIG_BATCH_POSTED      = keccak256("BatchPosted(uint256)")
//    SIG_EXECUTION_CONSUMED= keccak256("ExecutionConsumed(bytes32,uint256,uint256)")
//    SIG_L2TX_EXECUTED     = keccak256("L2TXExecuted(uint256,uint256)")
//    SIG_ENTRY_EXECUTED    = keccak256("EntryExecuted(uint256,bytes32,uint256,uint256)")
// ═══════════════════════════════════════════════════════════════════════

contract DecodeExecutions is Script {
    error ObsoleteDecoder();

    function runBlock(uint256, address) external pure {
        revert ObsoleteDecoder();
    }

    function decodeRecordedLogs(Vm.Log[] memory) external pure {
        revert ObsoleteDecoder();
    }
}
