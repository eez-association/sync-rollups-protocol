// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta, ICrossChainManager} from "../../../src/ICrossChainManager.sol";
import {ReentrantCounter} from "../../../test/mocks/ReentrantCounter.sol";
import {getOrCreateProxy} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  reentrantCrossChainCalls — 5 reentrant cross-chain hops (L1-starting)
//
//  L1.deepCall(5) ─CC1─▶ L2.deepCall(4) ─CC2─▶ L1.deepCall(3) ─CC3─▶
//  L2.deepCall(2) ─CC4─▶ L1.deepCall(1) ─CC5─▶ L2.deepCall(0)
//
//  Same ReentrantCounter contract on both chains. Each invocation:
//    if (remainingCalls > 0) peer.deepCall(remainingCalls - 1);
//    return ++count;
//
//  Count increments bottom-up (innermost first):
//    L2: deepCall(0)→1, deepCall(2)→2, deepCall(4)→3
//    L1: deepCall(1)→1, deepCall(3)→2, deepCall(5)→3
//
//  On L1 (3 reentrant executeCrossChainCall + 2 scoped executions):
//    [0] CALL L2 deepCall(4) → CALL L1 deepCall(3) scope=[0]    s0→s1
//    [1] CALL L2 deepCall(2) → CALL L1 deepCall(1) scope=[0]    s1→s2
//    [2] CALL L2 deepCall(0) → RESULT(L2, 1)                    s2→s3
//    [3] RESULT(L1, 1)       → RESULT(L2, 2)                    s3→s4
//    [4] RESULT(L1, 2)       → RESULT(L2, 3)                    s4→s5
//
//  On L2 (2 executeCrossChainCall + 2 scoped deliveries + terminal):
//    [0] CALL L1 deepCall(3) → CALL L2 deepCall(2) scope=[0]
//    [1] CALL L1 deepCall(1) → CALL L2 deepCall(0) scope=[0]
//    [2] RESULT(L2, 1)       → RESULT(L1, 1)
//    [3] RESULT(L2, 2)       → RESULT(L1, 2)
//    [4] RESULT(L2, 3)       → RESULT(L2, 3)  [terminal]
// ═══════════════════════════════════════════════════════════════════════

/// @dev Centralized action & entry definitions for the reentrantCrossChainCalls scenario.
abstract contract ReentrantCrossChainActions {
    uint256 internal constant L2_ROLLUP_ID = 1;
    uint256 internal constant MAINNET_ROLLUP_ID = 0;

    // ── Action builders ──

    /// @dev CALL from L1→L2: DC_L1 calls proxy for DC_L2 on L1 (scope always [])
    function _callL1ToL2(address dcL2, address dcL1, uint256 remainingCalls)
        internal
        pure
        returns (Action memory)
    {
        return Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: dcL2,
            value: 0,
            data: abi.encodeWithSelector(ReentrantCounter.deepCall.selector, remainingCalls),
            failed: false,
            sourceAddress: dcL1,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });
    }

    /// @dev CALL from L2→L1: DC_L2 calls proxy for DC_L1 on L2
    function _callL2ToL1(address dcL1, address dcL2, uint256 remainingCalls, uint256[] memory scope)
        internal
        pure
        returns (Action memory)
    {
        return Action({
            actionType: ActionType.CALL,
            rollupId: MAINNET_ROLLUP_ID,
            destination: dcL1,
            value: 0,
            data: abi.encodeWithSelector(ReentrantCounter.deepCall.selector, remainingCalls),
            failed: false,
            sourceAddress: dcL2,
            sourceRollup: L2_ROLLUP_ID,
            scope: scope
        });
    }

    /// @dev CALL from L1→L2 delivered via scope navigation on L2
    function _callL1ToL2Scoped(address dcL2, address dcL1, uint256 remainingCalls, uint256[] memory scope)
        internal
        pure
        returns (Action memory)
    {
        return Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: dcL2,
            value: 0,
            data: abi.encodeWithSelector(ReentrantCounter.deepCall.selector, remainingCalls),
            failed: false,
            sourceAddress: dcL1,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: scope
        });
    }

    function _resultL2(uint256 val) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: abi.encode(val),
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    function _resultMainnet(uint256 val) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: MAINNET_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: abi.encode(val),
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    // ── Entry builders ──

    function _l1Entries(address dcL1, address dcL2) internal pure returns (ExecutionEntry[] memory entries) {
        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;

        // State chain: s0 → s1 → s2 → s3 → s4 → s5
        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-reentrant-step1");
        bytes32 s2 = keccak256("l2-state-reentrant-step2");
        bytes32 s3 = keccak256("l2-state-reentrant-step3");
        bytes32 s4 = keccak256("l2-state-reentrant-step4");
        bytes32 s5 = keccak256("l2-state-reentrant-step5");

        entries = new ExecutionEntry[](5);

        // [0] CALL(L2, deepCall(4)) → CALL(MAINNET, deepCall(3), scope=[0])
        entries[0].stateDeltas = _delta(L2_ROLLUP_ID, s0, s1);
        entries[0].actionHash = keccak256(abi.encode(_callL1ToL2(dcL2, dcL1, 4)));
        entries[0].nextAction = _callL2ToL1(dcL1, dcL2, 3, scope0);

        // [1] CALL(L2, deepCall(2)) → CALL(MAINNET, deepCall(1), scope=[0])
        entries[1].stateDeltas = _delta(L2_ROLLUP_ID, s1, s2);
        entries[1].actionHash = keccak256(abi.encode(_callL1ToL2(dcL2, dcL1, 2)));
        entries[1].nextAction = _callL2ToL1(dcL1, dcL2, 1, scope0);

        // [2] CALL(L2, deepCall(0)) → RESULT(L2, 1)
        entries[2].stateDeltas = _delta(L2_ROLLUP_ID, s2, s3);
        entries[2].actionHash = keccak256(abi.encode(_callL1ToL2(dcL2, dcL1, 0)));
        entries[2].nextAction = _resultL2(1);

        // [3] RESULT(MAINNET, 1) → RESULT(L2, 2)
        entries[3].stateDeltas = _delta(L2_ROLLUP_ID, s3, s4);
        entries[3].actionHash = keccak256(abi.encode(_resultMainnet(1)));
        entries[3].nextAction = _resultL2(2);

        // [4] RESULT(MAINNET, 2) → RESULT(L2, 3)
        entries[4].stateDeltas = _delta(L2_ROLLUP_ID, s4, s5);
        entries[4].actionHash = keccak256(abi.encode(_resultMainnet(2)));
        entries[4].nextAction = _resultL2(3);
    }

    function _l2Entries(address dcL1, address dcL2) internal pure returns (ExecutionEntry[] memory entries) {
        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;
        uint256[] memory noScope = new uint256[](0);

        entries = new ExecutionEntry[](5);

        // [0] CALL(MAINNET, deepCall(3), scope=[]) → CALL(L2, deepCall(2), scope=[0])
        entries[0].stateDeltas = new StateDelta[](0);
        entries[0].actionHash = keccak256(abi.encode(_callL2ToL1(dcL1, dcL2, 3, noScope)));
        entries[0].nextAction = _callL1ToL2Scoped(dcL2, dcL1, 2, scope0);

        // [1] CALL(MAINNET, deepCall(1), scope=[]) → CALL(L2, deepCall(0), scope=[0])
        entries[1].stateDeltas = new StateDelta[](0);
        entries[1].actionHash = keccak256(abi.encode(_callL2ToL1(dcL1, dcL2, 1, noScope)));
        entries[1].nextAction = _callL1ToL2Scoped(dcL2, dcL1, 0, scope0);

        // [2] RESULT(L2, 1) → RESULT(MAINNET, 1)
        entries[2].stateDeltas = new StateDelta[](0);
        entries[2].actionHash = keccak256(abi.encode(_resultL2(1)));
        entries[2].nextAction = _resultMainnet(1);

        // [3] RESULT(L2, 2) → RESULT(MAINNET, 2)
        entries[3].stateDeltas = new StateDelta[](0);
        entries[3].actionHash = keccak256(abi.encode(_resultL2(2)));
        entries[3].nextAction = _resultMainnet(2);

        // [4] RESULT(L2, 3) → RESULT(L2, 3) [terminal, self-ref]
        entries[4].stateDeltas = new StateDelta[](0);
        entries[4].actionHash = keccak256(abi.encode(_resultL2(3)));
        entries[4].nextAction = _resultL2(3);
    }

    // ── Helpers ──

    function _delta(uint256 rollupId, bytes32 from, bytes32 to)
        internal
        pure
        returns (StateDelta[] memory deltas)
    {
        deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, currentState: from, newState: to, etherDelta: 0});
    }
}

/// @notice Batcher: postBatch + call ReentrantCounterL1.deepCall(5) in one tx (local mode only)
contract Batcher {
    function execute(Rollups rollups, ExecutionEntry[] calldata entries, address target, bytes calldata data)
        external
    {
        rollups.postBatch(entries, 0, "", "proof");
        (bool success, bytes memory ret) = target.call(data);
        if (!success) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

/// @title Deploy — Deploy ReentrantCounterL1 on L1 (target set later in Deploy2)
/// @dev Outputs: DEEP_COUNTER_L1, ALICE
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();

        ReentrantCounter dcL1 = new ReentrantCounter(address(0));
        console.log("DEEP_COUNTER_L1=%s", address(dcL1));
        console.log("ALICE=%s", msg.sender);

        vm.stopBroadcast();
    }
}

/// @title DeployL2 — Deploy ReentrantCounterL2 + DC_L1 proxy on L2
/// @dev Env: MANAGER_L2, DEEP_COUNTER_L1
/// Outputs: DEEP_COUNTER_L2, DEEP_COUNTER_L1_PROXY_L2
contract DeployL2 is Script {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address dcL1Addr = vm.envAddress("DEEP_COUNTER_L1");

        vm.startBroadcast();

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        // Proxy for DC_L1 on L2 (used by DC_L2 as crossChainTarget)
        address dcL1ProxyL2 = getOrCreateProxy(manager, dcL1Addr, 0);

        // Deploy DC_L2 with target = proxy for DC_L1 on L2
        ReentrantCounter dcL2 = new ReentrantCounter(dcL1ProxyL2);

        console.log("DEEP_COUNTER_L2=%s", address(dcL2));
        console.log("DEEP_COUNTER_L1_PROXY_L2=%s", dcL1ProxyL2);

        vm.stopBroadcast();
    }
}

/// @title Deploy2 — Create DC_L2 proxy on L1 + set DC_L1 target
/// @dev Env: ROLLUPS, DEEP_COUNTER_L1, DEEP_COUNTER_L2
/// Outputs: DEEP_COUNTER_L2_PROXY_L1
contract Deploy2 is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address dcL1Addr = vm.envAddress("DEEP_COUNTER_L1");
        address dcL2Addr = vm.envAddress("DEEP_COUNTER_L2");

        vm.startBroadcast();

        Rollups rollups = Rollups(rollupsAddr);

        // Proxy for DC_L2 on L1 (used by DC_L1 as crossChainTarget + scope navigation)
        address dcL2ProxyL1 = getOrCreateProxy(rollups, dcL2Addr, 1);

        // Wire DC_L1's target to the proxy for DC_L2 on L1
        ReentrantCounter(dcL1Addr).setPeer(dcL2ProxyL1);

        console.log("DEEP_COUNTER_L2_PROXY_L1=%s", dcL2ProxyL1);

        vm.stopBroadcast();
    }
}

/// @title ExecuteL2 — Load L2 table + SYSTEM calls executeIncomingCrossChainCall (local mode)
/// @dev 1. Load 5 L2 entries
///      2. SYSTEM calls executeIncomingCrossChainCall(DC_L2, deepCall(4), DC_L1, MAINNET, [])
///      Inside L2: deepCall(4) → [reentrant] deepCall(2) → [reentrant] deepCall(0)
/// Env: MANAGER_L2, DEEP_COUNTER_L1, DEEP_COUNTER_L2
contract ExecuteL2 is Script, ReentrantCrossChainActions {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address dcL1Addr = vm.envAddress("DEEP_COUNTER_L1");
        address dcL2Addr = vm.envAddress("DEEP_COUNTER_L2");

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        vm.startBroadcast();

        manager.loadExecutionTable(_l2Entries(dcL1Addr, dcL2Addr));

        manager.executeIncomingCrossChainCall(
            dcL2Addr, // destination
            0, // value
            abi.encodeWithSelector(ReentrantCounter.deepCall.selector, 4),
            dcL1Addr, // sourceAddress
            0, // sourceRollup (MAINNET)
            new uint256[](0) // scope
        );

        console.log("done");
        console.log("L2 count=%s", ReentrantCounter(dcL2Addr).count());

        vm.stopBroadcast();
    }
}

/// @title Execute — Local mode: postBatch (5 entries) + call DC_L1.deepCall(5) via Batcher
/// @dev Inside L1: deepCall(5) → [reentrant] deepCall(3) → [reentrant] deepCall(1)
///      Each reentrant executeCrossChainCall matches a CALL entry, scope navigation executes the callback.
/// Env: ROLLUPS, DEEP_COUNTER_L1, DEEP_COUNTER_L2
contract Execute is Script, ReentrantCrossChainActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address dcL1Addr = vm.envAddress("DEEP_COUNTER_L1");
        address dcL2Addr = vm.envAddress("DEEP_COUNTER_L2");

        vm.startBroadcast();

        Batcher batcher = new Batcher();
        batcher.execute(
            Rollups(rollupsAddr),
            _l1Entries(dcL1Addr, dcL2Addr),
            dcL1Addr,
            abi.encodeWithSelector(ReentrantCounter.deepCall.selector, 5)
        );

        console.log("done");
        console.log("L1 count=%s", ReentrantCounter(dcL1Addr).count());

        vm.stopBroadcast();
    }
}

/// @title ExecuteNetwork — Network mode: user calls DC_L1.deepCall(5) on L1
/// @dev Env: DEEP_COUNTER_L1
contract ExecuteNetwork is Script {
    function run() external view {
        address dcL1 = vm.envAddress("DEEP_COUNTER_L1");
        bytes memory data = abi.encodeWithSelector(ReentrantCounter.deepCall.selector, 5);
        console.log("TARGET=%s", dcL1);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

/// @title ComputeExpected — Compute expected hashes + print expected tables
/// @dev Env: DEEP_COUNTER_L1, DEEP_COUNTER_L2, ALICE
contract ComputeExpected is ComputeExpectedBase, ReentrantCrossChainActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("DEEP_COUNTER_L1")) return "DC_L1";
        if (a == vm.envAddress("DEEP_COUNTER_L2")) return "DC_L2";
        if (a == vm.envAddress("ALICE")) return "Alice";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == ReentrantCounter.deepCall.selector) return "deepCall";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address dcL1 = vm.envAddress("DEEP_COUNTER_L1");
        address dcL2 = vm.envAddress("DEEP_COUNTER_L2");

        // Build entries (single source of truth)
        ExecutionEntry[] memory l1 = _l1Entries(dcL1, dcL2);
        ExecutionEntry[] memory l2 = _l2Entries(dcL1, dcL2);

        // Compute entry hashes
        bytes32 l1eh0 = _entryHash(l1[0].actionHash, l1[0].nextAction);
        bytes32 l1eh1 = _entryHash(l1[1].actionHash, l1[1].nextAction);
        bytes32 l1eh2 = _entryHash(l1[2].actionHash, l1[2].nextAction);
        bytes32 l1eh3 = _entryHash(l1[3].actionHash, l1[3].nextAction);
        bytes32 l1eh4 = _entryHash(l1[4].actionHash, l1[4].nextAction);

        bytes32 l2eh0 = _entryHash(l2[0].actionHash, l2[0].nextAction);
        bytes32 l2eh1 = _entryHash(l2[1].actionHash, l2[1].nextAction);
        bytes32 l2eh2 = _entryHash(l2[2].actionHash, l2[2].nextAction);
        bytes32 l2eh3 = _entryHash(l2[3].actionHash, l2[3].nextAction);
        bytes32 l2eh4 = _entryHash(l2[4].actionHash, l2[4].nextAction);

        // L2 call hash: the CALL built by executeIncomingCrossChainCall = same as L1 entry[0] trigger
        bytes32 l2CallHash = l1[0].actionHash;

        // ── Parseable output ──
        string memory l1h = string.concat(
            "[", vm.toString(l1eh0), ",", vm.toString(l1eh1), ","
        );
        l1h = string.concat(l1h, vm.toString(l1eh2), ",", vm.toString(l1eh3), ",", vm.toString(l1eh4), "]");
        console.log("EXPECTED_L1_HASHES=%s", l1h);

        string memory l2h = string.concat(
            "[", vm.toString(l2eh0), ",", vm.toString(l2eh1), ","
        );
        l2h = string.concat(l2h, vm.toString(l2eh2), ",", vm.toString(l2eh3), ",", vm.toString(l2eh4), "]");
        console.log("EXPECTED_L2_HASHES=%s", l2h);

        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(l2CallHash));

        // ── Human-readable: L1 execution table ──
        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (5 entries) ===");

        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;

        Action memory callL1ToL2_4 = _callL1ToL2(dcL2, dcL1, 4);
        Action memory callL1ToL2_2 = _callL1ToL2(dcL2, dcL1, 2);
        Action memory callL1ToL2_0 = _callL1ToL2(dcL2, dcL1, 0);
        Action memory callL2ToL1_3s = _callL2ToL1(dcL1, dcL2, 3, scope0);
        Action memory callL2ToL1_1s = _callL2ToL1(dcL1, dcL2, 1, scope0);

        _logEntry(0, l1[0].actionHash, l1[0].stateDeltas, _fmtCall(callL1ToL2_4), _fmtCall(callL2ToL1_3s));
        _logEntry(1, l1[1].actionHash, l1[1].stateDeltas, _fmtCall(callL1ToL2_2), _fmtCall(callL2ToL1_1s));
        _logEntry(
            2, l1[2].actionHash, l1[2].stateDeltas, _fmtCall(callL1ToL2_0), _fmtResult(_resultL2(1), "uint256(1)")
        );
        _logEntry(
            3,
            l1[3].actionHash,
            l1[3].stateDeltas,
            _fmtResult(_resultMainnet(1), "uint256(1)"),
            _fmtResult(_resultL2(2), "uint256(2)")
        );
        _logEntry(
            4,
            l1[4].actionHash,
            l1[4].stateDeltas,
            _fmtResult(_resultMainnet(2), "uint256(2)"),
            _fmtResult(_resultL2(3), "uint256(3)")
        );

        // ── Human-readable: L2 execution table ──
        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (5 entries) ===");

        Action memory callL2ToL1_3 = _callL2ToL1(dcL1, dcL2, 3, new uint256[](0));
        Action memory callL2ToL1_1 = _callL2ToL1(dcL1, dcL2, 1, new uint256[](0));
        Action memory callL1ToL2s_2 = _callL1ToL2Scoped(dcL2, dcL1, 2, scope0);
        Action memory callL1ToL2s_0 = _callL1ToL2Scoped(dcL2, dcL1, 0, scope0);

        _logL2Entry(0, l2eh0, _fmtCall(callL2ToL1_3), _fmtCall(callL1ToL2s_2));
        _logL2Entry(1, l2eh1, _fmtCall(callL2ToL1_1), _fmtCall(callL1ToL2s_0));
        _logL2Entry(2, l2eh2, _fmtResult(_resultL2(1), "uint256(1)"), _fmtResult(_resultMainnet(1), "uint256(1)"));
        _logL2Entry(3, l2eh3, _fmtResult(_resultL2(2), "uint256(2)"), _fmtResult(_resultMainnet(2), "uint256(2)"));
        _logL2Entry(
            4,
            l2eh4,
            _fmtResult(_resultL2(3), "uint256(3)"),
            string.concat(_fmtResult(_resultL2(3), "uint256(3)"), "  (terminal)")
        );

        // ── Human-readable: L2 calls ──
        console.log("");
        console.log("=== EXPECTED L2 CALLS (1 call) ===");
        _logL2Call(0, l2CallHash, callL1ToL2_4);
    }
}
