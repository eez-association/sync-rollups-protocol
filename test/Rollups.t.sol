// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {Rollups, RollupConfig} from "../src/Rollups.sol";
import {IProofSystem} from "../src/IProofSystem.sol";
import {Action, ActionType, ExecutionEntry, StateDelta, ProxyInfo} from "../src/ICrossChainManager.sol";
import {CrossChainProxy} from "../src/CrossChainProxy.sol";
import {MockZKVerifier} from "./helpers/TestBase.sol";

/// @notice Simple target contract for testing
contract TestTarget {
    uint256 public value;

    function setValue(uint256 _value) external {
        value = _value;
    }

    function getValue() external view returns (uint256) {
        return value;
    }

    receive() external payable {}
}

/// @notice Target contract that always reverts
contract RevertingTarget {
    error TargetReverted();

    fallback() external payable {
        revert TargetReverted();
    }
}

contract RollupsTest is Test {
    Rollups public rollups;
    MockZKVerifier public verifier;
    TestTarget public target;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    bytes32 constant DEFAULT_VK = keccak256("verificationKey");

    function setUp() public {
        verifier = new MockZKVerifier();
        rollups = new Rollups(1);
        rollups.registerProofSystem(IProofSystem(address(verifier)));
        target = new TestTarget();
    }

    function _createRollup(bytes32 initialState, bytes32 vk, address owner) internal returns (uint256) {
        Rollups _r = rollups;
        return _r.createRollup(initialState, address(verifier), vk, owner);
    }

    function _postBatch(ExecutionEntry[] memory entries, uint256 blobs, bytes memory data, bytes memory proof) internal {
        Rollups _r = rollups;
        _r.postBatch(address(verifier), entries, blobs, data, proof);
    }

    function _getRollupState(uint256 rollupId) internal view returns (bytes32) {
        (,, bytes32 stateRoot,) = rollups.rollups(rollupId);
        return stateRoot;
    }

    function _getRollupOwner(uint256 rollupId) internal view returns (address) {
        (address owner,,,) = rollups.rollups(rollupId);
        return owner;
    }

    function _getRollupVK(uint256 rollupId) internal view returns (bytes32) {
        return rollups.verificationKeys(rollupId, address(verifier));
    }

    function _getRollupEtherBalance(uint256 rollupId) internal view returns (uint256) {
        (,,, uint256 etherBalance) = rollups.rollups(rollupId);
        return etherBalance;
    }

    /// @notice Directly sets a rollup's ether balance and funds the contract
    function _fundRollup(uint256 rollupId, uint256 amount) internal {
        // Storage layout (Rollups inherits ProofSystemRegistry which occupies slots 0-1):
        //   isProofSystem mapping  = slot 0
        //   validators array     = slot 1
        //   rollupCounter        = slot 2
        //   rollups mapping      = slot 3
        // RollupConfig is {owner, validator, stateRoot, etherBalance}; etherBalance is field index 3.
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(rollupId, uint256(3)))) + 3);
        vm.store(address(rollups), slot, bytes32(amount));
        vm.deal(address(rollups), address(rollups).balance + amount);
    }

    function _emptyAction() internal pure returns (Action memory) {
        return Action({
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

    /// @notice Helper to build an immediate state update entry (actionHash == 0)
    function _immediateEntry(uint256 rollupId, bytes32 currentState, bytes32 newState)
        internal
        pure
        returns (ExecutionEntry memory entry)
    {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, currentState: currentState, newState: newState, etherDelta: 0});
        entry.stateDeltas = deltas;
        entry.actionHash = bytes32(0);
        entry.nextAction = Action({
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

    /// @notice Helper to build the RESULT action that _processCallAtScope creates
    /// after a successful executeOnBehalf call to a void function
    function _buildResultAction(uint256 rollupId) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: "", // raw return from executeOnBehalf (void = empty)
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    /// @notice Helper to build a REVERT_CONTINUE action for a given rollupId
    function _buildRevertContinue(uint256 rollupId) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.REVERT_CONTINUE,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: "",
            failed: true,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    // ──────────────────────────────────────────────
    //  Original tests
    // ──────────────────────────────────────────────

    function test_CreateRollup() public {
        bytes32 initialState = keccak256("initial");
        uint256 rollupId = _createRollup(initialState, DEFAULT_VK, alice);
        assertEq(rollupId, 1);

        uint256 rollupId2 = _createRollup(bytes32(0), DEFAULT_VK, bob);
        assertEq(rollupId2, 2);

        assertEq(_getRollupState(rollupId), initialState);
        assertEq(_getRollupOwner(rollupId), alice);
        assertEq(_getRollupVK(rollupId), DEFAULT_VK);

        assertEq(_getRollupState(rollupId2), bytes32(0));
        assertEq(_getRollupOwner(rollupId2), bob);
    }

    function test_CreateCrossChainProxy() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        address targetAddr = address(0x1234);
        address proxy = rollups.createCrossChainProxy(targetAddr, rollupId);

        // Verify proxy is authorized
        (address origAddr,) = rollups.authorizedProxies(proxy);
        assertTrue(origAddr != address(0));

        uint256 codeSize;
        assembly {
            codeSize := extcodesize(proxy)
        }
        assertTrue(codeSize > 0);
    }

    function test_ComputeCrossChainProxyAddress() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        address targetAddr = address(0x5678);

        address computedAddr = rollups.computeCrossChainProxyAddress(targetAddr, rollupId);
        address actualAddr = rollups.createCrossChainProxy(targetAddr, rollupId);

        assertEq(computedAddr, actualAddr);
    }

    function test_PostBatch_ImmediateStateUpdate() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newState = keccak256("new state");

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rollupId, bytes32(0), newState);

        _postBatch(entries, 0, "", "proof");

        assertEq(_getRollupState(rollupId), newState);
    }

    function test_PostBatch_MultipleRollups() public {
        uint256 rollupId1 = _createRollup(bytes32(0), DEFAULT_VK, alice);
        uint256 rollupId2 = _createRollup(bytes32(0), DEFAULT_VK, bob);
        bytes32 newState1 = keccak256("new state 1");
        bytes32 newState2 = keccak256("new state 2");

        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _immediateEntry(rollupId1, bytes32(0), newState1);
        entries[1] = _immediateEntry(rollupId2, bytes32(0), newState2);

        _postBatch(entries, 0, "shared data", "proof");

        assertEq(_getRollupState(rollupId1), newState1);
        assertEq(_getRollupState(rollupId2), newState2);
    }

    function test_PostBatch_InvalidProof() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newState = keccak256("new state");

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rollupId, bytes32(0), newState);

        verifier.setVerifyResult(false);

        vm.expectRevert(Rollups.InvalidProof.selector);
        _postBatch(entries, 0, "", "bad proof");
    }

    function test_PostBatch_AfterL2ExecutionSameBlockReverts() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);

        bytes32 currentState = bytes32(0);
        bytes32 newState = keccak256("state1");

        bytes memory callData = abi.encodeCall(TestTarget.setValue, (42));

        // Build the CALL action as executeCrossChainCall would
        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        Action memory resultAction = _emptyAction();

        StateDelta[] memory stateDeltas = new StateDelta[](1);
        stateDeltas[0] = StateDelta({rollupId: rollupId, currentState: currentState, newState: newState, etherDelta: 0});

        // Load execution via postBatch (deferred entry)
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = stateDeltas;
        entries[0].actionHash = keccak256(abi.encode(action));
        entries[0].nextAction = resultAction;
        _postBatch(entries, 0, "", "proof");

        // Execute L2 via proxy fallback
        (bool success,) = proxyAddr.call(callData);
        assertTrue(success);
        assertEq(_getRollupState(rollupId), newState);

        // Now try to call postBatch in the same block - should revert
        ExecutionEntry[] memory entries2 = new ExecutionEntry[](1);
        entries2[0] = _immediateEntry(rollupId, newState, keccak256("another state"));

        vm.expectRevert(Rollups.StateAlreadyUpdatedThisBlock.selector);
        _postBatch(entries2, 0, "", "proof");

        assertEq(_getRollupState(rollupId), newState);
    }

    function test_SetStateByOwner() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newState = keccak256("owner set state");

        vm.prank(alice);
        rollups.setStateByOwner(rollupId, newState);

        assertEq(_getRollupState(rollupId), newState);
    }

    function test_SetStateByOwner_NotOwner() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newState = keccak256("owner set state");

        vm.prank(bob);
        vm.expectRevert(Rollups.NotRollupOwner.selector);
        rollups.setStateByOwner(rollupId, newState);
    }

    function test_SetVerificationKey() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newVK = keccak256("new verification key");

        vm.prank(alice);
        rollups.setVerificationKey(rollupId, newVK);

        assertEq(_getRollupVK(rollupId), newVK);
    }

    function test_SetVerificationKey_NotOwner() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newVK = keccak256("new verification key");

        vm.prank(bob);
        vm.expectRevert(Rollups.NotRollupOwner.selector);
        rollups.setVerificationKey(rollupId, newVK);
    }

    function test_TransferRollupOwnership() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        vm.prank(alice);
        rollups.transferRollupOwnership(rollupId, bob);

        assertEq(_getRollupOwner(rollupId), bob);

        vm.prank(bob);
        rollups.setStateByOwner(rollupId, keccak256("bob's state"));

        vm.prank(alice);
        vm.expectRevert(Rollups.NotRollupOwner.selector);
        rollups.setStateByOwner(rollupId, keccak256("alice's state"));
    }

    function test_ExecuteCrossChainCall_Simple() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);

        bytes32 currentState = bytes32(0);
        bytes32 newState = keccak256("state1");

        bytes memory callData = abi.encodeCall(TestTarget.setValue, (42));

        // Build the CALL action matching what executeCrossChainCall builds
        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        Action memory resultAction = _emptyAction();

        StateDelta[] memory stateDeltas = new StateDelta[](1);
        stateDeltas[0] = StateDelta({rollupId: rollupId, currentState: currentState, newState: newState, etherDelta: 0});

        // Load execution
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = stateDeltas;
        entries[0].actionHash = keccak256(abi.encode(action));
        entries[0].nextAction = resultAction;
        _postBatch(entries, 0, "", "proof");

        // Execute via proxy fallback
        (bool success,) = proxyAddr.call(callData);
        assertTrue(success);

        assertEq(_getRollupState(rollupId), newState);
    }

    function test_ExecuteCrossChainCall_UnauthorizedProxy() public {
        _createRollup(bytes32(0), DEFAULT_VK, alice);

        // Call executeCrossChainCall directly (not from a proxy)
        vm.expectRevert(Rollups.UnauthorizedProxy.selector);
        rollups.executeCrossChainCall(alice, "");
    }

    function test_ExecuteCrossChainCall_ExecutionNotFound() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);

        // Call via proxy without loading execution
        bytes memory callData = abi.encodeCall(TestTarget.setValue, (999));
        vm.expectRevert(Rollups.ExecutionNotFound.selector);
        (bool success,) = proxyAddr.call(callData);
        success;
    }

    function test_ExecuteL2TX() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        bytes32 currentState = bytes32(0);
        bytes32 newState = keccak256("state1");

        bytes memory rlpTx = hex"deadbeef";

        // Build L2TX action
        Action memory action = Action({
            actionType: ActionType.L2TX,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: rlpTx,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        Action memory resultAction = _emptyAction();

        StateDelta[] memory stateDeltas = new StateDelta[](1);
        stateDeltas[0] = StateDelta({rollupId: rollupId, currentState: currentState, newState: newState, etherDelta: 0});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = stateDeltas;
        entries[0].actionHash = keccak256(abi.encode(action));
        entries[0].nextAction = resultAction;
        _postBatch(entries, 0, "", "proof");

        rollups.executeL2TX(rollupId, rlpTx);

        assertEq(_getRollupState(rollupId), newState);
    }

    function test_StartingRollupId() public {
        Rollups rollups2 = new Rollups(1000);
        rollups2.registerProofSystem(IProofSystem(address(verifier)));

        uint256 rollupId = rollups2.createRollup(bytes32(0), address(verifier), DEFAULT_VK, alice);
        assertEq(rollupId, 1000);

        uint256 rollupId2 = rollups2.createRollup(bytes32(0), address(verifier), DEFAULT_VK, alice);
        assertEq(rollupId2, 1001);
    }

    function test_MultipleProxiesSameTarget() public {
        uint256 rollup1 = _createRollup(bytes32(0), DEFAULT_VK, alice);
        uint256 rollup2 = _createRollup(bytes32(0), DEFAULT_VK, alice);

        address targetAddr = address(0x9999);

        address proxy1 = rollups.createCrossChainProxy(targetAddr, rollup1);
        address proxy2 = rollups.createCrossChainProxy(targetAddr, rollup2);

        assertTrue(proxy1 != proxy2);

        (address origAddr1,) = rollups.authorizedProxies(proxy1);
        (address origAddr2,) = rollups.authorizedProxies(proxy2);
        assertTrue(origAddr1 != address(0));
        assertTrue(origAddr2 != address(0));
    }

    function test_RollupWithCustomInitialState() public {
        bytes32 customState = keccak256("custom initial state");
        bytes32 customVK = keccak256("custom vk");

        uint256 rollupId = _createRollup(customState, customVK, bob);

        assertEq(_getRollupState(rollupId), customState);
        assertEq(_getRollupVK(rollupId), customVK);
        assertEq(_getRollupOwner(rollupId), bob);
    }

    // ──────────────────────────────────────────────
    //  Deposits & ether tracking
    // ──────────────────────────────────────────────

    function test_PostBatch_EtherDeltasMustSumToZero() public {
        uint256 rollupId1 = _createRollup(bytes32(0), DEFAULT_VK, alice);
        uint256 rollupId2 = _createRollup(bytes32(0), DEFAULT_VK, bob);

        // Fund rollup1 so it has balance to transfer
        _fundRollup(rollupId1, 5 ether);

        // Transfer 2 ether from rollup1 to rollup2 (sum = 0)
        StateDelta[] memory deltas = new StateDelta[](2);
        deltas[0] = StateDelta({
            rollupId: rollupId1, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: -2 ether
        });
        deltas[1] =
            StateDelta({rollupId: rollupId2, currentState: bytes32(0), newState: keccak256("s2"), etherDelta: 2 ether});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = bytes32(0);
        entries[0].nextAction = _emptyAction();

        _postBatch(entries, 0, "", "proof");

        assertEq(_getRollupEtherBalance(rollupId1), 3 ether);
        assertEq(_getRollupEtherBalance(rollupId2), 2 ether);
    }

    function test_PostBatch_EtherDeltasNonZeroSumReverts() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        _fundRollup(rollupId, 5 ether);

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] =
            StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: 1 ether});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = bytes32(0);
        entries[0].nextAction = _emptyAction();

        vm.expectRevert(Rollups.EtherDeltaMismatch.selector);
        _postBatch(entries, 0, "", "proof");
    }

    function test_PostBatch_InsufficientRollupBalanceReverts() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        // No deposit - balance is 0

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] =
            StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: -1 ether});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = bytes32(0);
        entries[0].nextAction = _emptyAction();

        vm.expectRevert(Rollups.InsufficientRollupBalance.selector);
        _postBatch(entries, 0, "", "proof");
    }

    function test_PostBatch_MixedImmediateAndDeferred() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);

        bytes32 state1 = keccak256("state1");
        bytes32 state2 = keccak256("state2");
        bytes memory callData = abi.encodeCall(TestTarget.setValue, (42));

        // Build CALL action for the deferred entry
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        // Mixed batch: one immediate, one deferred
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);

        // Immediate entry
        entries[0] = _immediateEntry(rollupId, bytes32(0), state1);

        // Deferred entry (needs state1 as currentState since immediate applies first)
        StateDelta[] memory deferredDeltas = new StateDelta[](1);
        deferredDeltas[0] = StateDelta({rollupId: rollupId, currentState: state1, newState: state2, etherDelta: 0});
        entries[1].stateDeltas = deferredDeltas;
        entries[1].actionHash = keccak256(abi.encode(callAction));
        entries[1].nextAction = _emptyAction();

        _postBatch(entries, 0, "", "proof");

        // Immediate was applied
        assertEq(_getRollupState(rollupId), state1);

        // Deferred can be consumed
        (bool success,) = proxyAddr.call(callData);
        assertTrue(success);
        assertEq(_getRollupState(rollupId), state2);
    }

    function test_PostBatch_SetsLastStateUpdateBlock() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rollupId, bytes32(0), keccak256("s"));

        _postBatch(entries, 0, "", "proof");

        assertEq(rollups.lastStateUpdateBlock(), block.number);
    }

    // ──────────────────────────────────────────────
    //  Proxy immutables (now internal — all non-manager calls hit fallback)
    // ──────────────────────────────────────────────

    // ══════════════════════════════════════════════
    //  NEW COVERAGE TESTS
    // ══════════════════════════════════════════════

    // ──────────────────────────────────────────────
    //  newScope: unauthorized caller (line 357-358)
    // ──────────────────────────────────────────────

    function test_NewScope_UnauthorizedCaller() public {
        uint256[] memory scope = new uint256[](0);
        Action memory action = _emptyAction();

        vm.prank(alice);
        vm.expectRevert(Rollups.UnauthorizedProxy.selector);
        rollups.newScope(scope, action);
    }

    // ──────────────────────────────────────────────
    //  Scope navigation: CALL at matching scope (lines 375-377)
    //  Covers: _processCallAtScope (409-453), _resolveScopes CALL path (540-543)
    //  _scopesMatch (613-618), _isChildScope (625-630), _appendToScope (600-606)
    // ──────────────────────────────────────────────

    function test_ScopeCall_AtMatchingScope() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        // Create source proxy for (address(this), rollup 0)
        rollups.createCrossChainProxy(address(this), 0);

        bytes32 state1 = keccak256("s1");
        bytes32 state2 = keccak256("s2");

        uint256[] memory callScope = new uint256[](1);
        callScope[0] = 0;

        // Build scoped CALL action
        Action memory scopedCall = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: abi.encodeCall(TestTarget.setValue, (42)),
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: callScope
        });

        // The RESULT that _processCallAtScope will build after calling executeOnBehalf
        // executeOnBehalf calls target.setValue(42) which returns nothing
        // returnData from .call() = "" (raw empty bytes)
        Action memory expectedResult = _buildResultAction(rollupId);
        bytes32 resultHash = keccak256(abi.encode(expectedResult));

        Action memory finalResult = _emptyAction();

        // Build L2TX to trigger the flow
        bytes memory rlpTx = hex"01";
        Action memory l2tx = Action({
            actionType: ActionType.L2TX,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: rlpTx,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 l2txHash = keccak256(abi.encode(l2tx));

        ExecutionEntry[] memory entries = new ExecutionEntry[](2);

        // Entry 1: L2TX -> scoped CALL
        StateDelta[] memory d1 = new StateDelta[](1);
        d1[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: state1, etherDelta: 0});
        entries[0].stateDeltas = d1;
        entries[0].actionHash = l2txHash;
        entries[0].nextAction = scopedCall;

        // Entry 2: RESULT from executeOnBehalf -> final RESULT
        StateDelta[] memory d2 = new StateDelta[](1);
        d2[0] = StateDelta({rollupId: rollupId, currentState: state1, newState: state2, etherDelta: 0});
        entries[1].stateDeltas = d2;
        entries[1].actionHash = resultHash;
        entries[1].nextAction = finalResult;

        _postBatch(entries, 0, "", "proof");

        rollups.executeL2TX(rollupId, rlpTx);
        assertEq(_getRollupState(rollupId), state2);
        assertEq(target.value(), 42);
    }

    // ──────────────────────────────────────────────
    //  Scope navigation: CALL at child scope (lines 365-374)
    //  Covers: _isChildScope true, _appendToScope, recursive newScope
    // ──────────────────────────────────────────────

    function test_ScopeCall_AtChildScope() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        rollups.createCrossChainProxy(address(this), 0);

        bytes32 state1 = keccak256("cs1");
        bytes32 state2 = keccak256("cs2");

        // CALL at deep scope [0, 1]: from empty scope, this is a child
        uint256[] memory deepScope = new uint256[](2);
        deepScope[0] = 0;
        deepScope[1] = 1;

        Action memory deepCall = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: abi.encodeCall(TestTarget.setValue, (99)),
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: deepScope
        });

        Action memory expectedResult = _buildResultAction(rollupId);
        bytes32 resultHash = keccak256(abi.encode(expectedResult));
        Action memory finalResult = _emptyAction();

        bytes memory rlpTx = hex"02";
        Action memory l2tx = Action({
            actionType: ActionType.L2TX,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: rlpTx,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 l2txHash = keccak256(abi.encode(l2tx));

        ExecutionEntry[] memory entries = new ExecutionEntry[](2);

        StateDelta[] memory d1 = new StateDelta[](1);
        d1[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: state1, etherDelta: 0});
        entries[0].stateDeltas = d1;
        entries[0].actionHash = l2txHash;
        entries[0].nextAction = deepCall;

        StateDelta[] memory d2 = new StateDelta[](1);
        d2[0] = StateDelta({rollupId: rollupId, currentState: state1, newState: state2, etherDelta: 0});
        entries[1].stateDeltas = d2;
        entries[1].actionHash = resultHash;
        entries[1].nextAction = finalResult;

        _postBatch(entries, 0, "", "proof");

        rollups.executeL2TX(rollupId, rlpTx);
        assertEq(_getRollupState(rollupId), state2);
        assertEq(target.value(), 99);
    }

    // ──────────────────────────────────────────────
    //  _processCallAtScope: auto-proxy creation (line 420-421)
    // ──────────────────────────────────────────────

    function test_ProcessCallAtScope_AutoProxyCreation() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        // Do NOT create proxy for (alice, 0) -- it should be auto-created
        address expectedProxy = rollups.computeCrossChainProxyAddress(alice, 0);

        bytes32 state1 = keccak256("ap1");
        bytes32 state2 = keccak256("ap2");

        uint256[] memory callScope = new uint256[](1);
        callScope[0] = 0;

        Action memory scopedCall = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: abi.encodeCall(TestTarget.setValue, (77)),
            failed: false,
            sourceAddress: alice,
            sourceRollup: 0,
            scope: callScope
        });

        Action memory expectedResult = _buildResultAction(rollupId);
        bytes32 resultHash = keccak256(abi.encode(expectedResult));
        Action memory finalResult = _emptyAction();

        bytes memory rlpTx = hex"03";
        Action memory l2tx = Action({
            actionType: ActionType.L2TX,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: rlpTx,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 l2txHash = keccak256(abi.encode(l2tx));

        ExecutionEntry[] memory entries = new ExecutionEntry[](2);

        StateDelta[] memory d1 = new StateDelta[](1);
        d1[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: state1, etherDelta: 0});
        entries[0].stateDeltas = d1;
        entries[0].actionHash = l2txHash;
        entries[0].nextAction = scopedCall;

        StateDelta[] memory d2 = new StateDelta[](1);
        d2[0] = StateDelta({rollupId: rollupId, currentState: state1, newState: state2, etherDelta: 0});
        entries[1].stateDeltas = d2;
        entries[1].actionHash = resultHash;
        entries[1].nextAction = finalResult;

        _postBatch(entries, 0, "", "proof");

        rollups.executeL2TX(rollupId, rlpTx);

        // Verify proxy was auto-created
        (address origAddr,) = rollups.authorizedProxies(expectedProxy);
        assertEq(origAddr, alice);
        assertEq(_getRollupState(rollupId), state2);
    }

    // ──────────────────────────────────────────────
    //  _processCallAtScope: value transfer (lines 424-429)
    // ──────────────────────────────────────────────

    function test_ProcessCallAtScope_ValueTransfer() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        rollups.createCrossChainProxy(address(this), 0);

        // Fund rollup 0 (sourceRollup=0)
        _fundRollup(0, 10 ether);

        bytes32 state1 = keccak256("vt1");
        bytes32 state2 = keccak256("vt2");

        uint256[] memory callScope = new uint256[](1);
        callScope[0] = 0;

        // CALL with value=1 ether, empty data (just ETH transfer to the target's receive())
        Action memory scopedCall = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 1 ether,
            data: "",
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: callScope
        });

        Action memory expectedResult = _buildResultAction(rollupId);
        bytes32 resultHash = keccak256(abi.encode(expectedResult));
        Action memory finalResult = _emptyAction();

        bytes memory rlpTx = hex"04";
        Action memory l2tx = Action({
            actionType: ActionType.L2TX,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: rlpTx,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 l2txHash = keccak256(abi.encode(l2tx));

        ExecutionEntry[] memory entries = new ExecutionEntry[](2);

        // First entry: L2TX lookup. No ETH has flowed yet, so ether deltas must sum to 0.
        StateDelta[] memory d1 = new StateDelta[](1);
        d1[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: state1, etherDelta: 0});
        entries[0].stateDeltas = d1;
        entries[0].actionHash = l2txHash;
        entries[0].nextAction = scopedCall;

        // Second entry: RESULT after executeOnBehalf sent 1 ether out. _etherDelta = -1 ether.
        StateDelta[] memory d2 = new StateDelta[](2);
        d2[0] = StateDelta({rollupId: rollupId, currentState: state1, newState: state2, etherDelta: 0});
        d2[1] = StateDelta({rollupId: 0, currentState: bytes32(0), newState: bytes32(0), etherDelta: -1 ether});
        entries[1].stateDeltas = d2;
        entries[1].actionHash = resultHash;
        entries[1].nextAction = finalResult;

        _postBatch(entries, 0, "", "proof");

        rollups.executeL2TX(rollupId, rlpTx);
        assertEq(_getRollupState(rollupId), state2);
        assertEq(_getRollupEtherBalance(0), 9 ether);
    }

    // ──────────────────────────────────────────────
    //  _applyStateDeltas: InsufficientRollupBalance via state delta
    // ──────────────────────────────────────────────

    function test_ApplyStateDeltas_InsufficientBalance() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        // Rollup has 0 ether balance

        // Try to apply a state delta with negative etherDelta → InsufficientRollupBalance
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] =
            StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: -1 ether});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = bytes32(0);
        entries[0].nextAction = _emptyAction();

        vm.expectRevert(Rollups.InsufficientRollupBalance.selector);
        _postBatch(entries, 0, "", "proof");
    }

    // ──────────────────────────────────────────────
    //  _resolveScopes: CallExecutionFailed (failed RESULT) (line 550-551)
    // ──────────────────────────────────────────────

    function test_ResolveScopes_CallExecutionFailed_FailedResult() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        bytes32 state1 = keccak256("cf1");

        Action memory failedResult = Action({
            actionType: ActionType.RESULT,
            rollupId: 0,
            destination: address(0),
            value: 0,
            data: "",
            failed: true,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        bytes memory rlpTx = hex"06";
        Action memory l2tx = Action({
            actionType: ActionType.L2TX,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: rlpTx,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 l2txHash = keccak256(abi.encode(l2tx));

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        StateDelta[] memory d = new StateDelta[](1);
        d[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: state1, etherDelta: 0});
        entries[0].stateDeltas = d;
        entries[0].actionHash = l2txHash;
        entries[0].nextAction = failedResult;

        _postBatch(entries, 0, "", "proof");

        vm.expectRevert(Rollups.CallExecutionFailed.selector);
        rollups.executeL2TX(rollupId, rlpTx);
    }

    // ──────────────────────────────────────────────
    //  _resolveScopes: CallExecutionFailed (non-RESULT) (line 550-551)
    // ──────────────────────────────────────────────

    function test_ResolveScopes_CallExecutionFailed_NonResult() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        bytes32 state1 = keccak256("nr1");

        // Return a REVERT_CONTINUE (not RESULT) -> triggers CallExecutionFailed
        Action memory nonResultAction = Action({
            actionType: ActionType.REVERT_CONTINUE,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: "",
            failed: true,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        bytes memory rlpTx = hex"07";
        Action memory l2tx = Action({
            actionType: ActionType.L2TX,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: rlpTx,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 l2txHash = keccak256(abi.encode(l2tx));

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        StateDelta[] memory d = new StateDelta[](1);
        d[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: state1, etherDelta: 0});
        entries[0].stateDeltas = d;
        entries[0].actionHash = l2txHash;
        entries[0].nextAction = nonResultAction;

        _postBatch(entries, 0, "", "proof");

        vm.expectRevert(Rollups.CallExecutionFailed.selector);
        rollups.executeL2TX(rollupId, rlpTx);
    }

    // ──────────────────────────────────────────────
    //  _findAndApplyExecution: swap-and-pop (lines 500-501)
    // ──────────────────────────────────────────────

    function test_FindAndApplyExecution_SwapAndPop() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);

        bytes32 state1 = keccak256("sp1");
        bytes32 state2 = keccak256("sp2");

        bytes memory callData = abi.encodeCall(TestTarget.setValue, (123));

        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 actionHash = keccak256(abi.encode(callAction));

        // Two entries with same actionHash:
        // Entry 0: matches (currentState = bytes32(0))
        // Entry 1: doesn't match (currentState = state2)
        // Search goes from last to first: entry 1 checked first (no match),
        // then entry 0 (match). Since matched index (0) != lastIndex (1), swap-and-pop fires.

        ExecutionEntry[] memory entries = new ExecutionEntry[](2);

        StateDelta[] memory d0 = new StateDelta[](1);
        d0[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: state1, etherDelta: 0});
        entries[0].stateDeltas = d0;
        entries[0].actionHash = actionHash;
        entries[0].nextAction = _emptyAction();

        StateDelta[] memory d1 = new StateDelta[](1);
        d1[0] = StateDelta({rollupId: rollupId, currentState: state2, newState: keccak256("sp3"), etherDelta: 0});
        entries[1].stateDeltas = d1;
        entries[1].actionHash = actionHash;
        entries[1].nextAction = _emptyAction();

        _postBatch(entries, 0, "", "proof");

        (bool success,) = proxyAddr.call(callData);
        assertTrue(success);
        assertEq(_getRollupState(rollupId), state1);
    }

    // ──────────────────────────────────────────────
    //  _findAndApplyExecution: state mismatch (lines 485-487)
    // ──────────────────────────────────────────────

    function test_FindAndApplyExecution_StateMismatch() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);

        bytes memory callData = abi.encodeCall(TestTarget.setValue, (456));

        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 actionHash = keccak256(abi.encode(callAction));

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        StateDelta[] memory d = new StateDelta[](1);
        d[0] = StateDelta({
            rollupId: rollupId, currentState: keccak256("wrong state"), newState: keccak256("new"), etherDelta: 0
        });
        entries[0].stateDeltas = d;
        entries[0].actionHash = actionHash;
        entries[0].nextAction = _emptyAction();

        _postBatch(entries, 0, "", "proof");

        vm.expectRevert(Rollups.ExecutionNotFound.selector);
        (bool success,) = proxyAddr.call(callData);
        success;
    }

    // ──────────────────────────────────────────────
    //  REVERT handling at matching scope (lines 382-388)
    //  Covers: _getRevertContinuation (577-593), _handleScopeRevert (559-571)
    //  ScopeReverted thrown at matching scope, caught by parent newScope
    // ──────────────────────────────────────────────

    function test_Scope_RevertAtMatchingScope() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        rollups.createCrossChainProxy(address(this), 0);

        bytes32 state1 = keccak256("rv1");
        bytes32 state2 = keccak256("rv2");
        bytes32 state3 = keccak256("rv3");

        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;

        // Flow: L2TX -> CALL at scope [0] -> executeOnBehalf -> RESULT
        //       -> REVERT at scope [0] (matching!) -> ScopeReverted
        //       -> caught by newScope([]) -> _handleScopeRevert -> _getRevertContinuation -> final RESULT

        Action memory scopedCall = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: abi.encodeCall(TestTarget.setValue, (11)),
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: scope0
        });

        // RESULT from executeOnBehalf
        Action memory resultFromCall = _buildResultAction(rollupId);
        bytes32 resultHash = keccak256(abi.encode(resultFromCall));

        // After result, next action is REVERT at scope [0]
        Action memory revertAtScope0 = Action({
            actionType: ActionType.REVERT,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: scope0
        });

        // REVERT_CONTINUE for rollupId
        Action memory revertCont = _buildRevertContinue(rollupId);
        bytes32 revertContHash = keccak256(abi.encode(revertCont));

        Action memory finalResult = _emptyAction();

        bytes memory rlpTx = hex"08";
        Action memory l2tx = Action({
            actionType: ActionType.L2TX,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: rlpTx,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 l2txHash = keccak256(abi.encode(l2tx));

        ExecutionEntry[] memory entries = new ExecutionEntry[](3);

        // Entry 1: L2TX -> scoped CALL at [0]
        StateDelta[] memory d1 = new StateDelta[](1);
        d1[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: state1, etherDelta: 0});
        entries[0].stateDeltas = d1;
        entries[0].actionHash = l2txHash;
        entries[0].nextAction = scopedCall;

        // Entry 2: RESULT -> REVERT at [0]
        StateDelta[] memory d2 = new StateDelta[](1);
        d2[0] = StateDelta({rollupId: rollupId, currentState: state1, newState: state2, etherDelta: 0});
        entries[1].stateDeltas = d2;
        entries[1].actionHash = resultHash;
        entries[1].nextAction = revertAtScope0;

        // Entry 3: REVERT_CONTINUE -> final RESULT
        // _getRevertContinuation runs INSIDE the reverted newScope call.
        // At that point stateRoot=state2 (after RESULT deltas applied).
        // The lookup needs currentState=state2.
        // But all state changes inside newScope revert after ScopeReverted.
        // _handleScopeRevert then restores stateRoot to the captured state2.
        // Final state = state2 (the one from ScopeReverted error data).
        StateDelta[] memory d3 = new StateDelta[](1);
        d3[0] = StateDelta({rollupId: rollupId, currentState: state2, newState: state3, etherDelta: 0});
        entries[2].stateDeltas = d3;
        entries[2].actionHash = revertContHash;
        entries[2].nextAction = finalResult;

        _postBatch(entries, 0, "", "proof");

        rollups.executeL2TX(rollupId, rlpTx);
        // State is state2 because state changes from the reverted newScope call are rolled back
        // and _handleScopeRevert restores to the captured state (state2)
        assertEq(_getRollupState(rollupId), state2);
    }

    // ──────────────────────────────────────────────
    //  newScope: CALL at parent/sibling scope breaks (line 379-380)
    //  Tests multiple calls at sibling scopes
    // ──────────────────────────────────────────────

    function test_Scope_CallAtSiblingScope_Breaks() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        rollups.createCrossChainProxy(address(this), 0);

        bytes32 state1 = keccak256("sb1");
        bytes32 state2 = keccak256("sb2");
        bytes32 state3 = keccak256("sb3");

        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;
        uint256[] memory scope1 = new uint256[](1);
        scope1[0] = 1;

        // CALL at scope [0]
        Action memory call0 = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: abi.encodeCall(TestTarget.setValue, (100)),
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: scope0
        });

        // CALL at scope [1] (sibling of [0])
        Action memory call1 = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: abi.encodeCall(TestTarget.setValue, (200)),
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: scope1
        });

        Action memory resultFromCall = _buildResultAction(rollupId);
        bytes32 resultHash = keccak256(abi.encode(resultFromCall));

        Action memory finalResult = _emptyAction();

        bytes memory rlpTx = hex"09";
        Action memory l2tx = Action({
            actionType: ActionType.L2TX,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: rlpTx,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 l2txHash = keccak256(abi.encode(l2tx));

        ExecutionEntry[] memory entries = new ExecutionEntry[](3);

        // L2TX -> CALL [0]
        StateDelta[] memory d1 = new StateDelta[](1);
        d1[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: state1, etherDelta: 0});
        entries[0].stateDeltas = d1;
        entries[0].actionHash = l2txHash;
        entries[0].nextAction = call0;

        // RESULT (from call0) -> CALL [1]
        StateDelta[] memory d2 = new StateDelta[](1);
        d2[0] = StateDelta({rollupId: rollupId, currentState: state1, newState: state2, etherDelta: 0});
        entries[1].stateDeltas = d2;
        entries[1].actionHash = resultHash;
        entries[1].nextAction = call1;

        // RESULT (from call1) -> final RESULT
        StateDelta[] memory d3 = new StateDelta[](1);
        d3[0] = StateDelta({rollupId: rollupId, currentState: state2, newState: state3, etherDelta: 0});
        entries[2].stateDeltas = d3;
        entries[2].actionHash = resultHash;
        entries[2].nextAction = finalResult;

        _postBatch(entries, 0, "", "proof");

        rollups.executeL2TX(rollupId, rlpTx);
        assertEq(_getRollupState(rollupId), state3);
        assertEq(target.value(), 200);
    }

    // ──────────────────────────────────────────────
    //  newScope: REVERT at parent scope breaks (line 389-391)
    // ──────────────────────────────────────────────

    function test_Scope_RevertAtParentScope_Breaks() public {
        // Set up: CALL at [0] processes, result is REVERT at scope []
        // In newScope([0], ...), REVERT scope [] != [0] -> break -> return to caller
        // In newScope([]), the returned REVERT at [] matches -> ScopeReverted
        // Caught by _resolveScopes -> _handleScopeRevert -> _getRevertContinuation
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        rollups.createCrossChainProxy(address(this), 0);

        bytes32 state1 = keccak256("rp1");
        bytes32 state2 = keccak256("rp2");
        bytes32 state3 = keccak256("rp3");

        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;
        uint256[] memory emptyScope = new uint256[](0);

        Action memory call0 = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: abi.encodeCall(TestTarget.setValue, (33)),
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: scope0
        });

        Action memory resultFromCall = _buildResultAction(rollupId);
        bytes32 resultHash = keccak256(abi.encode(resultFromCall));

        // REVERT at empty scope []
        Action memory revertAtEmpty = Action({
            actionType: ActionType.REVERT,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: emptyScope
        });

        Action memory revertCont = _buildRevertContinue(rollupId);
        bytes32 revertContHash = keccak256(abi.encode(revertCont));
        Action memory finalResult = _emptyAction();

        bytes memory rlpTx = hex"0a";
        Action memory l2tx = Action({
            actionType: ActionType.L2TX,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: rlpTx,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 l2txHash = keccak256(abi.encode(l2tx));

        ExecutionEntry[] memory entries = new ExecutionEntry[](3);

        // L2TX -> CALL at [0]
        StateDelta[] memory d1 = new StateDelta[](1);
        d1[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: state1, etherDelta: 0});
        entries[0].stateDeltas = d1;
        entries[0].actionHash = l2txHash;
        entries[0].nextAction = call0;

        // RESULT -> REVERT at []
        StateDelta[] memory d2 = new StateDelta[](1);
        d2[0] = StateDelta({rollupId: rollupId, currentState: state1, newState: state2, etherDelta: 0});
        entries[1].stateDeltas = d2;
        entries[1].actionHash = resultHash;
        entries[1].nextAction = revertAtEmpty;

        // REVERT_CONTINUE -> final RESULT
        // _getRevertContinuation runs inside the reverted call. At that point state=state2.
        StateDelta[] memory d3 = new StateDelta[](1);
        d3[0] = StateDelta({rollupId: rollupId, currentState: state2, newState: state3, etherDelta: 0});
        entries[2].stateDeltas = d3;
        entries[2].actionHash = revertContHash;
        entries[2].nextAction = finalResult;

        _postBatch(entries, 0, "", "proof");

        rollups.executeL2TX(rollupId, rlpTx);
        // State changes inside reverted newScope call are rolled back.
        // _handleScopeRevert restores state to state2 (captured at revert time).
        assertEq(_getRollupState(rollupId), state2);
    }

    // ──────────────────────────────────────────────
    //  _resolveScopes: catch path from root scope REVERT (lines 543-545)
    //  CALL at scope [] -> _processCallAtScope -> REVERT at scope []
    //  -> ScopeReverted thrown from newScope([]) -> caught by _resolveScopes
    // ──────────────────────────────────────────────

    function test_ResolveScopes_CatchScopeRevert() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        rollups.createCrossChainProxy(address(this), 0);

        bytes32 state1 = keccak256("cr1");
        bytes32 state2 = keccak256("cr2");
        bytes32 stateAfterRevert = keccak256("cr3");

        uint256[] memory emptyScope = new uint256[](0);

        // CALL at scope [] (empty)
        Action memory callAtEmpty = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: abi.encodeCall(TestTarget.setValue, (300)),
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: emptyScope
        });

        Action memory resultFromCall = _buildResultAction(rollupId);
        bytes32 resultHash = keccak256(abi.encode(resultFromCall));

        // REVERT at scope []
        Action memory revertAtEmpty = Action({
            actionType: ActionType.REVERT,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: emptyScope
        });

        Action memory revertCont = _buildRevertContinue(rollupId);
        bytes32 revertContHash = keccak256(abi.encode(revertCont));
        Action memory finalResult = _emptyAction();

        bytes memory rlpTx = hex"0b";
        Action memory l2tx = Action({
            actionType: ActionType.L2TX,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: rlpTx,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 l2txHash = keccak256(abi.encode(l2tx));

        ExecutionEntry[] memory entries = new ExecutionEntry[](3);

        // L2TX -> CALL at []
        StateDelta[] memory d1 = new StateDelta[](1);
        d1[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: state1, etherDelta: 0});
        entries[0].stateDeltas = d1;
        entries[0].actionHash = l2txHash;
        entries[0].nextAction = callAtEmpty;

        // RESULT -> REVERT at []
        StateDelta[] memory d2 = new StateDelta[](1);
        d2[0] = StateDelta({rollupId: rollupId, currentState: state1, newState: state2, etherDelta: 0});
        entries[1].stateDeltas = d2;
        entries[1].actionHash = resultHash;
        entries[1].nextAction = revertAtEmpty;

        // REVERT_CONTINUE -> final RESULT
        // _getRevertContinuation runs inside the reverted call. At that point state=state2.
        StateDelta[] memory d3 = new StateDelta[](1);
        d3[0] = StateDelta({rollupId: rollupId, currentState: state2, newState: stateAfterRevert, etherDelta: 0});
        entries[2].stateDeltas = d3;
        entries[2].actionHash = revertContHash;
        entries[2].nextAction = finalResult;

        _postBatch(entries, 0, "", "proof");

        rollups.executeL2TX(rollupId, rlpTx);
        // State changes inside reverted newScope call are rolled back.
        // _handleScopeRevert restores state to state2 (captured at revert time).
        assertEq(_getRollupState(rollupId), state2);
    }

    // ──────────────────────────────────────────────
    //  PostBatch with empty entries
    // ──────────────────────────────────────────────

    function test_PostBatch_EmptyEntries() public {
        ExecutionEntry[] memory entries = new ExecutionEntry[](0);
        _postBatch(entries, 0, "", "proof");
    }

    // ──────────────────────────────────────────────
    //  PostBatch twice in different blocks
    // ──────────────────────────────────────────────

    function test_PostBatch_DifferentBlocks() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 state1 = keccak256("s1");
        bytes32 state2 = keccak256("s2");

        ExecutionEntry[] memory entries1 = new ExecutionEntry[](1);
        entries1[0] = _immediateEntry(rollupId, bytes32(0), state1);
        _postBatch(entries1, 0, "", "proof");

        vm.roll(block.number + 1);

        ExecutionEntry[] memory entries2 = new ExecutionEntry[](1);
        entries2[0] = _immediateEntry(rollupId, state1, state2);
        _postBatch(entries2, 0, "", "proof");

        assertEq(_getRollupState(rollupId), state2);
    }

    // ──────────────────────────────────────────────
    //  executeCrossChainCall with CALL as nextAction
    //  Tests _resolveScopes CALL path via proxy call
    // ──────────────────────────────────────────────

    function test_ExecuteCrossChainCall_WithScopedNextAction() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        // Create proxy for target
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);
        // Create source proxy for (address(this), 0) used in the scoped call
        rollups.createCrossChainProxy(address(this), 0);

        bytes32 state1 = keccak256("ec1");
        bytes32 state2 = keccak256("ec2");

        bytes memory callData = abi.encodeCall(TestTarget.setValue, (42));

        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;

        // Next action after initial CALL is a scoped CALL
        Action memory scopedCall = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: abi.encodeCall(TestTarget.setValue, (42)),
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: scope0
        });

        // Build the initial CALL action as executeCrossChainCall would
        Action memory initialCall = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 initialCallHash = keccak256(abi.encode(initialCall));

        Action memory resultFromScoped = _buildResultAction(rollupId);
        bytes32 resultHash = keccak256(abi.encode(resultFromScoped));
        Action memory finalResult = _emptyAction();

        ExecutionEntry[] memory entries = new ExecutionEntry[](2);

        StateDelta[] memory d1 = new StateDelta[](1);
        d1[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: state1, etherDelta: 0});
        entries[0].stateDeltas = d1;
        entries[0].actionHash = initialCallHash;
        entries[0].nextAction = scopedCall;

        StateDelta[] memory d2 = new StateDelta[](1);
        d2[0] = StateDelta({rollupId: rollupId, currentState: state1, newState: state2, etherDelta: 0});
        entries[1].stateDeltas = d2;
        entries[1].actionHash = resultHash;
        entries[1].nextAction = finalResult;

        _postBatch(entries, 0, "", "proof");

        (bool success,) = proxyAddr.call(callData);
        assertTrue(success);
        assertEq(_getRollupState(rollupId), state2);
    }

    // ──────────────────────────────────────────────
    //  _processCallAtScope: failed executeOnBehalf
    //  When the target call fails (reverts)
    // ──────────────────────────────────────────────

    function test_ProcessCallAtScope_FailedCall() public {
        RevertingTarget revertTarget = new RevertingTarget();
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        rollups.createCrossChainProxy(address(this), 0);

        bytes32 state1 = keccak256("fc1");
        bytes32 state2 = keccak256("fc2");

        uint256[] memory callScope = new uint256[](1);
        callScope[0] = 0;

        // CALL to a reverting target
        Action memory scopedCall = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(revertTarget),
            value: 0,
            data: abi.encodeCall(TestTarget.setValue, (1)),
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: callScope
        });

        // When executeOnBehalf reverts, the outer .call() returns success=false
        // and returnData = the revert data from the reverting target
        // The RESULT action has failed=true and data=revertData
        // The revert data from RevertingTarget is:
        //   abi.encodeWithSelector(RevertingTarget.TargetReverted.selector)
        bytes memory revertData = abi.encodeWithSelector(RevertingTarget.TargetReverted.selector);

        Action memory failedResultAction = Action({
            actionType: ActionType.RESULT,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: revertData,
            failed: true,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 failedResultHash = keccak256(abi.encode(failedResultAction));

        // After the failed result, return a successful RESULT
        Action memory finalResult = _emptyAction();

        bytes memory rlpTx = hex"0d";
        Action memory l2tx = Action({
            actionType: ActionType.L2TX,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: rlpTx,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 l2txHash = keccak256(abi.encode(l2tx));

        ExecutionEntry[] memory entries = new ExecutionEntry[](2);

        StateDelta[] memory d1 = new StateDelta[](1);
        d1[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: state1, etherDelta: 0});
        entries[0].stateDeltas = d1;
        entries[0].actionHash = l2txHash;
        entries[0].nextAction = scopedCall;

        StateDelta[] memory d2 = new StateDelta[](1);
        d2[0] = StateDelta({rollupId: rollupId, currentState: state1, newState: state2, etherDelta: 0});
        entries[1].stateDeltas = d2;
        entries[1].actionHash = failedResultHash;
        entries[1].nextAction = finalResult;

        _postBatch(entries, 0, "", "proof");

        rollups.executeL2TX(rollupId, rlpTx);
        assertEq(_getRollupState(rollupId), state2);
    }

    // ──────────────────────────────────────────────
    //  Ether delta: positive increment in _applyStateDeltas
    // ──────────────────────────────────────────────

    function test_PostBatch_EtherDeltaPositiveIncrement() public {
        uint256 rollupId1 = _createRollup(bytes32(0), DEFAULT_VK, alice);
        uint256 rollupId2 = _createRollup(bytes32(0), DEFAULT_VK, bob);

        _fundRollup(rollupId1, 10 ether);

        StateDelta[] memory deltas = new StateDelta[](2);
        deltas[0] = StateDelta({
            rollupId: rollupId1, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: -3 ether
        });
        deltas[1] =
            StateDelta({rollupId: rollupId2, currentState: bytes32(0), newState: keccak256("s2"), etherDelta: 3 ether});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = bytes32(0);
        entries[0].nextAction = _emptyAction();

        _postBatch(entries, 0, "", "proof");

        assertEq(_getRollupEtherBalance(rollupId1), 7 ether);
        assertEq(_getRollupEtherBalance(rollupId2), 3 ether);
    }

    // ──────────────────────────────────────────────
    //  _isChildScope: prefix mismatch (line 628)
    //  Tests the branch where currentScope prefix != targetScope prefix
    // ──────────────────────────────────────────────

    function test_Scope_IsChildScope_PrefixMismatch() public {
        // Set up a call where the target scope's prefix doesn't match the current scope
        // currentScope = [1], targetScope = [0, 1] - prefix mismatch at index 0
        // This will cause _isChildScope to return false, meaning the scope is not a child
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        rollups.createCrossChainProxy(address(this), 0);

        bytes32 state1 = keccak256("pm1");
        bytes32 state2 = keccak256("pm2");
        bytes32 state3 = keccak256("pm3");

        // First CALL at scope [0, 1]
        uint256[] memory scope01 = new uint256[](2);
        scope01[0] = 0;
        scope01[1] = 1;

        Action memory call01 = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: abi.encodeCall(TestTarget.setValue, (10)),
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: scope01
        });

        // After processing call01, the next action is a CALL at scope [1, 0]
        // From newScope([0]), [1, 0] is NOT a child of [0] because prefix [1] != [0]
        // This triggers the break (parent/sibling scope)
        uint256[] memory scope10 = new uint256[](2);
        scope10[0] = 1;
        scope10[1] = 0;

        Action memory call10 = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: abi.encodeCall(TestTarget.setValue, (20)),
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: scope10
        });

        Action memory resultFromCall = _buildResultAction(rollupId);
        bytes32 resultHash = keccak256(abi.encode(resultFromCall));

        Action memory finalResult = _emptyAction();

        bytes memory rlpTx = hex"0e";
        Action memory l2tx = Action({
            actionType: ActionType.L2TX,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: rlpTx,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 l2txHash = keccak256(abi.encode(l2tx));

        ExecutionEntry[] memory entries = new ExecutionEntry[](3);

        // L2TX -> CALL at [0, 1]
        StateDelta[] memory d1 = new StateDelta[](1);
        d1[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: state1, etherDelta: 0});
        entries[0].stateDeltas = d1;
        entries[0].actionHash = l2txHash;
        entries[0].nextAction = call01;

        // RESULT (from call01) -> CALL at [1, 0] (prefix mismatch with [0])
        StateDelta[] memory d2 = new StateDelta[](1);
        d2[0] = StateDelta({rollupId: rollupId, currentState: state1, newState: state2, etherDelta: 0});
        entries[1].stateDeltas = d2;
        entries[1].actionHash = resultHash;
        entries[1].nextAction = call10;

        // RESULT (from call10) -> final RESULT
        StateDelta[] memory d3 = new StateDelta[](1);
        d3[0] = StateDelta({rollupId: rollupId, currentState: state2, newState: state3, etherDelta: 0});
        entries[2].stateDeltas = d3;
        entries[2].actionHash = resultHash;
        entries[2].nextAction = finalResult;

        _postBatch(entries, 0, "", "proof");

        rollups.executeL2TX(rollupId, rlpTx);
        assertEq(_getRollupState(rollupId), state3);
    }

    // ──────────────────────────────────────────────
    //  PostBatch: multiple deltas per entry
    // ──────────────────────────────────────────────

    function test_PostBatch_MultipleDeltasPerEntry() public {
        uint256 r1 = _createRollup(keccak256("a"), DEFAULT_VK, alice);
        uint256 r2 = _createRollup(keccak256("b"), DEFAULT_VK, bob);

        StateDelta[] memory deltas = new StateDelta[](2);
        deltas[0] = StateDelta({rollupId: r1, currentState: keccak256("a"), newState: keccak256("a2"), etherDelta: 0});
        deltas[1] = StateDelta({rollupId: r2, currentState: keccak256("b"), newState: keccak256("b2"), etherDelta: 0});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = bytes32(0);
        entries[0].nextAction = _emptyAction();

        _postBatch(entries, 0, "", "proof");

        assertEq(_getRollupState(r1), keccak256("a2"));
        assertEq(_getRollupState(r2), keccak256("b2"));
    }

    // ──────────────────────────────────────────────
    //  executeCrossChainCall with msg.value > 0
    //  Covers: _etherDelta += int256(msg.value) (line 262)
    // ──────────────────────────────────────────────

    function test_ExecuteCrossChainCall_WithETHValue() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);

        bytes32 state1 = keccak256("ethv1");
        bytes memory callData = abi.encodeCall(TestTarget.setValue, (55));

        // Build CALL action as executeCrossChainCall builds it (with value)
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 1 ether,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        Action memory resultAction = _emptyAction();

        // State delta must reflect the +1 ether from msg.value
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: state1, etherDelta: 1 ether});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = keccak256(abi.encode(callAction));
        entries[0].nextAction = resultAction;

        _postBatch(entries, 0, "", "proof");

        // Call the proxy with 1 ether value
        (bool success,) = proxyAddr.call{value: 1 ether}(callData);
        assertTrue(success);
        assertEq(_getRollupState(rollupId), state1);
    }

    // ──────────────────────────────────────────────
    //  EtherDeltaMismatch in _findAndApplyExecution (line 459)
    // ──────────────────────────────────────────────

    function test_FindAndApplyExecution_EtherDeltaMismatch() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);

        bytes32 state1 = keccak256("edm1");
        bytes memory callData = abi.encodeCall(TestTarget.setValue, (66));

        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        // State delta has etherDelta = 1 ether but no ETH flows (_etherDelta = 0)
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: state1, etherDelta: 1 ether});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = keccak256(abi.encode(callAction));
        entries[0].nextAction = _emptyAction();

        _postBatch(entries, 0, "", "proof");

        vm.expectRevert(Rollups.EtherDeltaMismatch.selector);
        (bool success,) = proxyAddr.call(callData);
        success;
    }

    // ──────────────────────────────────────────────
    //  InvalidRevertData in _handleScopeRevert (line 529)
    //  Covers: revertData.length <= 4 when newScope reverts
    //  with a non-ScopeReverted error
    // ──────────────────────────────────────────────

    function test_HandleScopeRevert_InvalidRevertData() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        rollups.createCrossChainProxy(address(this), 0);

        bytes32 state1 = keccak256("ird1");

        uint256[] memory callScope = new uint256[](1);
        callScope[0] = 0;

        // CALL at scope [0], after which the RESULT lookup will fail (no entry)
        // This causes ExecutionNotFound (4 bytes) inside newScope,
        // caught by _resolveScopes -> _handleScopeRevert -> InvalidRevertData
        Action memory scopedCall = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: abi.encodeCall(TestTarget.setValue, (88)),
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: callScope
        });

        bytes memory rlpTx = hex"0f";
        Action memory l2tx = Action({
            actionType: ActionType.L2TX,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: rlpTx,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 l2txHash = keccak256(abi.encode(l2tx));

        // Only load the L2TX entry, NOT the result entry
        // So the result lookup inside _processCallAtScope will revert with ExecutionNotFound
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        StateDelta[] memory d = new StateDelta[](1);
        d[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: state1, etherDelta: 0});
        entries[0].stateDeltas = d;
        entries[0].actionHash = l2txHash;
        entries[0].nextAction = scopedCall;

        _postBatch(entries, 0, "", "proof");

        vm.expectRevert(Rollups.InvalidRevertData.selector);
        rollups.executeL2TX(rollupId, rlpTx);
    }

    // ──────────────────────────────────────────────
    //  executeCrossChainCall: CALL nextAction triggers _resolveScopes
    //  with catch path (ScopeReverted caught at root)
    // ──────────────────────────────────────────────

    function test_ExecuteCrossChainCall_ResolveScopesCatchPath() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);
        rollups.createCrossChainProxy(address(this), 0);

        bytes32 state1 = keccak256("rsc1");
        bytes32 state2 = keccak256("rsc2");
        bytes32 state3 = keccak256("rsc3");

        bytes memory callData = abi.encodeCall(TestTarget.setValue, (42));

        // Initial CALL (from proxy fallback)
        Action memory initialCall = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;

        // Next action is a scoped CALL
        Action memory scopedCall = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: abi.encodeCall(TestTarget.setValue, (99)),
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: scope0
        });

        Action memory resultFromScoped = _buildResultAction(rollupId);
        bytes32 resultHash = keccak256(abi.encode(resultFromScoped));

        uint256[] memory emptyScope = new uint256[](0);
        // REVERT at scope [] after the scoped call
        Action memory revertAtEmpty = Action({
            actionType: ActionType.REVERT,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: emptyScope
        });

        Action memory revertCont = _buildRevertContinue(rollupId);
        bytes32 revertContHash = keccak256(abi.encode(revertCont));
        Action memory finalResult = _emptyAction();

        ExecutionEntry[] memory entries = new ExecutionEntry[](3);

        // Initial CALL -> scoped CALL
        StateDelta[] memory d1 = new StateDelta[](1);
        d1[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: state1, etherDelta: 0});
        entries[0].stateDeltas = d1;
        entries[0].actionHash = keccak256(abi.encode(initialCall));
        entries[0].nextAction = scopedCall;

        // RESULT from scoped call -> REVERT at []
        StateDelta[] memory d2 = new StateDelta[](1);
        d2[0] = StateDelta({rollupId: rollupId, currentState: state1, newState: state2, etherDelta: 0});
        entries[1].stateDeltas = d2;
        entries[1].actionHash = resultHash;
        entries[1].nextAction = revertAtEmpty;

        // REVERT_CONTINUE -> final RESULT
        StateDelta[] memory d3 = new StateDelta[](1);
        d3[0] = StateDelta({rollupId: rollupId, currentState: state2, newState: state3, etherDelta: 0});
        entries[2].stateDeltas = d3;
        entries[2].actionHash = revertContHash;
        entries[2].nextAction = finalResult;

        _postBatch(entries, 0, "", "proof");

        (bool success,) = proxyAddr.call(callData);
        assertTrue(success);
        // State restored to state2 by _handleScopeRevert
        assertEq(_getRollupState(rollupId), state2);
    }

    // ──────────────────────────────────────────────
    //  Proxy fallback: reverts bubble up through proxy
    // ──────────────────────────────────────────────

    function test_Proxy_Fallback_BubblesRevert() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);

        // Call proxy with no execution loaded -> ExecutionNotInCurrentBlock bubbles through proxy
        bytes memory callData = abi.encodeCall(TestTarget.setValue, (1));
        (bool success, bytes memory retData) = proxyAddr.call(callData);
        assertFalse(success);
        // Verify the revert selector is ExecutionNotInCurrentBlock
        bytes4 selector;
        assembly {
            selector := mload(add(retData, 32))
        }
        assertEq(selector, Rollups.ExecutionNotInCurrentBlock.selector);
    }

    // ──────────────────────────────────────────────
    //  Proxy executeOnBehalf: non-manager caller falls through to cross-chain path
    // ──────────────────────────────────────────────

    function test_Proxy_ExecuteOnBehalf_NonManagerFallsThrough() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);
        CrossChainProxy proxy = CrossChainProxy(payable(proxyAddr));

        // Non-manager callers are routed through _fallback() (cross-chain path),
        // which calls executeCrossChainCall and reverts with ExecutionNotInCurrentBlock
        vm.prank(alice);
        vm.expectRevert(Rollups.ExecutionNotInCurrentBlock.selector);
        proxy.executeOnBehalf(address(target), abi.encodeCall(TestTarget.setValue, (42)));
    }


    // ──────────────────────────────────────────────
    //  newScope: child scope catch path (lines 340-342)
    //  ScopeReverted from child caught by parent newScope
    // ──────────────────────────────────────────────

    function test_NewScope_ChildScope_CatchesScopeReverted() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        rollups.createCrossChainProxy(address(this), 0);

        bytes32 state1 = keccak256("csc1");
        bytes32 state2 = keccak256("csc2");
        bytes32 state3 = keccak256("csc3");

        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;
        uint256[] memory scope00 = new uint256[](2);
        scope00[0] = 0;
        scope00[1] = 0;

        // CALL at scope [0, 0] (child of [0])
        Action memory deepCall = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: abi.encodeCall(TestTarget.setValue, (10)),
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: scope00
        });

        Action memory resultFromCall = _buildResultAction(rollupId);
        bytes32 resultHash = keccak256(abi.encode(resultFromCall));

        // REVERT at scope [0, 0]
        Action memory revertAtDeep = Action({
            actionType: ActionType.REVERT,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: scope00
        });

        Action memory revertCont = _buildRevertContinue(rollupId);
        bytes32 revertContHash = keccak256(abi.encode(revertCont));
        Action memory finalResult = _emptyAction();

        bytes memory rlpTx = hex"11";
        Action memory l2tx = Action({
            actionType: ActionType.L2TX,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: rlpTx,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 l2txHash = keccak256(abi.encode(l2tx));

        ExecutionEntry[] memory entries = new ExecutionEntry[](3);

        // L2TX -> CALL at [0, 0]
        StateDelta[] memory d1 = new StateDelta[](1);
        d1[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: state1, etherDelta: 0});
        entries[0].stateDeltas = d1;
        entries[0].actionHash = l2txHash;
        entries[0].nextAction = deepCall;

        // RESULT -> REVERT at [0, 0]
        StateDelta[] memory d2 = new StateDelta[](1);
        d2[0] = StateDelta({rollupId: rollupId, currentState: state1, newState: state2, etherDelta: 0});
        entries[1].stateDeltas = d2;
        entries[1].actionHash = resultHash;
        entries[1].nextAction = revertAtDeep;

        // REVERT_CONTINUE -> final RESULT
        StateDelta[] memory d3 = new StateDelta[](1);
        d3[0] = StateDelta({rollupId: rollupId, currentState: state2, newState: state3, etherDelta: 0});
        entries[2].stateDeltas = d3;
        entries[2].actionHash = revertContHash;
        entries[2].nextAction = finalResult;

        _postBatch(entries, 0, "", "proof");

        rollups.executeL2TX(rollupId, rlpTx);
        // ScopeReverted at [0,0] is caught by newScope([0]) (child scope catch path)
        // Then caught by newScope([]) which calls _handleScopeRevert
        assertEq(_getRollupState(rollupId), state2);
    }

    // ──────────────────────────────────────────────
    //  _findAndApplyExecution: multiple deltas, all must match
    // ──────────────────────────────────────────────

    function test_FindAndApplyExecution_MultiDeltaAllMatch() public {
        uint256 r1 = _createRollup(keccak256("x"), DEFAULT_VK, alice);
        uint256 r2 = _createRollup(keccak256("y"), DEFAULT_VK, bob);
        address proxyAddr = rollups.createCrossChainProxy(address(target), r1);

        bytes memory callData = abi.encodeCall(TestTarget.setValue, (789));
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: r1,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 actionHash = keccak256(abi.encode(callAction));

        // Both deltas must match current state for execution to be found
        StateDelta[] memory deltas = new StateDelta[](2);
        deltas[0] = StateDelta({rollupId: r1, currentState: keccak256("x"), newState: keccak256("x2"), etherDelta: 0});
        deltas[1] = StateDelta({rollupId: r2, currentState: keccak256("y"), newState: keccak256("y2"), etherDelta: 0});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = actionHash;
        entries[0].nextAction = _emptyAction();

        _postBatch(entries, 0, "", "proof");

        (bool success,) = proxyAddr.call(callData);
        assertTrue(success);
        assertEq(_getRollupState(r1), keccak256("x2"));
        assertEq(_getRollupState(r2), keccak256("y2"));
    }

    // ──────────────────────────────────────────────
    //  _findAndApplyExecution: multi delta partial mismatch
    // ──────────────────────────────────────────────

    function test_FindAndApplyExecution_MultiDeltaPartialMismatch() public {
        uint256 r1 = _createRollup(keccak256("a"), DEFAULT_VK, alice);
        uint256 r2 = _createRollup(keccak256("b"), DEFAULT_VK, bob);
        address proxyAddr = rollups.createCrossChainProxy(address(target), r1);

        bytes memory callData = abi.encodeCall(TestTarget.setValue, (111));
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: r1,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 actionHash = keccak256(abi.encode(callAction));

        // First delta matches but second doesn't
        StateDelta[] memory deltas = new StateDelta[](2);
        deltas[0] = StateDelta({rollupId: r1, currentState: keccak256("a"), newState: keccak256("a2"), etherDelta: 0});
        deltas[1] =
            StateDelta({rollupId: r2, currentState: keccak256("wrong"), newState: keccak256("b2"), etherDelta: 0});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = actionHash;
        entries[0].nextAction = _emptyAction();

        _postBatch(entries, 0, "", "proof");

        vm.expectRevert(Rollups.ExecutionNotFound.selector);
        (bool success,) = proxyAddr.call(callData);
        success;
    }

    // ──────────────────────────────────────────────
    //  PostBatch: only deferred entries (ether deltas not checked)
    // ──────────────────────────────────────────────

    function test_PostBatch_OnlyDeferredEntries() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 actionHash = keccak256(abi.encode(callAction));

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: keccak256("d1"), etherDelta: 0});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = actionHash;
        entries[0].nextAction = _emptyAction();

        // Deferred entries do NOT have their ether deltas summed
        // (only immediate entries do), so this should pass
        _postBatch(entries, 0, "", "proof");

        // State should NOT have changed (deferred entry)
        assertEq(_getRollupState(rollupId), bytes32(0));
    }

    // ──────────────────────────────────────────────
    //  TransferRollupOwnership: non-owner reverts
    // ──────────────────────────────────────────────

    function test_TransferRollupOwnership_NotOwner() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        vm.prank(bob);
        vm.expectRevert(Rollups.NotRollupOwner.selector);
        rollups.transferRollupOwnership(rollupId, bob);
    }

    // ──────────────────────────────────────────────
    //  _applyStateDeltas: zero etherDelta (no change)
    // ──────────────────────────────────────────────

    function test_ApplyStateDeltas_ZeroEtherDelta() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        _fundRollup(rollupId, 5 ether);

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: keccak256("zd"), etherDelta: 0});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = bytes32(0);
        entries[0].nextAction = _emptyAction();

        _postBatch(entries, 0, "", "proof");

        assertEq(_getRollupEtherBalance(rollupId), 5 ether);
        assertEq(_getRollupState(rollupId), keccak256("zd"));
    }

    // ──────────────────────────────────────────────
    //  Events: verify key events are emitted
    // ──────────────────────────────────────────────

    // ──────────────────────────────────────────────
    //  PostBatch with blobCount > 0 (blobhash loop)
    // ──────────────────────────────────────────────

    function test_PostBatch_WithBlobCount() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        // Set blob hashes for the transaction
        bytes32[] memory blobs = new bytes32[](2);
        blobs[0] = keccak256("blob0");
        blobs[1] = keccak256("blob1");
        vm.blobhashes(blobs);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rollupId, bytes32(0), keccak256("blobState"));

        // blobCount=2 makes the contract read blobhash(0) and blobhash(1)
        _postBatch(entries, 2, "", "proof");

        assertEq(_getRollupState(rollupId), keccak256("blobState"));
    }

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    function test_CreateRollup_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit Rollups.RollupCreated(1, alice, address(verifier), DEFAULT_VK, keccak256("init"));
        _createRollup(keccak256("init"), DEFAULT_VK, alice);
    }

    function test_SetStateByOwner_EmitsEvent() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newState = keccak256("emitState");

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Rollups.StateUpdated(rollupId, newState);
        rollups.setStateByOwner(rollupId, newState);
    }

    function test_SetVerificationKey_EmitsEvent() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newVK = keccak256("newVK");

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Rollups.VerificationKeyUpdated(rollupId, address(verifier), newVK);
        rollups.setVerificationKey(rollupId, newVK);
    }

    function test_TransferOwnership_EmitsEvent() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Rollups.OwnershipTransferred(rollupId, alice, bob);
        rollups.transferRollupOwnership(rollupId, bob);
    }

    function test_CreateCrossChainProxy_EmitsEvent() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        address expectedProxy = rollups.computeCrossChainProxyAddress(address(target), rollupId);

        vm.expectEmit(true, true, true, true);
        emit Rollups.CrossChainProxyCreated(expectedProxy, address(target), rollupId);
        rollups.createCrossChainProxy(address(target), rollupId);
    }

    // ──────────────────────────────────────────────
    //  RESULT with uint256 return data
    // ──────────────────────────────────────────────

    function test_ScopeCall_ResultWithUint256Return() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        rollups.createCrossChainProxy(address(this), 0);

        bytes32 state1 = keccak256("u1");
        bytes32 state2 = keccak256("u2");

        uint256[] memory callScope = new uint256[](1);
        callScope[0] = 0;

        // CALL getValue() which returns uint256
        Action memory scopedCall = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: abi.encodeCall(TestTarget.getValue, ()),
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: callScope
        });

        // getValue() returns uint256(0) — raw return is abi.encode(uint256(0))
        Action memory expectedResult = Action({
            actionType: ActionType.RESULT,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(0)),
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 resultHash = keccak256(abi.encode(expectedResult));

        // Final result carries the uint256 value back
        Action memory finalResult = Action({
            actionType: ActionType.RESULT,
            rollupId: 0,
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(0)),
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        bytes memory rlpTx = hex"20";
        Action memory l2tx = Action({
            actionType: ActionType.L2TX,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: rlpTx,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 l2txHash = keccak256(abi.encode(l2tx));

        ExecutionEntry[] memory entries = new ExecutionEntry[](2);

        StateDelta[] memory d1 = new StateDelta[](1);
        d1[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: state1, etherDelta: 0});
        entries[0].stateDeltas = d1;
        entries[0].actionHash = l2txHash;
        entries[0].nextAction = scopedCall;

        StateDelta[] memory d2 = new StateDelta[](1);
        d2[0] = StateDelta({rollupId: rollupId, currentState: state1, newState: state2, etherDelta: 0});
        entries[1].stateDeltas = d2;
        entries[1].actionHash = resultHash;
        entries[1].nextAction = finalResult;

        _postBatch(entries, 0, "", "proof");

        bytes memory result = rollups.executeL2TX(rollupId, rlpTx);
        uint256 decoded = abi.decode(result, (uint256));
        assertEq(decoded, 0);
        assertEq(_getRollupState(rollupId), state2);
    }

    // ══════════════════════════════════════════════
    //  BatchPosted event tests
    // ══════════════════════════════════════════════

    function _batchPostedSelector() internal pure returns (bytes32) {
        return keccak256("BatchPosted((uint256,bytes32,bytes32,int256)[],bytes32,(uint8,uint256,address,uint256,bytes,bool,address,uint256,uint256[]))[],bytes32)");
    }

    function _findBatchPostedLog(Vm.Log[] memory logs) internal view returns (bool found, uint256 idx) {
        bytes32 sel = Rollups.BatchPosted.selector;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sel) {
                return (true, i);
            }
        }
        return (false, 0);
    }

    function test_BatchPosted_EmitsOnImmediateEntry() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newState = keccak256("bp1");

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rollupId, bytes32(0), newState);

        vm.recordLogs();
        _postBatch(entries, 0, "", "proof");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool found, uint256 idx) = _findBatchPostedLog(logs);
        assertTrue(found, "BatchPosted event not found");

        (ExecutionEntry[] memory emitted, bytes32 pubHash) = abi.decode(logs[idx].data, (ExecutionEntry[], bytes32));
        assertEq(emitted.length, 1);
        assertEq(emitted[0].actionHash, bytes32(0));
        assertEq(emitted[0].stateDeltas.length, 1);
        assertEq(emitted[0].stateDeltas[0].rollupId, rollupId);
        assertEq(emitted[0].stateDeltas[0].newState, newState);
        assertTrue(pubHash != bytes32(0));
    }

    function test_BatchPosted_EmitsOnDeferredEntry() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes memory callData = abi.encodeCall(TestTarget.setValue, (42));

        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 actionHash = keccak256(abi.encode(action));

        StateDelta[] memory stateDeltas = new StateDelta[](1);
        stateDeltas[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: keccak256("s"), etherDelta: 0});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = stateDeltas;
        entries[0].actionHash = actionHash;
        entries[0].nextAction = _emptyAction();

        vm.recordLogs();
        _postBatch(entries, 0, "", "proof");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool found, uint256 idx) = _findBatchPostedLog(logs);
        assertTrue(found, "BatchPosted event not found");

        (ExecutionEntry[] memory emitted,) = abi.decode(logs[idx].data, (ExecutionEntry[], bytes32));
        assertEq(emitted.length, 1);
        assertEq(emitted[0].actionHash, actionHash);
        assertEq(emitted[0].stateDeltas[0].rollupId, rollupId);
        assertEq(uint8(emitted[0].nextAction.actionType), uint8(ActionType.RESULT));
    }

    function test_BatchPosted_MixedImmediateAndDeferred() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 state1 = keccak256("s1");

        bytes memory callData = abi.encodeCall(TestTarget.setValue, (42));
        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 deferredHash = keccak256(abi.encode(action));

        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _immediateEntry(rollupId, bytes32(0), state1);
        StateDelta[] memory deferredDeltas = new StateDelta[](1);
        deferredDeltas[0] = StateDelta({rollupId: rollupId, currentState: state1, newState: keccak256("s2"), etherDelta: 0});
        entries[1].stateDeltas = deferredDeltas;
        entries[1].actionHash = deferredHash;
        entries[1].nextAction = _emptyAction();

        vm.recordLogs();
        _postBatch(entries, 0, "", "proof");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool found, uint256 idx) = _findBatchPostedLog(logs);
        assertTrue(found, "BatchPosted event not found");

        (ExecutionEntry[] memory emitted,) = abi.decode(logs[idx].data, (ExecutionEntry[], bytes32));
        assertEq(emitted.length, 2);
        assertEq(emitted[0].actionHash, bytes32(0)); // immediate
        assertEq(emitted[1].actionHash, deferredHash); // deferred
        // Verify full state delta data is present
        assertEq(emitted[1].stateDeltas[0].currentState, state1);
        assertEq(emitted[1].stateDeltas[0].newState, keccak256("s2"));
    }

    // ══════════════════════════════════════════════
    //  CrossChainCallExecuted event tests (L1)
    // ══════════════════════════════════════════════

    function test_CrossChainCallExecuted_L1_EmitsOnProxyCall() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);

        bytes32 currentState = bytes32(0);
        bytes32 newState = keccak256("state1");
        bytes memory callData = abi.encodeCall(TestTarget.setValue, (42));

        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 actionHash = keccak256(abi.encode(action));

        StateDelta[] memory stateDeltas = new StateDelta[](1);
        stateDeltas[0] = StateDelta({rollupId: rollupId, currentState: currentState, newState: newState, etherDelta: 0});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = stateDeltas;
        entries[0].actionHash = actionHash;
        entries[0].nextAction = _emptyAction();
        _postBatch(entries, 0, "", "proof");

        vm.recordLogs();
        (bool success,) = proxyAddr.call(callData);
        assertTrue(success);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sel = Rollups.CrossChainCallExecuted.selector;
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sel) {
                assertEq(logs[i].topics[1], actionHash);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), proxyAddr);
                (address src, bytes memory cd, uint256 val) = abi.decode(logs[i].data, (address, bytes, uint256));
                assertEq(src, address(this));
                assertEq(cd, callData);
                assertEq(val, 0);
                found = true;
                break;
            }
        }
        assertTrue(found, "CrossChainCallExecuted event not found");
    }

    // ══════════════════════════════════════════════
    //  L2TXExecuted event tests
    // ══════════════════════════════════════════════

    function test_L2TXExecuted_EmitsOnExecute() public {
        uint256 rollupId = _createRollup(bytes32(0), DEFAULT_VK, alice);

        bytes32 currentState = bytes32(0);
        bytes32 newState = keccak256("state1");
        bytes memory rlpTx = hex"deadbeef";

        Action memory action = Action({
            actionType: ActionType.L2TX,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: rlpTx,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 actionHash = keccak256(abi.encode(action));

        StateDelta[] memory stateDeltas = new StateDelta[](1);
        stateDeltas[0] = StateDelta({rollupId: rollupId, currentState: currentState, newState: newState, etherDelta: 0});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = stateDeltas;
        entries[0].actionHash = actionHash;
        entries[0].nextAction = _emptyAction();
        _postBatch(entries, 0, "", "proof");

        vm.recordLogs();
        rollups.executeL2TX(rollupId, rlpTx);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sel = Rollups.L2TXExecuted.selector;
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sel) {
                assertEq(logs[i].topics[1], actionHash);
                assertEq(uint256(logs[i].topics[2]), rollupId);
                (bytes memory emittedRlp) = abi.decode(logs[i].data, (bytes));
                assertEq(emittedRlp, rlpTx);
                found = true;
                break;
            }
        }
        assertTrue(found, "L2TXExecuted event not found");
    }
}
