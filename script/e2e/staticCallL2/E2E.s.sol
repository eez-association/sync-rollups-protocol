// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {
    Action,
    ActionType,
    ExecutionEntry,
    StateDelta,
    StaticCall,
    StaticSubCall,
    RollupStateRoot
} from "../../../src/ICrossChainManager.sol";
import {L2TXBatcher, L2TXActionsBase, getOrCreateProxy} from "../shared/E2EHelpers.sol";
// ═══════════════════════════════════════════════════════════════════════
//  staticCallL2 — L2 -> L1 static read via static call table on L2
//
//  Alice calls ValueReaderL2.readFromL1(counterL1ProxyL2) on L2
//    -> ValueReaderL2 STATICCALLs proxy
//    -> proxy detects static via TSTORE probe
//    -> CrossChainManagerL2.staticCallLookup matches StaticCall entry
//    -> returns abi.encode(7)
//
//  Meanwhile on L1 (system posts batch):
//    postBatch stores 2 deferred entries (L2TX->CALL, RESULT->RESULT)
//    executeL2TX triggers scope navigation
//    -> CALL has isStatic=true -> sourceProxy.staticcall(executeOnBehalf)
//    -> CounterL1.getValue() returns 7 natively on L1
// ═══════════════════════════════════════════════════════════════════════

// ── App contracts ──

contract CounterL1 {
    function getValue() external pure returns (uint256) {
        return 7;
    }
}

contract ValueReaderL2 {
    function readFromL1(address counterL1Proxy) external view returns (uint256) {
        (bool ok, bytes memory ret) = counterL1Proxy.staticcall(
            abi.encodeWithSelector(CounterL1.getValue.selector)
        );
        require(ok, "staticcall failed");
        return abi.decode(ret, (uint256));
    }
}

/// @dev Centralized action & entry definitions for the staticCallL2 scenario.
abstract contract StaticCallL2Actions is L2TXActionsBase {

    function _callAction(address counterL1, address valueReaderL2) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.CALL,
            rollupId: MAINNET_ROLLUP_ID,
            destination: counterL1,
            value: 0,
            data: abi.encodeWithSelector(CounterL1.getValue.selector),
            failed: false,
            isStatic: true,
            sourceAddress: valueReaderL2,
            sourceRollup: L2_ROLLUP_ID,
            scope: new uint256[](0)
        });
    }

    function _resultAction() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: MAINNET_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(7)),
            failed: false,
            isStatic: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    function _terminalResultAction() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            isStatic: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    function _l1Entries(address counterL1, address valueReaderL2, bytes memory rlpEncodedTx)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        Action memory l2tx = _l2txAction(rlpEncodedTx);
        Action memory call_ = _callAction(counterL1, valueReaderL2);
        Action memory result = _resultAction();
        Action memory terminal = _terminalResultAction();

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-before-call");
        bytes32 s2 = keccak256("l2-state-after-scenario2");

        StateDelta[] memory deltas0 = new StateDelta[](1);
        deltas0[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s0, newState: s1, etherDelta: 0});

        StateDelta[] memory deltas1 = new StateDelta[](1);
        deltas1[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s1, newState: s2, etherDelta: 0});

        entries = new ExecutionEntry[](2);
        entries[0].stateDeltas = deltas0;
        entries[0].actionHash = keccak256(abi.encode(l2tx));
        entries[0].nextAction = call_;

        entries[1].stateDeltas = deltas1;
        entries[1].actionHash = keccak256(abi.encode(result));
        entries[1].nextAction = terminal;
    }

    /// L2 static call table: one entry matching the user's STATICCALL on L2.
    /// Uses the same _callAction (isStatic=true) — staticCallLookup reconstructs this exact action.
    function _l2StaticCalls(address counterL1, address valueReaderL2)
        internal
        pure
        returns (StaticCall[] memory scs)
    {
        Action memory action = _callAction(counterL1, valueReaderL2);
        scs = new StaticCall[](1);
        scs[0].actionHash = keccak256(abi.encode(action));
        scs[0].returnData = abi.encode(uint256(7));
        scs[0].failed = false;
        scs[0].calls = new StaticSubCall[](0);
        scs[0].rollingHash = bytes32(0);
        scs[0].stateRoots = new RollupStateRoot[](0);
    }
}

/// @title Deploy — Deploy CounterL1 on L1
/// @dev Env: ROLLUPS
/// Outputs: COUNTER_L1
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();

        CounterL1 counterL1 = new CounterL1();
        console.log("COUNTER_L1=%s", address(counterL1));

        vm.stopBroadcast();
    }
}

/// @title DeployL2 — Deploy ValueReaderL2 on L2 with proxy for CounterL1(L1)
/// @dev Env: MANAGER_L2, COUNTER_L1
/// Outputs: VALUE_READER_L2, COUNTER_L1_PROXY_L2
contract DeployL2 is Script {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        // C': proxy for CounterL1(L1), deployed on L2
        address counterL1ProxyL2 = getOrCreateProxy(manager, counterL1Addr, 0);

        // ValueReaderL2 on L2
        ValueReaderL2 reader = new ValueReaderL2();

        console.log("VALUE_READER_L2=%s", address(reader));
        console.log("COUNTER_L1_PROXY_L2=%s", counterL1ProxyL2);

        vm.stopBroadcast();
    }
}

/// @title Deploy2 — Create proxy for ValueReaderL2(L2) on L1
/// @dev Env: ROLLUPS, VALUE_READER_L2
/// Outputs: VALUE_READER_L2_PROXY_L1
contract Deploy2 is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address valueReaderL2Addr = vm.envAddress("VALUE_READER_L2");

        vm.startBroadcast();

        // Proxy for ValueReaderL2(L2), deployed on L1
        // Needed for scope navigation: sourceProxy.staticcall(executeOnBehalf(CounterL1, getValue))
        Rollups rollups = Rollups(rollupsAddr);
        address valueReaderL2ProxyL1 = getOrCreateProxy(rollups, valueReaderL2Addr, 1);
        console.log("VALUE_READER_L2_PROXY_L1=%s", valueReaderL2ProxyL1);

        vm.stopBroadcast();
    }
}

/// @title ExecuteL2 — Load L2 execution table + Alice calls readFromL1 (local mode)
/// @dev Env: MANAGER_L2, COUNTER_L1, VALUE_READER_L2, COUNTER_L1_PROXY_L2
contract ExecuteL2 is Script, StaticCallL2Actions {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address valueReaderL2Addr = vm.envAddress("VALUE_READER_L2");
        address counterL1ProxyL2Addr = vm.envAddress("COUNTER_L1_PROXY_L2");

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        vm.startBroadcast();

        manager.loadExecutionTable(
            new ExecutionEntry[](0),
            _l2StaticCalls(counterL1Addr, valueReaderL2Addr)
        );

        // Alice calls ValueReaderL2.readFromL1(counterL1ProxyL2) on L2
        uint256 val = ValueReaderL2(valueReaderL2Addr).readFromL1(counterL1ProxyL2Addr);

        console.log("done");
        console.log("value=%s", val);

        vm.stopBroadcast();
    }
}

/// @title Execute — Local mode: postBatch + executeL2TX via Batcher on L1
/// @dev Env: ROLLUPS, COUNTER_L1, VALUE_READER_L2
contract Execute is Script, StaticCallL2Actions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address valueReaderL2Addr = vm.envAddress("VALUE_READER_L2");

        vm.startBroadcast();

        bytes memory rlpTx = vm.envBytes("RLP_ENCODED_TX");

        L2TXBatcher batcher = new L2TXBatcher();
        batcher.execute(
            Rollups(rollupsAddr), _l1Entries(counterL1Addr, valueReaderL2Addr, rlpTx), L2_ROLLUP_ID, rlpTx
        );

        console.log("done");

        vm.stopBroadcast();
    }
}

/// @title ExecuteNetworkL2 — Network mode: user transaction on L2 (trigger)
/// @dev Env: VALUE_READER_L2, COUNTER_L1_PROXY_L2
/// Returns (target, value, calldata) so the runner can send via `cast send`.
contract ExecuteNetworkL2 is Script {
    function run() external view {
        address target = vm.envAddress("VALUE_READER_L2");
        address proxy = vm.envAddress("COUNTER_L1_PROXY_L2");
        bytes memory data = abi.encodeWithSelector(ValueReaderL2.readFromL1.selector, proxy);
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

/// @title ComputeExpected — Compute expected actionHashes + print expected table
/// @dev Env: COUNTER_L1, VALUE_READER_L2
contract ComputeExpected is ComputeExpectedBase, StaticCallL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L1")) return "CounterL1";
        if (a == vm.envAddress("VALUE_READER_L2")) return "ValueReaderL2";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == CounterL1.getValue.selector) return "getValue";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address valueReaderL2Addr = vm.envAddress("VALUE_READER_L2");
        bytes memory rlpTx = vm.envBytes("RLP_ENCODED_TX");

        // L1 entries
        ExecutionEntry[] memory l1 = _l1Entries(counterL1Addr, valueReaderL2Addr, rlpTx);
        bytes32 eh0 = _entryHash(l1[0].actionHash, l1[0].nextAction);
        bytes32 eh1 = _entryHash(l1[1].actionHash, l1[1].nextAction);

        // L2 static call hash
        Action memory staticAction = _callAction(counterL1Addr, valueReaderL2Addr);
        bytes32 scHash = keccak256(abi.encode(staticAction));

        // Parseable lines
        console.log("EXPECTED_L1_HASHES=[%s,%s]", vm.toString(eh0), vm.toString(eh1));
        console.log("EXPECTED_L2_HASHES=[]");
        console.log("EXPECTED_L2_CALL_HASHES=[]");
        console.log("EXPECTED_STATIC_CALL_HASHES=[%s]", vm.toString(scHash));

        // Summary
        console.log("");
        console.log("=== EXPECTED SUMMARY ===");
        console.log("  L1 [0] L2TX, next: CALL CounterL1.getValue() isStatic=true");
        console.log("  L1 [1] RESULT uint256(7), next: RESULT (terminal)");
        console.log("  L2 StaticCall: CounterL1.getValue() = 7 (via staticCallLookup)");
    }
}
