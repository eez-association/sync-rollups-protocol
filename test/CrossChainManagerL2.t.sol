// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {CrossChainManagerL2} from "../src/CrossChainManagerL2.sol";
import {CrossChainProxy} from "../src/CrossChainProxy.sol";
import {Action, ActionType, ExecutionEntry, StateDelta, ProxyInfo} from "../src/ICrossChainManager.sol";

contract L2TestTarget {
    uint256 public value;

    function setValue(uint256 _value) external {
        value = _value;
    }

    function getValue() external view returns (uint256) {
        return value;
    }

    function setAndReturn(uint256 _value) external returns (uint256) {
        value = _value;
        return _value;
    }

    function reverting() external pure {
        revert("boom");
    }

    receive() external payable {}
}

contract RevertingTarget {
    fallback() external payable {
        revert("always reverts");
    }
}

contract CrossChainManagerL2Test is Test {
    CrossChainManagerL2 public manager;
    L2TestTarget public target;

    uint256 constant TEST_ROLLUP_ID = 42;
    address constant SYSTEM_ADDRESS = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);

    function setUp() public {
        manager = new CrossChainManagerL2(TEST_ROLLUP_ID, SYSTEM_ADDRESS);
        target = new L2TestTarget();
    }

    function _resultAction(bytes memory data) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: 0,
            destination: address(0),
            value: 0,
            data: data,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    function _emptyResult() internal pure returns (Action memory) {
        return _resultAction("");
    }

    function _loadEntry(bytes32 actionHash, Action memory nextAction) internal {
        StateDelta[] memory emptyDeltas = new StateDelta[](0);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = emptyDeltas;
        entries[0].actionHash = actionHash;
        entries[0].nextAction = nextAction;
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries);
    }

    function _makeCallAction(
        uint256 rollupId,
        address destination,
        uint256 value_,
        bytes memory data,
        address sourceAddress,
        uint256 sourceRollup,
        uint256[] memory scope
    )
        internal
        pure
        returns (Action memory)
    {
        return Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: destination,
            value: value_,
            data: data,
            failed: false,
            sourceAddress: sourceAddress,
            sourceRollup: sourceRollup,
            scope: scope
        });
    }

    function _makeRevertAction(uint256 rollupId, uint256[] memory scope) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.REVERT,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: scope
        });
    }

    function _makeRevertContinueAction(uint256 rollupId) internal pure returns (Action memory) {
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

    // ── Constructor ──

    function test_Constructor_SetsRollupId() public view {
        assertEq(manager.ROLLUP_ID(), TEST_ROLLUP_ID);
    }

    function test_Constructor_SetsSystemAddress() public view {
        assertEq(manager.SYSTEM_ADDRESS(), SYSTEM_ADDRESS);
    }

    // ── loadExecutionTable ──

    function test_LoadExecutionTable_RevertsIfNotSystem() public {
        ExecutionEntry[] memory entries = new ExecutionEntry[](0);
        vm.expectRevert(CrossChainManagerL2.Unauthorized.selector);
        manager.loadExecutionTable(entries);
        vm.prank(address(0xBEEF));
        vm.expectRevert(CrossChainManagerL2.Unauthorized.selector);
        manager.loadExecutionTable(entries);
    }

    function test_LoadExecutionTable_SystemCanLoadEmpty() public {
        ExecutionEntry[] memory entries = new ExecutionEntry[](0);
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries);
        assertEq(manager.pendingEntryCount(), 0);
    }

    function test_LoadExecutionTable_StoresEntries() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: TEST_ROLLUP_ID,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            scope: new uint256[](0)
        });
        _loadEntry(keccak256(abi.encode(callAction)), _emptyResult());
        (bool success,) = proxy.call(callData);
        assertTrue(success);
    }

    function test_LoadExecutionTable_MultipleEntries() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: TEST_ROLLUP_ID,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            scope: new uint256[](0)
        });
        bytes32 actionHash = keccak256(abi.encode(callAction));
        StateDelta[] memory emptyDeltas = new StateDelta[](0);
        ExecutionEntry[] memory entries = new ExecutionEntry[](3);
        for (uint256 i = 0; i < 3; i++) {
            entries[i].stateDeltas = emptyDeltas;
            entries[i].actionHash = actionHash;
            entries[i].nextAction = _emptyResult();
        }
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries);
        for (uint256 i = 0; i < 3; i++) {
            (bool success,) = proxy.call(callData);
            assertTrue(success);
        }
        vm.expectRevert(CrossChainManagerL2.ExecutionNotFound.selector);
        (bool s,) = proxy.call(callData);
        s;
    }

    // ── pendingEntryCount ──

    function test_PendingEntryCount_IncreasesOnLoad() public {
        assertEq(manager.pendingEntryCount(), 0);
        _loadEntry(bytes32(uint256(1)), _emptyResult());
        assertEq(manager.pendingEntryCount(), 1);
        StateDelta[] memory emptyDeltas = new StateDelta[](0);
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0].stateDeltas = emptyDeltas;
        entries[0].actionHash = bytes32(uint256(2));
        entries[0].nextAction = _emptyResult();
        entries[1].stateDeltas = emptyDeltas;
        entries[1].actionHash = bytes32(uint256(3));
        entries[1].nextAction = _emptyResult();
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries);
        assertEq(manager.pendingEntryCount(), 3);
    }

    function test_PendingEntryCount_DecreasesOnConsume() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: TEST_ROLLUP_ID,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            scope: new uint256[](0)
        });
        bytes32 actionHash = keccak256(abi.encode(callAction));
        StateDelta[] memory emptyDeltas = new StateDelta[](0);
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0].stateDeltas = emptyDeltas;
        entries[0].actionHash = actionHash;
        entries[0].nextAction = _emptyResult();
        entries[1].stateDeltas = emptyDeltas;
        entries[1].actionHash = actionHash;
        entries[1].nextAction = _emptyResult();
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries);
        assertEq(manager.pendingEntryCount(), 2);
        (bool s1,) = proxy.call(callData);
        assertTrue(s1);
        assertEq(manager.pendingEntryCount(), 1);
        (bool s2,) = proxy.call(callData);
        assertTrue(s2);
        assertEq(manager.pendingEntryCount(), 0);
    }

    // ── createCrossChainProxy ──

    function test_CreateCrossChainProxy() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        (address origAddr, uint64 origRollup) = manager.authorizedProxies(proxy);
        assertEq(origAddr, address(target));
        assertEq(uint256(origRollup), TEST_ROLLUP_ID);
        uint256 codeSize;
        assembly { codeSize := extcodesize(proxy) }
        assertTrue(codeSize > 0);
    }

    function test_CreateCrossChainProxy_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit CrossChainManagerL2.CrossChainProxyCreated(
            manager.computeCrossChainProxyAddress(address(target), TEST_ROLLUP_ID, block.chainid),
            address(target),
            TEST_ROLLUP_ID
        );
        manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
    }

    function test_ComputeCrossChainProxyAddress_MatchesActual() public {
        address computed = manager.computeCrossChainProxyAddress(address(target), TEST_ROLLUP_ID, block.chainid);
        address actual = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        assertEq(computed, actual);
    }

    function test_MultipleProxies_DifferentRollups() public {
        address proxy1 = manager.createCrossChainProxy(address(target), 1);
        address proxy2 = manager.createCrossChainProxy(address(target), 2);
        assertTrue(proxy1 != proxy2);
    }

    function test_MultipleProxies_DifferentAddresses() public {
        L2TestTarget target2 = new L2TestTarget();
        address proxy1 = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        address proxy2 = manager.createCrossChainProxy(address(target2), TEST_ROLLUP_ID);
        assertTrue(proxy1 != proxy2);
    }

    // ── executeCrossChainCall ──

    function test_ExecuteCrossChainCall_RevertsUnauthorizedProxy() public {
        vm.expectRevert(CrossChainManagerL2.UnauthorizedProxy.selector);
        manager.executeCrossChainCall(address(this), "");
    }

    function test_ExecuteCrossChainCall_RevertsExecutionNotFound() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));
        vm.expectRevert(CrossChainManagerL2.ExecutionNotFound.selector);
        (bool s,) = proxy.call(callData);
        s;
    }

    function test_ExecuteL2Call_SimpleResult() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: TEST_ROLLUP_ID,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            scope: new uint256[](0)
        });
        _loadEntry(keccak256(abi.encode(callAction)), _emptyResult());
        (bool success,) = proxy.call(callData);
        assertTrue(success);
        assertEq(target.value(), 0);
    }

    function test_ExecuteL2Call_ResultWithReturnData() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.getValue, ());
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: TEST_ROLLUP_ID,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            scope: new uint256[](0)
        });
        bytes memory returnData = abi.encode(uint256(999));
        _loadEntry(keccak256(abi.encode(callAction)), _resultAction(returnData));
        (bool success, bytes memory ret) = proxy.call(callData);
        assertTrue(success);
        bytes memory decoded = abi.decode(ret, (bytes));
        assertEq(decoded, returnData);
    }

    function test_ExecuteL2Call_FailedResultReverts() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: TEST_ROLLUP_ID,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            scope: new uint256[](0)
        });
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
        _loadEntry(keccak256(abi.encode(callAction)), failedResult);
        vm.expectRevert(CrossChainManagerL2.CallExecutionFailed.selector);
        (bool s,) = proxy.call(callData);
        s;
    }

    function test_ExecuteL2Call_ConsumesInLifoOrder() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.getValue, ());
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: TEST_ROLLUP_ID,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            scope: new uint256[](0)
        });
        bytes32 actionHash = keccak256(abi.encode(callAction));
        StateDelta[] memory emptyDeltas = new StateDelta[](0);
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0].stateDeltas = emptyDeltas;
        entries[0].actionHash = actionHash;
        entries[0].nextAction = _resultAction(abi.encode(uint256(111)));
        entries[1].stateDeltas = emptyDeltas;
        entries[1].actionHash = actionHash;
        entries[1].nextAction = _resultAction(abi.encode(uint256(222)));
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries);
        (bool s1, bytes memory r1) = proxy.call(callData);
        assertTrue(s1);
        assertEq(abi.decode(abi.decode(r1, (bytes)), (uint256)), 222);
        (bool s2, bytes memory r2) = proxy.call(callData);
        assertTrue(s2);
        assertEq(abi.decode(abi.decode(r2, (bytes)), (uint256)), 111);
        vm.expectRevert(CrossChainManagerL2.ExecutionNotFound.selector);
        (bool s3,) = proxy.call(callData);
        s3;
    }

    function test_ExecuteCrossChainCall_NonResultNonCallActionReverts() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: TEST_ROLLUP_ID,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            scope: new uint256[](0)
        });
        Action memory l2txAction = Action({
            actionType: ActionType.L2TX,
            rollupId: TEST_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        _loadEntry(keccak256(abi.encode(callAction)), l2txAction);
        vm.expectRevert(CrossChainManagerL2.CallExecutionFailed.selector);
        (bool s,) = proxy.call(callData);
        s;
    }

    // ── executeIncomingCrossChainCall ──

    function test_ExecuteRemoteCall_RevertsIfNotSystem() public {
        uint256[] memory scope = new uint256[](0);
        vm.expectRevert(CrossChainManagerL2.Unauthorized.selector);
        manager.executeIncomingCrossChainCall(address(target), 0, "", address(this), 0, scope);
    }

    function test_ExecuteRemoteCall_ExecutesOnChainCall() public {
        address sourceAddr = address(0xBEEF);
        uint256 sourceRollup = 1;
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (77));
        uint256[] memory scope = new uint256[](0);
        bytes memory expectedReturnData = "";
        Action memory resultFromCall = Action({
            actionType: ActionType.RESULT,
            rollupId: TEST_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: expectedReturnData,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        _loadEntry(keccak256(abi.encode(resultFromCall)), _emptyResult());
        vm.prank(SYSTEM_ADDRESS);
        manager.executeIncomingCrossChainCall(address(target), 0, callData, sourceAddr, sourceRollup, scope);
        assertEq(target.value(), 77);
    }

    function test_ExecuteRemoteCall_UsesContractRollupId() public {
        address sourceAddr = address(0xBEEF);
        uint256 sourceRollup = 1;
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (55));
        uint256[] memory scope = new uint256[](0);
        bytes memory expectedReturnData = "";
        Action memory resultFromCall = Action({
            actionType: ActionType.RESULT,
            rollupId: TEST_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: expectedReturnData,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        _loadEntry(keccak256(abi.encode(resultFromCall)), _emptyResult());
        vm.prank(SYSTEM_ADDRESS);
        manager.executeIncomingCrossChainCall(address(target), 0, callData, sourceAddr, sourceRollup, scope);
        assertEq(target.value(), 55);
    }

    function test_ExecuteRemoteCall_AutoCreatesProxy() public {
        address sourceAddr = address(0xCAFE);
        uint256 sourceRollup = 7;
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (33));
        uint256[] memory scope = new uint256[](0);
        bytes memory expectedReturnData = "";
        Action memory resultFromCall = Action({
            actionType: ActionType.RESULT,
            rollupId: TEST_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: expectedReturnData,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        _loadEntry(keccak256(abi.encode(resultFromCall)), _emptyResult());
        address expectedProxy = manager.computeCrossChainProxyAddress(sourceAddr, sourceRollup, block.chainid);
        (address origBefore,) = manager.authorizedProxies(expectedProxy);
        assertEq(origBefore, address(0));
        vm.prank(SYSTEM_ADDRESS);
        manager.executeIncomingCrossChainCall(address(target), 0, callData, sourceAddr, sourceRollup, scope);
        (address origAfter,) = manager.authorizedProxies(expectedProxy);
        assertEq(origAfter, sourceAddr);
    }

    function test_ExecuteRemoteCall_CallExecutionFailed_WhenResultFailed() public {
        address sourceAddr = address(0xBEEF);
        uint256 sourceRollup = 1;
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (77));
        uint256[] memory scope = new uint256[](0);
        bytes memory expectedReturnData = "";
        Action memory resultFromCall = Action({
            actionType: ActionType.RESULT,
            rollupId: TEST_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: expectedReturnData,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
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
        _loadEntry(keccak256(abi.encode(resultFromCall)), failedResult);
        vm.prank(SYSTEM_ADDRESS);
        vm.expectRevert(CrossChainManagerL2.CallExecutionFailed.selector);
        manager.executeIncomingCrossChainCall(address(target), 0, callData, sourceAddr, sourceRollup, scope);
    }

    function test_ExecuteRemoteCall_CallExecutionFailed_NonResultAction() public {
        address sourceAddr = address(0xBEEF);
        uint256 sourceRollup = 1;
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (77));
        uint256[] memory scope = new uint256[](0);
        bytes memory expectedReturnData = "";
        Action memory resultFromCall = Action({
            actionType: ActionType.RESULT,
            rollupId: TEST_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: expectedReturnData,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        Action memory l2txAction = Action({
            actionType: ActionType.L2TX,
            rollupId: TEST_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        _loadEntry(keccak256(abi.encode(resultFromCall)), l2txAction);
        vm.prank(SYSTEM_ADDRESS);
        vm.expectRevert(CrossChainManagerL2.CallExecutionFailed.selector);
        manager.executeIncomingCrossChainCall(address(target), 0, callData, sourceAddr, sourceRollup, scope);
    }

    // ── executeCrossChainCall with nested CALL ──

    function test_ExecuteCrossChainCall_WithNestedCall() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (100));
        Action memory initialCall = Action({
            actionType: ActionType.CALL,
            rollupId: TEST_ROLLUP_ID,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            scope: new uint256[](0)
        });
        address nestedSource = address(0xABCD);
        uint256 nestedSourceRollup = 3;
        bytes memory nestedCallData = abi.encodeCall(L2TestTarget.setValue, (200));
        Action memory nestedCall = Action({
            actionType: ActionType.CALL,
            rollupId: TEST_ROLLUP_ID,
            destination: address(target),
            value: 0,
            data: nestedCallData,
            failed: false,
            sourceAddress: nestedSource,
            sourceRollup: nestedSourceRollup,
            scope: new uint256[](0)
        });
        bytes memory expectedReturnData = "";
        Action memory resultFromNestedCall = Action({
            actionType: ActionType.RESULT,
            rollupId: TEST_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: expectedReturnData,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        StateDelta[] memory emptyDeltas = new StateDelta[](0);
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0].stateDeltas = emptyDeltas;
        entries[0].actionHash = keccak256(abi.encode(initialCall));
        entries[0].nextAction = nestedCall;
        entries[1].stateDeltas = emptyDeltas;
        entries[1].actionHash = keccak256(abi.encode(resultFromNestedCall));
        entries[1].nextAction = _emptyResult();
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries);
        (bool success,) = proxy.call(callData);
        assertTrue(success);
        assertEq(target.value(), 200);
    }

    // ── newScope access control ──

    function test_NewScope_RevertsUnauthorizedCaller() public {
        Action memory action = _emptyResult();
        uint256[] memory scope = new uint256[](0);
        vm.prank(address(0xDEAD));
        vm.expectRevert(CrossChainManagerL2.UnauthorizedProxy.selector);
        manager.newScope(scope, action);
    }

    function test_NewScope_ResultPassesThrough() public {
        Action memory result = _resultAction(abi.encode(uint256(42)));
        uint256[] memory scope = new uint256[](0);
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        vm.prank(proxy);
        Action memory returned = manager.newScope(scope, result);
        assertEq(uint8(returned.actionType), uint8(ActionType.RESULT));
        assertEq(returned.data, abi.encode(uint256(42)));
    }

    // ── newScope: child scope navigation ──

    function test_NewScope_ChildScopeRecursion() public {
        address sourceAddr = address(0xABCD);
        uint256 sourceRollup = 5;
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (999));
        uint256[] memory childScope = new uint256[](1);
        childScope[0] = 0;
        Action memory callAtChildScope =
            _makeCallAction(TEST_ROLLUP_ID, address(target), 0, callData, sourceAddr, sourceRollup, childScope);
        bytes memory expectedReturnData = "";
        Action memory resultFromChildCall = Action({
            actionType: ActionType.RESULT,
            rollupId: TEST_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: expectedReturnData,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        _loadEntry(keccak256(abi.encode(resultFromChildCall)), _emptyResult());
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        vm.prank(proxy);
        Action memory returned = manager.newScope(new uint256[](0), callAtChildScope);
        assertEq(uint8(returned.actionType), uint8(ActionType.RESULT));
        assertEq(target.value(), 999);
    }

    // ── newScope: parent/sibling scope (break path) ──

    function test_NewScope_SiblingScope_BreaksAndReturns() public {
        uint256[] memory currentScope = new uint256[](1);
        currentScope[0] = 0;
        uint256[] memory siblingScope = new uint256[](1);
        siblingScope[0] = 1;
        Action memory callAtSibling =
            _makeCallAction(TEST_ROLLUP_ID, address(target), 0, "", address(0xBEEF), 1, siblingScope);
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        vm.prank(proxy);
        Action memory returned = manager.newScope(currentScope, callAtSibling);
        assertEq(uint8(returned.actionType), uint8(ActionType.CALL));
        assertEq(returned.scope[0], 1);
    }

    function test_NewScope_ParentScope_BreaksAndReturns() public {
        uint256[] memory currentScope = new uint256[](2);
        currentScope[0] = 0;
        currentScope[1] = 1;
        Action memory callAtParent =
            _makeCallAction(TEST_ROLLUP_ID, address(target), 0, "", address(0xBEEF), 1, new uint256[](0));
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        vm.prank(proxy);
        Action memory returned = manager.newScope(currentScope, callAtParent);
        assertEq(uint8(returned.actionType), uint8(ActionType.CALL));
        assertEq(returned.scope.length, 0);
    }

    // ── newScope: REVERT action handling ──

    function test_NewScope_RevertAtMatchingScope_RevertsScopeReverted() public {
        uint256[] memory scope = new uint256[](0);
        Action memory revertAction = _makeRevertAction(TEST_ROLLUP_ID, scope);
        Action memory revertContinue = _makeRevertContinueAction(TEST_ROLLUP_ID);
        bytes32 revertHash = keccak256(abi.encode(revertContinue));
        Action memory continuationAction = _emptyResult();
        _loadEntry(revertHash, continuationAction);
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        vm.prank(proxy);
        vm.expectRevert(
            abi.encodeWithSelector(CrossChainManagerL2.ScopeReverted.selector, abi.encode(continuationAction))
        );
        manager.newScope(scope, revertAction);
    }

    function test_NewScope_RevertAtNonMatchingScope_BreaksAndReturns() public {
        uint256[] memory currentScope = new uint256[](1);
        currentScope[0] = 0;
        uint256[] memory revertScope = new uint256[](1);
        revertScope[0] = 1;
        Action memory revertAction = _makeRevertAction(TEST_ROLLUP_ID, revertScope);
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        vm.prank(proxy);
        Action memory returned = manager.newScope(currentScope, revertAction);
        assertEq(uint8(returned.actionType), uint8(ActionType.REVERT));
        assertEq(returned.scope[0], 1);
    }

    function test_NewScope_RevertAtDifferentLengthScope_BreaksAndReturns() public {
        uint256[] memory currentScope = new uint256[](1);
        currentScope[0] = 0;
        Action memory revertAction = _makeRevertAction(TEST_ROLLUP_ID, new uint256[](0));
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        vm.prank(proxy);
        Action memory returned = manager.newScope(currentScope, revertAction);
        assertEq(uint8(returned.actionType), uint8(ActionType.REVERT));
    }

    // ── _resolveScopes catch path (ScopeReverted) ──

    function test_ResolveScopes_CatchesScopeRevertedFromNewScope() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));
        Action memory initialCall = Action({
            actionType: ActionType.CALL,
            rollupId: TEST_ROLLUP_ID,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            scope: new uint256[](0)
        });
        address nestedSource = address(0xABCD);
        uint256 nestedSourceRollup = 3;
        bytes memory nestedCallData = abi.encodeCall(L2TestTarget.setValue, (500));
        uint256[] memory childScope = new uint256[](1);
        childScope[0] = 0;
        Action memory callAtChildScope = _makeCallAction(
            TEST_ROLLUP_ID, address(target), 0, nestedCallData, nestedSource, nestedSourceRollup, childScope
        );
        bytes memory expectedReturnData = "";
        Action memory resultFromChildCall = Action({
            actionType: ActionType.RESULT,
            rollupId: TEST_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: expectedReturnData,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        Action memory revertAtChild = _makeRevertAction(TEST_ROLLUP_ID, childScope);
        Action memory revertContinue = _makeRevertContinueAction(TEST_ROLLUP_ID);
        bytes32 revertContinueHash = keccak256(abi.encode(revertContinue));
        Action memory finalResult = _resultAction(abi.encode(uint256(777)));
        StateDelta[] memory emptyDeltas = new StateDelta[](0);
        ExecutionEntry[] memory entries = new ExecutionEntry[](3);
        entries[0].stateDeltas = emptyDeltas;
        entries[0].actionHash = keccak256(abi.encode(initialCall));
        entries[0].nextAction = callAtChildScope;
        entries[1].stateDeltas = emptyDeltas;
        entries[1].actionHash = keccak256(abi.encode(resultFromChildCall));
        entries[1].nextAction = revertAtChild;
        entries[2].stateDeltas = emptyDeltas;
        entries[2].actionHash = revertContinueHash;
        entries[2].nextAction = finalResult;
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries);
        (bool success, bytes memory ret) = proxy.call(callData);
        assertTrue(success);
        bytes memory decoded = abi.decode(ret, (bytes));
        assertEq(decoded, abi.encode(uint256(777)));
    }

    // ── _resolveScopes catch path at root scope ──

    function test_ResolveScopes_CatchBranch_RevertAtRootScope() public {
        // This test hits _resolveScopes lines 251-252 (catch branch).
        // Flow: executeCrossChainCall -> _consumeExecution -> CALL at scope []
        // -> _resolveScopes(CALL) -> this.newScope([], CALL)
        // -> _scopesMatch -> _processCallAtScope -> result consumed -> REVERT at scope []
        // -> _scopesMatch -> _getRevertContinuation -> revert ScopeReverted(continuation)
        // -> back in _resolveScopes catch -> _handleScopeRevert -> continuation (RESULT)
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));
        // The initial CALL from executeCrossChainCall
        Action memory initialCall = Action({
            actionType: ActionType.CALL,
            rollupId: TEST_ROLLUP_ID,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            scope: new uint256[](0)
        });
        // The consumed nextAction is a CALL at scope [] (triggers _resolveScopes CALL branch)
        address nestedSource = address(0xFACE);
        uint256 nestedRollup = 9;
        bytes memory nestedData = abi.encodeCall(L2TestTarget.setValue, (333));
        Action memory nestedCall = _makeCallAction(
            TEST_ROLLUP_ID, address(target), 0, nestedData, nestedSource, nestedRollup, new uint256[](0)
        );
        // After executing the nested call, the result is consumed.
        bytes memory expectedReturnData = "";
        Action memory resultFromNested = Action({
            actionType: ActionType.RESULT,
            rollupId: TEST_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: expectedReturnData,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        // After consuming the result, next action is REVERT at scope []
        Action memory revertAtRoot = _makeRevertAction(TEST_ROLLUP_ID, new uint256[](0));
        // _getRevertContinuation consumes entry for REVERT_CONTINUE hash
        Action memory revertContinue = _makeRevertContinueAction(TEST_ROLLUP_ID);
        bytes32 revertContinueHash = keccak256(abi.encode(revertContinue));
        // The continuation after revert: a successful RESULT
        Action memory finalResult = _resultAction(abi.encode(uint256(888)));
        // Load entries:
        // 1. initialCall hash -> nestedCall
        // 2. resultFromNested hash -> revertAtRoot
        // 3. revertContinueHash -> finalResult
        StateDelta[] memory emptyDeltas = new StateDelta[](0);
        ExecutionEntry[] memory entries = new ExecutionEntry[](3);
        entries[0].stateDeltas = emptyDeltas;
        entries[0].actionHash = keccak256(abi.encode(initialCall));
        entries[0].nextAction = nestedCall;
        entries[1].stateDeltas = emptyDeltas;
        entries[1].actionHash = keccak256(abi.encode(resultFromNested));
        entries[1].nextAction = revertAtRoot;
        entries[2].stateDeltas = emptyDeltas;
        entries[2].actionHash = revertContinueHash;
        entries[2].nextAction = finalResult;
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries);
        (bool success, bytes memory ret) = proxy.call(callData);
        assertTrue(success);
        bytes memory decoded = abi.decode(ret, (bytes));
        assertEq(decoded, abi.encode(uint256(888)));
    }

    // ── _handleScopeRevert: InvalidRevertData ──

    function test_HandleScopeRevert_InvalidRevertData() public {
        address sourceAddr = address(0xBEEF);
        uint256 sourceRollup = 1;
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (77));
        uint256[] memory scope = new uint256[](0);
        vm.prank(SYSTEM_ADDRESS);
        vm.expectRevert(CrossChainManagerL2.InvalidRevertData.selector);
        manager.executeIncomingCrossChainCall(address(target), 0, callData, sourceAddr, sourceRollup, scope);
    }

    // ── _processCallAtScope: ETH value ──

    function test_ProcessCallAtScope_WithETHValue() public {
        address sourceAddr = address(0xBEEF);
        uint256 sourceRollup = 1;
        // Use empty calldata so it hits the receive() function which is payable
        bytes memory callData = "";
        uint256[] memory scope = new uint256[](0);
        uint256 ethValue = 1 ether;
        vm.deal(address(manager), 10 ether);
        // executeOnBehalf returns raw bytes from the destination call.
        // With empty calldata + value, it calls receive() which returns nothing.
        // The raw return is empty bytes.
        bytes memory expectedReturnData = "";
        Action memory resultFromCall = Action({
            actionType: ActionType.RESULT,
            rollupId: TEST_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: expectedReturnData,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        _loadEntry(keccak256(abi.encode(resultFromCall)), _emptyResult());
        vm.prank(SYSTEM_ADDRESS);
        manager.executeIncomingCrossChainCall(address(target), ethValue, callData, sourceAddr, sourceRollup, scope);
        assertEq(address(target).balance, ethValue);
    }

    // ── _processCallAtScope: existing proxy ──

    function test_ProcessCallAtScope_ExistingProxy() public {
        address sourceAddr = address(0xBEEF);
        uint256 sourceRollup = 1;
        manager.createCrossChainProxy(sourceAddr, sourceRollup);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (88));
        uint256[] memory scope = new uint256[](0);
        bytes memory expectedReturnData = "";
        Action memory resultFromCall = Action({
            actionType: ActionType.RESULT,
            rollupId: TEST_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: expectedReturnData,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        _loadEntry(keccak256(abi.encode(resultFromCall)), _emptyResult());
        vm.prank(SYSTEM_ADDRESS);
        manager.executeIncomingCrossChainCall(address(target), 0, callData, sourceAddr, sourceRollup, scope);
        assertEq(target.value(), 88);
    }

    // ── _processCallAtScope: failed call ──

    function test_ProcessCallAtScope_FailedCall() public {
        RevertingTarget revTarget = new RevertingTarget();
        address sourceAddr = address(0xBEEF);
        uint256 sourceRollup = 1;
        bytes memory callData = hex"deadbeef";
        uint256[] memory scope = new uint256[](0);
        bytes memory revertMsg = abi.encodeWithSignature("Error(string)", "always reverts");
        Action memory failedResultAction = Action({
            actionType: ActionType.RESULT,
            rollupId: TEST_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: revertMsg,
            failed: true,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        _loadEntry(keccak256(abi.encode(failedResultAction)), _emptyResult());
        vm.prank(SYSTEM_ADDRESS);
        manager.executeIncomingCrossChainCall(address(revTarget), 0, callData, sourceAddr, sourceRollup, scope);
    }

    // ── executeIncomingCrossChainCall: catch ScopeReverted ──

    function test_ExecuteRemoteCall_CatchesScopeReverted() public {
        address sourceAddr = address(0xBEEF);
        uint256 sourceRollup = 1;
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (77));
        uint256[] memory scope = new uint256[](0);
        bytes memory expectedReturnData = "";
        Action memory resultFromCall = Action({
            actionType: ActionType.RESULT,
            rollupId: TEST_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: expectedReturnData,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        Action memory revertAction = _makeRevertAction(TEST_ROLLUP_ID, scope);
        Action memory revertContinue = _makeRevertContinueAction(TEST_ROLLUP_ID);
        bytes32 revertContinueHash = keccak256(abi.encode(revertContinue));
        Action memory finalResult = _resultAction(abi.encode(uint256(555)));
        StateDelta[] memory emptyDeltas = new StateDelta[](0);
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0].stateDeltas = emptyDeltas;
        entries[0].actionHash = keccak256(abi.encode(resultFromCall));
        entries[0].nextAction = revertAction;
        entries[1].stateDeltas = emptyDeltas;
        entries[1].actionHash = revertContinueHash;
        entries[1].nextAction = finalResult;
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries);
        vm.prank(SYSTEM_ADDRESS);
        bytes memory result = manager.executeIncomingCrossChainCall(address(target), 0, callData, sourceAddr, sourceRollup, scope);
        assertEq(result, abi.encode(uint256(555)));
    }

    // ── _scopesMatch edge cases ──

    function test_ScopesMatch_DifferentLengths() public {
        uint256[] memory currentScope = new uint256[](1);
        currentScope[0] = 0;
        Action memory callAtRoot =
            _makeCallAction(TEST_ROLLUP_ID, address(target), 0, "", address(0xBEEF), 1, new uint256[](0));
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        vm.prank(proxy);
        Action memory returned = manager.newScope(currentScope, callAtRoot);
        assertEq(uint8(returned.actionType), uint8(ActionType.CALL));
    }

    function test_ScopesMatch_SameLength_DifferentValues() public {
        uint256[] memory currentScope = new uint256[](2);
        currentScope[0] = 0;
        currentScope[1] = 1;
        uint256[] memory actionScope = new uint256[](2);
        actionScope[0] = 0;
        actionScope[1] = 2;
        Action memory callAction =
            _makeCallAction(TEST_ROLLUP_ID, address(target), 0, "", address(0xBEEF), 1, actionScope);
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        vm.prank(proxy);
        Action memory returned = manager.newScope(currentScope, callAction);
        assertEq(uint8(returned.actionType), uint8(ActionType.CALL));
    }

    // ── _isChildScope edge cases ──

    function test_IsChildScope_ShorterTarget() public {
        uint256[] memory currentScope = new uint256[](2);
        currentScope[0] = 0;
        currentScope[1] = 1;
        uint256[] memory actionScope = new uint256[](1);
        actionScope[0] = 0;
        Action memory callAction =
            _makeCallAction(TEST_ROLLUP_ID, address(target), 0, "", address(0xBEEF), 1, actionScope);
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        vm.prank(proxy);
        Action memory returned = manager.newScope(currentScope, callAction);
        assertEq(uint8(returned.actionType), uint8(ActionType.CALL));
    }

    function test_IsChildScope_PrefixMismatch() public {
        uint256[] memory currentScope = new uint256[](1);
        currentScope[0] = 0;
        uint256[] memory actionScope = new uint256[](2);
        actionScope[0] = 1;
        actionScope[1] = 2;
        Action memory callAction =
            _makeCallAction(TEST_ROLLUP_ID, address(target), 0, "", address(0xBEEF), 1, actionScope);
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        vm.prank(proxy);
        Action memory returned = manager.newScope(currentScope, callAction);
        assertEq(uint8(returned.actionType), uint8(ActionType.CALL));
    }

    // ── _appendToScope with non-empty scope ──

    function test_AppendToScope_NonEmptyScope() public {
        address sourceAddr = address(0xABCD);
        uint256 sourceRollup = 5;
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (321));
        uint256[] memory deepScope = new uint256[](2);
        deepScope[0] = 0;
        deepScope[1] = 1;
        Action memory callAtDeepScope =
            _makeCallAction(TEST_ROLLUP_ID, address(target), 0, callData, sourceAddr, sourceRollup, deepScope);
        bytes memory expectedReturnData = "";
        Action memory resultFromCall = Action({
            actionType: ActionType.RESULT,
            rollupId: TEST_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: expectedReturnData,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        _loadEntry(keccak256(abi.encode(resultFromCall)), _emptyResult());
        uint256[] memory startScope = new uint256[](1);
        startScope[0] = 0;
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        vm.prank(proxy);
        Action memory returned = manager.newScope(startScope, callAtDeepScope);
        assertEq(uint8(returned.actionType), uint8(ActionType.RESULT));
        assertEq(target.value(), 321);
    }

    // ── Two levels deep ──

    function test_NewScope_TwoLevelsDeep() public {
        address sourceAddr = address(0xABCD);
        uint256 sourceRollup = 5;
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (777));
        uint256[] memory deepScope = new uint256[](2);
        deepScope[0] = 0;
        deepScope[1] = 0;
        Action memory callAtDeepScope =
            _makeCallAction(TEST_ROLLUP_ID, address(target), 0, callData, sourceAddr, sourceRollup, deepScope);
        bytes memory expectedReturnData = "";
        Action memory resultFromCall = Action({
            actionType: ActionType.RESULT,
            rollupId: TEST_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: expectedReturnData,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        _loadEntry(keccak256(abi.encode(resultFromCall)), _emptyResult());
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        vm.prank(proxy);
        Action memory returned = manager.newScope(new uint256[](0), callAtDeepScope);
        assertEq(uint8(returned.actionType), uint8(ActionType.RESULT));
        assertEq(target.value(), 777);
    }

    // ── while loop continues with multiple calls at same scope ──

    function test_NewScope_WhileLoopContinuesWithMultipleCalls() public {
        address sourceAddr1 = address(0xABCD);
        uint256 sourceRollup1 = 3;
        bytes memory callData1 = abi.encodeCall(L2TestTarget.setValue, (100));
        address sourceAddr2 = address(0xDEAD);
        uint256 sourceRollup2 = 4;
        bytes memory callData2 = abi.encodeCall(L2TestTarget.setValue, (200));
        uint256[] memory emptyScope = new uint256[](0);
        Action memory firstCall =
            _makeCallAction(TEST_ROLLUP_ID, address(target), 0, callData1, sourceAddr1, sourceRollup1, emptyScope);
        Action memory secondCall =
            _makeCallAction(TEST_ROLLUP_ID, address(target), 0, callData2, sourceAddr2, sourceRollup2, emptyScope);
        bytes memory expectedReturnData = "";
        Action memory result1 = Action({
            actionType: ActionType.RESULT,
            rollupId: TEST_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: expectedReturnData,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 resultHash = keccak256(abi.encode(result1));
        StateDelta[] memory emptyDeltas = new StateDelta[](0);
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0].stateDeltas = emptyDeltas;
        entries[0].actionHash = resultHash;
        entries[0].nextAction = _emptyResult();
        entries[1].stateDeltas = emptyDeltas;
        entries[1].actionHash = resultHash;
        entries[1].nextAction = secondCall;
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries);
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        vm.prank(proxy);
        Action memory returned = manager.newScope(emptyScope, firstCall);
        assertEq(uint8(returned.actionType), uint8(ActionType.RESULT));
        assertEq(target.value(), 200);
    }

    // ── executeIncomingCrossChainCall with non-empty scope ──

    function test_ExecuteRemoteCall_WithNonEmptyScope() public {
        address sourceAddr = address(0xBEEF);
        uint256 sourceRollup = 1;
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (44));
        uint256[] memory scope = new uint256[](1);
        scope[0] = 0;
        bytes memory expectedReturnData = "";
        Action memory resultFromCall = Action({
            actionType: ActionType.RESULT,
            rollupId: TEST_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: expectedReturnData,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        _loadEntry(keccak256(abi.encode(resultFromCall)), _emptyResult());
        vm.prank(SYSTEM_ADDRESS);
        manager.executeIncomingCrossChainCall(address(target), 0, callData, sourceAddr, sourceRollup, scope);
        assertEq(target.value(), 44);
    }

    // ── newScope child scope catches ScopeReverted (L179-181) ──

    function test_NewScope_ChildScope_CatchesScopeReverted() public {
        address sourceAddr = address(0xABCD);
        uint256 sourceRollup = 5;
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (123));
        uint256[] memory childScope = new uint256[](1);
        childScope[0] = 0;
        Action memory callAtChildScope =
            _makeCallAction(TEST_ROLLUP_ID, address(target), 0, callData, sourceAddr, sourceRollup, childScope);
        bytes memory expectedReturnData = "";
        Action memory resultFromCall = Action({
            actionType: ActionType.RESULT,
            rollupId: TEST_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: expectedReturnData,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        Action memory revertAtChild = _makeRevertAction(TEST_ROLLUP_ID, childScope);
        Action memory revertContinue = _makeRevertContinueAction(TEST_ROLLUP_ID);
        bytes32 revertContinueHash = keccak256(abi.encode(revertContinue));
        Action memory continuationResult = _resultAction(abi.encode(uint256(456)));
        StateDelta[] memory emptyDeltas = new StateDelta[](0);
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0].stateDeltas = emptyDeltas;
        entries[0].actionHash = keccak256(abi.encode(resultFromCall));
        entries[0].nextAction = revertAtChild;
        entries[1].stateDeltas = emptyDeltas;
        entries[1].actionHash = revertContinueHash;
        entries[1].nextAction = continuationResult;
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries);
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        vm.prank(proxy);
        Action memory returned = manager.newScope(new uint256[](0), callAtChildScope);
        assertEq(uint8(returned.actionType), uint8(ActionType.RESULT));
        assertEq(abi.decode(returned.data, (uint256)), 456);
    }

    // ── CrossChainProxy direct tests ──

    function test_Proxy_StoresImmutables() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        CrossChainProxy p = CrossChainProxy(payable(proxy));
        assertEq(address(p.MANAGER()), address(manager));
        assertEq(p.ORIGINAL_ADDRESS(), address(target));
        assertEq(p.ORIGINAL_ROLLUP_ID(), TEST_ROLLUP_ID);
    }

    function test_Proxy_ExecuteOnBehalf_NonManagerFallsThrough() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        CrossChainProxy p = CrossChainProxy(payable(proxy));
        // Non-manager callers are routed through _fallback() (cross-chain path),
        // which calls executeCrossChainCall and reverts with ExecutionNotFound
        vm.prank(address(0xDEAD));
        vm.expectRevert(CrossChainManagerL2.ExecutionNotFound.selector);
        p.executeOnBehalf(address(target), abi.encodeCall(L2TestTarget.setValue, (42)));
    }

    // ── RESULT with uint256 return data ──

    function test_ExecuteIncomingCrossChainCall_ResultWithUint256() public {
        address sourceAddr = address(0xBEEF);
        uint256 sourceRollup = 1;
        // setAndReturn(42) returns uint256(42)
        bytes memory callData = abi.encodeCall(L2TestTarget.setAndReturn, (42));
        uint256[] memory scope = new uint256[](0);

        // After executeOnBehalf, raw return = abi.encode(uint256(42))
        Action memory resultFromCall = Action({
            actionType: ActionType.RESULT,
            rollupId: TEST_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(42)),
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        // Final result also carries the uint256
        Action memory finalResult = _resultAction(abi.encode(uint256(42)));
        _loadEntry(keccak256(abi.encode(resultFromCall)), finalResult);

        vm.prank(SYSTEM_ADDRESS);
        bytes memory result =
            manager.executeIncomingCrossChainCall(address(target), 0, callData, sourceAddr, sourceRollup, scope);

        assertEq(target.value(), 42);
        uint256 decoded = abi.decode(result, (uint256));
        assertEq(decoded, 42);
    }

    function test_ExecuteCrossChainCall_ResultWithUint256() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setAndReturn, (99));

        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: TEST_ROLLUP_ID,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            scope: new uint256[](0)
        });

        // After executeOnBehalf calls setAndReturn(99), raw return = abi.encode(uint256(99))
        Action memory nestedCall = Action({
            actionType: ActionType.CALL,
            rollupId: TEST_ROLLUP_ID,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            scope: new uint256[](0)
        });

        Action memory resultFromCall = Action({
            actionType: ActionType.RESULT,
            rollupId: TEST_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(99)),
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        Action memory finalResult = _resultAction(abi.encode(uint256(99)));

        StateDelta[] memory emptyDeltas = new StateDelta[](0);
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0].stateDeltas = emptyDeltas;
        entries[0].actionHash = keccak256(abi.encode(callAction));
        entries[0].nextAction = nestedCall;
        entries[1].stateDeltas = emptyDeltas;
        entries[1].actionHash = keccak256(abi.encode(resultFromCall));
        entries[1].nextAction = finalResult;
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries);

        (bool success, bytes memory ret) = proxy.call(callData);
        assertTrue(success);
        assertEq(target.value(), 99);
        bytes memory decoded = abi.decode(ret, (bytes));
        uint256 val = abi.decode(decoded, (uint256));
        assertEq(val, 99);
    }

    // ══════════════════════════════════════════════
    //  Event tests
    // ══════════════════════════════════════════════

    // ── ExecutionTableLoaded ──

    function _findExecutionTableLoadedLog(Vm.Log[] memory logs) internal view returns (bool found, uint256 idx) {
        bytes32 sel = CrossChainManagerL2.ExecutionTableLoaded.selector;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sel) {
                return (true, i);
            }
        }
        return (false, 0);
    }

    function test_ExecutionTableLoaded_EmitsOnLoad() public {
        bytes32 hash1 = bytes32(uint256(1));
        bytes32 hash2 = bytes32(uint256(2));

        StateDelta[] memory emptyDeltas = new StateDelta[](0);
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0].stateDeltas = emptyDeltas;
        entries[0].actionHash = hash1;
        entries[0].nextAction = _emptyResult();
        entries[1].stateDeltas = emptyDeltas;
        entries[1].actionHash = hash2;
        entries[1].nextAction = _emptyResult();

        vm.recordLogs();
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool found, uint256 idx) = _findExecutionTableLoadedLog(logs);
        assertTrue(found, "ExecutionTableLoaded event not found");

        (ExecutionEntry[] memory emitted) = abi.decode(logs[idx].data, (ExecutionEntry[]));
        assertEq(emitted.length, 2);
        assertEq(emitted[0].actionHash, hash1);
        assertEq(emitted[1].actionHash, hash2);
        assertEq(uint8(emitted[0].nextAction.actionType), uint8(ActionType.RESULT));
    }

    function test_ExecutionTableLoaded_EmptyBatch() public {
        ExecutionEntry[] memory entries = new ExecutionEntry[](0);

        vm.recordLogs();
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool found, uint256 idx) = _findExecutionTableLoadedLog(logs);
        assertTrue(found, "ExecutionTableLoaded event not found for empty batch");

        (ExecutionEntry[] memory emitted) = abi.decode(logs[idx].data, (ExecutionEntry[]));
        assertEq(emitted.length, 0);
    }

    // ── ExecutionConsumed ──

    function test_ExecutionConsumed_EmitsOnConsume() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: TEST_ROLLUP_ID,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            scope: new uint256[](0)
        });
        bytes32 actionHash = keccak256(abi.encode(callAction));
        _loadEntry(actionHash, _emptyResult());

        vm.recordLogs();
        (bool success,) = proxy.call(callData);
        assertTrue(success);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sel = CrossChainManagerL2.ExecutionConsumed.selector;
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sel) {
                assertEq(logs[i].topics[1], actionHash);
                // Decode the Action from event data
                (Action memory emittedAction) = abi.decode(logs[i].data, (Action));
                assertEq(uint8(emittedAction.actionType), uint8(ActionType.CALL));
                assertEq(emittedAction.rollupId, TEST_ROLLUP_ID);
                assertEq(emittedAction.destination, address(target));
                assertEq(emittedAction.sourceAddress, address(this));
                found = true;
                break;
            }
        }
        assertTrue(found, "ExecutionConsumed event not found");
    }

    function test_ExecutionConsumed_EmitsForEachConsumption() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: TEST_ROLLUP_ID,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            scope: new uint256[](0)
        });
        bytes32 actionHash = keccak256(abi.encode(callAction));

        // Load 2 entries with the same action hash
        StateDelta[] memory emptyDeltas = new StateDelta[](0);
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0].stateDeltas = emptyDeltas;
        entries[0].actionHash = actionHash;
        entries[0].nextAction = _emptyResult();
        entries[1].stateDeltas = emptyDeltas;
        entries[1].actionHash = actionHash;
        entries[1].nextAction = _emptyResult();
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries);

        vm.recordLogs();
        (bool s1,) = proxy.call(callData);
        assertTrue(s1);
        (bool s2,) = proxy.call(callData);
        assertTrue(s2);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sel = CrossChainManagerL2.ExecutionConsumed.selector;
        uint256 consumedCount = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sel) {
                assertEq(logs[i].topics[1], actionHash);
                consumedCount++;
            }
        }
        assertEq(consumedCount, 2);
    }

    // ── CrossChainCallExecuted ──

    function test_CrossChainCallExecuted_EmitsOnProxyCall() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: TEST_ROLLUP_ID,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            scope: new uint256[](0)
        });
        bytes32 actionHash = keccak256(abi.encode(callAction));
        _loadEntry(actionHash, _emptyResult());

        vm.recordLogs();
        (bool success,) = proxy.call(callData);
        assertTrue(success);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sel = CrossChainManagerL2.CrossChainCallExecuted.selector;
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sel) {
                assertEq(logs[i].topics[1], actionHash);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), proxy);
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

    // ── IncomingCrossChainCallExecuted ──

    function test_IncomingCrossChainCallExecuted_EmitsOnRemoteCall() public {
        address sourceAddr = address(0xBEEF);
        uint256 sourceRollup = 1;
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (77));
        uint256[] memory scope = new uint256[](0);

        bytes memory expectedReturnData = "";
        Action memory resultFromCall = Action({
            actionType: ActionType.RESULT,
            rollupId: TEST_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: expectedReturnData,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        _loadEntry(keccak256(abi.encode(resultFromCall)), _emptyResult());

        vm.recordLogs();
        vm.prank(SYSTEM_ADDRESS);
        manager.executeIncomingCrossChainCall(address(target), 0, callData, sourceAddr, sourceRollup, scope);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Compute expected action hash
        Action memory expectedAction = Action({
            actionType: ActionType.CALL,
            rollupId: TEST_ROLLUP_ID,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: sourceAddr,
            sourceRollup: sourceRollup,
            scope: scope
        });
        bytes32 expectedHash = keccak256(abi.encode(expectedAction));

        bytes32 sel = CrossChainManagerL2.IncomingCrossChainCallExecuted.selector;
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sel) {
                assertEq(logs[i].topics[1], expectedHash);
                (address dest, uint256 val, bytes memory data, address src, uint256 srcRollup, uint256[] memory sc) =
                    abi.decode(logs[i].data, (address, uint256, bytes, address, uint256, uint256[]));
                assertEq(dest, address(target));
                assertEq(val, 0);
                assertEq(data, callData);
                assertEq(src, sourceAddr);
                assertEq(srcRollup, sourceRollup);
                assertEq(sc.length, 0);
                found = true;
                break;
            }
        }
        assertTrue(found, "IncomingCrossChainCallExecuted event not found");
    }
}
