// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CrossChainManagerL2} from "../src/CrossChainManagerL2.sol";
import {CrossChainProxy} from "../src/CrossChainProxy.sol";
import {Action, ActionType, ExecutionEntry, StateDelta, ProxyInfo} from "../src/Rollups.sol";

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

    // ── Helpers ──

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

    // ──────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────

    function test_Constructor_SetsRollupId() public view {
        assertEq(manager.ROLLUP_ID(), TEST_ROLLUP_ID);
    }

    // ──────────────────────────────────────────────
    //  loadExecutionTable
    // ──────────────────────────────────────────────

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
    }

    function test_LoadExecutionTable_StoresEntries() public {
        // Load an entry, then consume it via executeCrossChainCall to prove it was stored
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
            sourceRollup: 0,
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
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        bytes32 actionHash = keccak256(abi.encode(callAction));

        // Load 3 entries in a single batch
        StateDelta[] memory emptyDeltas = new StateDelta[](0);
        ExecutionEntry[] memory entries = new ExecutionEntry[](3);
        for (uint256 i = 0; i < 3; i++) {
            entries[i].stateDeltas = emptyDeltas;
            entries[i].actionHash = actionHash;
            entries[i].nextAction = _emptyResult();
        }
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries);

        // All 3 can be consumed
        for (uint256 i = 0; i < 3; i++) {
            (bool success,) = proxy.call(callData);
            assertTrue(success);
        }

        // 4th call fails
        vm.expectRevert(CrossChainManagerL2.ExecutionNotFound.selector);
        (bool s,) = proxy.call(callData);
        s;
    }

    // ──────────────────────────────────────────────
    //  createCrossChainProxy
    // ──────────────────────────────────────────────

    function test_CreateCrossChainProxy() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);

        (address origAddr, uint64 origRollup) = manager.authorizedProxies(proxy);
        assertEq(origAddr, address(target));
        assertEq(uint256(origRollup), TEST_ROLLUP_ID);

        uint256 codeSize;
        assembly {
            codeSize := extcodesize(proxy)
        }
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

    // ──────────────────────────────────────────────
    //  executeCrossChainCall
    // ──────────────────────────────────────────────

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
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        _loadEntry(keccak256(abi.encode(callAction)), _emptyResult());

        (bool success,) = proxy.call(callData);
        assertTrue(success);
        // Note: target.value() is NOT 42 here — no actual call happens in simple CALL->RESULT path
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
            sourceRollup: 0,
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
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        bytes32 actionHash = keccak256(abi.encode(callAction));

        // Load 2 entries: first returns 111, second returns 222
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

        // First call gets last entry (222)
        (bool s1, bytes memory r1) = proxy.call(callData);
        assertTrue(s1);
        assertEq(abi.decode(abi.decode(r1, (bytes)), (uint256)), 222);

        // Second call gets first entry (111)
        (bool s2, bytes memory r2) = proxy.call(callData);
        assertTrue(s2);
        assertEq(abi.decode(abi.decode(r2, (bytes)), (uint256)), 111);

        // Third call reverts
        vm.expectRevert(CrossChainManagerL2.ExecutionNotFound.selector);
        (bool s3,) = proxy.call(callData);
        s3;
    }

    // ──────────────────────────────────────────────
    //  executeRemoteCall
    // ──────────────────────────────────────────────

    function test_ExecuteRemoteCall_RevertsIfNotSystem() public {
        uint256[] memory scope = new uint256[](0);
        vm.expectRevert(CrossChainManagerL2.Unauthorized.selector);
        manager.executeRemoteCall(address(target), 0, "", address(this), 0, scope);
    }

    function test_ExecuteRemoteCall_ExecutesOnChainCall() public {
        address sourceAddr = address(0xBEEF);
        uint256 sourceRollup = 1;
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (77));
        uint256[] memory scope = new uint256[](0);

        // _processCallAtScope will call executeOnBehalf(target, callData) on a proxy.
        // setValue returns void, so returnData from .call(executeOnBehalf) = abi.encode(bytes(""))
        bytes memory expectedReturnData = abi.encode(bytes(""));

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
        manager.executeRemoteCall(address(target), 0, callData, sourceAddr, sourceRollup, scope);

        // The actual on-chain call happened
        assertEq(target.value(), 77);
    }

    function test_ExecuteRemoteCall_UsesContractRollupId() public {
        address sourceAddr = address(0xBEEF);
        uint256 sourceRollup = 1;
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (55));
        uint256[] memory scope = new uint256[](0);

        bytes memory expectedReturnData = abi.encode(bytes(""));

        // RESULT uses ROLLUP_ID (from the CALL action built by executeRemoteCall)
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
        manager.executeRemoteCall(address(target), 0, callData, sourceAddr, sourceRollup, scope);

        assertEq(target.value(), 55);
    }

    function test_ExecuteRemoteCall_AutoCreatesProxy() public {
        address sourceAddr = address(0xCAFE);
        uint256 sourceRollup = 7;
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (33));
        uint256[] memory scope = new uint256[](0);

        bytes memory expectedReturnData = abi.encode(bytes(""));

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

        // Proxy doesn't exist yet
        address expectedProxy = manager.computeCrossChainProxyAddress(sourceAddr, sourceRollup, block.chainid);
        (address origBefore,) = manager.authorizedProxies(expectedProxy);
        assertEq(origBefore, address(0));

        vm.prank(SYSTEM_ADDRESS);
        manager.executeRemoteCall(address(target), 0, callData, sourceAddr, sourceRollup, scope);

        // Proxy was auto-created
        (address origAfter,) = manager.authorizedProxies(expectedProxy);
        assertEq(origAfter, sourceAddr);
    }

    // ──────────────────────────────────────────────
    //  executeCrossChainCall with nested CALL (scope navigation)
    // ──────────────────────────────────────────────

    function test_ExecuteCrossChainCall_WithNestedCall() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (100));

        // Initial CALL action from proxy
        Action memory initialCall = Action({
            actionType: ActionType.CALL,
            rollupId: TEST_ROLLUP_ID,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        // Next action: a nested CALL to setValue(200)
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

        // The nested call executes via _processCallAtScope.
        // setValue(200) returns void -> returnData from .call(executeOnBehalf) = abi.encode(bytes(""))
        bytes memory expectedReturnData = abi.encode(bytes(""));

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

        // Load both entries
        StateDelta[] memory emptyDeltas = new StateDelta[](0);
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);

        // Entry 1: initial CALL -> nested CALL
        entries[0].stateDeltas = emptyDeltas;
        entries[0].actionHash = keccak256(abi.encode(initialCall));
        entries[0].nextAction = nestedCall;

        // Entry 2: RESULT from nested call -> final RESULT
        entries[1].stateDeltas = emptyDeltas;
        entries[1].actionHash = keccak256(abi.encode(resultFromNestedCall));
        entries[1].nextAction = _emptyResult();

        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries);

        // Execute via proxy
        (bool success,) = proxy.call(callData);
        assertTrue(success);

        // The nested call actually executed setValue(200)
        assertEq(target.value(), 200);
    }

    // ──────────────────────────────────────────────
    //  newScope access control
    // ──────────────────────────────────────────────

    function test_NewScope_RevertsUnauthorizedCaller() public {
        Action memory action = _emptyResult();
        uint256[] memory scope = new uint256[](0);

        vm.prank(address(0xDEAD));
        vm.expectRevert(CrossChainManagerL2.UnauthorizedProxy.selector);
        manager.newScope(scope, action);
    }

    function test_NewScope_ResultPassesThrough() public {
        // newScope with a RESULT action just returns it immediately
        Action memory result = _resultAction(abi.encode(uint256(42)));
        uint256[] memory scope = new uint256[](0);

        // Call from the manager itself (self-call is allowed)
        // We simulate this by calling via the manager's external interface
        // Actually, we need to be an authorized proxy or the contract itself.
        // Create a proxy so its address is authorized, then prank from it.
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);

        vm.prank(proxy);
        Action memory returned = manager.newScope(scope, result);
        assertEq(uint8(returned.actionType), uint8(ActionType.RESULT));
        assertEq(returned.data, abi.encode(uint256(42)));
    }

    // ──────────────────────────────────────────────
    //  CrossChainProxy direct tests
    // ──────────────────────────────────────────────

    function test_Proxy_StoresImmutables() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        CrossChainProxy p = CrossChainProxy(payable(proxy));

        assertEq(p.MANAGER(), address(manager));
        assertEq(p.ORIGINAL_ADDRESS(), address(target));
        assertEq(p.ORIGINAL_ROLLUP_ID(), TEST_ROLLUP_ID);
    }

    function test_Proxy_ExecuteOnBehalf_RevertsIfNotManager() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        CrossChainProxy p = CrossChainProxy(payable(proxy));

        vm.prank(address(0xDEAD));
        vm.expectRevert(CrossChainProxy.Unauthorized.selector);
        p.executeOnBehalf(address(target), abi.encodeCall(L2TestTarget.setValue, (42)));
    }
}
