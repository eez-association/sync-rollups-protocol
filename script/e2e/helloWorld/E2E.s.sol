// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title HelloWorld E2E — Simple L1 → L2 cross-chain greeting
/// @dev Flow:
///
///   L1 (User) --> HelloWorldL1.helloL2World()
///                     |
///                     v
///                 l2Proxy.getWord()  -- cross-chain -->  HelloWorldL2.getWord()
///                     |                                        |
///                     v                                   returns "World"
///               greeting = "Hello World! This is EEZ."

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {HelloWorldL1, HelloWorldL2, IHelloWorldL2} from "../../../test/mocks/helloword.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {getOrCreateProxy} from "../shared/E2EHelpers.sol";

// ──────────────────────────────────────────────
//  Actions Base — single source of truth
// ──────────────────────────────────────────────

abstract contract HelloWorldActions {
    uint256 internal constant L2_ROLLUP_ID = 1;
    uint256 internal constant MAINNET_ROLLUP_ID = 0;

    function _callAction(address helloWorldL2, address helloWorldL1) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: helloWorldL2,
            value: 0,
            data: abi.encodeWithSelector(HelloWorldL2.getWord.selector),
            failed: false,
            sourceAddress: helloWorldL1,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });
    }

    function _resultAction() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: abi.encode("World"),
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    function _l1Entries(address helloWorldL2, address helloWorldL1)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        Action memory call_ = _callAction(helloWorldL2, helloWorldL1);
        Action memory result = _resultAction();

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-helloworld"),
            etherDelta: 0
        });

        entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = keccak256(abi.encode(call_));
        entries[0].nextAction = result;
    }

    function _l2Entries() internal pure returns (ExecutionEntry[] memory entries) {
        Action memory result = _resultAction();

        entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = new StateDelta[](0);
        entries[0].actionHash = keccak256(abi.encode(result));
        entries[0].nextAction = result;
    }
}

// ──────────────────────────────────────────────
//  Batcher — postBatch + user call in one tx
// ──────────────────────────────────────────────

contract Batcher {
    function execute(Rollups rollups, ExecutionEntry[] calldata entries, HelloWorldL1 helloWorld)
        external
        returns (string memory)
    {
        rollups.postBatch(entries, 0, "", "proof");
        return helloWorld.helloL2World();
    }
}

// ──────────────────────────────────────────────
//  Deploy contracts
// ──────────────────────────────────────────────

/// @title DeployL2 — Deploy HelloWorldL2 on L2
/// Outputs: HELLO_WORLD_L2
contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();

        HelloWorldL2 helloL2 = new HelloWorldL2("World");
        console.log("HELLO_WORLD_L2=%s", address(helloL2));

        vm.stopBroadcast();
    }
}

/// @title Deploy — Deploy HelloWorldL1 on L1 + create proxy for HelloWorldL2
/// @dev Env: ROLLUPS, HELLO_WORLD_L2
/// Outputs: HELLO_PROXY_L1, HELLO_WORLD_L1
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address helloWorldL2Addr = vm.envAddress("HELLO_WORLD_L2");

        vm.startBroadcast();

        Rollups rollups = Rollups(rollupsAddr);

        address helloProxy = getOrCreateProxy(rollups, helloWorldL2Addr, 1);
        HelloWorldL1 helloL1 = new HelloWorldL1(helloProxy);

        console.log("HELLO_PROXY_L1=%s", helloProxy);
        console.log("HELLO_WORLD_L1=%s", address(helloL1));

        vm.stopBroadcast();
    }
}

// ──────────────────────────────────────────────
//  ExecuteL2 — Load L2 table + executeIncomingCrossChainCall
// ──────────────────────────────────────────────

/// @dev Env: MANAGER_L2, HELLO_WORLD_L2, HELLO_WORLD_L1
contract ExecuteL2 is Script, HelloWorldActions {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address helloWorldL2Addr = vm.envAddress("HELLO_WORLD_L2");
        address helloWorldL1Addr = vm.envAddress("HELLO_WORLD_L1");

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        vm.startBroadcast();

        manager.loadExecutionTable(_l2Entries());

        manager.executeIncomingCrossChainCall(
            helloWorldL2Addr,
            0,
            abi.encodeWithSelector(HelloWorldL2.getWord.selector),
            helloWorldL1Addr,
            MAINNET_ROLLUP_ID,
            new uint256[](0)
        );

        console.log("done");

        vm.stopBroadcast();
    }
}

// ──────────────────────────────────────────────
//  Execute — Local mode L1 (Batcher)
// ──────────────────────────────────────────────

/// @dev Env: ROLLUPS, HELLO_WORLD_L2, HELLO_WORLD_L1
contract Execute is Script, HelloWorldActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address helloWorldL2Addr = vm.envAddress("HELLO_WORLD_L2");
        address helloWorldL1Addr = vm.envAddress("HELLO_WORLD_L1");

        vm.startBroadcast();

        Batcher batcher = new Batcher();
        string memory greeting =
            batcher.execute(Rollups(rollupsAddr), _l1Entries(helloWorldL2Addr, helloWorldL1Addr), HelloWorldL1(helloWorldL1Addr));

        console.log("done");
        console.log("greeting=%s", greeting);
        console.log("lastGreeting=%s", HelloWorldL1(helloWorldL1Addr).lastGreeting());

        vm.stopBroadcast();
    }
}

// ──────────────────────────────────────────────
//  ExecuteNetwork — Network mode
// ──────────────────────────────────────────────

/// @dev Env: HELLO_WORLD_L1
contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("HELLO_WORLD_L1");
        bytes memory data = abi.encodeWithSelector(HelloWorldL1.helloL2World.selector);
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

// ──────────────────────────────────────────────
//  ComputeExpected — Expected entry hashes
// ──────────────────────────────────────────────

/// @dev Env: HELLO_WORLD_L2, HELLO_WORLD_L1
contract ComputeExpected is ComputeExpectedBase, HelloWorldActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("HELLO_WORLD_L2")) return "HelloWorldL2";
        if (a == vm.envAddress("HELLO_WORLD_L1")) return "HelloWorldL1";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == HelloWorldL2.getWord.selector) return "getWord";
        if (sel == HelloWorldL1.helloL2World.selector) return "helloL2World";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address helloWorldL2Addr = vm.envAddress("HELLO_WORLD_L2");
        address helloWorldL1Addr = vm.envAddress("HELLO_WORLD_L1");

        // Actions (single source of truth)
        Action memory callAction = _callAction(helloWorldL2Addr, helloWorldL1Addr);
        Action memory resultAction = _resultAction();

        // Entries (single source of truth)
        ExecutionEntry[] memory l1 = _l1Entries(helloWorldL2Addr, helloWorldL1Addr);
        ExecutionEntry[] memory l2 = _l2Entries();

        // Compute hashes from entries
        bytes32 l1Hash = _entryHash(l1[0].actionHash, l1[0].nextAction);
        bytes32 l2Hash = _entryHash(l2[0].actionHash, l2[0].nextAction);
        bytes32 callActionHash = l1[0].actionHash;

        // Parseable lines
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(callActionHash));

        // Summary
        console.log("");
        console.log("=== EXPECTED SUMMARY ===");
        _logEntrySummary(0, callAction, resultAction, false);

        // Human-readable: L1 execution table
        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (1 entry) ===");
        _logEntry(0, l1Hash, l1[0].stateDeltas, _fmtCall(callAction), _fmtResult(resultAction, "string(World)"));

        // Human-readable: L2 execution table
        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (1 entry) ===");
        _logL2Entry(
            0,
            l2Hash,
            _fmtResult(resultAction, "string(World)"),
            string.concat(_fmtResult(resultAction, "string(World)"), "  (terminal)")
        );

        // Human-readable: L2 calls
        console.log("");
        console.log("=== EXPECTED L2 CALLS (1 call) ===");
        _logL2Call(0, callActionHash, callAction);
    }
}
