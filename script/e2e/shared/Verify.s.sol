// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ActionType, Action, StateDelta, ExecutionEntry} from "../../../src/ICrossChainManager.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Shared formatting helpers used by multiple verify contracts
abstract contract VerifyHelpers is Script {
    bytes32 constant SIG_BATCH_POSTED = keccak256(
        "BatchPosted(((uint256,bytes32,bytes32,int256)[],bytes32,(uint8,uint256,address,uint256,bytes,bool,address,uint256,uint256[]))[],bytes32)"
    );

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
                typeName,
                "(rollup ",
                vm.toString(a.rollupId),
                a.failed ? ", FAILED" : ", ok",
                ", data=",
                _shortBytes(a.data),
                ")"
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
        for (uint256 i = s; i < e; i++) {
            r[i - s] = b[i];
        }
        return string(r);
    }

    function _findMissingHashes(bytes32[] memory actual, bytes32[] calldata expected)
        internal
        pure
        returns (bytes32[] memory)
    {
        bytes32[] memory tmp = new bytes32[](expected.length);
        uint256 count;
        for (uint256 i = 0; i < expected.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < actual.length; j++) {
                if (actual[j] == expected[i]) {
                    found = true;
                    break;
                }
            }
            if (!found) tmp[count++] = expected[i];
        }
        bytes32[] memory result = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = tmp[i];
        }
        return result;
    }
}

/// @title VerifyL1Batch — Verify that a block's BatchPosted events contain expected entries
/// @dev Compares entry hashes (actionHash + nextAction) not just actionHash alone.
///   On failure, prints the actual execution table from the block before reverting.
contract VerifyL1Batch is VerifyHelpers {
    function run(uint256 blockNumber, address rollups, bytes32[] calldata expectedEntryHashes) external view {
        bytes32[] memory topics = new bytes32[](0);
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(blockNumber, blockNumber, rollups, topics);

        ExecutionEntry[] memory actual = _collectEntries(logs);

        // Compute entry hashes: encode both actionHash and nextAction
        bytes32[] memory actualEntryHashes = new bytes32[](actual.length);
        for (uint256 i = 0; i < actual.length; i++) {
            actualEntryHashes[i] = keccak256(
                abi.encode(actual[i].actionHash, keccak256(abi.encode(actual[i].nextAction)))
            );
        }
        bytes32[] memory missing = _findMissingHashes(actualEntryHashes, expectedEntryHashes);

        if (missing.length > 0) {
            console.log(
                "FAIL: %s/%s expected entries missing in block %s",
                missing.length,
                expectedEntryHashes.length,
                blockNumber
            );
            console.log("");
            console.log("=== ACTUAL EXECUTION TABLE (L1 block %s, %s entries) ===", blockNumber, actual.length);
            _printEntries(actual);
            console.log("");
            console.log("=== MISSING ENTRY HASHES ===");
            for (uint256 i = 0; i < missing.length; i++) {
                console.log("  %s", vm.toString(missing[i]));
            }
            revert("Verification failed");
        }

        console.log(
            "PASS: %s/%s expected entries found in block %s",
            expectedEntryHashes.length,
            expectedEntryHashes.length,
            blockNumber
        );
        // Output tx hash of the BatchPosted event for the summary
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_BATCH_POSTED) {
                console.log("L1_BATCH_TX=%s", vm.toString(logs[i].transactionHash));
                break;
            }
        }
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

    function _printEntries(ExecutionEntry[] memory entries) internal pure {
        for (uint256 i = 0; i < entries.length; i++) {
            _logEntry(i, entries[i]);
        }
    }

    function _logEntry(uint256 idx, ExecutionEntry memory entry) internal pure {
        bool immediate = entry.actionHash == bytes32(0);
        console.log(
            "  [%s] %s  actionHash: %s", idx, immediate ? "IMMEDIATE" : "DEFERRED", vm.toString(entry.actionHash)
        );
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
}

/// @title VerifyL2Blocks — Verify expected entries exist in one of the given L2 blocks
/// @dev Compares entry hashes (actionHash + nextAction) not just actionHash alone.
///   Runs against L2 RPC. Tries each block — if all expected entry hashes found in any single block, PASS.
contract VerifyL2Blocks is VerifyHelpers {
    bytes32 constant SIG_TABLE_LOADED = keccak256(
        "ExecutionTableLoaded(((uint256,bytes32,bytes32,int256)[],bytes32,(uint8,uint256,address,uint256,bytes,bool,address,uint256,uint256[]))[])"
    );

    function run(uint256[] calldata l2Blocks, address managerL2, bytes32[] calldata expectedEntryHashes) external view {
        if (l2Blocks.length == 0) {
            console.log("FAIL: no L2 blocks to check");
            revert("No L2 blocks");
        }

        // Try each block
        for (uint256 i = 0; i < l2Blocks.length; i++) {
            ExecutionEntry[] memory entries = _getEntries(l2Blocks[i], managerL2);
            if (_allPresent(entries, expectedEntryHashes)) {
                console.log("PASS: all %s expected entries found at L2 block %s", expectedEntryHashes.length, l2Blocks[i]);
                // Output tx hash of the ExecutionTableLoaded event
                bytes32[] memory topics = new bytes32[](0);
                Vm.EthGetLogs[] memory blkLogs = vm.eth_getLogs(l2Blocks[i], l2Blocks[i], managerL2, topics);
                for (uint256 j = 0; j < blkLogs.length; j++) {
                    if (blkLogs[j].topics[0] == SIG_TABLE_LOADED) {
                        console.log("L2_TABLE_TX=%s", vm.toString(blkLogs[j].transactionHash));
                        break;
                    }
                }
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
        console.log("=== MISSING ENTRY HASHES ===");
        for (uint256 i = 0; i < expectedEntryHashes.length; i++) {
            console.log("  %s", vm.toString(expectedEntryHashes[i]));
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

    function _allPresent(ExecutionEntry[] memory entries, bytes32[] calldata expectedEntryHashes) internal pure returns (bool) {
        // Compute entry hashes from actuals
        bytes32[] memory actualEntryHashes = new bytes32[](entries.length);
        for (uint256 i = 0; i < entries.length; i++) {
            actualEntryHashes[i] = keccak256(
                abi.encode(entries[i].actionHash, keccak256(abi.encode(entries[i].nextAction)))
            );
        }
        // Check all expected are present
        for (uint256 i = 0; i < expectedEntryHashes.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < actualEntryHashes.length; j++) {
                if (actualEntryHashes[j] == expectedEntryHashes[i]) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }
}

/// @title VerifyL2Calls — Verify that cross-chain call events match expected actionHashes
/// @dev Runs against L2 RPC. Checks across given blocks for matching events.
///   Checks both IncomingCrossChainCallExecuted (L1→L2) and CrossChainCallExecuted (L2→L1).
///   Both events have bytes32 indexed actionHash as topics[1].
///   forge script script/e2e/shared/Verify.s.sol:VerifyL2Calls \
///     --rpc-url $L2_RPC \
///     --sig "run(uint256[],address,bytes32[])" "[5,6]" $MANAGER_L2 "[$HASH1,$HASH2]"
contract VerifyL2Calls is VerifyHelpers {
    bytes32 constant SIG_INCOMING_CALL =
        keccak256("IncomingCrossChainCallExecuted(bytes32,address,uint256,bytes,address,uint256,uint256[])");
    bytes32 constant SIG_CROSS_CHAIN_CALL =
        keccak256("CrossChainCallExecuted(bytes32,address,address,bytes,uint256)");

    function run(uint256[] calldata l2Blocks, address managerL2, bytes32[] calldata expectedCallHashes) external view {
        if (l2Blocks.length == 0) {
            console.log("FAIL: no L2 blocks to check");
            revert("No L2 blocks");
        }

        // Collect actionHashes from both event types across all blocks
        bytes32[] memory found = _collectActionHashes(l2Blocks, managerL2);

        // Check all expected are present (subset match)
        bytes32[] memory missing = _findMissingHashes(found, expectedCallHashes);

        if (missing.length > 0) {
            console.log("FAIL: %s/%s expected L2 calls missing", missing.length, expectedCallHashes.length);
            console.log("");
            console.log("=== ACTUAL CROSS-CHAIN CALL HASHES ===");
            for (uint256 i = 0; i < found.length; i++) {
                console.log("  %s", vm.toString(found[i]));
            }
            console.log("");
            console.log("=== MISSING CALL HASHES ===");
            for (uint256 i = 0; i < missing.length; i++) {
                console.log("  %s", vm.toString(missing[i]));
            }
            revert("Verification failed");
        }

        console.log("PASS: %s/%s expected L2 calls verified", expectedCallHashes.length, expectedCallHashes.length);
        // Output tx hashes of matching events
        for (uint256 i = 0; i < l2Blocks.length; i++) {
            bytes32[] memory topics = new bytes32[](0);
            Vm.EthGetLogs[] memory blkLogs = vm.eth_getLogs(l2Blocks[i], l2Blocks[i], managerL2, topics);
            for (uint256 j = 0; j < blkLogs.length; j++) {
                if (_isCallEvent(blkLogs[j].topics[0])) {
                    console.log("L2_CALL_TX=%s", vm.toString(blkLogs[j].transactionHash));
                }
            }
        }
    }

    function _isCallEvent(bytes32 sig) internal pure returns (bool) {
        return sig == SIG_INCOMING_CALL || sig == SIG_CROSS_CHAIN_CALL;
    }

    function _collectActionHashes(uint256[] calldata blocks, address managerL2)
        internal
        view
        returns (bytes32[] memory)
    {
        uint256 count;
        for (uint256 i = 0; i < blocks.length; i++) {
            bytes32[] memory topics = new bytes32[](0);
            Vm.EthGetLogs[] memory logs = vm.eth_getLogs(blocks[i], blocks[i], managerL2, topics);
            for (uint256 j = 0; j < logs.length; j++) {
                if (_isCallEvent(logs[j].topics[0])) count++;
            }
        }
        bytes32[] memory result = new bytes32[](count);
        uint256 idx;
        for (uint256 i = 0; i < blocks.length; i++) {
            bytes32[] memory topics = new bytes32[](0);
            Vm.EthGetLogs[] memory logs = vm.eth_getLogs(blocks[i], blocks[i], managerL2, topics);
            for (uint256 j = 0; j < logs.length; j++) {
                if (_isCallEvent(logs[j].topics[0])) {
                    // actionHash is topics[1] (first indexed parameter) for both events
                    result[idx++] = logs[j].topics[1];
                }
            }
        }
        return result;
    }
}
