// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {Counter, SelfCallerWithRevert} from "../../../test/mocks/CounterContracts.sol";
import {L2TXBatcher, L2TXActionsBase, getOrCreateProxy} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  revertContinueL2 — L2 → L1, self-call revert + retry
//
//  SCA (SelfCallerWithRevert) on L2 calls itself; inside the self-call
//  it calls Counter on L1 (cross-chain, succeeds, returns 1), then reverts.
//  After catching the revert, SCA calls Counter on L1 again — same entry
//  (first consumption was rolled back by the EVM revert).
//
//  ┌──────────────────────────────────────────────────────────────────┐
//  │  L2 (loadTable + SCA.execute())                                  │
//  │    1 entry: CALL(CounterL1, src=SCA) → RESULT(1)                 │
//  │    Only 1 entry needed: both calls target the same contract with │
//  │    the same state (counter=0), so they produce the same RESULT.  │
//  │    The first consumption is rolled back by the self-call revert, │
//  │    and the same entry is reused for the second call.             │
//  │    SCA.execute():                                                │
//  │      try this.innerCall():                                       │
//  │        CounterL1_proxy.increment() → entry consumed → 1          │
//  │        revert("inner scope revert")  ← real Solidity revert      │
//  │      catch: entry consumption rolled back by EVM                 │
//  │      CounterL1_proxy.increment() → same entry consumed → 1       │
//  │    SCA.lastResult = 1                                            │
//  │                                                                  │
//  │  L1 (L2TXBatcher: postBatch + executeL2TX)                       │
//  │    4 entries — scope navigation models the revert:               │
//  │      L2TX → CALL(CounterL1, scope=[0,0])                         │
//  │      [0,0]: Counter.increment() → 1                              │
//  │      RESULT → REVERT(scope=[0]) → REVERT_CONTINUE                │
//  │      → CALL(CounterL1, scope=[1])                                │
//  │      [1]: Counter.increment() → 1                                │
//  │      → terminal RESULT                                           │
//  │    Counter = 1 (first increment rolled back, second kept)        │
//  └──────────────────────────────────────────────────────────────────┘
// ═══════════════════════════════════════════════════════════════════════

/// @dev Actions & entries for the revertContinueL2 scenario (L2 → L1).
abstract contract RevertContinueL2Actions is L2TXActionsBase {

    function _callToCounterL1(address counterL1, address scaL2, uint256[] memory scope)
        internal
        pure
        returns (Action memory)
    {
        return Action({
            actionType: ActionType.CALL,
            rollupId: MAINNET_ROLLUP_ID,
            destination: counterL1,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            failed: false,
            sourceAddress: scaL2,
            sourceRollup: L2_ROLLUP_ID,
            scope: scope
        });
    }

    function _resultFromCounterL1() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: MAINNET_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(1)),
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

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

    function _delta(bytes32 from, bytes32 to) internal pure returns (StateDelta[] memory d) {
        d = new StateDelta[](1);
        d[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: from, newState: to, etherDelta: 0});
    }

    /// @dev L1: 4 entries — scope navigation with revert + retry.
    ///   Entry 0: L2TX → CALL(CounterL1, scope=[0,0])          [s0→s1]
    ///   Entry 1: RESULT(1) → REVERT(scope=[0])                [s1→s2]
    ///   Entry 2: REVERT_CONTINUE → CALL(CounterL1, scope=[1]) [s2→s3]
    ///   Entry 3: RESULT(1) → terminal RESULT                  [s2→s4]
    ///   Note: entry 3 starts at s2 because _handleScopeRevert restores to s2.
    function _l1Entries(address counterL1, address scaL2, bytes memory rlpTx)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        uint256[] memory scope00 = new uint256[](2);
        scope00[0] = 0;
        scope00[1] = 0;
        uint256[] memory scope1 = new uint256[](1);
        scope1[0] = 1;

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-revcont2-step1");
        bytes32 s2 = keccak256("l2-state-revcont2-step2");
        bytes32 s3 = keccak256("l2-state-revcont2-step3");
        bytes32 s4 = keccak256("l2-state-revcont2-step4");

        entries = new ExecutionEntry[](4);

        entries[0].stateDeltas = _delta(s0, s1);
        entries[0].actionHash = keccak256(abi.encode(_l2txAction(rlpTx)));
        entries[0].nextAction = _callToCounterL1(counterL1, scaL2, scope00);

        entries[1].stateDeltas = _delta(s1, s2);
        entries[1].actionHash = keccak256(abi.encode(_resultFromCounterL1()));
        entries[1].nextAction = _revertAction();

        entries[2].stateDeltas = _delta(s2, s3);
        entries[2].actionHash = keccak256(abi.encode(_revertContinueAction()));
        entries[2].nextAction = _callToCounterL1(counterL1, scaL2, scope1);

        // currentState=s3: _handleScopeRevert restores to s3 (captured after REVERT_CONTINUE)
        entries[3].stateDeltas = _delta(s3, s4);
        entries[3].actionHash = keccak256(abi.encode(_resultFromCounterL1()));
        entries[3].nextAction = _terminalResultL2Tx();
    }

    /// @dev L2: 1 entry — both cross-chain calls target the same contract starting from
    ///   the same state (counter=0), so they produce identical CALL and RESULT actions.
    ///   Only one entry is needed: the first consumption is rolled back by the self-call
    ///   revert, and the same entry is reused for the second call.
    ///   CALL(CounterL1, src=SCA, srcRollup=L2, scope=[]) → RESULT(1)
    function _l2Entries(address counterL1, address scaL2)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = new StateDelta[](0);
        entries[0].actionHash = keccak256(abi.encode(_callToCounterL1(counterL1, scaL2, new uint256[](0))));
        entries[0].nextAction = _resultFromCounterL1();
    }
}

// ═══════════════════════════════════════════════════════════════
//  Deploy
// ═══════════════════════════════════════════════════════════════

/// @title Deploy — Deploy Counter on L1
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterL1 = new Counter();
        console.log("COUNTER_L1=%s", address(counterL1));
        console.log("ALICE=%s", msg.sender);
        vm.stopBroadcast();
    }
}

/// @title DeployL2 — CounterL1 proxy + SCA on L2
/// Env: MANAGER_L2, COUNTER_L1
contract DeployL2 is Script {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);
        address counterL1ProxyL2 = getOrCreateProxy(manager, counterL1Addr, 0);
        SelfCallerWithRevert sca = new SelfCallerWithRevert(Counter(counterL1ProxyL2));

        console.log("COUNTER_L1_PROXY_L2=%s", counterL1ProxyL2);
        console.log("SCA=%s", address(sca));
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════
//  Execute
// ═══════════════════════════════════════════════════════════════

/// @title ExecuteL2 — Load table + SCA.execute() on L2
/// Env: MANAGER_L2, COUNTER_L1, SCA
contract ExecuteL2 is Script, RevertContinueL2Actions {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address scaAddr = vm.envAddress("SCA");
        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        vm.startBroadcast();
        manager.loadExecutionTable(_l2Entries(counterL1Addr, scaAddr));
        SelfCallerWithRevert(scaAddr).execute();

        console.log("done");
        console.log("sca_lastResult=%s", SelfCallerWithRevert(scaAddr).lastResult());
        vm.stopBroadcast();
    }
}

/// @title Execute — L2TXBatcher: postBatch + executeL2TX on L1
/// Env: ROLLUPS, COUNTER_L1, SCA
contract Execute is Script, RevertContinueL2Actions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address scaAddr = vm.envAddress("SCA");
        bytes memory rlpTx = vm.envBytes("RLP_ENCODED_TX");

        vm.startBroadcast();
        L2TXBatcher batcher = new L2TXBatcher();
        batcher.execute(Rollups(rollupsAddr), _l1Entries(counterL1Addr, scaAddr, rlpTx), L2_ROLLUP_ID, rlpTx);

        console.log("done");
        console.log("counterL1=%s", Counter(counterL1Addr).counter());
        vm.stopBroadcast();
    }
}

/// @title ExecuteNetworkL2 — Network mode: user tx on L2 (SCA.execute())
/// Env: SCA
contract ExecuteNetworkL2 is Script {
    function run() external view {
        address target = vm.envAddress("SCA");
        bytes memory data = abi.encodeWithSelector(SelfCallerWithRevert.execute.selector);
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

// ═══════════════════════════════════════════════════════════════
//  Verification
// ═══════════════════════════════════════════════════════════════

/// @title ComputeExpected
/// Env: COUNTER_L1, SCA, ALICE
contract ComputeExpected is ComputeExpectedBase, RevertContinueL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L1")) return "CounterL1";
        if (a == vm.envAddress("SCA")) return "SCA";
        if (a == vm.envAddress("ALICE")) return "Alice";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address scaAddr = vm.envAddress("SCA");
        bytes memory rlpTx = vm.envBytes("RLP_ENCODED_TX");

        ExecutionEntry[] memory l1 = _l1Entries(counterL1Addr, scaAddr, rlpTx);
        ExecutionEntry[] memory l2 = _l2Entries(counterL1Addr, scaAddr);

        bytes32 l1eh0 = _entryHash(l1[0].actionHash, l1[0].nextAction);
        bytes32 l1eh1 = _entryHash(l1[1].actionHash, l1[1].nextAction);
        bytes32 l1eh2 = _entryHash(l1[2].actionHash, l1[2].nextAction);
        bytes32 l1eh3 = _entryHash(l1[3].actionHash, l1[3].nextAction);
        bytes32 l2eh0 = _entryHash(l2[0].actionHash, l2[0].nextAction);

        console.log(
            "EXPECTED_L1_HASHES=[%s,%s,%s,%s]",
            vm.toString(l1eh0),
            vm.toString(l1eh1),
            string.concat(vm.toString(l1eh2), ",", vm.toString(l1eh3))
        );
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2eh0));

        uint256[] memory scope00 = new uint256[](2);
        scope00[0] = 0;
        scope00[1] = 0;
        uint256[] memory scope1 = new uint256[](1);
        scope1[0] = 1;

        Action memory l2txAction = _l2txAction(rlpTx);
        Action memory callScoped00 = _callToCounterL1(counterL1Addr, scaAddr, scope00);
        Action memory callScoped1 = _callToCounterL1(counterL1Addr, scaAddr, scope1);
        Action memory callScopeless = _callToCounterL1(counterL1Addr, scaAddr, new uint256[](0));
        Action memory resultC1 = _resultFromCounterL1();
        Action memory revertAct = _revertAction();
        Action memory revertCont = _revertContinueAction();
        Action memory termResult = _terminalResultL2Tx();

        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (4 entries) ===");
        _logEntry(0, l1[0].actionHash, l1[0].stateDeltas, _fmtL2TX(l2txAction), _fmtCall(callScoped00));
        _logEntry(1, l1[1].actionHash, l1[1].stateDeltas, _fmtResult(resultC1, "uint256(1)"), "REVERT rollupId=1 scope=[0]");
        _logEntry(2, l1[2].actionHash, l1[2].stateDeltas, "REVERT_CONTINUE rollupId=1", _fmtCall(callScoped1));
        _logEntry(3, l1[3].actionHash, l1[3].stateDeltas, _fmtResult(resultC1, "uint256(1)"), string.concat(_fmtResult(termResult, "(void)"), "  (terminal)"));

        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (1 entry) ===");
        _logL2Entry(0, l2eh0, _fmtCall(callScopeless), _fmtResult(resultC1, "uint256(1)"));
    }
}
