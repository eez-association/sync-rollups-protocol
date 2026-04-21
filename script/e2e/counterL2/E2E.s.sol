// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {
    Action,
    StateDelta,
    CrossChainCall,
    NestedAction,
    ExecutionEntry,
    StaticCall
} from "../../../src/ICrossChainManager.sol";
import {Counter, CounterAndProxy} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {actionHash, noStaticCalls, noNestedActions, noCalls} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  CounterL2 scenario — L2-starting, simplest case (mirror of counter)
//
//  Flow:
//    1. loadExecutionTable loads ONE entry on L2 with precomputed return=uint256(1)
//    2. User calls CounterAndProxy.incrementProxy() on L2
//    3. CounterAndProxy calls CounterProxy (L2 proxy for Counter@L1)
//    4. Proxy forwards to managerL2.executeCrossChainCall
//    5. Entry consumed, returns abi.encode(1)
//    6. CounterAndProxy (on L2): counter=1, targetCounter=1
//
//  L1 chain is not touched at all in this scenario.
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract CounterL2Actions {
    function _incrementCallData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    function _callAction(address counterL1, address counterAndProxyL2) internal pure returns (Action memory) {
        return Action({
            rollupId: MAINNET_ROLLUP_ID,
            destination: counterL1,
            value: 0,
            data: _incrementCallData(),
            sourceAddress: counterAndProxyL2,
            sourceRollup: L2_ROLLUP_ID
        });
    }

    function _l2Entries(address counterL1, address counterAndProxyL2)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: new StateDelta[](0),
            actionHash: actionHash(_callAction(counterL1, counterAndProxyL2)),
            calls: noCalls(),
            nestedActions: noNestedActions(),
            callCount: 0,
            returnData: abi.encode(uint256(1)),
            failed: false,
            rollingHash: bytes32(0)
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Deploys
// ═══════════════════════════════════════════════════════════════════════

/// @title Deploy — on L1, deploy Counter (the L1 target)
/// Outputs: COUNTER_L1
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterL1 = new Counter();
        console.log("COUNTER_L1=%s", address(counterL1));
        vm.stopBroadcast();
    }
}

/// @title DeployL2 — on L2, create proxy for counterL1 + deploy CounterAndProxy
/// Env: MANAGER_L2, COUNTER_L1
/// Outputs: COUNTER_PROXY_L2, COUNTER_AND_PROXY_L2
contract DeployL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        CrossChainManagerL2 manager = CrossChainManagerL2(managerAddr);

        address counterProxy;
        try manager.createCrossChainProxy(counterL1Addr, MAINNET_ROLLUP_ID) returns (address p) {
            counterProxy = p;
        } catch {
            counterProxy = manager.computeCrossChainProxyAddress(counterL1Addr, MAINNET_ROLLUP_ID);
        }

        CounterAndProxy cap = new CounterAndProxy(Counter(counterProxy));

        console.log("COUNTER_PROXY_L2=%s", counterProxy);
        console.log("COUNTER_AND_PROXY_L2=%s", address(cap));
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// @title ExecuteL2 — local mode: loadExecutionTable (system) + incrementProxy (user) in same block
/// @dev Runs on L2. SYSTEM_ADDRESS is the local deployer (anvil account 0),
///      so the deployer can call loadExecutionTable directly. The run-local.sh
///      `execute_l2_same_block` wrapper disables automine, lets both txs queue,
///      then mines them together — same-block guarantee satisfied.
/// Env: MANAGER_L2, COUNTER_L1, COUNTER_AND_PROXY_L2
contract ExecuteL2 is Script, CounterL2Actions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY_L2");

        console.log("ExecuteL2: manager=%s counterL1=%s cap=%s", managerAddr, counterL1Addr, capAddr);

        vm.startBroadcast();
        CrossChainManagerL2(managerAddr).loadExecutionTable(
            _l2Entries(counterL1Addr, capAddr),
            noStaticCalls()
        );
        console.log("ExecuteL2: loadExecutionTable done");

        CounterAndProxy(capAddr).incrementProxy();
        console.log("ExecuteL2: incrementProxy done");

        console.log("done");
        console.log("counter=%s", CounterAndProxy(capAddr).counter());
        console.log("targetCounter=%s", CounterAndProxy(capAddr).targetCounter());
        vm.stopBroadcast();
    }
}

/// @title ExecuteNetworkL2 — network mode: outputs user tx fields for L2
/// Env: COUNTER_AND_PROXY_L2
contract ExecuteNetworkL2 is Script {
    function run() external view {
        address target = vm.envAddress("COUNTER_AND_PROXY_L2");
        bytes memory data = abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, CounterL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L1")) return "Counter";
        if (a == vm.envAddress("COUNTER_AND_PROXY_L2")) return "CounterAndProxy";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY_L2");

        ExecutionEntry[] memory l2 = _l2Entries(counterL1Addr, capAddr);

        bytes32 l2Hash = _entryHash(l2[0]);
        bytes32 callHash = l2[0].actionHash;

        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(callHash));

        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (1 entry) ===");
        _logL2Entry(0, l2[0]);
    }
}
