// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {
    StateDelta,
    CrossChainCall,
    NestedAction,
    StaticCall,
    ExecutionEntry
} from "../src/ICrossChainManager.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title DecodeExecutions
/// @notice Decodes cross-chain events from a block and shows execution flow
/// @dev Usage:
///   forge script script/DecodeExecutions.s.sol:DecodeExecutions --rpc-url <RPC> --sig "runBlock(uint256,address)" <BLOCK> <CONTRACT>
contract DecodeExecutions is Script {
    bytes32 constant SIG_CROSSCHAIN_CALL =
        keccak256("CrossChainCallExecuted(bytes32,address,address,bytes,uint256)");
    bytes32 constant SIG_EXECUTION_CONSUMED =
        keccak256("ExecutionConsumed(bytes32,uint256)");
    bytes32 constant SIG_L2TX_EXECUTED =
        keccak256("L2TXExecuted(uint256)");
    bytes32 constant SIG_L2_EXECUTION_PERFORMED =
        keccak256("L2ExecutionPerformed(uint256,bytes32)");
    bytes32 constant SIG_BATCH_POSTED = keccak256(
        "BatchPosted(((uint256,bytes32,int256)[],bytes32,(address,uint256,bytes,address,uint256,uint256)[],(bytes32,uint256,bytes)[],uint256,bytes,bool,bytes32)[],bytes32)"
    );
    bytes32 constant SIG_CALL_RESULT =
        keccak256("CallResult(uint256,uint256,bool,bytes)");
    bytes32 constant SIG_NESTED_ACTION_CONSUMED =
        keccak256("NestedActionConsumed(uint256,uint256,bytes32,uint256)");
    bytes32 constant SIG_ENTRY_EXECUTED =
        keccak256("EntryExecuted(uint256,bytes32,uint256,uint256)");

    // ── Collected data per tx ──
    struct TxData {
        bytes32 txHash;
        ExecutionEntry[] batchEntries;
        bytes32[] consumedHashes;
        uint256[] consumedEntryIndices;
        uint256 consumedCount;
        bool hasL2TX;
        uint256 l2txEntryIndex;
        bool hasCrossChainCall;
        address ccProxy;
        address ccSourceAddress;
        bytes ccCallData;
        uint256 ccValue;
        bytes32 ccActionHash;
    }

    // ──────────────────── Entry point ────────────────────

    function runBlock(uint256 blockNumber, address target) external view {
        bytes32[] memory topics = new bytes32[](0);
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(blockNumber, blockNumber, target, topics);

        console.log("================================================================");
        console.log("BLOCK %s | %s logs | target %s", blockNumber, logs.length, vm.toString(target));
        console.log("================================================================");

        _processBlock(logs);
    }

    function decodeRecordedLogs(Vm.Log[] memory logs) external view {
        console.log("================================================================");
        console.log("RECORDED LOGS | %s logs", logs.length);
        console.log("================================================================");

        ExecutionEntry[] memory batchEntries;
        bytes32[] memory consumedHashes = new bytes32[](logs.length);
        uint256[] memory consumedEntryIndices = new uint256[](logs.length);
        uint256 consumedCount;

        bool hasL2TX;
        uint256 l2txEntryIndex;
        bool hasCCCall;
        address ccProxy;
        address ccSource;
        bytes memory ccCallData;
        bytes32 ccActionHash;

        for (uint256 i = 0; i < logs.length; i++) {
            bytes32 t0 = logs[i].topics[0];
            if (t0 == SIG_BATCH_POSTED) {
                (batchEntries,) = abi.decode(logs[i].data, (ExecutionEntry[], bytes32));
            } else if (t0 == SIG_EXECUTION_CONSUMED) {
                consumedHashes[consumedCount] = logs[i].topics[1];
                consumedEntryIndices[consumedCount] = uint256(logs[i].topics[2]);
                consumedCount++;
            } else if (t0 == SIG_L2TX_EXECUTED) {
                hasL2TX = true;
                l2txEntryIndex = uint256(logs[i].topics[1]);
            } else if (t0 == SIG_CROSSCHAIN_CALL) {
                hasCCCall = true;
                ccActionHash = logs[i].topics[1];
                ccProxy = address(uint160(uint256(logs[i].topics[2])));
                (ccSource, ccCallData,) = abi.decode(logs[i].data, (address, bytes, uint256));
            }
        }

        _printFullDetail(
            batchEntries, consumedHashes, consumedEntryIndices, consumedCount,
            hasL2TX, l2txEntryIndex, hasCCCall, ccProxy, ccSource, ccCallData, ccActionHash
        );

        _printFlow(
            batchEntries, consumedHashes, consumedEntryIndices, consumedCount,
            hasL2TX, l2txEntryIndex, hasCCCall, ccSource, ccCallData
        );
    }

    // ──────────────────── Block processing ────────────────────

    function _processBlock(Vm.EthGetLogs[] memory logs) internal view {
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
        ExecutionEntry[] memory localBatchEntries;
        bytes32[] memory consumedHashes = new bytes32[](to - from);
        uint256[] memory consumedEntryIndices = new uint256[](to - from);
        uint256 consumedCount;

        bool hasL2TX;
        uint256 l2txEntryIndex;
        bool hasCCCall;
        address ccProxy;
        address ccSource;
        bytes memory ccCallData;
        bytes32 ccActionHash;

        for (uint256 i = from; i < to; i++) {
            bytes32 t0 = logs[i].topics[0];
            if (t0 == SIG_BATCH_POSTED) {
                (localBatchEntries,) = abi.decode(logs[i].data, (ExecutionEntry[], bytes32));
            } else if (t0 == SIG_EXECUTION_CONSUMED) {
                consumedHashes[consumedCount] = logs[i].topics[1];
                consumedEntryIndices[consumedCount] = uint256(logs[i].topics[2]);
                consumedCount++;
            } else if (t0 == SIG_L2TX_EXECUTED) {
                hasL2TX = true;
                l2txEntryIndex = uint256(logs[i].topics[1]);
            } else if (t0 == SIG_CROSSCHAIN_CALL) {
                hasCCCall = true;
                ccActionHash = logs[i].topics[1];
                ccProxy = address(uint160(uint256(logs[i].topics[2])));
                (ccSource, ccCallData,) = abi.decode(logs[i].data, (address, bytes, uint256));
            }
        }

        console.log("");
        console.log("========================================");
        console.log("TX %s", vm.toString(txHash));
        console.log("========================================");

        _printFullDetail(
            localBatchEntries, consumedHashes, consumedEntryIndices, consumedCount,
            hasL2TX, l2txEntryIndex, hasCCCall, ccProxy, ccSource, ccCallData, ccActionHash
        );

        _printFlow(
            allBatchEntries, consumedHashes, consumedEntryIndices, consumedCount,
            hasL2TX, l2txEntryIndex, hasCCCall, ccSource, ccCallData
        );
    }

    // ──────────────────── Full detail section ────────────────────

    function _printFullDetail(
        ExecutionEntry[] memory batchEntries,
        bytes32[] memory consumedHashes,
        uint256[] memory consumedEntryIndices,
        uint256 consumedCount,
        bool hasL2TX,
        uint256 l2txEntryIndex,
        bool hasCCCall,
        address ccProxy,
        address ccSource,
        bytes memory ccCallData,
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
            console.log("    entryIndex: %s", l2txEntryIndex);
        }
        if (hasCCCall) {
            console.log("");
            console.log("  TRIGGER: CrossChainCall");
            console.log("    actionHash:    %s", vm.toString(ccActionHash));
            console.log("    proxy:         %s", vm.toString(ccProxy));
            console.log("    sourceAddress: %s", vm.toString(ccSource));
            console.log("    callData:      %s", vm.toString(ccCallData));
            _logSelector(ccCallData, "    ");
        }

        // ── Consumed executions ──
        if (consumedCount > 0) {
            console.log("");
            console.log("  EXECUTIONS CONSUMED (%s)", consumedCount);
            for (uint256 c = 0; c < consumedCount; c++) {
                console.log(
                    "    [%s] actionHash: %s  entryIndex: %s",
                    c, vm.toString(consumedHashes[c]), consumedEntryIndices[c]
                );
            }
        }
    }

    // ──────────────────── Flow chain section ────────────────────

    function _printFlow(
        ExecutionEntry[] memory batchEntries,
        bytes32[] memory consumedHashes,
        uint256[] memory,
        uint256 consumedCount,
        bool hasL2TX,
        uint256 l2txEntryIndex,
        bool hasCCCall,
        address ccSource,
        bytes memory ccCallData
    ) internal pure {
        if (!hasL2TX && !hasCCCall) return;
        if (consumedCount == 0 && !hasL2TX) return;

        console.log("");
        console.log("  ============ EXECUTION FLOW ============");
        console.log("");

        if (hasL2TX) {
            console.log("  L2TX(entryIndex %s)", l2txEntryIndex);
        }
        if (hasCCCall) {
            console.log("  CrossChainCall(src=%s, %s)", _shortAddr(ccSource), _shortBytes(ccCallData));
        }

        for (uint256 c = 0; c < consumedCount; c++) {
            bytes32 hash = consumedHashes[c];
            (bool found, ExecutionEntry memory entry) = _findBatchEntry(batchEntries, hash);

            console.log("    |");

            if (found) {
                string memory deltaStr = _formatDeltas(entry.stateDeltas);
                console.log(
                    string.concat(
                        "    +-- [consumed] actionHash=", _shortHash(hash),
                        "  calls=", vm.toString(entry.calls.length),
                        "  nested=", vm.toString(entry.nestedActions.length),
                        "  ", deltaStr
                    )
                );
                if (entry.calls.length > 0) {
                    for (uint256 i = 0; i < entry.calls.length; i++) {
                        CrossChainCall memory cc = entry.calls[i];
                        console.log(
                            string.concat(
                                "    |     call[", vm.toString(i), "]: ",
                                _shortAddr(cc.destination), ".", _selectorName(cc.data),
                                " from=", _shortAddr(cc.sourceAddress),
                                " revertSpan=", vm.toString(cc.revertSpan)
                            )
                        );
                    }
                }
                if (entry.nestedActions.length > 0) {
                    for (uint256 i = 0; i < entry.nestedActions.length; i++) {
                        NestedAction memory na = entry.nestedActions[i];
                        console.log(
                            string.concat(
                                "    |     nested[", vm.toString(i), "]: actionHash=",
                                _shortHash(na.actionHash),
                                "  callCount=", vm.toString(na.callCount)
                            )
                        );
                    }
                }
                if (entry.returnData.length > 0) {
                    console.log("    |     returnData: %s", _shortBytes(entry.returnData));
                }
                console.log("    |     rollingHash: %s", _shortHash(entry.rollingHash));
            } else {
                console.log("    +-- [consumed] actionHash=%s  (not found in batch)", _shortHash(hash));
            }
        }

        console.log("    |");
        console.log("    +-- END");

        // One-liner summary
        console.log("");
        console.log(
            "  SUMMARY: %s",
            _buildSummaryLine(
                consumedHashes, consumedCount, batchEntries,
                hasL2TX, l2txEntryIndex, hasCCCall, ccSource, ccCallData
            )
        );
        console.log("");
    }

    // ──────────────────── Flow formatting helpers ────────────────────

    function _formatDeltas(StateDelta[] memory deltas) internal pure returns (string memory) {
        if (deltas.length == 0) return "[]";
        string memory s = "[";
        for (uint256 i = 0; i < deltas.length; i++) {
            if (i > 0) s = string.concat(s, ", ");
            s = string.concat(
                s,
                "r", vm.toString(deltas[i].rollupId), ":",
                _shortHash(deltas[i].newState),
                " ether:", vm.toString(deltas[i].etherDelta)
            );
        }
        return string.concat(s, "]");
    }

    function _buildSummaryLine(
        bytes32[] memory consumedHashes,
        uint256 consumedCount,
        ExecutionEntry[] memory batchEntries,
        bool hasL2TX,
        uint256 l2txEntryIndex,
        bool hasCCCall,
        address ccSource,
        bytes memory ccCallData
    ) internal pure returns (string memory line) {
        if (hasL2TX) {
            line = string.concat("L2TX(entry=", vm.toString(l2txEntryIndex), ")");
        }
        if (hasCCCall) {
            string memory trigger = string.concat(
                "CCCall(", _shortAddr(ccSource), ",", _selectorName(ccCallData), ")"
            );
            if (bytes(line).length > 0) {
                line = string.concat(line, " -> ", trigger);
            } else {
                line = trigger;
            }
        }

        for (uint256 c = 0; c < consumedCount; c++) {
            (bool found, ExecutionEntry memory entry) = _findBatchEntry(batchEntries, consumedHashes[c]);
            string memory entryStr;
            if (found) {
                entryStr = string.concat(
                    "Entry(calls=", vm.toString(entry.calls.length),
                    ",nested=", vm.toString(entry.nestedActions.length),
                    ",deltas=", vm.toString(entry.stateDeltas.length), ")"
                );
            } else {
                entryStr = string.concat("Entry(", _shortHash(consumedHashes[c]), ")");
            }
            if (bytes(line).length > 0) {
                line = string.concat(line, " -> ", entryStr);
            } else {
                line = entryStr;
            }
        }

        return line;
    }

    // ──────────────────── Batch lookup ────────────────────

    function _findBatchEntry(ExecutionEntry[] memory entries, bytes32 actionHash)
        internal
        pure
        returns (bool, ExecutionEntry memory)
    {
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].actionHash == actionHash) return (true, entries[i]);
        }
        ExecutionEntry memory empty;
        return (false, empty);
    }

    // ──────────────────── Detail formatters ────────────────────

    function _logBatchEntry(uint256 e, ExecutionEntry memory entry) internal pure {
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
                    "        stateDelta: rollup ", vm.toString(delta.rollupId),
                    "  -> ", _shortHash(delta.newState),
                    "  ether: ", vm.toString(delta.etherDelta)
                )
            );
        }
        console.log("        callCount: %s  calls: %s  nestedActions: %s", entry.callCount, entry.calls.length, entry.nestedActions.length);
        for (uint256 i = 0; i < entry.calls.length; i++) {
            CrossChainCall memory cc = entry.calls[i];
            console.log(
                string.concat(
                    "        call[", vm.toString(i), "]: ",
                    _shortAddr(cc.destination), ".", _selectorName(cc.data),
                    " from=", _shortAddr(cc.sourceAddress),
                    " srcRollup=", vm.toString(cc.sourceRollup),
                    " val=", vm.toString(cc.value),
                    " revertSpan=", vm.toString(cc.revertSpan)
                )
            );
        }
        for (uint256 i = 0; i < entry.nestedActions.length; i++) {
            NestedAction memory na = entry.nestedActions[i];
            console.log(
                string.concat(
                    "        nested[", vm.toString(i), "]: actionHash=",
                    _shortHash(na.actionHash),
                    " callCount=", vm.toString(na.callCount),
                    " returnData=", _shortBytes(na.returnData)
                )
            );
        }
        if (entry.returnData.length > 0) {
            console.log("        returnData: %s", vm.toString(entry.returnData));
        }
        console.log("        failed: %s  rollingHash: %s", entry.failed ? "true" : "false", _shortHash(entry.rollingHash));
    }

    // ──────────────────── String helpers ────────────────────

    function _shortAddr(address a) internal pure returns (string memory) {
        if (a == address(0)) return "0x0";
        string memory full = vm.toString(a);
        return string.concat(_substring(full, 0, 6), "..", _substring(full, 38, 42));
    }

    function _shortHash(bytes32 h) internal pure returns (string memory) {
        string memory full = vm.toString(h);
        return string.concat(_substring(full, 0, 6), "..", _substring(full, 62, 66));
    }

    function _shortBytes(bytes memory b) internal pure returns (string memory) {
        if (b.length == 0) return "0x";
        return vm.toString(b);
    }

    function _selectorName(bytes memory data) internal pure returns (string memory) {
        if (data.length < 4) return "()";
        bytes4 sel = bytes4(data[0]) | (bytes4(data[1]) >> 8) | (bytes4(data[2]) >> 16) | (bytes4(data[3]) >> 24);
        if (sel == bytes4(keccak256("increment()"))) return "increment()";
        if (sel == bytes4(keccak256("decrement()"))) return "decrement()";
        if (sel == bytes4(keccak256("setNumber(uint256)"))) return "setNumber()";
        if (sel == bytes4(keccak256("incrementProxy()"))) return "incrementProxy()";
        if (sel == bytes4(keccak256("receiveTokens(address,uint256,address,uint256,string,string,uint8,uint256)"))) return "receiveTokens()";
        if (sel == bytes4(keccak256("claimAndBridgeBack(address,address,address,uint256,address)"))) return "claimAndBridgeBack()";
        if (sel == bytes4(keccak256("bridgeTokens(address,uint256,uint256,address)"))) return "bridgeTokens()";
        if (sel == bytes4(keccak256("bridgeEther(uint256,address)"))) return "bridgeEther()";
        string memory full = vm.toString(abi.encodePacked(sel));
        return full;
    }

    function _logSelector(bytes memory data, string memory p) internal pure {
        if (data.length < 4) return;
        string memory name = _selectorName(data);
        if (bytes(name).length > 10) {
            console.log(string.concat(p, "-> ", name));
        }
    }

    function _substring(string memory str, uint256 startIndex, uint256 endIndex)
        internal
        pure
        returns (string memory)
    {
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
