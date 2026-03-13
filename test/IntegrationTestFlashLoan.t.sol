// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Rollups, RollupConfig} from "../src/Rollups.sol";
import {CrossChainManagerL2} from "../src/CrossChainManagerL2.sol";
import {CrossChainProxy} from "../src/CrossChainProxy.sol";
import {Action, ActionType, ExecutionEntry, StateDelta, ProxyInfo} from "../src/ICrossChainManager.sol";
import {IZKVerifier} from "../src/IZKVerifier.sol";
import {Bridge} from "../src/periphery/Bridge.sol";
import {WrappedToken} from "../src/periphery/WrappedToken.sol";
import {FlashLoan} from "../src/periphery/defiMock/FlashLoan.sol";
import {FlashLoanBridgeExecutor} from "../src/periphery/defiMock/FlashLoanBridgeExecutor.sol";
import {FlashLoanersNFT} from "../src/periphery/defiMock/FlashLoanersNFT.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockZKVerifier is IZKVerifier {
    function verify(bytes calldata, bytes32) external pure override returns (bool) {
        return true;
    }
}

contract TestToken is ERC20 {
    constructor() ERC20("Test Token", "TT") {
        _mint(msg.sender, 1_000_000e18);
    }
}

/// @title IntegrationTestFlashLoan
/// @notice End-to-end test: cross-chain flash loan on L1, bridge to L2, claim token-gated NFT, bridge back, repay
///
/// ┌──────────────────────────────────────────────────────────────────────────┐
/// │  Legend                                                                  │
/// │    flashLoanL1  = FlashLoan pool on L1 (holds 10k tokens)               │
/// │    executorL2   = FlashLoanBridgeExecutor on L2 (receives wrapped,      │
/// │                   claims NFT, bridges back)                             │
/// │    executor     = FlashLoanBridgeExecutor on L1 (orchestrates the flow) │
/// │    bridgeL1     = Bridge on L1 (locks/releases native tokens)           │
/// │    bridgeL2     = Bridge on L2 (mints/burns wrapped tokens)             │
/// │    flashLoanersNFT = FlashLoanersNFT on L2 (token-gated NFT claim)     │
/// └──────────────────────────────────────────────────────────────────────────┘
///
/// ┌────────────────────────────────────────────────────────────────────────────────────┐
/// │  Flow                                                                              │
/// │                                                                                    │
/// │  Alice → executor.execute()                                                        │
/// │    → FlashLoan_L1.flashLoan(token, 10k)                                            │
/// │      → onFlashLoan:                                                                │
/// │        1. bridge.bridgeTokens → CALL#1: Bridge_L1 → Bridge_L2.receiveTokens        │
/// │        2. executorL2Proxy.call(claimAndBridgeBack) → CALL#2                        │
/// │           On L2: claim NFT, bridge tokens back → CALL#3 (scope=[0])                │
/// │        3. repay flash loan                                                         │
/// └────────────────────────────────────────────────────────────────────────────────────┘
contract IntegrationTestFlashLoan is Test {
    // ── L1 contracts ──
    Rollups public rollups;
    MockZKVerifier public verifier;

    // ── L2 contracts ──
    CrossChainManagerL2 public managerL2;

    // ── Bridge contracts ──
    Bridge public bridgeL1;
    Bridge public bridgeL2;

    // ── Application contracts ──
    TestToken public token;
    FlashLoan public flashLoanL1;
    FlashLoanBridgeExecutor public executorL2;
    FlashLoanBridgeExecutor public executor;
    FlashLoanersNFT public flashLoanersNFT;

    // ── Pre-computed addresses ──
    address public wrappedTokenL2;
    address public executorL2Proxy;

    // ── Constants ──
    uint256 constant L2_ROLLUP_ID = 1;
    uint256 constant MAINNET_ROLLUP_ID = 0;
    address constant SYSTEM_ADDRESS = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
    bytes32 constant DEFAULT_VK = keccak256("verificationKey");

    address public alice = makeAddr("alice");

    function setUp() public {
        // ── L1 infrastructure ──
        verifier = new MockZKVerifier();
        rollups = new Rollups(address(verifier), 1);
        rollups.createRollup(keccak256("l2-initial-state"), DEFAULT_VK, address(this));

        // ── L2 infrastructure ──
        managerL2 = new CrossChainManagerL2(L2_ROLLUP_ID, SYSTEM_ADDRESS);

        // ── Token ──
        token = new TestToken();

        // ── Bridge deployment ──
        bridgeL1 = new Bridge();
        bridgeL2 = new Bridge();
        bridgeL1.initialize(address(rollups), MAINNET_ROLLUP_ID, address(this));
        bridgeL2.initialize(address(managerL2), L2_ROLLUP_ID, address(this));
        // Cross-reference canonical addresses (critical for onlyBridgeProxy checks)
        bridgeL1.setCanonicalBridgeAddress(address(bridgeL2));
        bridgeL2.setCanonicalBridgeAddress(address(bridgeL1));

        // ── FlashLoan pool on L1 ──
        flashLoanL1 = new FlashLoan();
        token.transfer(address(flashLoanL1), 10_000e18);

        // ── Executor on L2 (receives wrapped tokens, claims NFT, bridges back) ──
        // Constructor args unused by claimAndBridgeBack — all params passed as function args
        executorL2 = new FlashLoanBridgeExecutor(
            address(0), address(0), address(0), address(0),
            address(0), address(0), address(0), 0, address(0)
        );

        // ── Pre-compute WrappedToken address on L2 (CREATE2 from Bridge_L2) ──
        bytes32 wrappedSalt = keccak256(abi.encodePacked(address(token), MAINNET_ROLLUP_ID));
        bytes32 wrappedBytecodeHash = keccak256(
            abi.encodePacked(
                type(WrappedToken).creationCode,
                abi.encode("Test Token", "TT", uint8(18), address(bridgeL2))
            )
        );
        wrappedTokenL2 = address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(bridgeL2), wrappedSalt, wrappedBytecodeHash)))
            )
        );

        // ── FlashLoanersNFT on L2 (needs wrapped token address) ──
        flashLoanersNFT = new FlashLoanersNFT(wrappedTokenL2);

        // ── Proxy for executorL2 on L1 ──
        executorL2Proxy = rollups.createCrossChainProxy(address(executorL2), L2_ROLLUP_ID);

        // ── Executor on L1 (orchestrates flash loan + cross-chain flow) ──
        executor = new FlashLoanBridgeExecutor(
            address(flashLoanL1),
            address(bridgeL1),
            executorL2Proxy,
            address(executorL2),
            wrappedTokenL2,
            address(flashLoanersNFT),
            address(bridgeL2),
            L2_ROLLUP_ID,
            address(token)
        );
    }

    function _getRollupState(uint256 rollupId) internal view returns (bytes32) {
        (,, bytes32 stateRoot,) = rollups.rollups(rollupId);
        return stateRoot;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Test: Cross-chain flash loan with token-gated NFT claim
    //
    //  Phase 1 — L2 execution (1 system call, chained via continuation):
    //    Call A: Bridge_L2.receiveTokens() mints wrapped tokens to executorL2
    //    Call B (continuation): executorL2.claimAndBridgeBack():
    //            → FlashLoanersNFT.claim() (balance check passes)
    //            → Bridge_L2.bridgeTokens (burns wrapped, calls bridge proxy)
    //
    //  Phase 2 — L1 execution:
    //    Alice → executor.execute() → FlashLoan_L1.flashLoan() → onFlashLoan:
    //      1. bridgeL1.bridgeTokens → CALL#1 matched → RESULT (terminal)
    //      2. executorL2Proxy.call(claimAndBridgeBack) → CALL#2 matched → CALL#3 (scope=[0])
    //         → _processCallAtScope → Bridge_L1.receiveTokens releases tokens
    //         → RESULT#3 matched → RESULT (terminal)
    //      3. repay flash loan ✓
    // ═══════════════════════════════════════════════════════════════════════

    function test_CrossChainFlashLoan() public {
        // ── Build calldata ──

        // Forward receiveTokens: L1 → L2, mint wrapped tokens to executorL2
        bytes memory fwdReceiveTokensCalldata = abi.encodeCall(
            Bridge.receiveTokens,
            (address(token), MAINNET_ROLLUP_ID, address(executorL2), 10_000e18, "Test Token", "TT", 18, MAINNET_ROLLUP_ID)
        );

        // claimAndBridgeBack: called on executorL2 via proxy
        bytes memory claimAndBridgeBackCalldata = abi.encodeCall(
            FlashLoanBridgeExecutor.claimAndBridgeBack,
            (wrappedTokenL2, address(flashLoanersNFT), address(bridgeL2), MAINNET_ROLLUP_ID, address(executor))
        );

        // Return receiveTokens: L2 → L1, release native tokens to executor
        bytes memory retReceiveTokensCalldata = abi.encodeCall(
            Bridge.receiveTokens,
            (address(token), MAINNET_ROLLUP_ID, address(executor), 10_000e18, "Test Token", "TT", 18, L2_ROLLUP_ID)
        );

        // ── Define shared action templates ──

        // RESULT: void return with rollupId=L2 (used as terminal for L2-targeted calls)
        Action memory result_L2_void = Action({
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

        // RESULT: void return with rollupId=MAINNET (used as terminal for MAINNET-targeted calls)
        Action memory result_MAINNET_void = Action({
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

        // CALL for bridge return trip: Bridge_L2 → Bridge_L1 (built by L2's executeCrossChainCall)
        Action memory callBridgeReturn = Action({
            actionType: ActionType.CALL,
            rollupId: MAINNET_ROLLUP_ID,
            destination: address(bridgeL1),
            value: 0,
            data: retReceiveTokensCalldata,
            failed: false,
            sourceAddress: address(bridgeL2),
            sourceRollup: L2_ROLLUP_ID,
            scope: new uint256[](0)
        });

        // CALL B: executor → executorL2 (claimAndBridgeBack) — chained as nextAction from Entry 1
        Action memory callB = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: address(executorL2),
            value: 0,
            data: claimAndBridgeBackCalldata,
            failed: false,
            sourceAddress: address(executor),
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        // ════════════════════════════════════════════
        //  Phase 1: L2 — Single SYSTEM call executes both receiveTokens + claimAndBridgeBack
        // ════════════════════════════════════════════
        //
        //  executeIncomingCrossChainCall(bridgeL2, receiveTokens, bridgeL1, MAINNET, [])
        //    → _processCallAtScope: receiveTokens → mints wrapped to executorL2
        //    → RESULT(L2,void) consumed → Entry 1 returns CALL B (continuation)
        //    → _processCallAtScope: claimAndBridgeBack → claim NFT, bridge tokens back
        //      → reentrant executeCrossChainCall → CALL(bridge return) consumed → Entry 2
        //    → RESULT(L2,void) consumed → Entry 3 returns terminal
        //
        //  L2 execution table (3 entries):
        //    1. RESULT(L2,void) hash → CALL B (continuation)     — consumed after receiveTokens returns
        //    2. CALL(bridge return) hash → RESULT(MAINNET,void)   — consumed by reentrant executeCrossChainCall of B
        //    3. RESULT(L2,void) hash → RESULT(L2,void) terminal  — consumed after claimAndBridgeBack returns
        {
            ExecutionEntry[] memory l2Entries = new ExecutionEntry[](3);
            StateDelta[] memory emptyDeltas = new StateDelta[](0);

            // Entry 1: consumed after receiveTokens → continues with CALL B
            l2Entries[0].stateDeltas = emptyDeltas;
            l2Entries[0].actionHash = keccak256(abi.encode(result_L2_void));
            l2Entries[0].nextAction = callB;

            // Entry 2: consumed by reentrant executeCrossChainCall of B, when Bridge_L2.bridgeTokens calls proxy
            l2Entries[1].stateDeltas = emptyDeltas;
            l2Entries[1].actionHash = keccak256(abi.encode(callBridgeReturn));
            l2Entries[1].nextAction = result_MAINNET_void;

            // Entry 3: consumed after claimAndBridgeBack returns void → terminal
            l2Entries[2].stateDeltas = emptyDeltas;
            l2Entries[2].actionHash = keccak256(abi.encode(result_L2_void));
            l2Entries[2].nextAction = result_L2_void;

            vm.prank(SYSTEM_ADDRESS);
            managerL2.loadExecutionTable(l2Entries);
        }

        // Single system call: receiveTokens on Bridge_L2, then claimAndBridgeBack on executorL2
        //   Call A: proxy(Bridge_L1,MAINNET).executeOnBehalf(Bridge_L2, receiveTokens)
        //     → mints 10k wrapped to executorL2 → RESULT consumed → returns CALL B
        //   Call B (continuation): proxy(executor,MAINNET).executeOnBehalf(executorL2, claimAndBridgeBack)
        //     → claim NFT, burn wrapped, bridge back → RESULT consumed → terminal
        vm.prank(SYSTEM_ADDRESS);
        managerL2.executeIncomingCrossChainCall(
            address(bridgeL2),        // dest = Bridge_L2
            0,                        // value = 0
            fwdReceiveTokensCalldata, // data = receiveTokens(...)
            address(bridgeL1),        // source = Bridge_L1
            MAINNET_ROLLUP_ID,        // sourceRollup = MAINNET
            new uint256[](0)          // scope = [] (root)
        );

        // Verify wrapped token deployed, NFT claimed, wrapped tokens burned
        assertEq(bridgeL2.getWrappedToken(address(token), MAINNET_ROLLUP_ID), wrappedTokenL2);
        assertEq(WrappedToken(wrappedTokenL2).balanceOf(address(executorL2)), 0, "Wrapped tokens burned");
        assertTrue(flashLoanersNFT.hasClaimed(address(executorL2)), "executorL2 should have claimed NFT");
        assertEq(flashLoanersNFT.nextTokenId(), 1, "One NFT should be minted");
        assertEq(managerL2.pendingEntryCount(), 0, "All L2 entries consumed");

        // ════════════════════════════════════════════
        //  Phase 2: L1 — Flash loan + cross-chain execution
        // ════════════════════════════════════════════
        //
        //  postBatch loads 3 deferred entries. Alice → executor.execute():
        //    1. bridgeL1.bridgeTokens → proxy → CALL#1 matched → RESULT (terminal)
        //    2. executorL2Proxy.call(claimAndBridgeBack) → CALL#2 matched → CALL#3 (scope=[0])
        //       → newScope → _processCallAtScope → Bridge_L1.receiveTokens releases tokens
        //       → RESULT#3 matched → RESULT (terminal)
        //    3. repay: transfer 10k tokens back to FlashLoan_L1

        // CALL#1: Bridge_L1 → Bridge_L2 (forward trip)
        // Built by executeCrossChainCall when bridgeL1 calls proxy for (bridgeL2, L2)
        Action memory callForward = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: address(bridgeL2),
            value: 0,
            data: fwdReceiveTokensCalldata,
            failed: false,
            sourceAddress: address(bridgeL1),
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        // CALL#2: executor → executorL2 (claimAndBridgeBack)
        // Built by executeCrossChainCall when executor calls proxy for (executorL2, L2)
        Action memory callClaimAndBridge = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: address(executorL2),
            value: 0,
            data: claimAndBridgeBackCalldata,
            failed: false,
            sourceAddress: address(executor),
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        // CALL#3: Bridge_L2 → Bridge_L1 (return trip, nested at scope=[0])
        // This is callBridgeReturn with scope=[0] added for L1 scope navigation
        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;
        Action memory callReturnScoped = Action({
            actionType: ActionType.CALL,
            rollupId: MAINNET_ROLLUP_ID,
            destination: address(bridgeL1),
            value: 0,
            data: retReceiveTokensCalldata,
            failed: false,
            sourceAddress: address(bridgeL2),
            sourceRollup: L2_ROLLUP_ID,
            scope: scope0
        });

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-tokens-bridged-to-executor");
        bytes32 s2 = keccak256("l2-nft-claimed-tokens-bridged-back");
        bytes32 s3 = keccak256("l2-bridge-return-executed");

        // postBatch: 3 deferred entries on L1
        {
            StateDelta[] memory deltas1 = new StateDelta[](1);
            deltas1[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s0, newState: s1, etherDelta: 0});

            StateDelta[] memory deltas2 = new StateDelta[](1);
            deltas2[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s1, newState: s2, etherDelta: 0});

            StateDelta[] memory deltas3 = new StateDelta[](1);
            deltas3[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s2, newState: s3, etherDelta: 0});

            ExecutionEntry[] memory entries = new ExecutionEntry[](3);

            // Entry 1: CALL#1 → RESULT(L2,void) terminal
            entries[0].stateDeltas = deltas1;
            entries[0].actionHash = keccak256(abi.encode(callForward));
            entries[0].nextAction = result_L2_void;

            // Entry 2: CALL#2 → CALL#3 (nested scope=[0])
            entries[1].stateDeltas = deltas2;
            entries[1].actionHash = keccak256(abi.encode(callClaimAndBridge));
            entries[1].nextAction = callReturnScoped;

            // Entry 3: RESULT#3 (MAINNET,void) → RESULT(L2,void) terminal
            entries[2].stateDeltas = deltas3;
            entries[2].actionHash = keccak256(abi.encode(result_MAINNET_void));
            entries[2].nextAction = result_L2_void;

            rollups.postBatch(entries, 0, "", "proof");
        }

        // Alice triggers the flash loan → full cross-chain flow
        vm.prank(alice);
        executor.execute();

        // ── Assertions ──
        assertTrue(flashLoanersNFT.hasClaimed(address(executorL2)), "executorL2 has claimed NFT");
        assertEq(flashLoanersNFT.nextTokenId(), 1, "One NFT minted (tokenId=0)");
        assertEq(token.balanceOf(address(flashLoanL1)), 10_000e18, "FlashLoan_L1 balance unchanged (loan repaid)");
        assertEq(token.balanceOf(address(executor)), 0, "Executor has no tokens remaining");
        assertEq(token.balanceOf(address(bridgeL1)), 0, "Bridge_L1 has no locked tokens (released back)");
        assertEq(_getRollupState(L2_ROLLUP_ID), s3, "L2 rollup state updated after all phases");
    }
}
