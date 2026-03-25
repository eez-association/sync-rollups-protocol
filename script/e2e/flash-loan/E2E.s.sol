// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Bridge} from "../../../src/periphery/Bridge.sol";
import {WrappedToken} from "../../../src/periphery/WrappedToken.sol";
import {FlashLoan} from "../../../src/periphery/defiMock/FlashLoan.sol";
import {FlashLoanBridgeExecutor} from "../../../src/periphery/defiMock/FlashLoanBridgeExecutor.sol";
import {FlashLoanersNFT} from "../../../src/periphery/defiMock/FlashLoanersNFT.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {_deployBridge} from "../../DeployBridge.s.sol";

/// @dev Simple test token deployed on L1
contract TestToken is ERC20 {
    constructor() ERC20("Test Token", "TT") {
        _mint(msg.sender, 1_000_000e18);
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Deployment contracts (run in file order by the generic runner)
//  Deploy   → L1: Token + Bridge L1
//  DeployL2 → L2: Bridge L2 + set canonical
//  Deploy2  → L1: set canonical, compute wrapped, deploy L1 flash loan contracts
//  Deploy2L2→ L2: deploy L2 executor contracts
// ═══════════════════════════════════════════════════════════════════════

/// @title Deploy — Deploy Token + Bridge on L1
/// @dev Env: ROLLUPS
/// Outputs: TOKEN, BRIDGE_L1
contract Deploy is Script {
    function run() external {
        address rollups = vm.envAddress("ROLLUPS");
        vm.startBroadcast();

        TestToken token = new TestToken();
        console.log("TOKEN=%s", address(token));

        bytes32 salt = keccak256("sync-rollups-bridge-v1");
        address bridge = _deployBridge(salt);
        Bridge(bridge).initialize(rollups, 0, msg.sender);
        console.log("BRIDGE_L1=%s", bridge);

        vm.stopBroadcast();
    }
}

/// @title DeployL2 — Deploy Bridge on L2 + set canonical bridge
/// @dev Env: MANAGER_L2, L2_ROLLUP_ID, BRIDGE_L1
/// Outputs: BRIDGE_L2
contract DeployL2 is Script {
    function run() external {
        address managerL2 = vm.envAddress("MANAGER_L2");
        uint256 l2RollupId = vm.envUint("L2_ROLLUP_ID");
        address bridgeL1 = vm.envAddress("BRIDGE_L1");

        vm.startBroadcast();

        bytes32 salt = keccak256("sync-rollups-bridge-v1");
        address bridge = _deployBridge(salt);
        Bridge(bridge).initialize(managerL2, l2RollupId, msg.sender);
        Bridge(bridge).setCanonicalBridgeAddress(bridgeL1);

        console.log("BRIDGE_L2=%s", bridge);

        vm.stopBroadcast();
    }
}

/// @title Deploy2 — Set canonical on L1, compute wrapped token, deploy L1 flash loan contracts
/// @dev Env: ROLLUPS, BRIDGE_L1, BRIDGE_L2, TOKEN, L2_ROLLUP_ID
/// Outputs: WRAPPED_TOKEN_L2, FLASH_LOAN_POOL, EXECUTOR_L2_PROXY, EXECUTOR_L1,
///          TOKEN_NAME, TOKEN_SYMBOL, TOKEN_DECIMALS
contract Deploy2 is Script {
    function run() external {
        address rollups = vm.envAddress("ROLLUPS");
        address bridgeL1 = vm.envAddress("BRIDGE_L1");
        address bridgeL2 = vm.envAddress("BRIDGE_L2");
        address token = vm.envAddress("TOKEN");
        uint256 l2RollupId = vm.envUint("L2_ROLLUP_ID");

        // Read token metadata (needed by ExecuteL2 later)
        string memory name = ERC20(token).name();
        string memory symbol = ERC20(token).symbol();
        uint8 tokenDecimals = ERC20(token).decimals();

        // Pre-compute WrappedToken address on L2
        bytes32 wrappedSalt = keccak256(abi.encodePacked(token, uint256(0)));
        bytes32 wrappedBytecodeHash = keccak256(
            abi.encodePacked(type(WrappedToken).creationCode, abi.encode(name, symbol, tokenDecimals, bridgeL2))
        );
        address wrappedTokenL2 = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), bridgeL2, wrappedSalt, wrappedBytecodeHash))))
        );
        console.log("WRAPPED_TOKEN_L2=%s", wrappedTokenL2);

        vm.startBroadcast();

        // Set canonical bridge on L1
        Bridge(bridgeL1).setCanonicalBridgeAddress(bridgeL2);

        // FlashLoan pool + fund it
        FlashLoan flashLoanPool = new FlashLoan();
        IERC20(token).transfer(address(flashLoanPool), 10_000e18);
        console.log("FLASH_LOAN_POOL=%s", address(flashLoanPool));

        // Create proxy for executorL2 on L1 (will be deployed in Deploy2L2, but we need the address now)
        // We deploy a dummy executor first to get the proxy address — the real one comes in Deploy2L2
        // Actually we can't reference executor L2 yet. We need Deploy2L2 first.
        // Instead, we'll output what we have and Deploy2L2 outputs EXECUTOR_L2.
        // Then we need a Deploy3 to create the proxy and executor L1.

        vm.stopBroadcast();

        // Output token metadata for ExecuteL2
        console.log("TOKEN_NAME=%s", name);
        console.log("TOKEN_SYMBOL=%s", symbol);
        console.log("TOKEN_DECIMALS=%s", uint256(tokenDecimals));
    }
}

/// @title Deploy2L2 — Deploy L2 executor contracts
/// @dev Env: WRAPPED_TOKEN_L2
/// Outputs: EXECUTOR_L2, FLASH_LOANERS_NFT
contract Deploy2L2 is Script {
    function run() external {
        address wrappedTokenL2 = vm.envAddress("WRAPPED_TOKEN_L2");

        vm.startBroadcast();

        FlashLoanBridgeExecutor executorL2 = new FlashLoanBridgeExecutor(
            address(0), address(0), address(0), address(0), address(0), address(0), address(0), 0, address(0)
        );
        console.log("EXECUTOR_L2=%s", address(executorL2));

        FlashLoanersNFT nft = new FlashLoanersNFT(wrappedTokenL2);
        console.log("FLASH_LOANERS_NFT=%s", address(nft));

        vm.stopBroadcast();
    }
}

/// @title Deploy3 — Create executor L2 proxy + deploy executor L1
/// @dev Env: ROLLUPS, BRIDGE_L1, BRIDGE_L2, TOKEN, EXECUTOR_L2, WRAPPED_TOKEN_L2,
///          FLASH_LOANERS_NFT, FLASH_LOAN_POOL, L2_ROLLUP_ID
/// Outputs: EXECUTOR_L2_PROXY, EXECUTOR_L1
contract Deploy3 is Script {
    function run() external {
        address rollups = vm.envAddress("ROLLUPS");
        address bridgeL1 = vm.envAddress("BRIDGE_L1");
        address bridgeL2 = vm.envAddress("BRIDGE_L2");
        address token = vm.envAddress("TOKEN");
        address executorL2 = vm.envAddress("EXECUTOR_L2");
        address wrappedTokenL2 = vm.envAddress("WRAPPED_TOKEN_L2");
        address flashLoanersNFT = vm.envAddress("FLASH_LOANERS_NFT");
        address flashLoanPool = vm.envAddress("FLASH_LOAN_POOL");
        uint256 l2RollupId = vm.envUint("L2_ROLLUP_ID");

        vm.startBroadcast();

        // Create proxy for executorL2 on L1
        address executorL2Proxy = Rollups(rollups).createCrossChainProxy(executorL2, l2RollupId);
        console.log("EXECUTOR_L2_PROXY=%s", executorL2Proxy);

        // Executor on L1
        FlashLoanBridgeExecutor executor = new FlashLoanBridgeExecutor(
            flashLoanPool, bridgeL1, executorL2Proxy, executorL2,
            wrappedTokenL2, flashLoanersNFT, bridgeL2, l2RollupId, token
        );
        console.log("EXECUTOR_L1=%s", address(executor));

        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Execution contracts
// ═══════════════════════════════════════════════════════════════════════

/// @title ExecuteL2 — Load execution table + executeIncomingCrossChainCall on L2
/// @dev Env: MANAGER_L2, BRIDGE_L1, BRIDGE_L2, EXECUTOR_L1, EXECUTOR_L2,
///          FLASH_LOANERS_NFT, TOKEN, WRAPPED_TOKEN_L2, TOKEN_NAME, TOKEN_SYMBOL, TOKEN_DECIMALS
contract ExecuteL2 is Script {
    uint256 constant L2_ROLLUP_ID = 1;
    uint256 constant MAINNET_ROLLUP_ID = 0;

    function run() external {
        address managerL2 = vm.envAddress("MANAGER_L2");
        address bridgeL1 = vm.envAddress("BRIDGE_L1");
        address bridgeL2 = vm.envAddress("BRIDGE_L2");
        address executorL1 = vm.envAddress("EXECUTOR_L1");
        address executorL2 = vm.envAddress("EXECUTOR_L2");
        address flashLoanersNFT = vm.envAddress("FLASH_LOANERS_NFT");
        address token = vm.envAddress("TOKEN");
        address wrappedTokenL2 = vm.envAddress("WRAPPED_TOKEN_L2");
        string memory name = vm.envString("TOKEN_NAME");
        string memory symbol = vm.envString("TOKEN_SYMBOL");
        uint8 tokenDecimals = uint8(vm.envUint("TOKEN_DECIMALS"));

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2);

        // Forward receiveTokens: L1 → L2
        bytes memory fwdReceiveTokensCalldata = abi.encodeCall(
            Bridge.receiveTokens,
            (token, MAINNET_ROLLUP_ID, executorL2, 10_000e18, name, symbol, tokenDecimals, MAINNET_ROLLUP_ID)
        );

        // claimAndBridgeBack — nftRecipient = msg.sender (Alice, the user who calls execute())
        bytes memory claimAndBridgeBackCalldata = abi.encodeCall(
            FlashLoanBridgeExecutor.claimAndBridgeBack,
            (wrappedTokenL2, flashLoanersNFT, bridgeL2, MAINNET_ROLLUP_ID, executorL1, msg.sender)
        );

        // Return receiveTokens: L2 → L1
        bytes memory retReceiveTokensCalldata = abi.encodeCall(
            Bridge.receiveTokens,
            (token, MAINNET_ROLLUP_ID, executorL1, 10_000e18, name, symbol, tokenDecimals, L2_ROLLUP_ID)
        );

        // Shared action templates
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

        Action memory callBridgeReturn = Action({
            actionType: ActionType.CALL,
            rollupId: MAINNET_ROLLUP_ID,
            destination: bridgeL1,
            value: 0,
            data: retReceiveTokensCalldata,
            failed: false,
            sourceAddress: bridgeL2,
            sourceRollup: L2_ROLLUP_ID,
            scope: new uint256[](0)
        });

        Action memory callB = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: executorL2,
            value: 0,
            data: claimAndBridgeBackCalldata,
            failed: false,
            sourceAddress: executorL1,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        vm.startBroadcast();

        // Load execution table (3 entries)
        ExecutionEntry[] memory l2Entries = new ExecutionEntry[](3);
        StateDelta[] memory emptyDeltas = new StateDelta[](0);

        l2Entries[0].stateDeltas = emptyDeltas;
        l2Entries[0].actionHash = keccak256(abi.encode(result_L2_void));
        l2Entries[0].nextAction = callB;

        l2Entries[1].stateDeltas = emptyDeltas;
        l2Entries[1].actionHash = keccak256(abi.encode(callBridgeReturn));
        l2Entries[1].nextAction = result_MAINNET_void;

        l2Entries[2].stateDeltas = emptyDeltas;
        l2Entries[2].actionHash = keccak256(abi.encode(result_L2_void));
        l2Entries[2].nextAction = result_L2_void;

        manager.loadExecutionTable(l2Entries);
        console.log("L2 execution table loaded (3 entries)");

        // Single system call: receiveTokens + claimAndBridgeBack (chained)
        manager.executeIncomingCrossChainCall(
            bridgeL2,
            0,
            fwdReceiveTokensCalldata,
            bridgeL1,
            MAINNET_ROLLUP_ID,
            new uint256[](0)
        );
        console.log("L2 execution complete");

        vm.stopBroadcast();
    }
}

/// @title Batcher — postBatch + executor.execute() in single tx
contract Batcher {
    function execute(
        Rollups rollups,
        ExecutionEntry[] calldata entries,
        FlashLoanBridgeExecutor executor
    ) external {
        rollups.postBatch(entries, 0, "", "proof");
        executor.execute(msg.sender);
    }
}

/// @title Execute — Post batch entries + trigger flash loan (local mode)
/// @dev Env: ROLLUPS, BRIDGE_L1, BRIDGE_L2, EXECUTOR_L1, EXECUTOR_L2,
///          FLASH_LOANERS_NFT, TOKEN, WRAPPED_TOKEN_L2
contract Execute is Script {
    uint256 constant L2_ROLLUP_ID = 1;
    uint256 constant MAINNET_ROLLUP_ID = 0;

    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address bridgeL1 = vm.envAddress("BRIDGE_L1");
        address bridgeL2 = vm.envAddress("BRIDGE_L2");
        address executorL1 = vm.envAddress("EXECUTOR_L1");
        address executorL2 = vm.envAddress("EXECUTOR_L2");
        address flashLoanersNFT = vm.envAddress("FLASH_LOANERS_NFT");
        address token = vm.envAddress("TOKEN");
        address wrappedTokenL2 = vm.envAddress("WRAPPED_TOKEN_L2");

        Rollups rollups = Rollups(rollupsAddr);

        string memory name = ERC20(token).name();
        string memory symbol = ERC20(token).symbol();
        uint8 tokenDecimals = ERC20(token).decimals();

        bytes memory fwdReceiveTokensCalldata = abi.encodeCall(
            Bridge.receiveTokens,
            (token, MAINNET_ROLLUP_ID, executorL2, 10_000e18, name, symbol, tokenDecimals, MAINNET_ROLLUP_ID)
        );

        bytes memory claimAndBridgeBackCalldata = abi.encodeCall(
            FlashLoanBridgeExecutor.claimAndBridgeBack,
            (wrappedTokenL2, flashLoanersNFT, bridgeL2, MAINNET_ROLLUP_ID, executorL1, msg.sender)
        );

        bytes memory retReceiveTokensCalldata = abi.encodeCall(
            Bridge.receiveTokens,
            (token, MAINNET_ROLLUP_ID, executorL1, 10_000e18, name, symbol, tokenDecimals, L2_ROLLUP_ID)
        );

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

        Action memory callForward = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: bridgeL2,
            value: 0,
            data: fwdReceiveTokensCalldata,
            failed: false,
            sourceAddress: bridgeL1,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        Action memory callClaimAndBridge = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: executorL2,
            value: 0,
            data: claimAndBridgeBackCalldata,
            failed: false,
            sourceAddress: executorL1,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;
        Action memory callReturnScoped = Action({
            actionType: ActionType.CALL,
            rollupId: MAINNET_ROLLUP_ID,
            destination: bridgeL1,
            value: 0,
            data: retReceiveTokensCalldata,
            failed: false,
            sourceAddress: bridgeL2,
            sourceRollup: L2_ROLLUP_ID,
            scope: scope0
        });

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-tokens-bridged-to-executor");
        bytes32 s2 = keccak256("l2-nft-claimed-tokens-bridged-back");
        bytes32 s3 = keccak256("l2-bridge-return-executed");

        StateDelta[] memory deltas1 = new StateDelta[](1);
        deltas1[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s0, newState: s1, etherDelta: 0});

        StateDelta[] memory deltas2 = new StateDelta[](1);
        deltas2[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s1, newState: s2, etherDelta: 0});

        StateDelta[] memory deltas3 = new StateDelta[](1);
        deltas3[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s2, newState: s3, etherDelta: 0});

        ExecutionEntry[] memory entries = new ExecutionEntry[](3);

        entries[0].stateDeltas = deltas1;
        entries[0].actionHash = keccak256(abi.encode(callForward));
        entries[0].nextAction = result_L2_void;

        entries[1].stateDeltas = deltas2;
        entries[1].actionHash = keccak256(abi.encode(callClaimAndBridge));
        entries[1].nextAction = callReturnScoped;

        entries[2].stateDeltas = deltas3;
        entries[2].actionHash = keccak256(abi.encode(result_MAINNET_void));
        entries[2].nextAction = result_L2_void;

        vm.startBroadcast();

        Batcher batcher = new Batcher();
        batcher.execute(rollups, entries, FlashLoanBridgeExecutor(executorL1));

        console.log("L1 execution complete");

        vm.stopBroadcast();
    }
}

/// @title ExecuteNetwork — Network mode L1: user transaction only (no Batcher)
/// @dev Env: EXECUTOR_L1
contract ExecuteNetwork is Script {
    function run() external {
        address executorL1 = vm.envAddress("EXECUTOR_L1");
        vm.startBroadcast();
        FlashLoanBridgeExecutor(executorL1).execute();
        console.log("done");
        vm.stopBroadcast();
    }
}

/// @title ComputeExpected — Compute expected entries for L1 batch and L2 table
/// @dev Env: BRIDGE_L1, BRIDGE_L2, EXECUTOR_L1, EXECUTOR_L2, FLASH_LOANERS_NFT, TOKEN, WRAPPED_TOKEN_L2
contract ComputeExpected is Script {
    uint256 constant L2_ROLLUP_ID = 1;
    uint256 constant MAINNET_ROLLUP_ID = 0;

    function run() external view {
        address bridgeL1 = vm.envAddress("BRIDGE_L1");
        address bridgeL2 = vm.envAddress("BRIDGE_L2");
        address executorL1 = vm.envAddress("EXECUTOR_L1");
        address executorL2 = vm.envAddress("EXECUTOR_L2");
        address flashLoanersNFT = vm.envAddress("FLASH_LOANERS_NFT");
        address token = vm.envAddress("TOKEN");
        address wrappedTokenL2 = vm.envAddress("WRAPPED_TOKEN_L2");
        string memory name = ERC20(token).name();
        string memory symbol = ERC20(token).symbol();
        uint8 tokenDecimals = ERC20(token).decimals();

        bytes memory fwdReceiveTokensCalldata = abi.encodeCall(
            Bridge.receiveTokens,
            (token, MAINNET_ROLLUP_ID, executorL2, 10_000e18, name, symbol, tokenDecimals, MAINNET_ROLLUP_ID)
        );
        bytes memory claimAndBridgeBackCalldata = abi.encodeCall(
            FlashLoanBridgeExecutor.claimAndBridgeBack,
            (wrappedTokenL2, flashLoanersNFT, bridgeL2, MAINNET_ROLLUP_ID, executorL1, msg.sender)
        );
        bytes memory retReceiveTokensCalldata = abi.encodeCall(
            Bridge.receiveTokens,
            (token, MAINNET_ROLLUP_ID, executorL1, 10_000e18, name, symbol, tokenDecimals, L2_ROLLUP_ID)
        );

        // ── L1 actions ──
        Action memory callForward = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: bridgeL2,
            value: 0,
            data: fwdReceiveTokensCalldata,
            failed: false,
            sourceAddress: bridgeL1,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });
        Action memory callClaimAndBridge = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: executorL2,
            value: 0,
            data: claimAndBridgeBackCalldata,
            failed: false,
            sourceAddress: executorL1,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });
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

        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;
        Action memory callReturnScoped = Action({
            actionType: ActionType.CALL,
            rollupId: MAINNET_ROLLUP_ID,
            destination: bridgeL1,
            value: 0,
            data: retReceiveTokensCalldata,
            failed: false,
            sourceAddress: bridgeL2,
            sourceRollup: L2_ROLLUP_ID,
            scope: scope0
        });

        Action memory callBridgeReturn = Action({
            actionType: ActionType.CALL,
            rollupId: MAINNET_ROLLUP_ID,
            destination: bridgeL1,
            value: 0,
            data: retReceiveTokensCalldata,
            failed: false,
            sourceAddress: bridgeL2,
            sourceRollup: L2_ROLLUP_ID,
            scope: new uint256[](0)
        });
        Action memory callB = Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: executorL2,
            value: 0,
            data: claimAndBridgeBackCalldata,
            failed: false,
            sourceAddress: executorL1,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });

        bytes32 h0 = keccak256(abi.encode(callForward));
        bytes32 h1 = keccak256(abi.encode(callClaimAndBridge));
        bytes32 h2 = keccak256(abi.encode(result_MAINNET_void));
        bytes32 l2h0 = keccak256(abi.encode(result_L2_void));
        bytes32 l2h1 = keccak256(abi.encode(callBridgeReturn));

        // State progression
        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-tokens-bridged-to-executor");
        bytes32 s2 = keccak256("l2-nft-claimed-tokens-bridged-back");
        bytes32 s3 = keccak256("l2-bridge-return-executed");

        // Parseable lines for shell scripts
        console.log("EXPECTED_L1_HASHES=[%s,%s,%s]", vm.toString(h0), vm.toString(h1), vm.toString(h2));
        console.log("EXPECTED_L2_HASHES=[%s,%s,%s]", vm.toString(l2h0), vm.toString(l2h1), vm.toString(l2h0));
        // L2 call verification: h0 = callForward is the one executeIncomingCrossChainCall on L2
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(h0));

        // Human-readable expected L1 table
        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (3 entries) ===");
        _logEntry(0, h0, s0, s1, 0, "RESULT(rollup 1, ok, data=0x)");
        _logEntry(1, h1, s1, s2, 0, _fmtCall(callReturnScoped));
        _logEntry(2, h2, s2, s3, 0, "RESULT(rollup 1, ok, data=0x)");

        // Human-readable expected L2 table
        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (3 entries) ===");
        console.log("  [0] actionHash: %s", vm.toString(l2h0));
        console.log("      nextAction: %s", _fmtCall(callB));
        console.log("  [1] actionHash: %s", vm.toString(l2h1));
        console.log("      nextAction: RESULT(rollup 0, ok, data=0x)");
        console.log("  [2] actionHash: %s", vm.toString(l2h0));
        console.log("      nextAction: RESULT(rollup 1, ok, data=0x)");
    }

    function _logEntry(uint256 idx, bytes32 hash, bytes32 cur, bytes32 next, int256 ether_, string memory nextAction)
        internal
        pure
    {
        console.log("  [%s] DEFERRED  actionHash: %s", idx, vm.toString(hash));
        console.log(
            string.concat(
                "      stateDelta: rollup 1  ",
                vm.toString(cur),
                " -> ",
                vm.toString(next),
                "  ether: ",
                vm.toString(ether_)
            )
        );
        console.log("      nextAction: %s", nextAction);
    }

    function _fmtCall(Action memory a) internal pure returns (string memory) {
        return string.concat(
            "CALL(rollup ",
            vm.toString(a.rollupId),
            ", dest=",
            vm.toString(a.destination),
            ", from=",
            vm.toString(a.sourceAddress),
            ", scope=[",
            _scopeStr(a.scope),
            "])"
        );
    }

    function _scopeStr(uint256[] memory scope) internal pure returns (string memory) {
        string memory s = "";
        for (uint256 i = 0; i < scope.length; i++) {
            if (i > 0) s = string.concat(s, ",");
            s = string.concat(s, vm.toString(scope[i]));
        }
        return s;
    }
}
