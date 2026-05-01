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
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {
    Action,
    actionHash,
    crossChainCallHash,
    noLookupCalls,
    noNestedActions,
    noCalls
} from "../shared/E2EHelpers.sol";

// TODO(post-refactor): this file's `Batcher.execute(rollups, entries, statics, ...)` callsite
// still uses the legacy 7-arg `postBatch(entries, statics, transientCount, ...)` signature.
// New API: `postBatch(ProofSystemBatch[] batches)`. The user (or a follow-up pass) must rewrite
// the Batcher to wrap entries into a `ProofSystemBatch[]` similar to `script/e2e/helloWorld/E2E.s.sol`.
// Other deltas: `entry.failed` removed, `entry.destinationRollupId` added, `StateDelta.currentState` added.

// ═══════════════════════════════════════════════════════════════════════
//  Bridge scenario — L1→L2 with ETH value transfer
//
//  A user deposits ETH via Rollups proxy targeting a destination on L2.
//  The entry carries value=1 ether and a StateDelta.etherDelta=+1e18 on L2.
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

/// @notice Minimal user contract: receives a value-bearing call and forwards it to the L2 proxy.
contract BridgeSender {
    address public immutable L2_PROXY;
    address public immutable L2_DESTINATION;

    constructor(address l2Proxy, address l2Destination) {
        L2_PROXY = l2Proxy;
        L2_DESTINATION = l2Destination;
    }

    function bridge() external payable {
        (bool ok,) = L2_PROXY.call{value: msg.value}("");
        require(ok, "bridge failed");
    }
}

abstract contract BridgeActions {
    function _callAction(address l2Destination, address sender) internal pure returns (Action memory) {
        return Action({
            targetRollupId: L2_ROLLUP_ID,
            targetAddress: l2Destination,
            value: 1 ether,
            data: "", // plain ETH transfer
            sourceAddress: sender,
            sourceRollupId: MAINNET_ROLLUP_ID
        });
    }

    function _l1Entries(address l2Destination, address sender) internal pure returns (ExecutionEntry[] memory entries) {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-bridge"),
            etherDelta: int256(1 ether)
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas,
            crossChainCallHash: actionHash(_callAction(l2Destination, sender)),
            destinationRollupId: L2_ROLLUP_ID,
            calls: noCalls(),
            nestedActions: noNestedActions(),
            callCount: 0,
            returnData: "",
            rollingHash: bytes32(0)
        });
    }
}

/// @title DeployL2 — deploy a placeholder L2 destination (just an address, code not exercised)
/// Outputs: L2_DESTINATION
contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        // Any deterministic contract — we only need its address for hashing.
        BridgeSender stub = new BridgeSender(address(0xDEAD), address(0xBEEF));
        console.log("L2_DESTINATION=%s", address(stub));
        vm.stopBroadcast();
    }
}

/// @title Deploy — on L1, create L2-destination proxy + deploy BridgeSender
/// Env: ROLLUPS, L2_DESTINATION
/// Outputs: L2_PROXY, BRIDGE_SENDER
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address l2DestAddr = vm.envAddress("L2_DESTINATION");

        vm.startBroadcast();
        Rollups rollups = Rollups(rollupsAddr);

        address l2Proxy;
        try rollups.createCrossChainProxy(l2DestAddr, L2_ROLLUP_ID) returns (address p) {
            l2Proxy = p;
        } catch {
            l2Proxy = rollups.computeCrossChainProxyAddress(l2DestAddr, L2_ROLLUP_ID);
        }

        BridgeSender sender = new BridgeSender(l2Proxy, l2DestAddr);
        console.log("L2_PROXY=%s", l2Proxy);
        console.log("BRIDGE_SENDER=%s", address(sender));
        vm.stopBroadcast();
    }
}

/// @notice Batcher: postBatch + bridge() with value in one tx.
contract Batcher {
    function execute(
        Rollups rollups,
        address proofSystem,
        ExecutionEntry[] calldata entries,
        LookupCall[] calldata lookupCalls,
        BridgeSender sender
    )
        external
        payable
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
        sender.bridge{value: msg.value}();
    }
}

/// @title Execute — local mode
contract Execute is Script, BridgeActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address l2DestAddr = vm.envAddress("L2_DESTINATION");
        address senderAddr = vm.envAddress("BRIDGE_SENDER");

        vm.startBroadcast();
        Batcher batcher = new Batcher();
        batcher.execute{
            value: 1 ether
        }(
            Rollups(rollupsAddr),
            proofSystemAddr,
            _l1Entries(l2DestAddr, senderAddr),
            noLookupCalls(),
            BridgeSender(senderAddr)
        );
        console.log("done");
        vm.stopBroadcast();
    }
}

/// @title ExecuteNetwork — network mode: outputs user tx fields
contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("BRIDGE_SENDER");
        console.log("TARGET=%s", target);
        console.log("VALUE=1000000000000000000"); // 1 ether
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(BridgeSender.bridge.selector)));
    }
}

contract ComputeExpected is ComputeExpectedBase, BridgeActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("L2_DESTINATION")) return "L2Destination";
        if (a == vm.envAddress("BRIDGE_SENDER")) return "BridgeSender";
        return _shortAddr(a);
    }

    function run() external view {
        address l2DestAddr = vm.envAddress("L2_DESTINATION");
        address senderAddr = vm.envAddress("BRIDGE_SENDER");

        ExecutionEntry[] memory l1 = _l1Entries(l2DestAddr, senderAddr);
        bytes32 l1Hash = _entryHash(l1[0]);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));

        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 1 ETH bridge) ===");
        _logEntry(0, l1[0]);
    }
}
