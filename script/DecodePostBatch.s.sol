// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ActionType, Action, StateDelta, ExecutionEntry} from "../src/ICrossChainManager.sol";

/// @title DecodePostBatch — Decode and pretty-print postBatch calldata
/// @dev Usage:
///   forge script script/DecodePostBatch.s.sol --sig "run(bytes)" 0x92cbb26e...
contract DecodePostBatch is Script {
    function run(bytes calldata rawCalldata) external pure {
        require(rawCalldata.length >= 4, "calldata too short");

        // Strip 4-byte selector
        bytes memory encoded = new bytes(rawCalldata.length - 4);
        for (uint256 i = 4; i < rawCalldata.length; i++) {
            encoded[i - 4] = rawCalldata[i];
        }

        (ExecutionEntry[] memory entries, uint256 blobCount, bytes memory callData_, bytes memory proof) =
            abi.decode(encoded, (ExecutionEntry[], uint256, bytes, bytes));

        console.log("========================================");
        console.log("         postBatch decoded");
        console.log("========================================");
        console.log("");

        // --- Top-level params ---
        console.log("blobCount:  %s", blobCount);
        console.log("callData:   %s (%s bytes)", _shortBytes(callData_), callData_.length);
        console.log("proof:      %s (%s bytes)", _shortBytes(proof), proof.length);
        console.log("entries:    %s", entries.length);
        console.log("");

        // --- Entries ---
        for (uint256 i = 0; i < entries.length; i++) {
            _printEntry(i, entries[i]);
        }

        console.log("========================================");
    }

    function _printEntry(uint256 idx, ExecutionEntry memory entry) internal pure {
        bool immediate = entry.actionHash == bytes32(0);
        console.log("--- Entry [%s] %s ---", idx, immediate ? "IMMEDIATE" : "DEFERRED");
        console.log("  actionHash: %s", vm.toString(entry.actionHash));

        // State deltas
        if (entry.stateDeltas.length == 0) {
            console.log("  stateDeltas: (none)");
        } else {
            console.log("  stateDeltas: %s", entry.stateDeltas.length);
            for (uint256 d = 0; d < entry.stateDeltas.length; d++) {
                StateDelta memory delta = entry.stateDeltas[d];
                console.log("    [%s] rollupId:     %s", d, delta.rollupId);
                console.log("        currentState:  %s", vm.toString(delta.currentState));
                console.log("        newState:      %s", vm.toString(delta.newState));
                console.log("        etherDelta:    %s", vm.toString(delta.etherDelta));
            }
        }

        // Next action
        console.log("  nextAction:");
        _printAction(entry.nextAction);
        console.log("");
    }

    function _printAction(Action memory a) internal pure {
        console.log("    actionType:    %s", _typeName(a.actionType));
        console.log("    rollupId:      %s", a.rollupId);
        console.log("    destination:   %s", vm.toString(a.destination));
        console.log("    value:         %s", a.value);
        console.log("    data:          %s (%s bytes)", _shortBytes(a.data), a.data.length);
        console.log("    failed:        %s", a.failed ? "true" : "false");
        console.log("    sourceAddress: %s", vm.toString(a.sourceAddress));
        console.log("    sourceRollup:  %s", a.sourceRollup);

        if (a.scope.length == 0) {
            console.log("    scope:         []");
        } else {
            string memory scopeStr = "[";
            for (uint256 i = 0; i < a.scope.length; i++) {
                if (i > 0) scopeStr = string.concat(scopeStr, ", ");
                scopeStr = string.concat(scopeStr, vm.toString(a.scope[i]));
            }
            scopeStr = string.concat(scopeStr, "]");
            console.log("    scope:         %s", scopeStr);
        }

        // If CALL, try to show the 4-byte selector
        if (a.actionType == ActionType.CALL && a.data.length >= 4) {
            bytes4 sel;
            assembly {
                sel := mload(add(a, 0x20))
            }
            sel = bytes4(a.data[0]) | (bytes4(a.data[1]) >> 8) | (bytes4(a.data[2]) >> 16) | (bytes4(a.data[3]) >> 24);
            console.log("    selector:      %s", vm.toString(sel));
        }
    }

    function _typeName(ActionType t) internal pure returns (string memory) {
        if (t == ActionType.CALL) return "CALL";
        if (t == ActionType.RESULT) return "RESULT";
        if (t == ActionType.L2TX) return "L2TX";
        if (t == ActionType.REVERT) return "REVERT";
        if (t == ActionType.REVERT_CONTINUE) return "REVERT_CONTINUE";
        return "UNKNOWN";
    }

    function _shortBytes(bytes memory b) internal pure returns (string memory) {
        if (b.length == 0) return "0x";
        if (b.length <= 36) return vm.toString(b);
        string memory full = vm.toString(b);
        bytes memory fb = bytes(full);
        // first 10 chars (0x + 4 bytes)
        bytes memory prefix = new bytes(10);
        for (uint256 i = 0; i < 10 && i < fb.length; i++) prefix[i] = fb[i];
        return string.concat(string(prefix), "...");
    }
}
