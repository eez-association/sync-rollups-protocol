// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Test.sol";
import {Rollups, RollupConfig} from "../src/Rollups.sol";
import {CrossChainManagerL2} from "../src/CrossChainManagerL2.sol";
import {CrossChainProxy} from "../src/CrossChainProxy.sol";
import {Action, ActionType, ExecutionEntry, StateDelta, ProxyInfo} from "../src/ICrossChainManager.sol";
import {Bridge} from "../src/periphery/Bridge.sol";
import {WrappedToken} from "../src/periphery/WrappedToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {RLPTxEncoder} from "./helpers/RLPTxEncoder.sol";
import {MockZKVerifier, IntegrationTestBase} from "./helpers/TestBase.sol";

contract TestToken is ERC20 {
    constructor() ERC20("Test Token", "TT") {
        _mint(msg.sender, 10000e18);
    }
}

/// @title IntegrationTestBridge
/// @notice End-to-end tests of L1 <-> L2 bridging flows for ETH and ERC20 tokens
///
/// ┌──────────────────────────────────────────────────────────────────────────┐
/// │  Legend                                                                  │
/// │    bridgeL1 = Bridge on L1 (manager = rollups)                          │
/// │    bridgeL2 = Bridge on L2 (manager = managerL2)                        │
/// │    Both share the same canonical bridge identity via                     │
/// │    bridgeL2.setCanonicalBridgeAddress(address(bridgeL1))                │
/// └──────────────────────────────────────────────────────────────────────────┘
///
/// ┌────┬───────────────────────────────────────┬──────────┬──────────────────┐
/// │  # │ Flow                                  │ Direction│ Asset            │
/// ├────┼───────────────────────────────────────┼──────────┼──────────────────┤
/// │  1 │ Alice bridges 1 ETH to herself        │ L1 → L2  │ Ether            │
/// │  2 │ Alice bridges 100 tokens to herself   │ L1 → L2  │ ERC20            │
/// │  3 │ Alice bridges tokens then back again  │ L1→L2→L1 │ ERC20 roundtrip  │
/// └────┴───────────────────────────────────────┴──────────┴──────────────────┘
contract IntegrationTestBridge is IntegrationTestBase {
    // ── L2 contracts ──
    CrossChainManagerL2 public managerL2;

    // ── Bridge contracts ──
    Bridge public bridgeL1;
    Bridge public bridgeL2;

    // ── Test token ──
    TestToken public token;

    address public alice = makeAddr("alice");

    function setUp() public {
        // ── L1 infrastructure ──
        verifier = new MockZKVerifier();
        rollups = new Rollups(1);
        _registerDefaultProofSystem();
        rollups.createRollup(keccak256("l2-initial-state"), address(verifier), DEFAULT_VK, address(this));

        // ── L2 infrastructure ──
        managerL2 = new CrossChainManagerL2(L2_ROLLUP_ID, SYSTEM_ADDRESS);

        // ── Bridge deployment ──
        bridgeL1 = new Bridge();
        bridgeL2 = new Bridge();
        bridgeL1.initialize(address(rollups), MAINNET_ROLLUP_ID, address(this));
        bridgeL2.initialize(address(managerL2), L2_ROLLUP_ID, address(this));
        bridgeL2.setCanonicalBridgeAddress(address(bridgeL1));

        // ── Token setup ──
        token = new TestToken();
        token.transfer(alice, 1000e18);

        // ── Fund alice ──
        vm.deal(alice, 10 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Test 1: Alice bridges 1 ETH from L1 to L2
    //
    //  Call chain (L1):
    //    Alice calls bridgeL1.bridgeEther{value: 1 ether}(L2_ROLLUP_ID)
    //    → Bridge creates proxy for (alice, L2_ROLLUP_ID) via rollups
    //    → proxy.call{value: 1 ether}("") → proxy fallback
    //    → Rollups.executeCrossChainCall(bridgeL1, "") with 1 ether
    //    → CALL{L2, alice, 1 ether, "", bridgeL1, MAINNET} matched → RESULT
    //
    //  Meanwhile on L2:
    //    SYSTEM calls executeIncomingCrossChainCall{value: 1 ether}(alice, ...)
    //    → proxy for (bridgeL1, MAINNET) sends 1 ether to alice
    // ═══════════════════════════════════════════════════════════════════════

    function test_BridgeEther_L1toL2() public {
        // RESULT: alice is EOA, empty return data (shared by both phases)
        Action memory resultAction = Action({
            actionType: ActionType.RESULT,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        // ════════════════════════════════════════════
        //  Phase 1: L1 — Alice bridges 1 ether via bridgeL1
        // ════════════════════════════════════════════
        //
        //  postBatch loads a deferred entry on L1. When Alice calls bridgeEther:
        //    1. Bridge creates proxy for (alice, L2_ROLLUP_ID) via rollups
        //    2. proxy.call{value: 1 ether}("") → proxy fallback
        //    3. Rollups.executeCrossChainCall(bridgeL1, "") with 1 ether
        //    4. Builds CALL{rollupId=L2, dest=alice, value=1 ether, source=bridgeL1, sourceRollup=MAINNET}
        //    5. _findAndApplyExecution matches entry → applies L2 state delta (+1 ether) → returns RESULT

        // The CALL action that executeCrossChainCall will build
        // dest=alice (proxy's originalAddress), source=bridgeL1 (msg.sender to proxy)
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: alice,
            value: 1 ether,
            data: "",
            failed: false,
            sourceAddress: address(bridgeL1),
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        bytes32 currentState = keccak256("l2-initial-state");
        bytes32 newState = keccak256("l2-state-after-ether-bridge");

        // L1 deferred entry: CALL hash → RESULT, with L2 state transition (+1 ether)
        {
            StateDelta[] memory stateDeltas = new StateDelta[](1);
            stateDeltas[0] = StateDelta({
                rollupId: L2_ROLLUP_ID,
                currentState: currentState,
                newState: newState,
                etherDelta: 1 ether
            });

            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0].stateDeltas = stateDeltas;
            entries[0].actionHash = keccak256(abi.encode(callAction));
            entries[0].nextAction = resultAction;

            rollups.postBatch(address(verifier), entries, 0, "", "proof");
        }

        // Alice triggers the bridge
        uint256 aliceL1BalanceBefore = alice.balance;
        vm.prank(alice);
        bridgeL1.bridgeEther{value: 1 ether}(L2_ROLLUP_ID, alice);

        assertEq(alice.balance, aliceL1BalanceBefore - 1 ether, "Alice L1 balance should decrease by 1 ether");
        assertEq(_getRollupState(L2_ROLLUP_ID), newState, "L2 rollup state should be updated");

        // ════════════════════════════════════════════
        //  Phase 2: L2 — SYSTEM delivers 1 ether to alice
        // ════════════════════════════════════════════
        //
        //  SYSTEM pre-loads execution table with the expected RESULT,
        //  then calls executeIncomingCrossChainCall which:
        //    1. Builds CALL{rollupId=L2, dest=alice, value=1 ether, source=bridgeL1, sourceRollup=MAINNET}
        //    2. newScope → _processCallAtScope → auto-creates proxy for (bridgeL1, MAINNET) on L2
        //    3. proxy.executeOnBehalf(alice, "") with 1 ether → alice receives 1 ether
        //    4. Builds RESULT{data=""} → hash matches table entry → consumed

        // L2 execution table: RESULT hash → RESULT (terminal, self-referencing)
        {
            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0].stateDeltas = new StateDelta[](0);
            entries[0].actionHash = keccak256(abi.encode(resultAction));
            entries[0].nextAction = resultAction;

            vm.prank(SYSTEM_ADDRESS);
            managerL2.loadExecutionTable(entries);
        }

        // Fund SYSTEM with 1 ether for the delivery
        vm.deal(SYSTEM_ADDRESS, 1 ether);

        uint256 aliceBalanceBefore = alice.balance;

        // SYSTEM delivers 1 ether to alice via proxy for (bridgeL1, MAINNET)
        vm.prank(SYSTEM_ADDRESS);
        managerL2.executeIncomingCrossChainCall{value: 1 ether}(
            alice,                    // dest = alice
            1 ether,                  // value
            "",                       // data (empty — ether transfer to EOA)
            address(bridgeL1),        // source = bridgeL1
            MAINNET_ROLLUP_ID,        // sourceRollup = MAINNET
            new uint256[](0)          // scope = [] (root)
        );

        assertEq(alice.balance, aliceBalanceBefore + 1 ether, "Alice should receive 1 ether on L2");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Test 2: Alice bridges 100 tokens from L1 to L2
    //
    //  Call chain (L1):
    //    Alice calls bridgeL1.bridgeTokens(token, 100e18, L2_ROLLUP_ID)
    //    → Bridge locks tokens (safeTransferFrom alice → bridgeL1)
    //    → Bridge creates proxy for (bridgeL1, L2_ROLLUP_ID) via rollups
    //    → proxy.call(receiveTokens calldata) → proxy fallback
    //    → Rollups.executeCrossChainCall(bridgeL1, receiveTokensCalldata)
    //    → CALL{L2, bridgeL1, 0, calldata, bridgeL1, MAINNET} matched → RESULT
    //
    //  Meanwhile on L2:
    //    SYSTEM calls executeIncomingCrossChainCall(bridgeL2, 0, calldata, bridgeL1, MAINNET, [])
    //    → proxy for (bridgeL1, MAINNET) calls bridgeL2.receiveTokens(...)
    //    → onlyBridgeProxy check passes (proxy identity matches canonical bridge)
    //    → Foreign token → deploys WrappedToken, mints 100e18 to alice
    // ═══════════════════════════════════════════════════════════════════════

    function test_BridgeTokens_L1toL2() public {
        // receiveTokens calldata: same encoding on both L1 and L2
        bytes memory receiveTokensCalldata = abi.encodeCall(
            Bridge.receiveTokens,
            (address(token), MAINNET_ROLLUP_ID, alice, 100e18, "Test Token", "TT", 18, MAINNET_ROLLUP_ID)
        );

        // RESULT: receiveTokens returns void → empty return data (shared by both phases)
        Action memory resultAction = Action({
            actionType: ActionType.RESULT,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        // ════════════════════════════════════════════
        //  Phase 1: L1 — Alice bridges tokens via bridgeL1
        // ════════════════════════════════════════════
        //
        //  postBatch loads a deferred entry on L1. When Alice calls bridgeTokens:
        //    1. Bridge locks 100e18 tokens (safeTransferFrom alice → bridgeL1)
        //    2. Bridge creates proxy for (_bridgeAddress()=bridgeL1, L2_ROLLUP_ID) via rollups
        //    3. proxy.call(receiveTokensCalldata) → proxy fallback
        //    4. Rollups.executeCrossChainCall(bridgeL1, receiveTokensCalldata)
        //    5. Builds CALL{rollupId=L2, dest=bridgeL1, data=calldata, source=bridgeL1, sourceRollup=MAINNET}
        //    6. _findAndApplyExecution matches entry → applies L2 state delta → returns RESULT

        // The CALL action that executeCrossChainCall will build
        // dest=bridgeL1 (proxy's originalAddress = _bridgeAddress()), source=bridgeL1 (bridge calls proxy)
        Action memory callAction = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: address(bridgeL1),
            value: 0,
            data: receiveTokensCalldata,
            failed: false,
            sourceAddress: address(bridgeL1),
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        bytes32 currentState = keccak256("l2-initial-state");
        bytes32 newState = keccak256("l2-state-after-token-bridge");

        // L1 deferred entry: CALL hash → RESULT, with L2 state transition (no ether)
        {
            StateDelta[] memory stateDeltas = new StateDelta[](1);
            stateDeltas[0] = StateDelta({
                rollupId: L2_ROLLUP_ID,
                currentState: currentState,
                newState: newState,
                etherDelta: 0
            });

            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0].stateDeltas = stateDeltas;
            entries[0].actionHash = keccak256(abi.encode(callAction));
            entries[0].nextAction = resultAction;

            rollups.postBatch(address(verifier), entries, 0, "", "proof");
        }

        // Alice approves and bridges tokens
        vm.prank(alice);
        token.approve(address(bridgeL1), 100e18);

        vm.prank(alice);
        bridgeL1.bridgeTokens(address(token), 100e18, L2_ROLLUP_ID, alice);

        assertEq(token.balanceOf(address(bridgeL1)), 100e18, "Bridge should hold 100e18 locked tokens");
        assertEq(token.balanceOf(alice), 900e18, "Alice should have 900e18 tokens remaining");
        assertEq(_getRollupState(L2_ROLLUP_ID), newState, "L2 rollup state should be updated");

        // ════════════════════════════════════════════
        //  Phase 2: L2 — SYSTEM delivers receiveTokens to bridgeL2
        // ════════════════════════════════════════════
        //
        //  SYSTEM pre-loads execution table with the expected RESULT,
        //  then calls executeIncomingCrossChainCall which:
        //    1. Builds CALL{rollupId=L2, dest=bridgeL2, source=bridgeL1, sourceRollup=MAINNET}
        //    2. newScope → _processCallAtScope → auto-creates proxy for (bridgeL1, MAINNET) on L2
        //    3. proxy.executeOnBehalf(bridgeL2, receiveTokensCalldata)
        //       → bridgeL2.receiveTokens(...) → onlyBridgeProxy(MAINNET) passes
        //       → originalRollupId(MAINNET) ≠ rollupId(L2) → foreign token
        //       → deploys WrappedToken, mints 100e18 to alice
        //    4. Builds RESULT{data=""} (void return) → hash matches → consumed

        // L2 execution table: RESULT hash → RESULT (terminal, self-referencing)
        {
            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0].stateDeltas = new StateDelta[](0);
            entries[0].actionHash = keccak256(abi.encode(resultAction));
            entries[0].nextAction = resultAction;

            vm.prank(SYSTEM_ADDRESS);
            managerL2.loadExecutionTable(entries);
        }

        // SYSTEM delivers receiveTokens to bridgeL2
        vm.prank(SYSTEM_ADDRESS);
        managerL2.executeIncomingCrossChainCall(
            address(bridgeL2),        // dest = bridgeL2
            0,                        // value = 0 (token bridge, no ether)
            receiveTokensCalldata,    // data = receiveTokens(...)
            address(bridgeL1),        // source = bridgeL1
            MAINNET_ROLLUP_ID,        // sourceRollup = MAINNET
            new uint256[](0)          // scope = [] (root)
        );

        // Assert wrapped token was deployed and minted
        address wrappedAddr = bridgeL2.getWrappedToken(address(token), MAINNET_ROLLUP_ID);
        assertTrue(wrappedAddr != address(0), "Wrapped token should be deployed on L2");
        assertEq(WrappedToken(wrappedAddr).balanceOf(alice), 100e18, "Alice should have 100e18 wrapped tokens");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Test 3: Alice bridges 100 tokens L1→L2, then bridges them back L2→L1
    //
    //  Round-trip: lock on L1 → mint wrapped on L2 → burn wrapped on L2 → release on L1
    //
    //  In test (single EVM), bridgeL1 and bridgeL2 have different addresses.
    //  For the return trip to pass onlyBridgeProxy checks in both directions,
    //  we set canonicalBridgeAddress on BOTH bridges (cross-referencing each other).
    //  In production (CREATE2), both would share the same address.
    //
    //  Forward:  bridgeL1._bridgeAddress() = bridgeL2  →  proxy for (bridgeL2, L2) on L1
    //  Return:   bridgeL2._bridgeAddress() = bridgeL1  →  proxy for (bridgeL1, MAINNET) on L2
    //  onlyBridgeProxy on L1 expects proxy for (bridgeL2, L2) — matches source proxy  ✓
    //  onlyBridgeProxy on L2 expects proxy for (bridgeL1, MAINNET) — matches source proxy  ✓
    // ═══════════════════════════════════════════════════════════════════════

    function test_BridgeTokens_Roundtrip() public {
        // Cross-reference canonical addresses so onlyBridgeProxy works in both directions
        bridgeL1.setCanonicalBridgeAddress(address(bridgeL2));
        // bridgeL2 already has bridgeL1 set as canonical from setUp

        // ════════════════════════════════════════════
        //  Phase 1: L1 — Lock tokens
        // ════════════════════════════════════════════
        //
        //  With bridgeL1._bridgeAddress() = bridgeL2:
        //    Bridge creates proxy for (bridgeL2, L2_ROLLUP_ID) via rollups
        //    proxy.call(receiveTokensCalldata) → executeCrossChainCall
        //    CALL{L2, bridgeL2, 0, calldata, bridgeL1, MAINNET} matched → RESULT

        // Forward calldata: bridgeL1 sends to bridgeL2 on L2
        bytes memory fwdCalldata = abi.encodeCall(
            Bridge.receiveTokens,
            (address(token), MAINNET_ROLLUP_ID, alice, 100e18, "Test Token", "TT", 18, MAINNET_ROLLUP_ID)
        );

        // Forward CALL: proxy for (bridgeL2, L2) on L1 → dest=bridgeL2, source=bridgeL1
        Action memory fwdCall = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: address(bridgeL2),
            value: 0,
            data: fwdCalldata,
            failed: false,
            sourceAddress: address(bridgeL1),
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        Action memory fwdResult = Action({
            actionType: ActionType.RESULT,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-after-roundtrip-fwd");

        {
            StateDelta[] memory stateDeltas = new StateDelta[](1);
            stateDeltas[0] = StateDelta({ rollupId: L2_ROLLUP_ID, currentState: s0, newState: s1, etherDelta: 0 });

            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0].stateDeltas = stateDeltas;
            entries[0].actionHash = keccak256(abi.encode(fwdCall));
            entries[0].nextAction = fwdResult;

            rollups.postBatch(address(verifier), entries, 0, "", "proof");
        }

        vm.prank(alice);
        token.approve(address(bridgeL1), 100e18);

        vm.prank(alice);
        bridgeL1.bridgeTokens(address(token), 100e18, L2_ROLLUP_ID, alice);

        assertEq(token.balanceOf(address(bridgeL1)), 100e18, "Phase 1: bridgeL1 should hold locked tokens");
        assertEq(token.balanceOf(alice), 900e18, "Phase 1: alice should have 900e18 tokens");
        assertEq(_getRollupState(L2_ROLLUP_ID), s1, "Phase 1: L2 state should be S1");

        // ════════════════════════════════════════════
        //  L2 execution table: load ALL entries for Phase 2 + Phase 3 in one call
        // ════════════════════════════════════════════
        //
        //  In production the system loads the full execution table once per block.
        //  Phase 2 needs: fwdResult hash → fwdResult (terminal)
        //  Phase 3 needs: retCall hash → retResult (terminal)

        // Return calldata: bridgeL2 sends back to bridgeL1 on L1
        // originalToken = token, originalRollupId = MAINNET (traced from wrappedTokenInfo)
        // sourceRollupId (last param) = bridgeL2.rollupId = L2_ROLLUP_ID
        bytes memory retCalldata = abi.encodeCall(
            Bridge.receiveTokens,
            (address(token), MAINNET_ROLLUP_ID, alice, 100e18, "Test Token", "TT", 18, L2_ROLLUP_ID)
        );

        // Return CALL: proxy for (bridgeL1, MAINNET) on L2 → dest=bridgeL1, source=bridgeL2
        Action memory retCall = Action({
            actionType: ActionType.CALL,
            rollupId: MAINNET_ROLLUP_ID,
            destination: address(bridgeL1),
            value: 0,
            data: retCalldata,
            failed: false,
            sourceAddress: address(bridgeL2),
            sourceRollup: L2_ROLLUP_ID,
            scope: new uint256[](0)
        });

        Action memory retResult = Action({
            actionType: ActionType.RESULT,
            rollupId: MAINNET_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        {
            ExecutionEntry[] memory entries = new ExecutionEntry[](2);
            // Phase 2 entry: incoming call result
            entries[0].stateDeltas = new StateDelta[](0);
            entries[0].actionHash = keccak256(abi.encode(fwdResult));
            entries[0].nextAction = fwdResult;
            // Phase 3 entry: outgoing bridge-back call
            entries[1].stateDeltas = new StateDelta[](0);
            entries[1].actionHash = keccak256(abi.encode(retCall));
            entries[1].nextAction = retResult;

            vm.prank(SYSTEM_ADDRESS);
            managerL2.loadExecutionTable(entries);
        }

        // ════════════════════════════════════════════
        //  Phase 2: L2 — Mint wrapped tokens
        // ════════════════════════════════════════════
        //
        //  SYSTEM delivers receiveTokens to bridgeL2:
        //    auto-creates proxy for (bridgeL1, MAINNET) on L2
        //    proxy.executeOnBehalf(bridgeL2, fwdCalldata) → bridgeL2.receiveTokens
        //    onlyBridgeProxy(MAINNET): proxy for (bridgeL1, MAINNET) ✓
        //    foreign token → deploys WrappedToken, mints to alice

        vm.prank(SYSTEM_ADDRESS);
        managerL2.executeIncomingCrossChainCall(
            address(bridgeL2), 0, fwdCalldata, address(bridgeL1), MAINNET_ROLLUP_ID, new uint256[](0)
        );

        address wrappedAddr = bridgeL2.getWrappedToken(address(token), MAINNET_ROLLUP_ID);
        assertTrue(wrappedAddr != address(0), "Phase 2: wrapped token should be deployed");
        assertEq(WrappedToken(wrappedAddr).balanceOf(alice), 100e18, "Phase 2: alice should have 100e18 wrapped");

        // ════════════════════════════════════════════
        //  Phase 3: L2 — Burn wrapped tokens (resolution from table)
        // ════════════════════════════════════════════
        //
        //  Alice calls bridgeL2.bridgeTokens(wrappedToken, 100e18, MAINNET_ROLLUP_ID):
        //    Burns wrapped tokens (bridge has burn authority)
        //    proxy for (bridgeL1, MAINNET) on L2 (already exists)
        //    executeCrossChainCall → CALL{MAINNET, bridgeL1, 0, retCalldata, bridgeL2, L2} matched → RESULT

        vm.prank(alice);
        bridgeL2.bridgeTokens(wrappedAddr, 100e18, MAINNET_ROLLUP_ID, alice);

        assertEq(WrappedToken(wrappedAddr).balanceOf(alice), 0, "Phase 3: alice wrapped balance should be 0");

        // ════════════════════════════════════════════
        //  Phase 4: L1 — Release tokens via executeL2TX
        // ════════════════════════════════════════════
        //
        //  executeL2TX → L2TX matched → CALL{MAINNET, bridgeL1, retCalldata, bridgeL2, L2}
        //    _processCallAtScope: proxy for (bridgeL2, L2) on L1
        //    proxy.executeOnBehalf(bridgeL1, retCalldata) → bridgeL1.receiveTokens
        //    onlyBridgeProxy(L2): expects proxy for (_bridgeAddress()=bridgeL2, L2) ✓
        //    originalRollupId(MAINNET) == rollupId(MAINNET) → native → release tokens to alice

        // Need new block for postBatch (StateAlreadyUpdatedThisBlock)
        vm.roll(block.number + 1);

        // Real signed L2 tx: Alice calls bridgeL2.bridgeTokens() on L2
        bytes memory rlpData = RLPTxEncoder.signedCallTx(
            address(bridgeL2),
            abi.encodeWithSelector(Bridge.bridgeTokens.selector, wrappedAddr, 100e18, MAINNET_ROLLUP_ID, alice),
            0, // alice's first L2 tx
            TX_SIGNER_PK
        );

        Action memory l2txAction = Action({
            actionType: ActionType.L2TX,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: rlpData,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        bytes32 s2 = keccak256("l2-state-after-roundtrip-ret1");
        bytes32 s3 = keccak256("l2-state-after-roundtrip-ret2");

        {
            StateDelta[] memory deltas1 = new StateDelta[](1);
            deltas1[0] = StateDelta({ rollupId: L2_ROLLUP_ID, currentState: s1, newState: s2, etherDelta: 0 });

            StateDelta[] memory deltas2 = new StateDelta[](1);
            deltas2[0] = StateDelta({ rollupId: L2_ROLLUP_ID, currentState: s2, newState: s3, etherDelta: 0 });

            ExecutionEntry[] memory entries = new ExecutionEntry[](2);

            // Entry 1: L2TX → CALL to bridgeL1.receiveTokens
            entries[0].stateDeltas = deltas1;
            entries[0].actionHash = keccak256(abi.encode(l2txAction));
            entries[0].nextAction = retCall;

            // Entry 2: RESULT → RESULT (terminal)
            entries[1].stateDeltas = deltas2;
            entries[1].actionHash = keccak256(abi.encode(retResult));
            entries[1].nextAction = retResult;

            rollups.postBatch(address(verifier), entries, 0, "", "proof");
        }

        rollups.executeL2TX(L2_ROLLUP_ID, rlpData);

        // ── Final assertions ──
        assertEq(token.balanceOf(alice), 1000e18, "Roundtrip: alice should have all 1000e18 tokens back");
        assertEq(token.balanceOf(address(bridgeL1)), 0, "Roundtrip: bridgeL1 should have 0 locked tokens");
        assertEq(WrappedToken(wrappedAddr).balanceOf(alice), 0, "Roundtrip: alice wrapped balance should be 0");
        assertEq(_getRollupState(L2_ROLLUP_ID), s3, "Roundtrip: L2 state should be S3");
    }
}
