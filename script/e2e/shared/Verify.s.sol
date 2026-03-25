// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ActionType, Action, StateDelta, ExecutionEntry} from "../../../src/ICrossChainManager.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title VerifyL1Batch — Verify that a block's BatchPosted events contain expected action hashes
/// @dev On failure, prints the actual execution table from the block before reverting.
contract VerifyL1Batch is Script {
    bytes32 constant SIG_BATCH_POSTED = keccak256(
        "BatchPosted(((uint256,bytes32,bytes32,int256)[],bytes32,(uint8,uint256,address,uint256,bytes,bool,address,uint256,uint256[]))[],bytes32)"
    );

    function run(uint256 blockNumber, address rollups, bytes32[] calldata expectedActionHashes) external view {
        bytes32[] memory topics = new bytes32[](0);
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(blockNumber, blockNumber, rollups, topics);

        ExecutionEntry[] memory actual = _collectEntries(logs);

        // Check all expected hashes are present
        bytes32[] memory missing = _findMissing(actual, expectedActionHashes);

        if (missing.length > 0) {
            console.log("FAIL: %s/%s expected entries missing in block %s", missing.length, expectedActionHashes.length, blockNumber);
            console.log("");
            console.log("=== ACTUAL EXECUTION TABLE (L1 block %s, %s entries) ===", blockNumber, actual.length);
            _printEntries(actual);
            console.log("");
            console.log("=== MISSING ACTION HASHES ===");
            for (uint256 i = 0; i < missing.length; i++) {
                console.log("  %s", vm.toString(missing[i]));
            }
            revert("Verification failed");
        }

        console.log("PASS: %s/%s expected entries found in block %s", expectedActionHashes.length, expectedActionHashes.length, blockNumber);
    }

    function _collectEntries(Vm.EthGetLogs[] memory logs) internal pure returns (ExecutionEntry[] memory) {
        uint256 totalCount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_BATCH_POSTED) {
                (ExecutionEntry[] memory entries,) = abi.decode(logs[i].data, (ExecutionEntry[], bytes32));
                totalCount += entries.length;
            }
        }
        ExecutionEntry[] memory all = new ExecutionEntry[](totalCount);
        uint256 idx;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_BATCH_POSTED) {
                (ExecutionEntry[] memory entries,) = abi.decode(logs[i].data, (ExecutionEntry[], bytes32));
                for (uint256 j = 0; j < entries.length; j++) {
                    all[idx++] = entries[j];
                }
            }
        }
        return all;
    }

    function _findMissing(ExecutionEntry[] memory actual, bytes32[] calldata expected) internal pure returns (bytes32[] memory) {
        bytes32[] memory tmp = new bytes32[](expected.length);
        uint256 count;
        for (uint256 i = 0; i < expected.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < actual.length; j++) {
                if (actual[j].actionHash == expected[i]) {
                    found = true;
                    break;
                }
            }
            if (!found) tmp[count++] = expected[i];
        }
        bytes32[] memory result = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) result[i] = tmp[i];
        return result;
    }

    function _printEntries(ExecutionEntry[] memory entries) internal pure {
        for (uint256 i = 0; i < entries.length; i++) {
            _logEntry(i, entries[i]);
        }
    }

    function _logEntry(uint256 idx, ExecutionEntry memory entry) internal pure {
        bool immediate = entry.actionHash == bytes32(0);
        console.log("  [%s] %s  actionHash: %s", idx, immediate ? "IMMEDIATE" : "DEFERRED", vm.toString(entry.actionHash));
        for (uint256 d = 0; d < entry.stateDeltas.length; d++) {
            StateDelta memory delta = entry.stateDeltas[d];
            console.log(
                string.concat(
                    "      stateDelta: rollup ",
                    vm.toString(delta.rollupId),
                    "  ",
                    _shortHash(delta.currentState),
                    " -> ",
                    _shortHash(delta.newState),
                    "  ether: ",
                    vm.toString(delta.etherDelta)
                )
            );
        }
        console.log("      nextAction: %s", _formatAction(entry.nextAction));
    }

    function _formatAction(Action memory a) internal pure returns (string memory) {
        string memory typeName = _typeName(a.actionType);
        if (a.actionType == ActionType.CALL) {
            string memory valStr = a.value > 0 ? string.concat(", val=", vm.toString(a.value)) : "";
            return string.concat(
                typeName,
                "(rollup ",
                vm.toString(a.rollupId),
                ", dest=",
                vm.toString(a.destination),
                ", from=",
                vm.toString(a.sourceAddress),
                valStr,
                ", data=",
                _shortBytes(a.data),
                ")"
            );
        } else if (a.actionType == ActionType.RESULT) {
            return string.concat(
                typeName, "(rollup ", vm.toString(a.rollupId), a.failed ? ", FAILED" : ", ok", ", data=", _shortBytes(a.data), ")"
            );
        }
        return string.concat(typeName, "(rollup ", vm.toString(a.rollupId), ")");
    }

    function _typeName(ActionType t) internal pure returns (string memory) {
        if (t == ActionType.CALL) return "CALL";
        if (t == ActionType.RESULT) return "RESULT";
        if (t == ActionType.L2TX) return "L2TX";
        if (t == ActionType.REVERT) return "REVERT";
        if (t == ActionType.REVERT_CONTINUE) return "REVERT_CONTINUE";
        return "?";
    }

    function _shortHash(bytes32 h) internal pure returns (string memory) {
        string memory full = vm.toString(h);
        return string.concat(_sub(full, 0, 6), "..", _sub(full, 62, 66));
    }

    function _shortBytes(bytes memory b) internal pure returns (string memory) {
        if (b.length == 0) return "0x";
        if (b.length <= 36) return vm.toString(b);
        string memory full = vm.toString(b);
        return string.concat(_sub(full, 0, 10), "...(", vm.toString(b.length), " bytes)");
    }

    function _sub(string memory str, uint256 s, uint256 e) internal pure returns (string memory) {
        bytes memory b = bytes(str);
        if (e > b.length) e = b.length;
        if (s >= e) return "";
        bytes memory r = new bytes(e - s);
        for (uint256 i = s; i < e; i++) r[i - s] = b[i];
        return string(r);
    }
}

/// @title ExtractL2Blocks — Extract L2 block numbers from postBatch callData on L1
/// @dev Runs against L1 RPC. Reads the postBatch transaction, decodes callData to get L2 block numbers.
///   forge script script/e2e/shared/Verify.s.sol:ExtractL2Blocks \
///     --rpc-url $L1_RPC \
///     --sig "run(uint256,address)" $BLOCK $ROLLUPS
contract ExtractL2Blocks is Script {
    bytes32 constant SIG_BATCH_POSTED = keccak256(
        "BatchPosted(((uint256,bytes32,bytes32,int256)[],bytes32,(uint8,uint256,address,uint256,bytes,bool,address,uint256,uint256[]))[],bytes32)"
    );

    function run(uint256 blockNumber, address rollups) external {
        bytes32[] memory topics = new bytes32[](0);
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(blockNumber, blockNumber, rollups, topics);

        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != SIG_BATCH_POSTED) continue;
            found = true;

            // Fetch the full transaction to get its input
            bytes32 txHash = logs[i].transactionHash;
            string memory params = string.concat('["', vm.toString(txHash), '"]');
            bytes memory rpcResult = vm.rpc("eth_getTransactionByHash", params);
            bytes memory txInput = vm.parseJsonBytes(string(rpcResult), ".input");

            // Strip 4-byte selector, decode postBatch params
            bytes memory encoded = _stripSelector(txInput);
            (,, bytes memory batchCallData,) = abi.decode(encoded, (ExecutionEntry[], uint256, bytes, bytes));

            if (batchCallData.length == 0) {
                console.log("L2_BLOCKS=[]");
                console.log("(empty callData - cross-chain-only batch)");
                continue;
            }

            // callData format: abi.encode(uint256[] l2BlockNumbers, bytes[] transactions)
            (uint256[] memory l2Blocks,) = abi.decode(batchCallData, (uint256[], bytes[]));

            // Output parseable array
            string memory s = "[";
            for (uint256 j = 0; j < l2Blocks.length; j++) {
                if (j > 0) s = string.concat(s, ",");
                s = string.concat(s, vm.toString(l2Blocks[j]));
            }
            s = string.concat(s, "]");
            console.log("L2_BLOCKS=%s", s);
            console.log("(%s L2 blocks in batch)", l2Blocks.length);
        }

        if (!found) {
            console.log("L2_BLOCKS=[]");
            console.log("(no BatchPosted events in block %s)", blockNumber);
        }
    }

    function _stripSelector(bytes memory input) internal pure returns (bytes memory) {
        require(input.length >= 4, "input too short");
        bytes memory result = new bytes(input.length - 4);
        for (uint256 i = 4; i < input.length; i++) {
            result[i - 4] = input[i];
        }
        return result;
    }
}

/// @title VerifyL2Blocks — Verify expected entries exist in one of the given L2 blocks
/// @dev Runs against L2 RPC. Tries each block — if all expected hashes found in any single block, PASS.
///   Otherwise prints all blocks' tables and reverts.
///   forge script script/e2e/shared/Verify.s.sol:VerifyL2Blocks \
///     --rpc-url $L2_RPC \
///     --sig "run(uint256[],address,bytes32[])" "[5,6,7]" $MANAGER_L2 "[$HASH1,$HASH2]"
contract VerifyL2Blocks is Script {
    bytes32 constant SIG_TABLE_LOADED = keccak256(
        "ExecutionTableLoaded(((uint256,bytes32,bytes32,int256)[],bytes32,(uint8,uint256,address,uint256,bytes,bool,address,uint256,uint256[]))[])"
    );

    function run(uint256[] calldata l2Blocks, address managerL2, bytes32[] calldata expectedHashes) external view {
        if (l2Blocks.length == 0) {
            console.log("FAIL: no L2 blocks to check");
            revert("No L2 blocks");
        }

        // Try each block
        for (uint256 i = 0; i < l2Blocks.length; i++) {
            ExecutionEntry[] memory entries = _getEntries(l2Blocks[i], managerL2);
            if (_allPresent(entries, expectedHashes)) {
                console.log("PASS: all %s expected entries found at L2 block %s", expectedHashes.length, l2Blocks[i]);
                return;
            }
        }

        // No match — print all blocks' tables
        console.log("FAIL: expected entries not found in any of %s L2 blocks", l2Blocks.length);
        for (uint256 i = 0; i < l2Blocks.length; i++) {
            ExecutionEntry[] memory entries = _getEntries(l2Blocks[i], managerL2);
            console.log("");
            console.log("=== L2 BLOCK %s (%s entries) ===", l2Blocks[i], entries.length);
            for (uint256 j = 0; j < entries.length; j++) {
                console.log("  [%s] actionHash: %s", j, vm.toString(entries[j].actionHash));
                for (uint256 d = 0; d < entries[j].stateDeltas.length; d++) {
                    StateDelta memory delta = entries[j].stateDeltas[d];
                    console.log(
                        string.concat(
                            "      stateDelta: rollup ",
                            vm.toString(delta.rollupId),
                            "  ",
                            _shortHash(delta.currentState),
                            " -> ",
                            _shortHash(delta.newState),
                            "  ether: ",
                            vm.toString(delta.etherDelta)
                        )
                    );
                }
                console.log("      nextAction: %s", _formatAction(entries[j].nextAction));
            }
        }

        console.log("");
        console.log("=== EXPECTED ACTION HASHES ===");
        for (uint256 i = 0; i < expectedHashes.length; i++) {
            console.log("  %s", vm.toString(expectedHashes[i]));
        }
        revert("Verification failed");
    }

    function _getEntries(uint256 blockNumber, address managerL2) internal view returns (ExecutionEntry[] memory) {
        bytes32[] memory topics = new bytes32[](0);
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(blockNumber, blockNumber, managerL2, topics);
        uint256 totalCount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_TABLE_LOADED) {
                ExecutionEntry[] memory entries = abi.decode(logs[i].data, (ExecutionEntry[]));
                totalCount += entries.length;
            }
        }
        ExecutionEntry[] memory all = new ExecutionEntry[](totalCount);
        uint256 idx;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_TABLE_LOADED) {
                ExecutionEntry[] memory entries = abi.decode(logs[i].data, (ExecutionEntry[]));
                for (uint256 j = 0; j < entries.length; j++) {
                    all[idx++] = entries[j];
                }
            }
        }
        return all;
    }

    function _allPresent(ExecutionEntry[] memory entries, bytes32[] calldata expected) internal pure returns (bool) {
        for (uint256 i = 0; i < expected.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < entries.length; j++) {
                if (entries[j].actionHash == expected[i]) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    function _formatAction(Action memory a) internal pure returns (string memory) {
        string memory typeName = _typeName(a.actionType);
        if (a.actionType == ActionType.CALL) {
            string memory valStr = a.value > 0 ? string.concat(", val=", vm.toString(a.value)) : "";
            return string.concat(
                typeName, "(rollup ", vm.toString(a.rollupId), ", dest=", vm.toString(a.destination),
                ", from=", vm.toString(a.sourceAddress), valStr, ", data=", _shortBytes(a.data), ")"
            );
        } else if (a.actionType == ActionType.RESULT) {
            return string.concat(
                typeName, "(rollup ", vm.toString(a.rollupId), a.failed ? ", FAILED" : ", ok", ", data=", _shortBytes(a.data), ")"
            );
        }
        return string.concat(typeName, "(rollup ", vm.toString(a.rollupId), ")");
    }

    function _typeName(ActionType t) internal pure returns (string memory) {
        if (t == ActionType.CALL) return "CALL";
        if (t == ActionType.RESULT) return "RESULT";
        if (t == ActionType.L2TX) return "L2TX";
        if (t == ActionType.REVERT) return "REVERT";
        if (t == ActionType.REVERT_CONTINUE) return "REVERT_CONTINUE";
        return "?";
    }

    function _shortHash(bytes32 h) internal pure returns (string memory) {
        string memory full = vm.toString(h);
        return string.concat(_sub(full, 0, 6), "..", _sub(full, 62, 66));
    }

    function _shortBytes(bytes memory b) internal pure returns (string memory) {
        if (b.length == 0) return "0x";
        if (b.length <= 36) return vm.toString(b);
        string memory full = vm.toString(b);
        return string.concat(_sub(full, 0, 10), "...(", vm.toString(b.length), " bytes)");
    }

    function _sub(string memory str, uint256 s, uint256 e) internal pure returns (string memory) {
        bytes memory b = bytes(str);
        if (e > b.length) e = b.length;
        if (s >= e) return "";
        bytes memory r = new bytes(e - s);
        for (uint256 i = s; i < e; i++) r[i - s] = b[i];
        return string(r);
    }
}
