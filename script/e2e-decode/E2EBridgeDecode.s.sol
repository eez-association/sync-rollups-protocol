// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Rollups, ProofSystemBatch} from "../../src/Rollups.sol";
import {Rollup} from "../../src/rollupContract/Rollup.sol";
import {IProofSystem} from "../../src/IProofSystem.sol";
import {ExecutionEntry, StateDelta, CrossChainCall, NestedAction, LookupCall} from "../../src/ICrossChainManager.sol";
import {Bridge} from "../../src/periphery/Bridge.sol";
import {_deployBridge} from "../DeployBridge.s.sol";

contract MockProofSystem is IProofSystem {
    function verify(bytes calldata, bytes32) external pure override returns (bool) {
        return true;
    }
}

/// @notice Helper that executes postBatch + bridgeEther in a single transaction.
contract BridgeBatcher {
    function execute(
        Rollups rollups,
        address proofSystem,
        uint256 rollupId,
        ExecutionEntry[] calldata entries,
        LookupCall[] calldata lookupCalls,
        Bridge bridge,
        address destination
    )
        external
        payable
    {
        address[] memory psList = new address[](1);
        psList[0] = proofSystem;
        uint256[] memory rids = new uint256[](1);
        rids[0] = rollupId;
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
        bridge.bridgeEther{value: msg.value}(rollupId, destination);
    }
}

/// @title E2EBridgeDeploy -- Deploy infra + bridge contracts
/// @dev Burns rollupId 0 (MAINNET); L2 rollup at id=1.
contract E2EBridgeDeploy is Script {
    bytes32 constant DEFAULT_VK = keccak256("verificationKey");

    function run() external {
        vm.startBroadcast();

        MockProofSystem ps = new MockProofSystem();
        Rollups rollups = new Rollups();

        address[] memory psList = new address[](1);
        psList[0] = address(ps);
        bytes32[] memory vks = new bytes32[](1);
        vks[0] = DEFAULT_VK;

        Rollup burn = new Rollup(address(rollups), msg.sender, 1, psList, vks);
        rollups.createRollup(address(burn), bytes32(0));

        Rollup l2Manager = new Rollup(address(rollups), msg.sender, 1, psList, vks);
        uint256 rid = rollups.createRollup(address(l2Manager), keccak256("l2-initial-state"));
        require(rid == 1, "expected L2 rollupId = 1");

        bytes32 salt = keccak256("sync-rollups-bridge-v1");
        address bridgeAddr = _deployBridge(salt);
        Bridge bridge = Bridge(bridgeAddr);
        bridge.initialize(address(rollups), 0, msg.sender);

        console.log("PROOF_SYSTEM=%s", address(ps));
        console.log("ROLLUPS=%s", address(rollups));
        console.log("BRIDGE=%s", address(bridge));

        vm.stopBroadcast();
    }
}

/// @title E2EBridgeExecute -- postBatch + bridgeEther via BridgeBatcher (single tx)
contract E2EBridgeExecute is Script {
    function run(address rollupsAddr, address proofSystemAddr, address bridgeAddr) external {
        vm.startBroadcast();

        BridgeBatcher batcher = new BridgeBatcher();

        address destination = msg.sender;
        uint256 L2_ROLLUP_ID = 1;

        bytes32 callHash = keccak256(
            abi.encode(
                L2_ROLLUP_ID, // targetRollupId
                destination, // targetAddress (proxy.originalAddress)
                uint256(1 ether), // value
                bytes(""), // data
                bridgeAddr, // sourceAddress
                uint256(0) // sourceRollupId (MAINNET)
            )
        );

        StateDelta[] memory stateDeltas = new StateDelta[](1);
        stateDeltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-bridge"),
            etherDelta: int256(1 ether)
        });

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: stateDeltas,
            crossChainCallHash: callHash,
            destinationRollupId: L2_ROLLUP_ID,
            calls: new CrossChainCall[](0),
            nestedActions: new NestedAction[](0),
            callCount: 0,
            returnData: "",
            rollingHash: bytes32(0)
        });

        LookupCall[] memory noLookups = new LookupCall[](0);

        batcher.execute{
            value: 1 ether
        }(Rollups(rollupsAddr), proofSystemAddr, L2_ROLLUP_ID, entries, noLookups, Bridge(bridgeAddr), destination);

        console.log("done");

        vm.stopBroadcast();
    }
}
