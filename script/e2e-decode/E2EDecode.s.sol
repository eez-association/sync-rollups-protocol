// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Rollups, ProofSystemBatch} from "../../src/Rollups.sol";
import {Rollup} from "../../src/rollupContract/Rollup.sol";
import {IProofSystem} from "../../src/IProofSystem.sol";
import {ExecutionEntry, StateDelta, CrossChainCall, NestedAction, LookupCall} from "../../src/ICrossChainManager.sol";
import {Counter, CounterAndProxy} from "../../test/mocks/CounterContracts.sol";

contract MockProofSystem is IProofSystem {
    function verify(bytes calldata, bytes32) external pure override returns (bool) {
        return true;
    }
}

/// @notice Helper that executes postBatch + incrementProxy in a single transaction.
/// @dev Same-block requirement for executeCrossChainCall after postBatch.
contract Batcher {
    function execute(
        Rollups rollups,
        address proofSystem,
        uint256 rollupId,
        ExecutionEntry[] calldata entries,
        LookupCall[] calldata lookupCalls,
        CounterAndProxy cap
    )
        external
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
        cap.incrementProxy();
    }
}

/// @title E2EDeploy -- Deploy infra + app contracts (single tx)
/// @dev Burns rollupId 0 (MAINNET); L2 rollup at id=1.
contract E2EDeploy is Script {
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

        Counter counterL2 = new Counter();
        address counterProxy = rollups.createCrossChainProxy(address(counterL2), 1);
        CounterAndProxy counterAndProxy = new CounterAndProxy(Counter(counterProxy));

        console.log("PROOF_SYSTEM=%s", address(ps));
        console.log("ROLLUPS=%s", address(rollups));
        console.log("COUNTER_L2=%s", address(counterL2));
        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("COUNTER_AND_PROXY=%s", address(counterAndProxy));

        vm.stopBroadcast();
    }
}

/// @title E2EExecute -- postBatch + incrementProxy via Batcher (single tx)
contract E2EExecute is Script {
    function run(address rollupsAddr, address proofSystemAddr, address counterL2Addr, address counterAndProxyAddr)
        external
    {
        vm.startBroadcast();

        Batcher batcher = new Batcher();

        Rollups rollups = Rollups(rollupsAddr);
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // Cross-chain call hash: CounterAndProxy → CounterProxy → counterL2 (rollupId=1).
        bytes32 callHash = keccak256(
            abi.encode(
                uint256(1), // targetRollupId (L2)
                counterL2Addr, // targetAddress
                uint256(0), // value
                incrementCallData, // data
                counterAndProxyAddr, // sourceAddress
                uint256(0) // sourceRollupId (MAINNET)
            )
        );

        StateDelta[] memory stateDeltas = new StateDelta[](1);
        stateDeltas[0] = StateDelta({
            rollupId: 1,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-scenario1"),
            etherDelta: 0
        });

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: stateDeltas,
            crossChainCallHash: callHash,
            destinationRollupId: 1,
            calls: new CrossChainCall[](0),
            nestedActions: new NestedAction[](0),
            callCount: 0,
            returnData: abi.encode(uint256(1)),
            rollingHash: bytes32(0)
        });

        LookupCall[] memory noLookups = new LookupCall[](0);

        batcher.execute(rollups, proofSystemAddr, 1, entries, noLookups, CounterAndProxy(counterAndProxyAddr));

        console.log("done");
        console.log("counter=%s", CounterAndProxy(counterAndProxyAddr).counter());
        console.log("targetCounter=%s", CounterAndProxy(counterAndProxyAddr).targetCounter());

        vm.stopBroadcast();
    }
}
