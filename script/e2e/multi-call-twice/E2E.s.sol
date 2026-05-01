// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Rollups, ProofSystemBatch} from "../../../src/Rollups.sol";
import {
    StateDelta,
    CrossChainCall,
    NestedAction,
    ExecutionEntry,
    LookupCall
} from "../../../src/ICrossChainManager.sol";
import {Counter} from "../../../test/mocks/CounterContracts.sol";
import {CallTwice} from "../../../test/mocks/MultiCallContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {Action, actionHash, noLookupCalls, noNestedActions, noCalls} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  Multi-call scenario: same target twice
//
//  CallTwice.callCounterTwice(counterProxy) invokes increment() twice.
//  Each invocation consumes an entry sequentially — two entries with the
//  SAME actionHash but different returnData (1 and 2).
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract MultiCallActions {
    function _callAction(address counterL2, address caller) internal pure returns (Action memory) {
        return Action({
            targetRollupId: L2_ROLLUP_ID,
            targetAddress: counterL2,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            sourceAddress: caller,
            sourceRollupId: MAINNET_ROLLUP_ID
        });
    }

    function _l1Entries(address counterL2, address caller) internal pure returns (ExecutionEntry[] memory entries) {
        bytes32 ah = actionHash(_callAction(counterL2, caller));

        StateDelta[] memory deltasA = new StateDelta[](1);
        deltasA[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-twice-1"),
            etherDelta: 0
        });

        StateDelta[] memory deltasB = new StateDelta[](1);
        deltasB[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-state-after-twice-1"),
            newState: keccak256("l2-state-after-twice-2"),
            etherDelta: 0
        });

        entries = new ExecutionEntry[](2);
        entries[0] = ExecutionEntry({
            stateDeltas: deltasA,
            crossChainCallHash: ah,
            destinationRollupId: L2_ROLLUP_ID,
            calls: noCalls(),
            nestedActions: noNestedActions(),
            callCount: 0,
            returnData: abi.encode(uint256(1)),
            rollingHash: bytes32(0)
        });
        entries[1] = ExecutionEntry({
            stateDeltas: deltasB,
            crossChainCallHash: ah,
            destinationRollupId: L2_ROLLUP_ID,
            calls: noCalls(),
            nestedActions: noNestedActions(),
            callCount: 0,
            returnData: abi.encode(uint256(2)),
            rollingHash: bytes32(0)
        });
    }
}

contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        Counter counter = new Counter();
        console.log("COUNTER_L2=%s", address(counter));
        vm.stopBroadcast();
    }
}

contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2Addr = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();
        Rollups rollups = Rollups(rollupsAddr);

        address counterProxy;
        try rollups.createCrossChainProxy(counterL2Addr, L2_ROLLUP_ID) returns (address p) {
            counterProxy = p;
        } catch {
            counterProxy = rollups.computeCrossChainProxyAddress(counterL2Addr, L2_ROLLUP_ID);
        }

        CallTwice caller = new CallTwice();
        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("CALL_TWICE=%s", address(caller));
        vm.stopBroadcast();
    }
}

contract Batcher {
    function execute(
        Rollups rollups,
        address proofSystem,
        ExecutionEntry[] calldata entries,
        LookupCall[] calldata lookupCalls,
        CallTwice caller,
        address counterProxy
    )
        external
        returns (uint256 first, uint256 second)
    {
        address[] memory psList = new address[](1);
        psList[0] = proofSystem;
        uint256[] memory rids = new uint256[](1);
        rids[0] = L2_ROLLUP_ID;
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";
        ProofSystemBatch[] memory batches = new ProofSystemBatch[](1);
        batches[0] = ProofSystemBatch({
            proofSystems: psList,
            rollupIds: rids,
            entries: entries,
            lookupCalls: lookupCalls,
            transientCount: 0,
            transientLookupCallCount: 0,
            blobIndices: new uint256[](0),
            callData: "",
            proof: proofs,
            crossProofSystemInteractions: bytes32(0)
        });
        rollups.postBatch(batches);
        (first, second) = caller.callCounterTwice(counterProxy);
    }
}

contract Execute is Script, MultiCallActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address counterProxy = vm.envAddress("COUNTER_PROXY");
        address callerAddr = vm.envAddress("CALL_TWICE");

        vm.startBroadcast();
        Batcher batcher = new Batcher();
        (uint256 first, uint256 second) = batcher.execute(
            Rollups(rollupsAddr),
            proofSystemAddr,
            _l1Entries(counterL2Addr, callerAddr),
            noLookupCalls(),
            CallTwice(callerAddr),
            counterProxy
        );
        console.log("done");
        console.log("first=%s second=%s", first, second);
        vm.stopBroadcast();
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        address caller = vm.envAddress("CALL_TWICE");
        address counterProxy = vm.envAddress("COUNTER_PROXY");
        console.log("TARGET=%s", caller);
        console.log("VALUE=0");
        console.log(
            "CALLDATA=%s", vm.toString(abi.encodeWithSelector(CallTwice.callCounterTwice.selector, counterProxy))
        );
    }
}

contract ComputeExpected is ComputeExpectedBase, MultiCallActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L2")) return "Counter";
        if (a == vm.envAddress("CALL_TWICE")) return "CallTwice";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address callerAddr = vm.envAddress("CALL_TWICE");

        ExecutionEntry[] memory l1 = _l1Entries(counterL2Addr, callerAddr);
        bytes32 h0 = _entryHash(l1[0]);
        bytes32 h1 = _entryHash(l1[1]);

        console.log("EXPECTED_L1_HASHES=[%s,%s]", vm.toString(h0), vm.toString(h1));
        console.log("");
        console.log("=== EXPECTED L1 TABLE (2 entries, same actionHash) ===");
        for (uint256 i = 0; i < l1.length; i++) {
            _logEntry(i, l1[i]);
        }
    }
}
