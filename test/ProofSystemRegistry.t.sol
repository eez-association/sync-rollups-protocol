// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Rollups, BatchUpdate} from "../src/Rollups.sol";
import {IProofSystem} from "../src/IProofSystem.sol";
import {ProofSystemRegistry} from "../src/ProofSystemRegistry.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../src/ICrossChainManager.sol";
import {MockZKVerifier} from "./helpers/TestBase.sol";

/// @notice Tests for `ProofSystemRegistry` + the Rollups single-proof-system wiring
///         (address-keyed, one proof system per rollup for now, with room to extend).
contract ProofSystemRegistryTest is Test {
    Rollups public rollups;
    MockZKVerifier public psA;
    MockZKVerifier public psB;

    address public owner = makeAddr("rollup-owner");
    address public stranger = makeAddr("stranger");

    bytes32 constant VK_A = keccak256("vk-A");
    bytes32 constant VK_B = keccak256("vk-B");

    function setUp() public {
        rollups = new Rollups(1);
        psA = new MockZKVerifier();
        psB = new MockZKVerifier();
    }

    // ── Registry ──

    function test_RegisterProofSystem_Permissionless() public {
        vm.prank(stranger);
        rollups.registerProofSystem(IProofSystem(address(psA)));
        assertTrue(rollups.isProofSystem(address(psA)));
        assertEq(rollups.proofSystemCount(), 1);
        assertEq(rollups.proofSystems(0), address(psA));
    }

    function test_RegisterProofSystem_RejectsZeroAddress() public {
        vm.expectRevert(ProofSystemRegistry.InvalidProofSystem.selector);
        rollups.registerProofSystem(IProofSystem(address(0)));
    }

    function test_RegisterProofSystem_DuplicateReverts() public {
        rollups.registerProofSystem(IProofSystem(address(psA)));
        vm.expectRevert(abi.encodeWithSelector(ProofSystemRegistry.ProofSystemAlreadyRegistered.selector, address(psA)));
        rollups.registerProofSystem(IProofSystem(address(psA)));
    }

    // ── createRollup ──

    function test_CreateRollup_UnregisteredProofSystemReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ProofSystemRegistry.ProofSystemNotRegistered.selector, address(psA)));
        rollups.createRollup(bytes32(0), address(psA), VK_A, owner);
    }

    function test_CreateRollup_ZeroVkeyReverts() public {
        rollups.registerProofSystem(IProofSystem(address(psA)));
        vm.expectRevert(Rollups.InvalidProofSystemConfig.selector);
        rollups.createRollup(bytes32(0), address(psA), bytes32(0), owner);
    }

    function test_CreateRollup_BindsProofSystemAndVkey() public {
        rollups.registerProofSystem(IProofSystem(address(psA)));
        uint256 rollupId = rollups.createRollup(bytes32(0), address(psA), VK_A, owner);

        (address o, address bound,,) = rollups.rollups(rollupId);
        assertEq(o, owner);
        assertEq(bound, address(psA));
        assertEq(rollups.verificationKeys(rollupId, address(psA)), VK_A);
    }

    // ── postBatch proof-system gating ──

    function _immediateEntry(uint256 rollupId, bytes32 curr, bytes32 next) internal pure returns (ExecutionEntry memory e) {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, currentState: curr, newState: next, etherDelta: 0});
        e.stateDeltas = deltas;
        e.actionHash = bytes32(0);
        e.nextAction = Action({
            actionType: ActionType.RESULT,
            rollupId: 0,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    function test_PostBatch_WithBoundProofSystem_Succeeds() public {
        rollups.registerProofSystem(IProofSystem(address(psA)));
        uint256 rollupId = rollups.createRollup(bytes32(0), address(psA), VK_A, owner);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rollupId, bytes32(0), keccak256("s1"));
        rollups.postBatch(address(psA), entries, 0, "", "proof");

        (,, bytes32 stateRoot,) = rollups.rollups(rollupId);
        assertEq(stateRoot, keccak256("s1"));
    }

    function test_PostBatch_WithWrongProofSystemReverts() public {
        rollups.registerProofSystem(IProofSystem(address(psA)));
        rollups.registerProofSystem(IProofSystem(address(psB)));
        uint256 rollupId = rollups.createRollup(bytes32(0), address(psA), VK_A, owner);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rollupId, bytes32(0), keccak256("s1"));
        vm.expectRevert(abi.encodeWithSelector(Rollups.ProofSystemNotAllowedForRollup.selector, rollupId, address(psB)));
        rollups.postBatch(address(psB), entries, 0, "", "proof");
    }

    function test_PostBatch_UnregisteredProofSystemReverts() public {
        rollups.registerProofSystem(IProofSystem(address(psA)));
        uint256 rollupId = rollups.createRollup(bytes32(0), address(psA), VK_A, owner);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rollupId, bytes32(0), keccak256("s1"));
        vm.expectRevert(abi.encodeWithSelector(ProofSystemRegistry.ProofSystemNotRegistered.selector, address(psB)));
        rollups.postBatch(address(psB), entries, 0, "", "proof");
    }

    // ── setProofSystem swaps atomically ──

    function test_SetProofSystem_ReplacesAndClearsPreviousVkey() public {
        rollups.registerProofSystem(IProofSystem(address(psA)));
        rollups.registerProofSystem(IProofSystem(address(psB)));
        uint256 rollupId = rollups.createRollup(bytes32(0), address(psA), VK_A, owner);

        vm.prank(owner);
        rollups.setProofSystem(rollupId, address(psB), VK_B);

        (, address bound,,) = rollups.rollups(rollupId);
        assertEq(bound, address(psB));
        assertEq(rollups.verificationKeys(rollupId, address(psA)), bytes32(0), "old vkey must be cleared");
        assertEq(rollups.verificationKeys(rollupId, address(psB)), VK_B);
    }

    function test_SetProofSystem_NotOwnerReverts() public {
        rollups.registerProofSystem(IProofSystem(address(psA)));
        rollups.registerProofSystem(IProofSystem(address(psB)));
        uint256 rollupId = rollups.createRollup(bytes32(0), address(psA), VK_A, owner);

        vm.prank(stranger);
        vm.expectRevert(Rollups.NotRollupOwner.selector);
        rollups.setProofSystem(rollupId, address(psB), VK_B);
    }

    // ── batchUpdates (block-scoped) ──

    function test_BatchUpdates_RecordedInCurrentBlock() public {
        rollups.registerProofSystem(IProofSystem(address(psA)));
        uint256 rollupId = rollups.createRollup(bytes32(0), address(psA), VK_A, owner);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rollupId, bytes32(0), keccak256("s1"));
        rollups.postBatch(address(psA), entries, 0, "", "proof");

        BatchUpdate memory u = rollups.currentBlockUpdate(rollupId);
        assertEq(u.blockNumber, block.number);
        assertEq(u.previousState, bytes32(0));
        assertEq(u.newState, keccak256("s1"));
    }

    function test_BatchUpdates_InvalidateOnBlockAdvance() public {
        rollups.registerProofSystem(IProofSystem(address(psA)));
        uint256 rollupId = rollups.createRollup(bytes32(0), address(psA), VK_A, owner);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rollupId, bytes32(0), keccak256("s1"));
        rollups.postBatch(address(psA), entries, 0, "", "proof");

        vm.roll(block.number + 1);

        BatchUpdate memory u = rollups.currentBlockUpdate(rollupId);
        assertEq(u.blockNumber, 0, "should report empty after block advances");
        assertEq(u.newState, bytes32(0));
    }
}
