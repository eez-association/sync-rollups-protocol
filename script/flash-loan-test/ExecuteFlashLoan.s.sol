// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../src/CrossChainManagerL2.sol";
import {Bridge} from "../../src/periphery/Bridge.sol";
import {FlashLoan} from "../../src/periphery/defiMock/FlashLoan.sol";
import {FlashLoanBridgeExecutor} from "../../src/periphery/defiMock/FlashLoanBridgeExecutor.sol";
import {Action, ActionType, ExecutionEntry, StaticCall, StateDelta} from "../../src/ICrossChainManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title ExecuteFlashLoanL2 — Load execution table + executeIncomingCrossChainCall on L2
/// @dev Usage:
///   forge script script/flash-loan-test/ExecuteFlashLoan.s.sol:ExecuteFlashLoanL2 \
///     --rpc-url $L2_RPC --broadcast --private-key $PK \
///     --sig "run(address,address,address,address,address,address,address,address,string,string,uint8)" \
///     $MANAGER_L2 $BRIDGE_L1 $BRIDGE_L2 $EXECUTOR_L1 $EXECUTOR_L2 $FLASH_LOANERS_NFT $TOKEN $WRAPPED_TOKEN_L2 $TOKEN_NAME $TOKEN_SYMBOL $TOKEN_DECIMALS
contract ExecuteFlashLoanL2 is Script {
    uint256 constant L2_ROLLUP_ID = 1;
    uint256 constant MAINNET_ROLLUP_ID = 0;

    function run(
        address managerL2,
        address bridgeL1,
        address bridgeL2,
        address executorL1,
        address executorL2,
        address flashLoanersNFT,
        address token,
        address wrappedTokenL2,
        string calldata name,
        string calldata symbol,
        uint8 tokenDecimals
    ) external {
        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2);

        // Forward receiveTokens: L1 → L2
        bytes memory fwdReceiveTokensCalldata = abi.encodeCall(
            Bridge.receiveTokens,
            (token, MAINNET_ROLLUP_ID, executorL2, 10_000e18, name, symbol, tokenDecimals, MAINNET_ROLLUP_ID)
        );

        // claimAndBridgeBack
        bytes memory claimAndBridgeBackCalldata = abi.encodeCall(
            FlashLoanBridgeExecutor.claimAndBridgeBack,
            (wrappedTokenL2, flashLoanersNFT, bridgeL2, MAINNET_ROLLUP_ID, executorL1, executorL2)
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

        manager.loadExecutionTable(l2Entries, new StaticCall[](0));
        console.log("L2 execution table loaded (3 entries)");

        // Single system call: receiveTokens + claimAndBridgeBack (chained)
        manager.executeIncomingCrossChainCall(
            bridgeL2, 0, fwdReceiveTokensCalldata, bridgeL1, MAINNET_ROLLUP_ID, new uint256[](0)
        );
        console.log("L2 execution complete");

        vm.stopBroadcast();
    }
}

/// @title FlashLoanBatcher — postBatch + executor.execute() in single tx
contract FlashLoanBatcher {
    function execute(
        Rollups rollups,
        ExecutionEntry[] calldata entries,
        FlashLoanBridgeExecutor executor
    ) external {
        rollups.postBatch(entries, new StaticCall[](0), 0, "", "proof");
        executor.execute();
    }
}

/// @title ExecuteFlashLoanL1 — Post batch entries + trigger flash loan (same block)
/// @dev Usage:
///   forge script script/flash-loan-test/ExecuteFlashLoan.s.sol:ExecuteFlashLoanL1 \
///     --rpc-url $L1_RPC --broadcast --private-key $PK \
///     --sig "run(address,address,address,address,address,address,address,address)" \
///     $ROLLUPS $BRIDGE_L1 $BRIDGE_L2 $EXECUTOR_L1 $EXECUTOR_L2 $FLASH_LOANERS_NFT $TOKEN $WRAPPED_TOKEN_L2
contract ExecuteFlashLoanL1 is Script {
    uint256 constant L2_ROLLUP_ID = 1;
    uint256 constant MAINNET_ROLLUP_ID = 0;

    function run(
        address rollupsAddr,
        address bridgeL1,
        address bridgeL2,
        address executorL1,
        address executorL2,
        address flashLoanersNFT,
        address token,
        address wrappedTokenL2
    ) external {
        Rollups rollups = Rollups(rollupsAddr);

        string memory name = ERC20(token).name();
        string memory symbol = ERC20(token).symbol();
        uint8 tokenDecimals = ERC20(token).decimals();

        // Forward receiveTokens: L1 → L2
        bytes memory fwdReceiveTokensCalldata = abi.encodeCall(
            Bridge.receiveTokens,
            (token, MAINNET_ROLLUP_ID, executorL2, 10_000e18, name, symbol, tokenDecimals, MAINNET_ROLLUP_ID)
        );

        // claimAndBridgeBack
        bytes memory claimAndBridgeBackCalldata = abi.encodeCall(
            FlashLoanBridgeExecutor.claimAndBridgeBack,
            (wrappedTokenL2, flashLoanersNFT, bridgeL2, MAINNET_ROLLUP_ID, executorL1, executorL2)
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

        // L1 CALL actions
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

        // 3 deferred entries
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

        // Batcher ensures postBatch + execute happen in the same block
        FlashLoanBatcher batcher = new FlashLoanBatcher();
        batcher.execute(rollups, entries, FlashLoanBridgeExecutor(executorL1));

        console.log("L1 execution complete");

        vm.stopBroadcast();
    }
}
