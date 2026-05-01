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
import {Counter, CounterAndProxy} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {crossChainCallHash, noLookupCalls, noNestedActions, noCalls} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  Counter scenario — L1-starting, simplest case
//
//  Flow:
//    1. postBatch loads ONE deferred L1 entry with precomputed return=uint256(1)
//    2. User calls CounterAndProxy.incrementProxy() on L1
//    3. CounterAndProxy calls CounterProxy (L1 proxy for Counter@L2)
//    4. Proxy forwards to Rollups.executeCrossChainCall
//    5. Entry consumed, returns abi.encode(1)
//    6. CounterAndProxy: counter=1, targetCounter=1
//    7. L2 rollup stateRoot updated via StateDelta (no L2 code runs)
//
//  The L2 chain does NOT need to execute anything in this simple flow —
//  this is the flatten model's sharpest improvement over scope-based designs.
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

/// @dev Centralized action + entry definitions — single source of truth for all contracts.
abstract contract CounterActions {
    function _incrementCallData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    function _callHash(address counterL2, address counterAndProxy) internal pure returns (bytes32) {
        return crossChainCallHash(L2_ROLLUP_ID, counterL2, 0, _incrementCallData(), counterAndProxy, MAINNET_ROLLUP_ID);
    }

    /// @dev Single L1 entry — matches Scenario 1 of IntegrationTest.t.sol.
    function _l1Entries(address counterL2, address counterAndProxy)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-counter"),
            etherDelta: 0
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas,
            crossChainCallHash: _callHash(counterL2, counterAndProxy),
            destinationRollupId: L2_ROLLUP_ID,
            calls: noCalls(),
            nestedActions: noNestedActions(),
            callCount: 0,
            returnData: abi.encode(uint256(1)),
            rollingHash: bytes32(0)
        });
    }
}

/// @notice Batcher: postBatch + incrementProxy in one tx (local mode only).
contract Batcher {
    function execute(
        Rollups rollups,
        address proofSystem,
        ExecutionEntry[] calldata entries,
        LookupCall[] calldata lookupCalls,
        CounterAndProxy cap
    )
        external
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
        cap.incrementProxy();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Deploys
// ═══════════════════════════════════════════════════════════════════════

/// @title DeployL2 — deploy Counter on L2
/// Outputs: COUNTER_L2
contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterL2 = new Counter();
        console.log("COUNTER_L2=%s", address(counterL2));
        vm.stopBroadcast();
    }
}

/// @title Deploy — on L1, create proxy for counterL2 + deploy CounterAndProxy
/// Env: ROLLUPS, COUNTER_L2
/// Outputs: COUNTER_PROXY, COUNTER_AND_PROXY
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

        CounterAndProxy cap = new CounterAndProxy(Counter(counterProxy));

        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("COUNTER_AND_PROXY=%s", address(cap));
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// @title Execute — local mode: postBatch + incrementProxy via Batcher
/// Env: ROLLUPS, COUNTER_L2, COUNTER_AND_PROXY
contract Execute is Script, CounterActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY");

        vm.startBroadcast();
        Batcher batcher = new Batcher();
        batcher.execute(
            Rollups(rollupsAddr),
            proofSystemAddr,
            _l1Entries(counterL2Addr, capAddr),
            noLookupCalls(),
            CounterAndProxy(capAddr)
        );

        console.log("done");
        console.log("counter=%s", CounterAndProxy(capAddr).counter());
        console.log("targetCounter=%s", CounterAndProxy(capAddr).targetCounter());
        vm.stopBroadcast();
    }
}

/// @title ExecuteNetwork — network mode: outputs user tx fields (no Batcher)
/// Env: COUNTER_AND_PROXY
contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("COUNTER_AND_PROXY");
        bytes memory data = abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected — print expected table for verification
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, CounterActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L2")) return "Counter";
        if (a == vm.envAddress("COUNTER_AND_PROXY")) return "CounterAndProxy";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY");

        ExecutionEntry[] memory l1 = _l1Entries(counterL2Addr, capAddr);

        bytes32 l1Hash = _entryHash(l1[0]);
        bytes32 callHash = l1[0].crossChainCallHash;

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("EXPECTED_L1_CALL_HASHES=[%s]", vm.toString(callHash));

        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (1 entry) ===");
        _logEntry(0, l1[0]);
    }
}
