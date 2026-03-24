// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ActionType, Action, StateDelta, ExecutionEntry} from "../src/ICrossChainManager.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title DecodeExecutions
/// @notice Decodes cross-chain events from a block and shows execution flow
/// @dev Usage:
///   forge script script/DecodeExecutions.s.sol:DecodeExecutions --rpc-url <RPC> --sig "runBlock(uint256,address)" <BLOCK> <CONTRACT>
contract DecodeExecutions is Script {
    bytes32 constant SIG_CROSSCHAIN_CALL =
        keccak256("CrossChainCallExecuted(bytes32,address,address,bytes,uint256)");
    bytes32 constant SIG_EXECUTION_CONSUMED = keccak256(
        "ExecutionConsumed(bytes32,(uint8,uint256,address,uint256,bytes,bool,address,uint256,uint256[]))"
    );
    bytes32 constant SIG_L2TX_EXECUTED = keccak256("L2TXExecuted()");
    bytes32 constant SIG_L2_EXECUTION_PERFORMED = keccak256("L2ExecutionPerformed(uint256,bytes32,bytes32)");
    bytes32 constant SIG_BATCH_POSTED = keccak256(
        "BatchPosted(((uint256,bytes32,bytes32,int256)[],bytes32,(uint8,uint256,address,uint256,bytes,bool,address,uint256,uint256[]))[],bytes32)"
    );

    // ── Collected data per tx ──
    struct TxData {
        bytes32 txHash;
        // Batch entries (actionHash → nextAction mapping)
        ExecutionEntry[] batchEntries;
        // Ordered consumed actions
        Action[] consumedActions;
        bytes32[] consumedHashes;
        // Trigger info
        bool hasL2TX;
        uint256 l2txRollupId;
        bytes l2txRlpData;
        bytes32 l2txActionHash;
        bool hasCrossChainCall;
        address ccProxy;
        address ccSourceAddress;
        bytes ccCallData;
        uint256 ccValue;
        bytes32 ccActionHash;
    }

    // ──────────────────── Entry point ────────────────────

    function runBlock(
        uint256 blockNumber,
        address target
    ) external view {
        bytes32[] memory topics = new bytes32[](0);
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(blockNumber, blockNumber, target, topics);

        console.log("================================================================");
        console.log("BLOCK %s | %s logs | target %s", blockNumber, logs.length, vm.toString(target));
        console.log("================================================================");

        // Group logs by tx
        _processBlock(logs);
    }

    function decodeRecordedLogs(
        Vm.Log[] memory logs
    ) external view {
        // Convert Vm.Log[] to a common format and process
        console.log("================================================================");
        console.log("RECORDED LOGS | %s logs", logs.length);
        console.log("================================================================");

        // Collect all data
        uint256 batchEntryCount;
        ExecutionEntry[] memory batchEntries;
        Action[] memory consumed = new Action[](logs.length);
        bytes32[] memory consumedHashes = new bytes32[](logs.length);
        uint256 consumedCount;

        // Trigger
        bool hasL2TX;
        uint256 l2txRollupId;
        bytes memory l2txRlpData;
        bytes32 l2txActionHash;
        bool hasCCCall;
        address ccProxy;
        address ccSource;
        bytes memory ccCallData;
        uint256 ccValue;
        bytes32 ccActionHash;

        for (uint256 i = 0; i < logs.length; i++) {
            bytes32 t0 = logs[i].topics[0];
            if (t0 == SIG_BATCH_POSTED) {
                (batchEntries,) = abi.decode(logs[i].data, (ExecutionEntry[], bytes32));
                batchEntryCount = batchEntries.length;
            } else if (t0 == SIG_EXECUTION_CONSUMED) {
                consumed[consumedCount] = abi.decode(logs[i].data, (Action));
                consumedHashes[consumedCount] = logs[i].topics[1];
                consumedCount++;
            } else if (t0 == SIG_L2TX_EXECUTED) {
                hasL2TX = true;
            } else if (t0 == SIG_CROSSCHAIN_CALL) {
                hasCCCall = true;
                ccActionHash = logs[i].topics[1];
                ccProxy = address(uint160(uint256(logs[i].topics[2])));
                (ccSource, ccCallData, ccValue) = abi.decode(logs[i].data, (address, bytes, uint256));
            }
        }

        // Print full detail
        _printFullDetail(
            batchEntries,
            consumed,
            consumedHashes,
            consumedCount,
            hasL2TX,
            l2txRollupId,
            l2txRlpData,
            l2txActionHash,
            hasCCCall,
            ccProxy,
            ccSource,
            ccCallData,
            ccValue,
            ccActionHash
        );

        // Print flow
        _printFlow(
            batchEntries,
            consumed,
            consumedHashes,
            consumedCount,
            hasL2TX,
            l2txRollupId,
            l2txRlpData,
            hasCCCall,
            ccSource,
            ccCallData
        );
    }

    // ──────────────────── Block processing ────────────────────

    function _processBlock(
        Vm.EthGetLogs[] memory logs
    ) internal view {
        if (logs.length == 0) {
            console.log("  (no events)");
            return;
        }

        // First pass: collect ALL batch entries from the block so cross-tx lookups work
        uint256 totalBatchCount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_BATCH_POSTED) {
                (ExecutionEntry[] memory entries,) = abi.decode(logs[i].data, (ExecutionEntry[], bytes32));
                totalBatchCount += entries.length;
            }
        }
        ExecutionEntry[] memory allBatchEntries = new ExecutionEntry[](totalBatchCount);
        uint256 idx;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_BATCH_POSTED) {
                (ExecutionEntry[] memory entries,) = abi.decode(logs[i].data, (ExecutionEntry[], bytes32));
                for (uint256 j = 0; j < entries.length; j++) {
                    allBatchEntries[idx++] = entries[j];
                }
            }
        }

        // Second pass: process each TX
        bytes32 currentTx = logs[0].transactionHash;
        uint256 txStart = 0;

        for (uint256 i = 0; i <= logs.length; i++) {
            bool newTx = (i == logs.length) || (logs[i].transactionHash != currentTx);
            if (newTx) {
                _processTxLogs(currentTx, logs, txStart, i, allBatchEntries);
                if (i < logs.length) {
                    currentTx = logs[i].transactionHash;
                    txStart = i;
                }
            }
        }
    }

    function _processTxLogs(
        bytes32 txHash,
        Vm.EthGetLogs[] memory logs,
        uint256 from,
        uint256 to,
        ExecutionEntry[] memory allBatchEntries
    ) internal view {
        // Collect data from this tx's logs
        ExecutionEntry[] memory localBatchEntries;
        Action[] memory consumed = new Action[](to - from);
        bytes32[] memory consumedHashes = new bytes32[](to - from);
        uint256 consumedCount;

        bool hasL2TX;
        uint256 l2txRollupId;
        bytes memory l2txRlpData;
        bytes32 l2txActionHash;
        bool hasCCCall;
        address ccProxy;
        address ccSource;
        bytes memory ccCallData;
        uint256 ccValue;
        bytes32 ccActionHash;

        for (uint256 i = from; i < to; i++) {
            bytes32 t0 = logs[i].topics[0];
            if (t0 == SIG_BATCH_POSTED) {
                (localBatchEntries,) = abi.decode(logs[i].data, (ExecutionEntry[], bytes32));
            } else if (t0 == SIG_EXECUTION_CONSUMED) {
                consumed[consumedCount] = abi.decode(logs[i].data, (Action));
                consumedHashes[consumedCount] = logs[i].topics[1];
                consumedCount++;
            } else if (t0 == SIG_L2TX_EXECUTED) {
                hasL2TX = true;
            } else if (t0 == SIG_CROSSCHAIN_CALL) {
                hasCCCall = true;
                ccActionHash = logs[i].topics[1];
                ccProxy = address(uint160(uint256(logs[i].topics[2])));
                (ccSource, ccCallData, ccValue) = abi.decode(logs[i].data, (address, bytes, uint256));
            }
        }

        console.log("");
        console.log("========================================");
        console.log("TX %s", vm.toString(txHash));
        console.log("========================================");

        // Full detail uses local batch entries (what was posted in THIS tx)
        _printFullDetail(
            localBatchEntries,
            consumed,
            consumedHashes,
            consumedCount,
            hasL2TX,
            l2txRollupId,
            l2txRlpData,
            l2txActionHash,
            hasCCCall,
            ccProxy,
            ccSource,
            ccCallData,
            ccValue,
            ccActionHash
        );

        // Flow/summary uses ALL batch entries from the block (cross-tx lookup)
        _printFlow(
            allBatchEntries,
            consumed,
            consumedHashes,
            consumedCount,
            hasL2TX,
            l2txRollupId,
            l2txRlpData,
            hasCCCall,
            ccSource,
            ccCallData
        );
    }

    // ──────────────────── Full detail section ────────────────────

    function _printFullDetail(
        ExecutionEntry[] memory batchEntries,
        Action[] memory consumed,
        bytes32[] memory consumedHashes,
        uint256 consumedCount,
        bool hasL2TX,
        uint256 l2txRollupId,
        bytes memory l2txRlpData,
        bytes32 l2txActionHash,
        bool hasCCCall,
        address ccProxy,
        address ccSource,
        bytes memory ccCallData,
        uint256 ccValue,
        bytes32 ccActionHash
    ) internal pure {
        // ── Batch entries ──
        if (batchEntries.length > 0) {
            console.log("");
            console.log("  BATCH POSTED (%s entries)", batchEntries.length);
            for (uint256 e = 0; e < batchEntries.length; e++) {
                _logBatchEntry(e, batchEntries[e]);
            }
        }

        // ── Trigger ──
        if (hasL2TX) {
            console.log("");
            console.log("  TRIGGER: L2TX");
            console.log("    actionHash: %s", vm.toString(l2txActionHash));
            console.log("    rollupId:   %s", l2txRollupId);
            console.log("    rlpData:    %s", vm.toString(l2txRlpData));
        }
        if (hasCCCall) {
            console.log("");
            console.log("  TRIGGER: CrossChainCall");
            console.log("    actionHash:    %s", vm.toString(ccActionHash));
            console.log("    proxy:         %s", vm.toString(ccProxy));
            console.log("    sourceAddress: %s", vm.toString(ccSource));
            console.log("    value:         %s", ccValue);
            console.log("    callData:      %s", vm.toString(ccCallData));
            _logSelector(ccCallData, "    ");
        }

        // ── Consumed executions ──
        if (consumedCount > 0) {
            console.log("");
            console.log("  EXECUTIONS CONSUMED (%s)", consumedCount);
            for (uint256 c = 0; c < consumedCount; c++) {
                console.log("    [%s] actionHash: %s", c, vm.toString(consumedHashes[c]));
                _logAction(consumed[c], "        ");
            }
        }
    }

    // ──────────────────── Flow chain section ────────────────────

    function _printFlow(
        ExecutionEntry[] memory batchEntries,
        Action[] memory consumed,
        bytes32[] memory consumedHashes,
        uint256 consumedCount,
        bool hasL2TX,
        uint256 l2txRollupId,
        bytes memory l2txRlpData,
        bool hasCCCall,
        address ccSource,
        bytes memory ccCallData
    ) internal pure {
        if (!hasL2TX && !hasCCCall) return;
        if (consumedCount == 0) return;

        console.log("");
        console.log("  ============ EXECUTION FLOW ============");
        console.log("");

        // Step 0: the trigger (only for L2TX — CrossChainCall IS the consumed CALL)
        if (hasL2TX) {
            console.log("  L2TX(rollup %s, %s)", l2txRollupId, vm.toString(l2txRlpData));
        }

        // Walk the chain: consumed[0] is the trigger action, its entry's nextAction leads to next step
        for (uint256 c = 0; c < consumedCount; c++) {
            Action memory act = consumed[c];
            bytes32 hash = consumedHashes[c];

            // Find the batch entry for this hash to get nextAction and stateDeltas
            (bool found, ExecutionEntry memory entry) = _findBatchEntry(batchEntries, hash);

            console.log("    |");

            // Print the consumed action as a step
            string memory stepLabel = _formatActionOneLiner(act);
            if (found && entry.stateDeltas.length > 0) {
                string memory deltaStr = _formatDeltas(entry.stateDeltas);
                console.log("    +-- [consumed] %s  %s", stepLabel, deltaStr);
            } else {
                console.log("    +-- [consumed] %s", stepLabel);
            }

            // Show what the next action will be (from batch)
            if (found) {
                string memory nextLabel = _formatActionOneLiner(entry.nextAction);
                console.log("    |     next -> %s", nextLabel);
            }
        }

        console.log("    |");
        console.log("    +-- END");

        // One-liner summary
        console.log("");
        console.log(
            "  SUMMARY: %s",
            _buildSummaryLine(
                consumed,
                consumedHashes,
                consumedCount,
                batchEntries,
                hasL2TX,
                l2txRollupId,
                l2txRlpData,
                hasCCCall,
                ccSource,
                ccCallData
            )
        );
        console.log("");
    }

    // ──────────────────── Flow formatting helpers ────────────────────

    function _formatActionOneLiner(
        Action memory a
    ) internal pure returns (string memory) {
        string memory typeName = _actionTypeName(a.actionType);

        if (a.actionType == ActionType.CALL) {
            string memory valStr = a.value > 0 ? string.concat(", val=", vm.toString(a.value)) : "";
            return string.concat(
                typeName,
                "(rollup ",
                vm.toString(a.rollupId),
                ", ",
                _shortAddr(a.destination),
                ".",
                _selectorName(a.data),
                ", from ",
                _shortAddr(a.sourceAddress),
                valStr,
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
        } else if (a.actionType == ActionType.L2TX) {
            return
                string.concat(
                    typeName, "(rollup ", vm.toString(a.rollupId), ", data=", _shortBytes(a.data), ")"
                );
        } else if (a.actionType == ActionType.REVERT || a.actionType == ActionType.REVERT_CONTINUE) {
            return string.concat(typeName, "(rollup ", vm.toString(a.rollupId), ")");
        }
        return typeName;
    }

    function _formatDeltas(
        StateDelta[] memory deltas
    ) internal pure returns (string memory) {
        string memory s = "[";
        for (uint256 i = 0; i < deltas.length; i++) {
            if (i > 0) s = string.concat(s, ", ");
            s = string.concat(
                s,
                "r",
                vm.toString(deltas[i].rollupId),
                ":",
                _shortHash(deltas[i].currentState),
                "->",
                _shortHash(deltas[i].newState)
            );
        }
        return string.concat(s, "]");
    }

    function _buildSummaryLine(
        Action[] memory consumed,
        bytes32[] memory,
        uint256 consumedCount,
        ExecutionEntry[] memory batchEntries,
        bool hasL2TX,
        uint256 l2txRollupId,
        bytes memory l2txRlpData,
        bool hasCCCall,
        address ccSource,
        bytes memory ccCallData
    ) internal pure returns (string memory line) {
        // Start with trigger (only for L2TX — CrossChainCall IS the consumed CALL, no separate prefix)
        if (hasL2TX) {
            line = string.concat("L2TX(r", vm.toString(l2txRollupId), ",", _shortBytes(l2txRlpData), ")");
        }

        // Chain consumed actions with their next actions
        for (uint256 c = 0; c < consumedCount; c++) {
            if (bytes(line).length > 0) {
                line = string.concat(line, " -> ", _tinyAction(consumed[c]));
            } else {
                line = _tinyAction(consumed[c]);
            }

            // Find next action from batch
            (bool found, ExecutionEntry memory entry) =
                _findBatchEntry(batchEntries, keccak256(abi.encode(consumed[c])));
            if (found) {
                // If nextAction is a CALL (L1 execution) and the next consumed is its RESULT, merge on same arrow
                if (
                    entry.nextAction.actionType == ActionType.CALL && c + 1 < consumedCount
                        && consumed[c + 1].actionType == ActionType.RESULT
                ) {
                    line = string.concat(
                        line, " -> ", _tinyAction(entry.nextAction), " - ", _tinyAction(consumed[c + 1])
                    );
                    c++; // skip the RESULT, already shown
                    // Also show the next action after the RESULT if available
                    (bool found2, ExecutionEntry memory entry2) =
                        _findBatchEntry(batchEntries, keccak256(abi.encode(consumed[c])));
                    if (found2) {
                        line = string.concat(line, " -> ", _tinyAction(entry2.nextAction));
                    }
                } else {
                    line = string.concat(line, " -> ", _tinyAction(entry.nextAction));
                }
            }
        }

        return line;
    }

    function _tinyAction(
        Action memory a
    ) internal pure returns (string memory) {
        if (a.actionType == ActionType.CALL) {
            string memory valStr = a.value > 0 ? string.concat(",val=", vm.toString(a.value)) : "";
            return string.concat("CALL(", _shortAddr(a.destination), ".", _selectorName(a.data), valStr, ")");
        } else if (a.actionType == ActionType.RESULT) {
            return string.concat("RESULT(", a.failed ? "fail" : "ok", ",", _shortBytes(a.data), ")");
        } else if (a.actionType == ActionType.L2TX) {
            return string.concat("L2TX(r", vm.toString(a.rollupId), ")");
        } else if (a.actionType == ActionType.REVERT) {
            return "REVERT";
        } else if (a.actionType == ActionType.REVERT_CONTINUE) {
            return "REVERT_CONTINUE";
        }
        return "?";
    }

    // ──────────────────── Batch lookup ────────────────────

    function _findBatchEntry(
        ExecutionEntry[] memory entries,
        bytes32 actionHash
    ) internal pure returns (bool, ExecutionEntry memory) {
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].actionHash == actionHash) return (true, entries[i]);
        }
        ExecutionEntry memory empty;
        return (false, empty);
    }

    // ──────────────────── Detail formatters ────────────────────

    function _logBatchEntry(
        uint256 e,
        ExecutionEntry memory entry
    ) internal pure {
        bool immediate = entry.actionHash == bytes32(0);
        console.log(
            "    [%s] %s  actionHash: %s",
            e,
            immediate ? "IMMEDIATE" : "DEFERRED",
            vm.toString(entry.actionHash)
        );
        for (uint256 d = 0; d < entry.stateDeltas.length; d++) {
            StateDelta memory delta = entry.stateDeltas[d];
            console.log(
                string.concat(
                    "        stateDelta: rollup ",
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
        if (!immediate) {
            console.log("        nextAction: %s", _formatActionOneLiner(entry.nextAction));
        }
    }

    function _logAction(
        Action memory a,
        string memory p
    ) internal pure {
        console.log(
            string.concat(
                p,
                _actionTypeName(a.actionType),
                " | rollup=",
                vm.toString(a.rollupId),
                " dest=",
                _shortAddr(a.destination),
                " val=",
                vm.toString(a.value)
            )
        );
        console.log(string.concat(p, "data=", vm.toString(a.data)));
        console.log(
            string.concat(
                p,
                "failed=",
                a.failed ? "true" : "false",
                " src=",
                _shortAddr(a.sourceAddress),
                " srcRollup=",
                vm.toString(a.sourceRollup),
                " scope=",
                _scopeToString(a.scope)
            )
        );
        _logSelector(a.data, p);
    }

    // ──────────────────── String helpers ────────────────────

    function _actionTypeName(
        ActionType t
    ) internal pure returns (string memory) {
        if (t == ActionType.CALL) return "CALL";
        if (t == ActionType.RESULT) return "RESULT";
        if (t == ActionType.L2TX) return "L2TX";
        if (t == ActionType.REVERT) return "REVERT";
        if (t == ActionType.REVERT_CONTINUE) return "REVERT_CONTINUE";
        return "UNKNOWN";
    }

    function _shortAddr(
        address a
    ) internal pure returns (string memory) {
        if (a == address(0)) return "0x0";
        string memory full = vm.toString(a);
        // Return 0x1234...5678 (first 6 + last 4)
        return string.concat(_substring(full, 0, 6), "..", _substring(full, 38, 42));
    }

    function _shortHash(
        bytes32 h
    ) internal pure returns (string memory) {
        string memory full = vm.toString(h);
        return string.concat(_substring(full, 0, 6), "..", _substring(full, 62, 66));
    }

    function _shortBytes(
        bytes memory b
    ) internal pure returns (string memory) {
        if (b.length == 0) return "0x";
        return vm.toString(b);
    }

    function _selectorName(
        bytes memory data
    ) internal pure returns (string memory) {
        if (data.length < 4) return "()";
        bytes4 sel =
            bytes4(data[0]) | (bytes4(data[1]) >> 8) | (bytes4(data[2]) >> 16) | (bytes4(data[3]) >> 24);
        if (sel == bytes4(keccak256("increment()"))) return "increment()";
        if (sel == bytes4(keccak256("decrement()"))) return "decrement()";
        if (sel == bytes4(keccak256("setNumber(uint256)"))) return "setNumber()";
        if (sel == bytes4(keccak256("incrementProxy()"))) return "incrementProxy()";
        // Return raw selector
        string memory full = vm.toString(abi.encodePacked(sel));
        return full;
    }

    function _logSelector(
        bytes memory data,
        string memory p
    ) internal pure {
        if (data.length < 4) return;
        string memory name = _selectorName(data);
        if (bytes(name).length > 10) {
            // Not a raw selector
            console.log(string.concat(p, "-> ", name));
        }
    }

    function _scopeToString(
        uint256[] memory scope
    ) internal pure returns (string memory) {
        string memory s = "[";
        for (uint256 i = 0; i < scope.length; i++) {
            if (i > 0) s = string.concat(s, ",");
            s = string.concat(s, vm.toString(scope[i]));
        }
        return string.concat(s, "]");
    }

    function _substring(
        string memory str,
        uint256 startIndex,
        uint256 endIndex
    ) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        if (endIndex > strBytes.length) endIndex = strBytes.length;
        if (startIndex >= endIndex) return "";
        bytes memory result = new bytes(endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            result[i - startIndex] = strBytes[i];
        }
        return string(result);
    }
}
