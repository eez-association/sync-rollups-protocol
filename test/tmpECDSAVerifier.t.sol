// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {tmpECDSAVerifier} from "../src/verifier/tmpECDSAVerifier.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Rollups} from "../src/Rollups.sol";
import {IProofSystem} from "../src/IProofSystem.sol";
import {ExecutionEntry, StateDelta, Action, ActionType} from "../src/ICrossChainManager.sol";

contract tmpECDSAVerifierTest is Test {
    tmpECDSAVerifier verifier;

    uint256 constant SIGNER_PK = 0xA11CE;
    address signerAddr;
    address owner = address(0xBEEF);

    function setUp() public {
        signerAddr = vm.addr(SIGNER_PK);
        verifier = new tmpECDSAVerifier(owner, signerAddr);
    }

    function _sign(uint256 pk, bytes32 publicInputsHash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, publicInputsHash);
        return abi.encodePacked(r, s, v);
    }

    function test_verify_validSignature() public view {
        bytes32 message = keccak256("test message");
        bytes memory proof = _sign(SIGNER_PK, message);
        assertTrue(verifier.verify(proof, message));
    }

    function test_verify_wrongSigner() public view {
        bytes32 message = keccak256("test message");
        uint256 wrongPk = 0xBAD;
        bytes memory proof = _sign(wrongPk, message);
        assertFalse(verifier.verify(proof, message));
    }

    function test_setSigner_byOwner() public {
        address newSigner = address(0x1234);
        vm.prank(owner);
        verifier.setSigner(newSigner);
        assertEq(verifier.signer(), newSigner);
    }

    function test_setSigner_byNonOwner_reverts() public {
        address nonOwner = address(0xDEAD);
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        verifier.setSigner(address(0x1234));
    }

    function test_postBatch_withECDSAVerifier() public {
        // Deploy Rollups and register the ECDSA verifier as a validator
        Rollups rollups = new Rollups(1);
        rollups.registerProofSystem(IProofSystem(address(verifier)));

        // Create a rollup bound to that validator
        bytes32 initialState = keccak256("initial");
        bytes32 newState = keccak256("new");
        bytes32 vk = keccak256("vk");
        uint256 rollupId = rollups.createRollup(initialState, address(verifier), vk, address(this));

        // Build an immediate entry (actionHash = 0) with a single state delta
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, currentState: initialState, newState: newState, etherDelta: 0});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas,
            actionHash: bytes32(0),
            nextAction: Action({
                actionType: ActionType.CALL,
                rollupId: 0,
                destination: address(0),
                value: 0,
                data: "",
                failed: false,
                sourceAddress: address(0),
                sourceRollup: 0,
                scope: new uint256[](0)
            })
        });

        // Reconstruct publicInputsHash the same way Rollups does
        bytes32[] memory vks = new bytes32[](1);
        vks[0] = vk;
        bytes32[] memory entryHashes = new bytes32[](1);
        entryHashes[0] = keccak256(
            abi.encodePacked(
                abi.encode(deltas),
                abi.encode(vks),
                entries[0].actionHash,
                abi.encode(entries[0].nextAction)
            )
        );

        // Roll forward so blockhash(block.number - 1) is available
        vm.roll(block.number + 1);

        bytes32 publicInputsHash = keccak256(
            abi.encodePacked(
                blockhash(block.number - 1),
                block.timestamp,
                abi.encode(entryHashes),
                abi.encode(new bytes32[](0)), // no blobs
                keccak256("")                 // empty callData
            )
        );

        // Sign the public inputs hash
        bytes memory proof = _sign(SIGNER_PK, publicInputsHash);

        // postBatch should succeed
        rollups.postBatch(address(verifier), entries, 0, "", proof);

        // Verify state was updated
        (,, bytes32 stateRoot,) = rollups.rollups(rollupId);
        assertEq(stateRoot, newState);
    }
}
