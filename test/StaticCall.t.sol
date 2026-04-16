// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Rollups} from "../src/Rollups.sol";
import {CrossChainManagerL2} from "../src/CrossChainManagerL2.sol";
import {CrossChainProxy} from "../src/CrossChainProxy.sol";
import {
    ICrossChainManager,
    Action,
    ActionType,
    ExecutionEntry,
    StateDelta,
    StaticCall,
    StaticSubCall,
    RollupStateRoot
} from "../src/ICrossChainManager.sol";
import {MockZKVerifier} from "./helpers/TestBase.sol";

/// @notice Minimal view target. The static lookup itself does not actually execute this contract —
///         it just needs a stable ABI for callData hashing. For test 7 the view method is also
///         invoked through executeOnBehalf via STATICCALL.
contract StaticTarget {
    uint256 public value;

    constructor(uint256 _v) {
        value = _v;
    }

    function readValue() external view returns (uint256) {
        return value;
    }

    function mutate(uint256 _v) external {
        value = _v;
    }
}

/// @notice Custom error used to test the `failed=true` replay path.
error StaticBoom(uint256 code);

contract StaticCallTest is Test {
    uint256 constant MAINNET_ROLLUP_ID = 0;
    uint256 constant L2_ROLLUP_ID = 1;
    uint256 constant OTHER_ROLLUP_ID = 2;
    address constant SYSTEM_ADDRESS = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
    bytes32 constant VK = keccak256("VK");
    bytes32 constant L2_INITIAL_STATE = bytes32(uint256(0xA11CE));
    bytes32 constant OTHER_INITIAL_STATE = bytes32(uint256(0xB0B));

    Rollups public rollups;
    MockZKVerifier public verifier;
    StaticTarget public target;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        verifier = new MockZKVerifier();
        // Starting rollup ID = 1 so that the first-created rollup has id 1 (L2_ROLLUP_ID)
        rollups = new Rollups(address(verifier), 1);
        target = new StaticTarget(42);

        // Create L2 rollup with initial state
        uint256 idA = rollups.createRollup(L2_INITIAL_STATE, VK, alice);
        require(idA == L2_ROLLUP_ID, "unexpected L2 id");

        // Create second rollup for multi-state-root test
        uint256 idB = rollups.createRollup(OTHER_INITIAL_STATE, VK, bob);
        require(idB == OTHER_ROLLUP_ID, "unexpected other id");
    }

    // ──────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────

    /// @dev Builds the CALL action that a manager's staticCallLookup reconstructs from
    ///      (sourceAddress, callData). The scope is ALWAYS empty, matching both the L1
    ///      and L2 managers' reconstruction.
    function _buildStaticAction(
        uint256 rollupId,
        address destination,
        bytes memory callData,
        address sourceAddress,
        uint256 sourceRollup
    ) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: destination,
            value: 0,
            data: callData,
            failed: false,
            isStatic: true,
            sourceAddress: sourceAddress,
            sourceRollup: sourceRollup,
            scope: new uint256[](0)
        });
    }

    function _makeStaticCall(
        bytes32 actionHash,
        bytes memory returnData,
        bool failed,
        RollupStateRoot[] memory stateRoots
    ) internal pure returns (StaticCall memory sc) {
        sc.actionHash = actionHash;
        sc.returnData = returnData;
        sc.failed = failed;
        sc.calls = new StaticSubCall[](0);
        sc.rollingHash = bytes32(0);
        sc.stateRoots = stateRoots;
    }

    function _postStaticBatch(StaticCall[] memory scs) internal {
        ExecutionEntry[] memory noEntries = new ExecutionEntry[](0);
        rollups.postBatch(noEntries, scs, 0, "", "proof");
    }

    function _postStaticBatchWithEntries(
        ExecutionEntry[] memory entries,
        StaticCall[] memory scs
    ) internal {
        rollups.postBatch(entries, scs, 0, "", "proof");
    }

    function _singleStaticBatch(StaticCall memory sc) internal {
        StaticCall[] memory scs = new StaticCall[](1);
        scs[0] = sc;
        _postStaticBatch(scs);
    }

    function _registerProxyL1(address originalAddress, uint256 originalRollupId)
        internal
        returns (address proxy)
    {
        proxy = rollups.createCrossChainProxy(originalAddress, originalRollupId);
    }

    function _registerProxyL2(CrossChainManagerL2 mgr, address originalAddress, uint256 originalRollupId)
        internal
        returns (address proxy)
    {
        proxy = mgr.createCrossChainProxy(originalAddress, originalRollupId);
    }

    function _loadL2Static(CrossChainManagerL2 mgr, StaticCall[] memory scs) internal {
        ExecutionEntry[] memory noEntries = new ExecutionEntry[](0);
        vm.prank(SYSTEM_ADDRESS);
        mgr.loadExecutionTable(noEntries, scs);
    }

    // ──────────────────────────────────────────────
    //  Tests
    // ──────────────────────────────────────────────

    /// @notice Test 1: L1 happy path — static lookup returns the pre-computed value.
    function test_StaticLookup_HappyPath_L1() public {
        address proxy = _registerProxyL1(address(target), L2_ROLLUP_ID);

        bytes memory callData = abi.encodeCall(StaticTarget.readValue, ());
        Action memory action = _buildStaticAction(
            L2_ROLLUP_ID,
            address(target),
            callData,
            alice,
            MAINNET_ROLLUP_ID
        );
        bytes32 actionHash = keccak256(abi.encode(action));

        bytes memory encodedReturn = abi.encode(uint256(42));
        _singleStaticBatch(_makeStaticCall(actionHash, encodedReturn, false, new RollupStateRoot[](0)));

        vm.prank(alice);
        (bool ok, bytes memory ret) = proxy.staticcall(callData);
        assertTrue(ok, "staticcall failed");
        uint256 decoded = abi.decode(ret, (uint256));
        assertEq(decoded, 42, "unexpected value");
    }

    /// @notice Test 2: L1 failed=true replays returnData as the revert payload.
    function test_StaticLookup_FailedTrue_L1() public {
        address proxy = _registerProxyL1(address(target), L2_ROLLUP_ID);

        bytes memory callData = abi.encodeCall(StaticTarget.readValue, ());
        Action memory action = _buildStaticAction(
            L2_ROLLUP_ID,
            address(target),
            callData,
            alice,
            MAINNET_ROLLUP_ID
        );
        bytes32 actionHash = keccak256(abi.encode(action));

        bytes memory customRevert = abi.encodeWithSelector(StaticBoom.selector, uint256(7));
        _singleStaticBatch(_makeStaticCall(actionHash, customRevert, true, new RollupStateRoot[](0)));

        vm.prank(alice);
        (bool ok, bytes memory ret) = proxy.staticcall(callData);
        assertFalse(ok, "should have reverted");
        assertEq(keccak256(ret), keccak256(customRevert), "revert payload mismatch");
    }

    /// @notice Test 3: L1 — no matching static call entry — surfaces `StaticCallNotFound()`
    ///         selector as raw bytes through the proxy.
    function test_StaticLookup_Revert_NotFound_L1() public {
        address proxy = _registerProxyL1(address(target), L2_ROLLUP_ID);

        // Post a batch with an unrelated entry so we are "in the current block" state-wise.
        _postStaticBatch(new StaticCall[](0));

        bytes memory callData = abi.encodeCall(StaticTarget.readValue, ());
        vm.prank(alice);
        (bool ok, bytes memory ret) = proxy.staticcall(callData);
        assertFalse(ok, "expected revert");
        assertEq(ret.length, 4, "expected 4-byte selector");
        assertEq(bytes4(ret), ICrossChainManager.StaticCallNotFound.selector, "wrong selector");
    }

    /// @notice Test 4: L1 — pinned rollup state root mismatches current state → revert.
    function test_StaticLookup_Revert_StateRootMismatch_L1() public {
        address proxy = _registerProxyL1(address(target), L2_ROLLUP_ID);

        bytes memory callData = abi.encodeCall(StaticTarget.readValue, ());
        Action memory action = _buildStaticAction(
            L2_ROLLUP_ID,
            address(target),
            callData,
            alice,
            MAINNET_ROLLUP_ID
        );
        bytes32 actionHash = keccak256(abi.encode(action));

        // Pin an intentionally wrong state root for L2_ROLLUP_ID
        RollupStateRoot[] memory roots = new RollupStateRoot[](1);
        roots[0] = RollupStateRoot({rollupId: L2_ROLLUP_ID, stateRoot: bytes32(uint256(0xDEAD))});

        _singleStaticBatch(_makeStaticCall(actionHash, abi.encode(uint256(42)), false, roots));

        vm.prank(alice);
        (bool ok, bytes memory ret) = proxy.staticcall(callData);
        assertFalse(ok, "expected revert");
        assertEq(bytes4(ret), ICrossChainManager.StaticCallStateRootMismatch.selector, "wrong selector");
    }

    /// @notice Test 5: L1 — multiple pinned state roots all match current state → success.
    function test_StaticLookup_MultipleStateRootsMatch_L1() public {
        address proxy = _registerProxyL1(address(target), L2_ROLLUP_ID);

        bytes memory callData = abi.encodeCall(StaticTarget.readValue, ());
        Action memory action = _buildStaticAction(
            L2_ROLLUP_ID,
            address(target),
            callData,
            alice,
            MAINNET_ROLLUP_ID
        );
        bytes32 actionHash = keccak256(abi.encode(action));

        RollupStateRoot[] memory roots = new RollupStateRoot[](2);
        roots[0] = RollupStateRoot({rollupId: L2_ROLLUP_ID, stateRoot: L2_INITIAL_STATE});
        roots[1] = RollupStateRoot({rollupId: OTHER_ROLLUP_ID, stateRoot: OTHER_INITIAL_STATE});

        _singleStaticBatch(_makeStaticCall(actionHash, abi.encode(uint256(42)), false, roots));

        vm.prank(alice);
        (bool ok, bytes memory ret) = proxy.staticcall(callData);
        assertTrue(ok, "staticcall failed");
        assertEq(abi.decode(ret, (uint256)), 42);
    }

    /// @notice Test 6: L1 — empty stateRoots array, no pinning required → success.
    function test_StaticLookup_EmptyStateRoots_L1() public {
        address proxy = _registerProxyL1(address(target), L2_ROLLUP_ID);

        bytes memory callData = abi.encodeCall(StaticTarget.readValue, ());
        Action memory action = _buildStaticAction(
            L2_ROLLUP_ID,
            address(target),
            callData,
            alice,
            MAINNET_ROLLUP_ID
        );
        bytes32 actionHash = keccak256(abi.encode(action));

        _singleStaticBatch(
            _makeStaticCall(actionHash, abi.encode(uint256(1337)), false, new RollupStateRoot[](0))
        );

        vm.prank(alice);
        (bool ok, bytes memory ret) = proxy.staticcall(callData);
        assertTrue(ok, "staticcall failed");
        assertEq(abi.decode(ret, (uint256)), 1337);
    }

    /// @notice Test 7: nested on-chain CALL whose `nextAction` is a static CALL that
    ///         `_processCallAtScope` must run via STATICCALL through the source proxy.
    ///
    ///         Design choice: the nested CALL's `destination` is the source proxy itself (the
    ///         *static* call target). Because `_processCallAtScope` routes via
    ///         `sourceProxy.executeOnBehalf(action.destination, action.data)`, and we want to
    ///         avoid a nested staticCallLookup (which would need its own StaticCall entry),
    ///         we pick `action.destination = address(target)` directly. The source proxy's
    ///         `executeOnBehalf` admin path (msg.sender == MANAGER) forwards with `.call`,
    ///         but because the outer `_processCallAtScope` used STATICCALL, the EVM will make
    ///         the whole sub-tree static — which is fine for `readValue()` (view).
    ///         No nested lookup is needed.
    function test_StaticLookup_NestedOnChainCall() public {
        // Register a proxy for the target under L2_ROLLUP_ID — destination of outer CALL
        address outerProxy = _registerProxyL1(address(target), L2_ROLLUP_ID);

        // We also pre-register the source proxy for `alice` under MAINNET_ROLLUP_ID
        // so `_processCallAtScope` doesn't have to create it.
        address sourceProxy = rollups.computeCrossChainProxyAddress(alice, MAINNET_ROLLUP_ID);
        _registerProxyL1(alice, MAINNET_ROLLUP_ID);

        // --- Outer CALL action (normal, not static). Triggered by alice via outerProxy. ---
        bytes memory outerCallData = abi.encodeCall(StaticTarget.readValue, ());
        Action memory outerAction = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: address(target),
            value: 0,
            data: outerCallData,
            failed: false,
            isStatic: false,
            sourceAddress: alice,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });
        bytes32 outerHash = keccak256(abi.encode(outerAction));

        // --- Nested static CALL (the nextAction of the outer entry). ---
        // It lives at scope [0]. Its `sourceAddress` is bob / MAINNET so that the source proxy
        // used for the staticcall is different and already-registered.
        // To simplify accounting, we keep it inside the same rollup.
        bytes memory nestedCallData = abi.encodeCall(StaticTarget.readValue, ());
        _registerProxyL1(bob, MAINNET_ROLLUP_ID);
        uint256[] memory nestedScope = new uint256[](1);
        nestedScope[0] = 0;
        Action memory nestedStaticAction = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: address(target),
            value: 0,
            data: nestedCallData,
            failed: false,
            isStatic: true,
            sourceAddress: bob,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: nestedScope
        });
        // nestedHash is not used directly — the outer entry's nextAction embeds nestedStaticAction
        // and the execution lookup after the nested staticcall is keyed on nestedResultHash.

        // The RESULT action (of the nested static call) — its data is the return value from
        // the staticcall, which (via proxy fallback -> staticCallLookup) will be our
        // pre-computed return bytes. We pin that to `abi.encode(uint256(42))`.
        bytes memory staticReturn = abi.encode(uint256(42));
        Action memory nestedResult = Action({
            actionType: ActionType.RESULT,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: staticReturn,
            failed: false,
            isStatic: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
        bytes32 nestedResultHash = keccak256(abi.encode(nestedResult));

        // And a final RESULT for the *outer* call at scope [] — returned to the caller.
        Action memory outerResult = Action({
            actionType: ActionType.RESULT,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(42)),
            failed: false,
            isStatic: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        // --- Build execution entries. ---
        // Entry 1: outerHash -> nestedStaticAction (scope [0])
        // Entry 2: nestedResultHash -> outerResult  (RESULT at root)
        StateDelta[] memory emptyDeltas = new StateDelta[](0);
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0].stateDeltas = emptyDeltas;
        entries[0].actionHash = outerHash;
        entries[0].nextAction = nestedStaticAction;
        entries[1].stateDeltas = emptyDeltas;
        entries[1].actionHash = nestedResultHash;
        entries[1].nextAction = outerResult;

        // --- Build StaticCall entry for the nested static call. ---
        // The nested staticcall goes through `bob`'s proxy -> tstore detect -> staticCallLookup.
        // The manager reconstructs the action using: sourceAddress = bob (msg.sender of lookup
        // arrives as... wait). Actually: _processCallAtScope calls
        // `sourceProxy.staticcall(encodeCall(executeOnBehalf, (dest, data)))`.
        // Inside the proxy, `executeOnBehalf` is entered with msg.sender = Rollups (MANAGER),
        // which takes the admin branch and does `destination.call{value:0}(data)`. Because the
        // outer context is STATICCALL, the admin branch actually runs the target.readValue()
        // as a staticcall from the proxy. This executes the view directly — NO staticCallLookup
        // is invoked. So we don't need a StaticCall entry for this nested call.
        StaticCall[] memory noStatic = new StaticCall[](0);

        _postStaticBatchWithEntries(entries, noStatic);

        // Trigger: alice calls the outer proxy.
        vm.prank(alice);
        (bool ok, bytes memory ret) = outerProxy.call(outerCallData);
        assertTrue(ok, "outer call failed");
        // The proxy strips the outer bytes wrapper before returning.
        assertEq(abi.decode(ret, (uint256)), 42, "unexpected outer result");

        // Ensure rollup ether balance is unchanged (no ETH moved, no EtherDeltaMismatch).
        (,, , uint256 etherBal) = rollups.rollups(L2_ROLLUP_ID);
        assertEq(etherBal, 0, "unexpected ether balance");
        // Silence unused warnings
        sourceProxy;
    }

    /// @notice Test 8: direct call to `staticCallLookup` from a non-proxy EOA — `UnauthorizedProxy`.
    function test_StaticLookup_Revert_Unauthorized() public {
        // Ensure we are in the current block
        _postStaticBatch(new StaticCall[](0));

        vm.prank(alice);
        vm.expectRevert(Rollups.UnauthorizedProxy.selector);
        rollups.staticCallLookup(alice, "");
    }

    /// @notice Test 9: after block advances, proxy staticcall surfaces `ExecutionNotInCurrentBlock`.
    function test_StaticLookup_Revert_NotInCurrentBlock() public {
        address proxy = _registerProxyL1(address(target), L2_ROLLUP_ID);

        bytes memory callData = abi.encodeCall(StaticTarget.readValue, ());
        Action memory action = _buildStaticAction(
            L2_ROLLUP_ID,
            address(target),
            callData,
            alice,
            MAINNET_ROLLUP_ID
        );
        bytes32 actionHash = keccak256(abi.encode(action));

        _singleStaticBatch(
            _makeStaticCall(actionHash, abi.encode(uint256(42)), false, new RollupStateRoot[](0))
        );

        // Advance to next block — lastStateUpdateBlock != block.number
        vm.roll(block.number + 1);

        vm.prank(alice);
        (bool ok, bytes memory ret) = proxy.staticcall(callData);
        assertFalse(ok, "expected revert");
        assertEq(bytes4(ret), Rollups.ExecutionNotInCurrentBlock.selector, "wrong selector");
    }

    /// @notice Test 10: L2 happy path — load table, staticcall proxy, decode return.
    function test_StaticLookup_HappyPath_L2() public {
        CrossChainManagerL2 l2 = new CrossChainManagerL2(L2_ROLLUP_ID, SYSTEM_ADDRESS);
        address proxy = _registerProxyL2(l2, address(target), MAINNET_ROLLUP_ID);

        bytes memory callData = abi.encodeCall(StaticTarget.readValue, ());
        // On L2, the manager uses `sourceRollup = ROLLUP_ID`
        Action memory action = _buildStaticAction(
            MAINNET_ROLLUP_ID,
            address(target),
            callData,
            alice,
            L2_ROLLUP_ID
        );
        bytes32 actionHash = keccak256(abi.encode(action));

        StaticCall[] memory scs = new StaticCall[](1);
        scs[0] = _makeStaticCall(actionHash, abi.encode(uint256(99)), false, new RollupStateRoot[](0));
        _loadL2Static(l2, scs);

        vm.prank(alice);
        (bool ok, bytes memory ret) = proxy.staticcall(callData);
        assertTrue(ok, "staticcall failed");
        assertEq(abi.decode(ret, (uint256)), 99);
    }

    // ──────────────────────────────────────────────
    //  Flatten / sub-call tests (§7 of the plan)
    // ──────────────────────────────────────────────

    /// @notice Test: flattened sub-call happy path on L1.
    ///
    /// The outer static lookup is routed to a StaticCall entry carrying one `StaticSubCall`.
    /// During `staticCallLookup`, the manager replays the sub-call via the inner source proxy's
    /// `executeOnBehalf` through a STATICCALL. Inside `executeOnBehalf`, msg.sender == MANAGER
    /// which takes the admin branch and returns the raw destination-call returndata (NOT ABI-
    /// wrapped in bytes — it uses assembly `return(add(result, 0x20), mload(result))`).
    ///
    /// For `StaticTarget.readValue()` returning `uint256(7)`, the raw inner returndata is
    /// `abi.encode(uint256(7))` (32 bytes). The rolling hash is therefore
    /// `keccak256(abi.encodePacked(bytes32(0), true, abi.encode(uint256(7))))`.
    ///
    /// Intra-rollup state changes (e.g. mutating the inner target) are implicitly covered on L1
    /// by the pinned `stateRoots`; for this test we pin the L2 rollup's current state root so
    /// the entry is valid. The outer entry's `returnData` can be anything the prover committed
    /// — we set it to `abi.encode(uint256(100))` to distinguish it from the inner value.
    function test_StaticFlatten_HappyPath() public {
        // Deploy a second StaticTarget on L2_ROLLUP_ID with value=7 (the "inner" target)
        StaticTarget inner = new StaticTarget(7);

        // Outer proxy: the caller will staticcall this
        address outerProxy = _registerProxyL1(address(target), L2_ROLLUP_ID);

        // Inner source proxy: alice on L2_ROLLUP_ID (must be deployed or _processNStaticCalls reverts)
        address innerSourceProxy = rollups.computeCrossChainProxyAddress(alice, L2_ROLLUP_ID);
        _registerProxyL1(alice, L2_ROLLUP_ID);

        // Build outer action
        bytes memory callData = abi.encodeCall(StaticTarget.readValue, ());
        Action memory action = _buildStaticAction(
            L2_ROLLUP_ID,
            address(target),
            callData,
            alice,
            MAINNET_ROLLUP_ID
        );
        bytes32 actionHash = keccak256(abi.encode(action));

        // Build sub-call list: one STATICCALL against `inner` via alice@L2 source proxy
        StaticSubCall[] memory subs = new StaticSubCall[](1);
        subs[0] = StaticSubCall({
            destination: address(inner),
            data: abi.encodeCall(StaticTarget.readValue, ()),
            sourceAddress: alice,
            sourceRollup: L2_ROLLUP_ID
        });

        // Compute expected rolling hash: fold(bytes32(0), success=true, ret=abi.encode(uint256(7)))
        bytes memory expectedInnerRet = abi.encode(uint256(7));
        bytes32 expectedRollingHash = keccak256(
            abi.encodePacked(bytes32(0), true, expectedInnerRet)
        );

        // Outer returnData is what staticCallLookup returns to the caller
        bytes memory outerReturn = abi.encode(uint256(100));

        StaticCall[] memory scs = new StaticCall[](1);
        scs[0] = StaticCall({
            actionHash: actionHash,
            returnData: outerReturn,
            failed: false,
            calls: subs,
            rollingHash: expectedRollingHash,
            stateRoots: new RollupStateRoot[](0)
        });
        _postStaticBatch(scs);

        vm.prank(alice);
        (bool ok, bytes memory ret) = outerProxy.staticcall(callData);
        assertTrue(ok, "outer static lookup failed");
        assertEq(abi.decode(ret, (uint256)), 100, "unexpected outer returnData");
        innerSourceProxy; // silence unused warning
    }

    /// @notice Test: committing the wrong rolling hash bubbles `RollingHashMismatch()` selector.
    function test_StaticFlatten_RollingHashMismatch() public {
        StaticTarget inner = new StaticTarget(7);
        address outerProxy = _registerProxyL1(address(target), L2_ROLLUP_ID);
        _registerProxyL1(alice, L2_ROLLUP_ID);

        bytes memory callData = abi.encodeCall(StaticTarget.readValue, ());
        Action memory action = _buildStaticAction(
            L2_ROLLUP_ID,
            address(target),
            callData,
            alice,
            MAINNET_ROLLUP_ID
        );
        bytes32 actionHash = keccak256(abi.encode(action));

        StaticSubCall[] memory subs = new StaticSubCall[](1);
        subs[0] = StaticSubCall({
            destination: address(inner),
            data: abi.encodeCall(StaticTarget.readValue, ()),
            sourceAddress: alice,
            sourceRollup: L2_ROLLUP_ID
        });

        // Intentionally wrong
        bytes32 wrongRollingHash = keccak256("definitely-not-the-right-hash");

        StaticCall[] memory scs = new StaticCall[](1);
        scs[0] = StaticCall({
            actionHash: actionHash,
            returnData: abi.encode(uint256(100)),
            failed: false,
            calls: subs,
            rollingHash: wrongRollingHash,
            stateRoots: new RollupStateRoot[](0)
        });
        _postStaticBatch(scs);

        vm.prank(alice);
        (bool ok, bytes memory ret) = outerProxy.staticcall(callData);
        assertFalse(ok, "expected revert");
        assertEq(ret.length, 4, "expected 4-byte selector");
        assertEq(bytes4(ret), ICrossChainManager.RollingHashMismatch.selector, "wrong selector");
    }

    /// @notice Test: sub-call's source proxy is not deployed → `ProxyNotDeployed()`.
    function test_StaticFlatten_ProxyNotDeployed() public {
        StaticTarget inner = new StaticTarget(7);
        address outerProxy = _registerProxyL1(address(target), L2_ROLLUP_ID);

        bytes memory callData = abi.encodeCall(StaticTarget.readValue, ());
        Action memory action = _buildStaticAction(
            L2_ROLLUP_ID,
            address(target),
            callData,
            alice,
            MAINNET_ROLLUP_ID
        );
        bytes32 actionHash = keccak256(abi.encode(action));

        // Sub-call points to (bob, OTHER_ROLLUP_ID) — no proxy registered for this pair
        StaticSubCall[] memory subs = new StaticSubCall[](1);
        subs[0] = StaticSubCall({
            destination: address(inner),
            data: abi.encodeCall(StaticTarget.readValue, ()),
            sourceAddress: bob,
            sourceRollup: OTHER_ROLLUP_ID
        });

        StaticCall[] memory scs = new StaticCall[](1);
        scs[0] = StaticCall({
            actionHash: actionHash,
            returnData: abi.encode(uint256(100)),
            failed: false,
            calls: subs,
            rollingHash: bytes32(0), // irrelevant — reverts before hash check
            stateRoots: new RollupStateRoot[](0)
        });
        _postStaticBatch(scs);

        vm.prank(alice);
        (bool ok, bytes memory ret) = outerProxy.staticcall(callData);
        assertFalse(ok, "expected revert");
        assertEq(ret.length, 4, "expected 4-byte selector");
        assertEq(bytes4(ret), ICrossChainManager.ProxyNotDeployed.selector, "wrong selector");
    }

    /// @notice Test: two StaticCall entries sharing actionHash on L2 → `DuplicateStaticCallActionHash`.
    function test_Static_L2_DuplicateActionHash() public {
        CrossChainManagerL2 l2 = new CrossChainManagerL2(L2_ROLLUP_ID, SYSTEM_ADDRESS);

        // Any valid action hash — duplicate check fires before action replay
        bytes32 someHash = keccak256("dup");

        StaticCall[] memory scs = new StaticCall[](2);
        scs[0] = _makeStaticCall(someHash, abi.encode(uint256(1)), false, new RollupStateRoot[](0));
        scs[1] = _makeStaticCall(someHash, abi.encode(uint256(2)), false, new RollupStateRoot[](0));

        ExecutionEntry[] memory noEntries = new ExecutionEntry[](0);
        vm.prank(SYSTEM_ADDRESS);
        vm.expectRevert(ICrossChainManager.DuplicateStaticCallActionHash.selector);
        l2.loadExecutionTable(noEntries, scs);
    }

    /// @notice Test 11 (bonus per task addendum): L2 — stateRoots populated → `StaticCallStateRootsNotSupported`.
    function test_StaticLookup_L2_StateRootsNotSupported() public {
        CrossChainManagerL2 l2 = new CrossChainManagerL2(L2_ROLLUP_ID, SYSTEM_ADDRESS);
        address proxy = _registerProxyL2(l2, address(target), MAINNET_ROLLUP_ID);

        bytes memory callData = abi.encodeCall(StaticTarget.readValue, ());
        Action memory action = _buildStaticAction(
            MAINNET_ROLLUP_ID,
            address(target),
            callData,
            alice,
            L2_ROLLUP_ID
        );
        bytes32 actionHash = keccak256(abi.encode(action));

        RollupStateRoot[] memory roots = new RollupStateRoot[](1);
        roots[0] = RollupStateRoot({rollupId: 0, stateRoot: bytes32(uint256(1))});

        StaticCall[] memory scs = new StaticCall[](1);
        scs[0] = _makeStaticCall(actionHash, abi.encode(uint256(1)), false, roots);
        _loadL2Static(l2, scs);

        vm.prank(alice);
        (bool ok, bytes memory ret) = proxy.staticcall(callData);
        assertFalse(ok, "expected revert");
        assertEq(bytes4(ret), ICrossChainManager.StaticCallStateRootsNotSupported.selector, "wrong selector");
    }
}
