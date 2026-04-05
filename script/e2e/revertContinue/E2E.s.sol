// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {JoinedCounter, DualCallerWithRevert} from "../../../test/mocks/CounterContracts.sol";
import {getOrCreateProxy} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  revertContinue — L1 → L2, self-call revert + retry (different target)
//
//  DualCaller on L1 calls itself; inside the self-call it calls
//  JoinedCounterA on L2 (cross-chain, returns (1,0,1)), then reverts.
//  After catching the revert, DualCaller calls JoinedCounterB on L2
//  (returns (1,0,2)). Different return data avoids the L2 duplicate-
//  actionHash limitation (see CAVEATS.md).
//
//  ┌──────────────────────────────────────────────────────────────────┐
//  │  L1 (Batcher: postBatch + DualCaller.execute())                  │
//  │    2 entries: CALL_A → RESULT_A, CALL_B → RESULT_B               │
//  │    DualCaller.execute():                                         │
//  │      try this.innerCall():                                       │
//  │        A_proxy.increment() → entry consumed → (1,0,1)            │
//  │        revert("inner scope revert")  ← real Solidity revert      │
//  │      catch: entry_A consumption rolled back                      │
//  │      B_proxy.increment() → entry consumed → (1,0,2)              │
//  │                                                                  │
//  │  L2 (executeIncomingCrossChainCall, scope=[0,0])                 │
//  │    3 entries — scope navigation with REVERT_CONTINUE → CALL:     │
//  │      [0,0]: A.increment() → (1,0,1) → REVERT(scope=[0])         │
//  │      REVERT_CONTINUE → CALL(B, scope=[1])                        │
//  │      [1]: B.increment() → (1,0,2) → terminal RESULT              │
//  │    A.counter=0 (rolled back), B.counter=1                        │
//  └──────────────────────────────────────────────────────────────────┘
// ═══════════════════════════════════════════════════════════════════════

/// @dev Actions & entries for the revertContinue scenario (L1 → L2).
abstract contract RevertContinueActions {
    uint256 internal constant L2_ROLLUP_ID = 1;
    uint256 internal constant MAINNET_ROLLUP_ID = 0;

    // ── CALL actions (built by executeCrossChainCall on L1, scopeless) ──

    function _callA(address joinA, address dualCaller) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: joinA,
            value: 0,
            data: abi.encodeWithSelector(JoinedCounter.increment.selector),
            failed: false,
            sourceAddress: dualCaller,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });
    }

    function _callB(address joinB, address dualCaller) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: joinB,
            value: 0,
            data: abi.encodeWithSelector(JoinedCounter.increment.selector),
            failed: false,
            sourceAddress: dualCaller,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });
    }

    // ── Scoped CALL for L2 scope navigation entries ──

    function _callBScoped(address joinB, address dualCaller, uint256[] memory scope) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: joinB,
            value: 0,
            data: abi.encodeWithSelector(JoinedCounter.increment.selector),
            failed: false,
            sourceAddress: dualCaller,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: scope
        });
    }

    // ── RESULT actions — different data thanks to JoinedCounter IDs ──

    function _resultA() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(1), uint256(0), uint256(1)), // (own=1, other=0, id=1)
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    function _resultB() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(1), uint256(0), uint256(2)), // (own=1, other=0, id=2)
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    function _terminalResult() internal pure returns (Action memory) {
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

    // ── REVERT / REVERT_CONTINUE ──

    function _revertAction() internal pure returns (Action memory) {
        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;
        return Action({
            actionType: ActionType.REVERT,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: scope0
        });
    }

    function _revertContinueAction() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.REVERT_CONTINUE,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: "",
            failed: true,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    // ── L1 entries: 2 entries ──
    //   Entry 0: CALL_A → RESULT_A  [s0→s1] (consumed+rolled back, then stays)
    //   Entry 1: CALL_B → RESULT_B  [s0→s2] (consumed after revert)

    function _l1Entries(address joinA, address joinB, address dualCaller)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-revcont-a");
        bytes32 s2 = keccak256("l2-state-revcont-b");

        entries = new ExecutionEntry[](2);

        StateDelta[] memory deltasA = new StateDelta[](1);
        deltasA[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s0, newState: s1, etherDelta: 0});
        entries[0].stateDeltas = deltasA;
        entries[0].actionHash = keccak256(abi.encode(_callA(joinA, dualCaller)));
        entries[0].nextAction = _resultA();

        StateDelta[] memory deltasB = new StateDelta[](1);
        deltasB[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s0, newState: s2, etherDelta: 0});
        entries[1].stateDeltas = deltasB;
        entries[1].actionHash = keccak256(abi.encode(_callB(joinB, dualCaller)));
        entries[1].nextAction = _resultB();
    }

    // ── L2 entries: 3 entries (scope navigation with REVERT_CONTINUE → CALL) ──
    //   Entry 0: RESULT_A → REVERT(scope=[0])         (consumed inside revert, restored)
    //   Entry 1: REVERT_CONTINUE → CALL(B, scope=[1])  (consumed inside revert, restored)
    //   Entry 2: RESULT_B → terminal RESULT             (consumed after revert)

    function _l2Entries(address joinB, address dualCaller)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        uint256[] memory scope1 = new uint256[](1);
        scope1[0] = 1;

        entries = new ExecutionEntry[](3);

        entries[0].stateDeltas = new StateDelta[](0);
        entries[0].actionHash = keccak256(abi.encode(_resultA()));
        entries[0].nextAction = _revertAction();

        entries[1].stateDeltas = new StateDelta[](0);
        entries[1].actionHash = keccak256(abi.encode(_revertContinueAction()));
        entries[1].nextAction = _callBScoped(joinB, dualCaller, scope1);

        entries[2].stateDeltas = new StateDelta[](0);
        entries[2].actionHash = keccak256(abi.encode(_resultB()));
        entries[2].nextAction = _terminalResult();
    }
}

// ═══════════════════════════════════════════════════════════════
//  Deploy
// ═══════════════════════════════════════════════════════════════

/// @title DeployL2 — Deploy JoinedCounterA + JoinedCounterB on L2, link them
/// Outputs: JOIN_A, JOIN_B
contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        JoinedCounter joinA = new JoinedCounter(1);
        JoinedCounter joinB = new JoinedCounter(2);
        joinA.setOther(joinB);
        joinB.setOther(joinA);
        console.log("JOIN_A=%s", address(joinA));
        console.log("JOIN_B=%s", address(joinB));
        vm.stopBroadcast();
    }
}

/// @title Deploy — Proxies for A,B + DualCallerWithRevert on L1
/// Env: ROLLUPS, JOIN_A, JOIN_B
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address joinAAddr = vm.envAddress("JOIN_A");
        address joinBAddr = vm.envAddress("JOIN_B");

        vm.startBroadcast();
        Rollups rollups = Rollups(rollupsAddr);
        address proxyA = getOrCreateProxy(rollups, joinAAddr, 1);
        address proxyB = getOrCreateProxy(rollups, joinBAddr, 1);
        DualCallerWithRevert dualCaller = new DualCallerWithRevert(JoinedCounter(proxyA), JoinedCounter(proxyB));
        console.log("PROXY_A=%s", proxyA);
        console.log("PROXY_B=%s", proxyB);
        console.log("DUAL_CALLER=%s", address(dualCaller));
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════
//  Execute
// ═══════════════════════════════════════════════════════════════

/// @title ExecuteL2 — Load table + executeIncomingCrossChainCall(A, scope=[0,0])
/// Env: MANAGER_L2, JOIN_A, JOIN_B, DUAL_CALLER
contract ExecuteL2 is Script, RevertContinueActions {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address joinAAddr = vm.envAddress("JOIN_A");
        address joinBAddr = vm.envAddress("JOIN_B");
        address dualCallerAddr = vm.envAddress("DUAL_CALLER");
        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        vm.startBroadcast();
        manager.loadExecutionTable(_l2Entries(joinBAddr, dualCallerAddr));

        uint256[] memory scope00 = new uint256[](2);
        scope00[0] = 0;
        scope00[1] = 0;
        manager.executeIncomingCrossChainCall(
            joinAAddr, 0, abi.encodeWithSelector(JoinedCounter.increment.selector),
            dualCallerAddr, MAINNET_ROLLUP_ID, scope00
        );

        console.log("done");
        console.log("counterA=%s", JoinedCounter(joinAAddr).counter());
        console.log("counterB=%s", JoinedCounter(joinBAddr).counter());
        vm.stopBroadcast();
    }
}

/// @notice Batcher: postBatch + DualCaller.execute() in one tx
contract Batcher {
    function execute(
        Rollups rollups,
        ExecutionEntry[] calldata entries,
        DualCallerWithRevert dualCaller
    ) external {
        rollups.postBatch(entries, 0, "", "proof");
        dualCaller.execute();
    }
}

/// @title Execute — postBatch + DualCaller.execute() via Batcher
/// Env: ROLLUPS, JOIN_A, JOIN_B, DUAL_CALLER
contract Execute is Script, RevertContinueActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address joinAAddr = vm.envAddress("JOIN_A");
        address joinBAddr = vm.envAddress("JOIN_B");
        address dualCallerAddr = vm.envAddress("DUAL_CALLER");

        vm.startBroadcast();
        Batcher batcher = new Batcher();
        batcher.execute(
            Rollups(rollupsAddr),
            _l1Entries(joinAAddr, joinBAddr, dualCallerAddr),
            DualCallerWithRevert(dualCallerAddr)
        );
        console.log("done");
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════
//  Verification
// ═══════════════════════════════════════════════════════════════

/// @title ComputeExpected
/// Env: JOIN_A, JOIN_B, DUAL_CALLER
contract ComputeExpected is ComputeExpectedBase, RevertContinueActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("JOIN_A")) return "JoinA";
        if (a == vm.envAddress("JOIN_B")) return "JoinB";
        if (a == vm.envAddress("DUAL_CALLER")) return "DualCaller";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == JoinedCounter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address joinAAddr = vm.envAddress("JOIN_A");
        address joinBAddr = vm.envAddress("JOIN_B");
        address dualCallerAddr = vm.envAddress("DUAL_CALLER");

        ExecutionEntry[] memory l1 = _l1Entries(joinAAddr, joinBAddr, dualCallerAddr);
        ExecutionEntry[] memory l2 = _l2Entries(joinBAddr, dualCallerAddr);

        bytes32 l1eh0 = _entryHash(l1[0].actionHash, l1[0].nextAction);
        bytes32 l1eh1 = _entryHash(l1[1].actionHash, l1[1].nextAction);
        bytes32 l2eh0 = _entryHash(l2[0].actionHash, l2[0].nextAction);
        bytes32 l2eh1 = _entryHash(l2[1].actionHash, l2[1].nextAction);
        bytes32 l2eh2 = _entryHash(l2[2].actionHash, l2[2].nextAction);

        console.log("EXPECTED_L1_HASHES=[%s,%s]", vm.toString(l1eh0), vm.toString(l1eh1));
        console.log("EXPECTED_L2_HASHES=[%s,%s,%s]", vm.toString(l2eh0), vm.toString(l2eh1), vm.toString(l2eh2));

        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (2 entries) ===");
        _logEntry(0, l1[0].actionHash, l1[0].stateDeltas, _fmtCall(_callA(joinAAddr, dualCallerAddr)), _fmtResult(_resultA(), "(1,0,1)"));
        _logEntry(1, l1[1].actionHash, l1[1].stateDeltas, _fmtCall(_callB(joinBAddr, dualCallerAddr)), _fmtResult(_resultB(), "(1,0,2)"));

        uint256[] memory scope1 = new uint256[](1);
        scope1[0] = 1;
        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (3 entries) ===");
        _logL2Entry(0, l2eh0, _fmtResult(_resultA(), "(1,0,1)"), "REVERT rollupId=1 scope=[0]");
        _logL2Entry(1, l2eh1, "REVERT_CONTINUE rollupId=1", _fmtCall(_callBScoped(joinBAddr, dualCallerAddr, scope1)));
        _logL2Entry(2, l2eh2, _fmtResult(_resultB(), "(1,0,2)"), _fmtResult(_terminalResult(), "(void)  (terminal)"));
    }
}
