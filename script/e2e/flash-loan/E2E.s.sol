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
import {_deployBridge, _computeBridgeAddress} from "../../DeployBridge.s.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";

/// @dev Centralized action & entry definitions for the flash-loan scenario.
///   Single source of truth — used by Execute, ExecuteL2, and ComputeExpected.
abstract contract FlashLoanActions {
    uint256 internal constant L2_ROLLUP_ID = 1;
    uint256 internal constant MAINNET_ROLLUP_ID = 0;

    function _callForward(address bridgeL2, address bridgeL1, bytes memory fwdCalldata)
        internal
        pure
        returns (Action memory)
    {
        return Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: bridgeL2,
            value: 0,
            data: fwdCalldata,
            failed: false,
            sourceAddress: bridgeL1,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });
    }

    function _callClaimAndBridge(address executorL2, address executorL1, bytes memory claimCalldata)
        internal
        pure
        returns (Action memory)
    {
        return Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: executorL2,
            value: 0,
            data: claimCalldata,
            failed: false,
            sourceAddress: executorL1,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });
    }

    function _callReturn(address bridgeL1, address bridgeL2, bytes memory retCalldata, uint256[] memory scope)
        internal
        pure
        returns (Action memory)
    {
        return Action({
            actionType: ActionType.CALL,
            rollupId: MAINNET_ROLLUP_ID,
            destination: bridgeL1,
            value: 0,
            data: retCalldata,
            failed: false,
            sourceAddress: bridgeL2,
            sourceRollup: L2_ROLLUP_ID,
            scope: scope
        });
    }

    function _resultL2Void() internal pure returns (Action memory) {
        return Action({
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
    }

    function _resultMainnetVoid() internal pure returns (Action memory) {
        return Action({
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
    }

    function _l1Entries(
        address bridgeL2,
        address bridgeL1,
        bytes memory fwdCalldata,
        address executorL2,
        address executorL1,
        bytes memory claimCalldata,
        bytes memory retCalldata
    ) internal pure returns (ExecutionEntry[] memory entries) {
        Action memory callFwd = _callForward(bridgeL2, bridgeL1, fwdCalldata);
        Action memory callClaim = _callClaimAndBridge(executorL2, executorL1, claimCalldata);
        Action memory resultL2 = _resultL2Void();
        Action memory resultMainnet = _resultMainnetVoid();

        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;
        Action memory callRet = _callReturn(bridgeL1, bridgeL2, retCalldata, scope0);

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

        entries = new ExecutionEntry[](3);

        entries[0].stateDeltas = deltas1;
        entries[0].actionHash = keccak256(abi.encode(callFwd));
        entries[0].nextAction = resultL2;

        entries[1].stateDeltas = deltas2;
        entries[1].actionHash = keccak256(abi.encode(callClaim));
        entries[1].nextAction = callRet;

        entries[2].stateDeltas = deltas3;
        entries[2].actionHash = keccak256(abi.encode(resultMainnet));
        entries[2].nextAction = resultL2;
    }

    function _l2Entries(
        address bridgeL1,
        address bridgeL2,
        bytes memory retCalldata,
        address executorL2,
        address executorL1,
        bytes memory claimCalldata
    ) internal pure returns (ExecutionEntry[] memory entries) {
        Action memory resultL2 = _resultL2Void();
        Action memory resultMainnet = _resultMainnetVoid();
        Action memory callClaim = _callClaimAndBridge(executorL2, executorL1, claimCalldata);
        Action memory callRet = _callReturn(bridgeL1, bridgeL2, retCalldata, new uint256[](0));

        entries = new ExecutionEntry[](3);

        entries[0].stateDeltas = new StateDelta[](0);
        entries[0].actionHash = keccak256(abi.encode(resultL2));
        entries[0].nextAction = callClaim;

        entries[1].stateDeltas = new StateDelta[](0);
        entries[1].actionHash = keccak256(abi.encode(callRet));
        entries[1].nextAction = resultMainnet;

        entries[2].stateDeltas = new StateDelta[](0);
        entries[2].actionHash = keccak256(abi.encode(resultL2));
        entries[2].nextAction = resultL2;
    }
}

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
        address bridge = _computeBridgeAddress(salt);
        if (bridge.code.length == 0) {
            bridge = _deployBridge(salt);
            Bridge(bridge).initialize(rollups, 0, msg.sender);
        }
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
        address bridge = _computeBridgeAddress(salt);
        if (bridge.code.length == 0) {
            bridge = _deployBridge(salt);
            Bridge(bridge).initialize(managerL2, l2RollupId, msg.sender);
            Bridge(bridge).setCanonicalBridgeAddress(bridgeL1);
        }

        console.log("BRIDGE_L2=%s", bridge);

        vm.stopBroadcast();
    }
}

/// @title Deploy2 — Set canonical on L1, compute wrapped token, deploy flash loan pool
/// @dev Env: ROLLUPS, BRIDGE_L1, BRIDGE_L2, TOKEN, L2_ROLLUP_ID
/// Outputs: WRAPPED_TOKEN_L2, FLASH_LOAN_POOL, TOKEN_NAME, TOKEN_SYMBOL, TOKEN_DECIMALS
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

        // Create proxy for executorL2 on L1 (try/catch for re-run tolerance)
        address executorL2Proxy;
        try Rollups(rollups).createCrossChainProxy(executorL2, l2RollupId) returns (address proxy) {
            executorL2Proxy = proxy;
        } catch {
            executorL2Proxy = Rollups(rollups).computeCrossChainProxyAddress(executorL2, l2RollupId);
        }
        console.log("EXECUTOR_L2_PROXY=%s", executorL2Proxy);

        // Executor on L1
        FlashLoanBridgeExecutor executor = new FlashLoanBridgeExecutor(
            flashLoanPool,
            bridgeL1,
            executorL2Proxy,
            executorL2,
            wrappedTokenL2,
            flashLoanersNFT,
            bridgeL2,
            l2RollupId,
            token
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
contract ExecuteL2 is Script, FlashLoanActions {
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

        vm.startBroadcast();

        manager.loadExecutionTable(
            _l2Entries(bridgeL1, bridgeL2, retReceiveTokensCalldata, executorL2, executorL1, claimAndBridgeBackCalldata)
        );
        console.log("L2 execution table loaded (3 entries)");

        manager.executeIncomingCrossChainCall(
            bridgeL2, 0, fwdReceiveTokensCalldata, bridgeL1, MAINNET_ROLLUP_ID, new uint256[](0)
        );
        console.log("L2 execution complete");

        vm.stopBroadcast();
    }
}

/// @title Batcher — postBatch + executor.execute() in single tx
contract Batcher {
    function execute(Rollups rollups, ExecutionEntry[] calldata entries, FlashLoanBridgeExecutor executor) external {
        rollups.postBatch(entries, 0, "", "proof");
        executor.execute(msg.sender);
    }
}

/// @title Execute — Post batch entries + trigger flash loan (local mode)
/// @dev Env: ROLLUPS, BRIDGE_L1, BRIDGE_L2, EXECUTOR_L1, EXECUTOR_L2,
///          FLASH_LOANERS_NFT, TOKEN, WRAPPED_TOKEN_L2
contract Execute is Script, FlashLoanActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
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

        vm.startBroadcast();

        Batcher batcher = new Batcher();
        batcher.execute(
            Rollups(rollupsAddr),
            _l1Entries(bridgeL2, bridgeL1, fwdReceiveTokensCalldata, executorL2, executorL1, claimAndBridgeBackCalldata, retReceiveTokensCalldata),
            FlashLoanBridgeExecutor(executorL1)
        );

        console.log("L1 execution complete");

        vm.stopBroadcast();
    }
}

/// @title ExecuteNetwork — Network mode L1: user transaction only (no Batcher)
/// @dev Env: EXECUTOR_L1
/// Returns (target, value, calldata) so the runner can send via `cast send`.
/// We can't use `forge script --broadcast` because the tx reverts in local simulation
/// (no execution table loaded yet). The system intercepts the tx from the mempool
/// and inserts postBatch before it in the same block.
contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("EXECUTOR_L1");
        bytes memory data = abi.encodeWithSignature("execute()");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

/// @title ComputeExpected — Compute expected entries for L1 batch and L2 table
/// @dev Env: BRIDGE_L1, BRIDGE_L2, EXECUTOR_L1, EXECUTOR_L2, FLASH_LOANERS_NFT, TOKEN, WRAPPED_TOKEN_L2
contract ComputeExpected is ComputeExpectedBase, FlashLoanActions {
    // ── Address-to-name mapping ──

    function _name(address a) internal view override returns (string memory) {
        address bridgeL1 = vm.envAddress("BRIDGE_L1");
        address bridgeL2 = vm.envAddress("BRIDGE_L2");
        address executorL1 = vm.envAddress("EXECUTOR_L1");
        address executorL2 = vm.envAddress("EXECUTOR_L2");
        address flashLoanersNFT = vm.envAddress("FLASH_LOANERS_NFT");
        address token = vm.envAddress("TOKEN");
        address wrappedTokenL2 = vm.envAddress("WRAPPED_TOKEN_L2");

        if (a == bridgeL1) return "BridgeL1";
        if (a == bridgeL2) return "BridgeL2";
        if (a == executorL1) return "ExecutorL1";
        if (a == executorL2) return "ExecutorL2";
        if (a == flashLoanersNFT) return "FlashLoanersNFT";
        if (a == token) return "Token";
        if (a == wrappedTokenL2) return "WrappedToken";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Bridge.receiveTokens.selector) return "receiveTokens";
        if (sel == FlashLoanBridgeExecutor.claimAndBridgeBack.selector) return "claimAndBridgeBack";
        return ComputeExpectedBase._funcName(sel);
    }

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

        // Actions (single source of truth)
        Action memory callFwd = _callForward(bridgeL2, bridgeL1, fwdReceiveTokensCalldata);
        Action memory callClaim = _callClaimAndBridge(executorL2, executorL1, claimAndBridgeBackCalldata);
        Action memory resultL2 = _resultL2Void();
        Action memory resultMainnet = _resultMainnetVoid();

        uint256[] memory scope0 = new uint256[](1);
        scope0[0] = 0;
        Action memory callRetScoped = _callReturn(bridgeL1, bridgeL2, retReceiveTokensCalldata, scope0);
        Action memory callRetUnscoped = _callReturn(bridgeL1, bridgeL2, retReceiveTokensCalldata, new uint256[](0));

        // Entries (single source of truth)
        ExecutionEntry[] memory l1 = _l1Entries(
            bridgeL2, bridgeL1, fwdReceiveTokensCalldata, executorL2, executorL1, claimAndBridgeBackCalldata, retReceiveTokensCalldata
        );
        ExecutionEntry[] memory l2 = _l2Entries(
            bridgeL1, bridgeL2, retReceiveTokensCalldata, executorL2, executorL1, claimAndBridgeBackCalldata
        );

        // Compute hashes from entries
        bytes32 h0 = _entryHash(l1[0].actionHash, l1[0].nextAction);
        bytes32 h1 = _entryHash(l1[1].actionHash, l1[1].nextAction);
        bytes32 h2 = _entryHash(l1[2].actionHash, l1[2].nextAction);
        bytes32 l2h0 = _entryHash(l2[0].actionHash, l2[0].nextAction);
        bytes32 l2h1 = _entryHash(l2[1].actionHash, l2[1].nextAction);
        bytes32 l2h2 = _entryHash(l2[2].actionHash, l2[2].nextAction);

        // Parseable lines for shell scripts
        console.log("EXPECTED_L1_HASHES=[%s,%s,%s]", vm.toString(h0), vm.toString(h1), vm.toString(h2));
        console.log("EXPECTED_L2_HASHES=[%s,%s,%s]", vm.toString(l2h0), vm.toString(l2h1), vm.toString(l2h2));
        // L2 call verification: callForward is the one executeIncomingCrossChainCall on L2
        bytes32 callForwardHash = l1[0].actionHash;
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(callForwardHash));

        // Summary
        console.log("");
        console.log("=== EXPECTED SUMMARY ===");
        _logEntrySummary(0, callFwd, resultL2, false);
        _logEntrySummary(1, callClaim, callRetScoped, false);
        _logEntrySummary(2, resultMainnet, resultL2, false);

        // ── Human-readable L1 table ──
        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (3 entries) ===");
        _logEntry(0, h0, l1[0].stateDeltas, _fmtCall(callFwd), _fmtResult(resultL2, "(void)"));
        _logEntry(1, h1, l1[1].stateDeltas, _fmtCall(callClaim), _fmtCall(callRetScoped));
        _logEntry(2, h2, l1[2].stateDeltas, _fmtResult(resultMainnet, "(void)  [MAINNET]"), _fmtResult(resultL2, "(void)"));

        // ── Human-readable L2 table ──
        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (3 entries) ===");
        _logL2Entry(0, l2h0, _fmtResult(resultL2, "(void)  [L2]"), _fmtCall(callClaim));
        _logL2Entry(1, l2h1, _fmtCall(callRetUnscoped), _fmtResult(resultMainnet, "(void)  [MAINNET]"));
        _logL2Entry(2, l2h2, _fmtResult(resultL2, "(void)  [L2]"), _fmtResult(resultL2, "(void)  (terminal)"));

        // ── Human-readable L2 calls ──
        console.log("");
        console.log("=== EXPECTED L2 CALLS (1 call) ===");
        _logL2Call(0, callForwardHash, callFwd);
    }
}
