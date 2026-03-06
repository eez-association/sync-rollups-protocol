// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Rollups, Action, ActionType, ExecutionEntry, StateDelta, ProxyInfo, RollupConfig} from "../src/Rollups.sol";
import {CrossChainProxy} from "../src/CrossChainProxy.sol";
import {IZKVerifier} from "../src/IZKVerifier.sol";

/// @notice Mock ZK verifier that always returns true
contract MockZKVerifier is IZKVerifier {
    bool public shouldVerify = true;

    function setVerifyResult(bool _shouldVerify) external {
        shouldVerify = _shouldVerify;
    }

    function verify(bytes calldata, bytes32) external view override returns (bool) {
        return shouldVerify;
    }
}

/// @notice Simple target contract for testing
contract TestTarget {
    uint256 public value;

    function setValue(uint256 _value) external {
        value = _value;
    }

    function getValue() external view returns (uint256) {
        return value;
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
        rollups = new Rollups(address(verifier), 1);
        target = new TestTarget();
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
        (, bytes32 vk,,) = rollups.rollups(rollupId);
        return vk;
    }

    function _getRollupEtherBalance(uint256 rollupId) internal view returns (uint256) {
        (,,, uint256 etherBalance) = rollups.rollups(rollupId);
        return etherBalance;
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

    function test_CreateRollup() public {
        bytes32 initialState = keccak256("initial");
        uint256 rollupId = rollups.createRollup(initialState, DEFAULT_VK, alice);
        assertEq(rollupId, 1);

        uint256 rollupId2 = rollups.createRollup(bytes32(0), DEFAULT_VK, bob);
        assertEq(rollupId2, 2);

        assertEq(_getRollupState(rollupId), initialState);
        assertEq(_getRollupOwner(rollupId), alice);
        assertEq(_getRollupVK(rollupId), DEFAULT_VK);

        assertEq(_getRollupState(rollupId2), bytes32(0));
        assertEq(_getRollupOwner(rollupId2), bob);
    }

    function test_CreateCrossChainProxy() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

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
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address targetAddr = address(0x5678);

        address computedAddr = rollups.computeCrossChainProxyAddress(targetAddr, rollupId, block.chainid);
        address actualAddr = rollups.createCrossChainProxy(targetAddr, rollupId);

        assertEq(computedAddr, actualAddr);
    }

    function test_PostBatch_ImmediateStateUpdate() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newState = keccak256("new state");

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rollupId, bytes32(0), newState);

        rollups.postBatch(entries, 0, "", "proof");

        assertEq(_getRollupState(rollupId), newState);
    }

    function test_PostBatch_MultipleRollups() public {
        uint256 rollupId1 = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        uint256 rollupId2 = rollups.createRollup(bytes32(0), DEFAULT_VK, bob);
        bytes32 newState1 = keccak256("new state 1");
        bytes32 newState2 = keccak256("new state 2");

        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _immediateEntry(rollupId1, bytes32(0), newState1);
        entries[1] = _immediateEntry(rollupId2, bytes32(0), newState2);

        rollups.postBatch(entries, 0, "shared data", "proof");

        assertEq(_getRollupState(rollupId1), newState1);
        assertEq(_getRollupState(rollupId2), newState2);
    }

    function test_PostBatch_InvalidProof() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newState = keccak256("new state");

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rollupId, bytes32(0), newState);

        verifier.setVerifyResult(false);

        vm.expectRevert(Rollups.InvalidProof.selector);
        rollups.postBatch(entries, 0, "", "bad proof");
    }

    function test_PostBatch_AfterL2ExecutionSameBlockReverts() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

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
        rollups.postBatch(entries, 0, "", "proof");

        // Execute L2 via proxy fallback
        (bool success,) = proxyAddr.call(callData);
        assertTrue(success);
        assertEq(_getRollupState(rollupId), newState);

        // Now try to call postBatch in the same block - should revert
        ExecutionEntry[] memory entries2 = new ExecutionEntry[](1);
        entries2[0] = _immediateEntry(rollupId, newState, keccak256("another state"));

        vm.expectRevert(Rollups.StateAlreadyUpdatedThisBlock.selector);
        rollups.postBatch(entries2, 0, "", "proof");

        assertEq(_getRollupState(rollupId), newState);
    }

    function test_SetStateByOwner() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newState = keccak256("owner set state");

        vm.prank(alice);
        rollups.setStateByOwner(rollupId, newState);

        assertEq(_getRollupState(rollupId), newState);
    }

    function test_SetStateByOwner_NotOwner() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newState = keccak256("owner set state");

        vm.prank(bob);
        vm.expectRevert(Rollups.NotRollupOwner.selector);
        rollups.setStateByOwner(rollupId, newState);
    }

    function test_SetVerificationKey() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newVK = keccak256("new verification key");

        vm.prank(alice);
        rollups.setVerificationKey(rollupId, newVK);

        assertEq(_getRollupVK(rollupId), newVK);
    }

    function test_SetVerificationKey_NotOwner() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newVK = keccak256("new verification key");

        vm.prank(bob);
        vm.expectRevert(Rollups.NotRollupOwner.selector);
        rollups.setVerificationKey(rollupId, newVK);
    }

    function test_TransferRollupOwnership() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

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
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

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
        rollups.postBatch(entries, 0, "", "proof");

        // Execute via proxy fallback
        (bool success,) = proxyAddr.call(callData);
        assertTrue(success);

        assertEq(_getRollupState(rollupId), newState);
    }

    function test_ExecuteCrossChainCall_UnauthorizedProxy() public {
        rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        // Call executeCrossChainCall directly (not from a proxy)
        vm.expectRevert(Rollups.UnauthorizedProxy.selector);
        rollups.executeCrossChainCall(alice, "");
    }

    function test_ExecuteCrossChainCall_ExecutionNotFound() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);

        // Call via proxy without loading execution
        bytes memory callData = abi.encodeCall(TestTarget.setValue, (999));
        vm.expectRevert(Rollups.ExecutionNotFound.selector);
        (bool success,) = proxyAddr.call(callData);
        success;
    }

    function test_ExecuteL2TX() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

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
        rollups.postBatch(entries, 0, "", "proof");

        rollups.executeL2TX(rollupId, rlpTx);

        assertEq(_getRollupState(rollupId), newState);
    }

    function test_StartingRollupId() public {
        Rollups rollups2 = new Rollups(address(verifier), 1000);

        uint256 rollupId = rollups2.createRollup(bytes32(0), DEFAULT_VK, alice);
        assertEq(rollupId, 1000);

        uint256 rollupId2 = rollups2.createRollup(bytes32(0), DEFAULT_VK, alice);
        assertEq(rollupId2, 1001);
    }

    function test_MultipleProxiesSameTarget() public {
        uint256 rollup1 = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        uint256 rollup2 = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

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

        uint256 rollupId = rollups.createRollup(customState, customVK, bob);

        assertEq(_getRollupState(rollupId), customState);
        assertEq(_getRollupVK(rollupId), customVK);
        assertEq(_getRollupOwner(rollupId), bob);
    }

    // ──────────────────────────────────────────────
    //  Deposits & ether tracking
    // ──────────────────────────────────────────────

    function test_DepositEther() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        assertEq(_getRollupEtherBalance(rollupId), 0);

        rollups.depositEther{value: 1 ether}(rollupId);
        assertEq(_getRollupEtherBalance(rollupId), 1 ether);

        rollups.depositEther{value: 0.5 ether}(rollupId);
        assertEq(_getRollupEtherBalance(rollupId), 1.5 ether);
    }

    function test_PostBatch_EtherDeltasMustSumToZero() public {
        uint256 rollupId1 = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        uint256 rollupId2 = rollups.createRollup(bytes32(0), DEFAULT_VK, bob);

        // Deposit ether to rollup1 so it has balance to transfer
        rollups.depositEther{value: 5 ether}(rollupId1);

        // Transfer 2 ether from rollup1 to rollup2 (sum = 0)
        StateDelta[] memory deltas = new StateDelta[](2);
        deltas[0] = StateDelta({rollupId: rollupId1, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: -2 ether});
        deltas[1] = StateDelta({rollupId: rollupId2, currentState: bytes32(0), newState: keccak256("s2"), etherDelta: 2 ether});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = bytes32(0);
        entries[0].nextAction = _emptyAction();

        rollups.postBatch(entries, 0, "", "proof");

        assertEq(_getRollupEtherBalance(rollupId1), 3 ether);
        assertEq(_getRollupEtherBalance(rollupId2), 2 ether);
    }

    function test_PostBatch_EtherDeltasNonZeroSumReverts() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        rollups.depositEther{value: 5 ether}(rollupId);

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: 1 ether});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = bytes32(0);
        entries[0].nextAction = _emptyAction();

        vm.expectRevert(Rollups.EtherIncrementsSumNotZero.selector);
        rollups.postBatch(entries, 0, "", "proof");
    }

    function test_PostBatch_InsufficientRollupBalanceReverts() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        // No deposit - balance is 0

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: -1 ether});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = bytes32(0);
        entries[0].nextAction = _emptyAction();

        vm.expectRevert(Rollups.InsufficientRollupBalance.selector);
        rollups.postBatch(entries, 0, "", "proof");
    }

    function test_PostBatch_MixedImmediateAndDeferred() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
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

        rollups.postBatch(entries, 0, "", "proof");

        // Immediate was applied
        assertEq(_getRollupState(rollupId), state1);

        // Deferred can be consumed
        (bool success,) = proxyAddr.call(callData);
        assertTrue(success);
        assertEq(_getRollupState(rollupId), state2);
    }

    function test_PostBatch_SetsLastStateUpdateBlock() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rollupId, bytes32(0), keccak256("s"));

        rollups.postBatch(entries, 0, "", "proof");

        assertEq(rollups.lastStateUpdateBlock(), block.number);
    }

    // ──────────────────────────────────────────────
    //  Proxy immutables
    // ──────────────────────────────────────────────

    function test_Proxy_StoresImmutables() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);
        CrossChainProxy proxy = CrossChainProxy(payable(proxyAddr));

        assertEq(proxy.MANAGER(), address(rollups));
        assertEq(proxy.ORIGINAL_ADDRESS(), address(target));
        assertEq(proxy.ORIGINAL_ROLLUP_ID(), rollupId);
    }
}
