// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";

/// @title ComputeExpectedBase — Shared formatting helpers for ComputeExpected contracts
/// @dev Each test's ComputeExpected inherits this and overrides _name() and _funcName().
abstract contract ComputeExpectedBase is Script {
    // ── Entry hash: encodes both actionHash and nextAction ──

    /// @dev Computes the entry hash used by VerifyL1Batch/VerifyL2Blocks for matching.
    ///   Encodes both the trigger (actionHash) and the response (nextAction).
    function _entryHash(bytes32 actionHash, Action memory nextAction) internal pure returns (bytes32) {
        return keccak256(abi.encode(actionHash, keccak256(abi.encode(nextAction))));
    }

    // ── Address-to-name mapping (override per test) ──

    /// @dev Override to map deployed addresses to human-readable names.
    ///   Fallback: short hex address.
    function _name(address a) internal view virtual returns (string memory) {
        return _shortAddr(a);
    }

    /// @dev Override to map 4-byte selectors to function names.
    ///   Fallback: raw hex selector.
    function _funcName(bytes4 sel) internal pure virtual returns (string memory) {
        return vm.toString(bytes32(sel));
    }

    // ── CALL formatting ──

    function _fmtCall(Action memory a) internal view returns (string memory) {
        string memory func;
        if (a.data.length == 0) {
            func = "(ETH transfer)";
        } else {
            bytes4 sel = bytes4(a.data);
            func = string.concat(".", _funcName(sel), "()");
        }

        string memory valStr = "";
        if (a.value > 0) {
            valStr = string.concat("  value=", _fmtEther(a.value));
        }

        return string.concat(
            "CALL ",
            _name(a.destination),
            func,
            valStr,
            "\n                from ",
            _name(a.sourceAddress),
            " @ rollup ",
            vm.toString(a.sourceRollup),
            _fmtScope(a.scope)
        );
    }

    // ── RESULT formatting ──

    /// @param decoded Human-readable decoded value, e.g. "uint256(1)" or "(void)"
    function _fmtResult(Action memory a, string memory decoded) internal pure returns (string memory) {
        return string.concat("RESULT ", a.failed ? "FAILED" : "ok", " -> ", decoded);
    }

    // ── L2TX formatting ──

    function _fmtL2TX(Action memory a) internal pure returns (string memory) {
        return string.concat(
            "L2TX rollup=",
            vm.toString(a.rollupId),
            "  rlpTx=",
            vm.toString(a.data),
            " (",
            vm.toString(a.data.length),
            " bytes)"
        );
    }

    // ── Full entry formatting ──

    /// @param triggerDesc What action triggers this entry (the action whose hash = actionHash)
    /// @param responseDesc What action is returned (nextAction formatted)
    function _logEntry(
        uint256 idx,
        bytes32 hash,
        StateDelta[] memory deltas,
        string memory triggerDesc,
        string memory responseDesc
    ) internal pure {
        console.log("  [%s] DEFERRED", idx);
        console.log(string.concat("      trigger:  ", triggerDesc));
        console.log("      hash:     %s", _shortHash(hash));
        for (uint256 d = 0; d < deltas.length; d++) {
            string memory etherStr =
                deltas[d].etherDelta == 0 ? "" : string.concat("  ether: ", _fmtEtherSigned(deltas[d].etherDelta));
            console.log(
                string.concat(
                    "      state:    rollup ",
                    vm.toString(deltas[d].rollupId),
                    "  ",
                    _shortHash(deltas[d].currentState),
                    " -> ",
                    _shortHash(deltas[d].newState),
                    etherStr
                )
            );
        }
        console.log(string.concat("      returns:  ", responseDesc));
    }

    /// L2 table entry (no state deltas)
    function _logL2Entry(uint256 idx, bytes32 hash, string memory triggerDesc, string memory responseDesc)
        internal
        pure
    {
        console.log("  [%s] trigger:  %s", idx, triggerDesc);
        console.log("      hash:     %s", _shortHash(hash));
        console.log(string.concat("      returns:  ", responseDesc));
    }

    /// L2 call entry
    function _logL2Call(uint256 idx, bytes32 hash, Action memory a) internal view {
        string memory func;
        if (a.data.length == 0) {
            func = "(ETH transfer)";
        } else {
            func = string.concat(".", _funcName(bytes4(a.data)), "()");
        }
        string memory valStr = a.value > 0 ? string.concat("  value=", _fmtEther(a.value)) : "";
        console.log(string.concat("  [", vm.toString(idx), "] ", _name(a.destination), func, valStr));
        console.log(
            string.concat("      from ", _name(a.sourceAddress), " @ rollup ", vm.toString(a.sourceRollup))
        );
        console.log("      hash: %s", _shortHash(hash));
    }

    // ── Summary helpers ──

    function _chainName(uint256 rollupId) internal pure returns (string memory) {
        if (rollupId == 0) return "L1";
        if (rollupId == 1) return "L2";
        return string.concat("rollup ", vm.toString(rollupId));
    }

    function _summaryAction(Action memory a) internal view returns (string memory) {
        if (a.actionType == ActionType.CALL) {
            string memory func;
            if (a.data.length == 0) {
                func = "(ETH transfer)";
            } else {
                func = string.concat(_name(a.destination), ".", _funcName(bytes4(a.data)), "()");
            }
            return string.concat("Call --> ", _chainName(a.rollupId), " (", func, ")");
        } else if (a.actionType == ActionType.RESULT) {
            return string.concat("Result ", a.failed ? "FAILED" : "ok");
        } else if (a.actionType == ActionType.L2TX) {
            return string.concat("L2TX rollup ", _chainName(a.rollupId));
        } else if (a.actionType == ActionType.REVERT) {
            return "Revert";
        } else if (a.actionType == ActionType.REVERT_CONTINUE) {
            return "RevertContinue";
        }
        return "?";
    }

    function _logEntrySummary(uint256 idx, Action memory trigger, Action memory response, bool isTerminal)
        internal
        view
    {
        string memory terminal = isTerminal ? " (terminal)" : "";
        console.log(
            string.concat(
                "  [", vm.toString(idx), "] ", _summaryAction(trigger), ", next: ", _summaryAction(response), terminal
            )
        );
    }

    // ── Primitives ──

    function _shortHash(bytes32 h) internal pure returns (string memory) {
        string memory full = vm.toString(h);
        return string.concat(_sub(full, 0, 6), "..", _sub(full, 62, 66));
    }

    function _shortAddr(address a) internal pure returns (string memory) {
        string memory full = vm.toString(a);
        return string.concat(_sub(full, 0, 6), "..", _sub(full, 38, 42));
    }

    function _fmtEther(uint256 wei_) internal pure returns (string memory) {
        if (wei_ == 0) return "0";
        if (wei_ % 1 ether == 0) {
            return string.concat(vm.toString(wei_ / 1 ether), " ETH");
        }
        return string.concat(vm.toString(wei_), " wei");
    }

    function _fmtEtherSigned(int256 wei_) internal pure returns (string memory) {
        if (wei_ >= 0) {
            return string.concat("+", _fmtEther(uint256(wei_)));
        }
        return string.concat("-", _fmtEther(uint256(-wei_)));
    }

    function _fmtScope(uint256[] memory scope) internal pure returns (string memory) {
        if (scope.length == 0) return "";
        string memory s = "  scope=[";
        for (uint256 i = 0; i < scope.length; i++) {
            if (i > 0) s = string.concat(s, ",");
            s = string.concat(s, vm.toString(scope[i]));
        }
        return string.concat(s, "]");
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
}
