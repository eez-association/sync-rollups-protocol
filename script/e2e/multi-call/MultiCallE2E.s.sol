// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainProxy} from "../../../src/CrossChainProxy.sol";
import {Action, ActionType, ExecutionEntry, StateDelta} from "../../../src/ICrossChainManager.sol";
import {Counter} from "../../../test/mocks/CounterContracts.sol";
import {CallTwice, CallTwoDifferent, ConditionalCallTwice} from "../../../test/mocks/MultiCallContracts.sol";

// ═══════════════════════════════════════════════════════════════════════
//  Batchers — wraps postBatch + user action in a single tx (same-block)
// ═══════════════════════════════════════════════════════════════════════

/// @notice Batcher for CallTwice: postBatch + callCounterTwice in one tx
contract CallTwiceBatcher {
    function execute(
        Rollups rollups,
        ExecutionEntry[] calldata entries,
        CallTwice app,
        address counterProxy
    ) external returns (uint256 first, uint256 second) {
        rollups.postBatch(entries, 0, "", "proof");
        (first, second) = app.callCounterTwice(counterProxy);
    }
}

/// @notice Batcher for CallTwoDifferent: postBatch + callBothCounters in one tx
contract CallTwoDiffBatcher {
    function execute(
        Rollups rollups,
        ExecutionEntry[] calldata entries,
        CallTwoDifferent app,
        address counterAProxy,
        address counterBProxy
    ) external returns (uint256 a, uint256 b) {
        rollups.postBatch(entries, 0, "", "proof");
        (a, b) = app.callBothCounters(counterAProxy, counterBProxy);
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Shared helpers
// ═══════════════════════════════════════════════════════════════════════

library MultiCallLib {
    /// @dev Build CALL action for a proxy call. Mirrors what executeCrossChainCall builds.
    function buildCallAction(
        address counterL2,
        address sourceContract,
        bytes memory incrementCallData
    ) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.CALL,
            rollupId: 1,
            destination: counterL2,
            value: 0,
            data: incrementCallData,
            failed: false,
            sourceAddress: sourceContract,
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    /// @dev Build RESULT action for a counter increment returning `value`.
    function buildResultAction(uint256 value) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: 1,
            destination: address(0),
            value: 0,
            data: abi.encode(value),
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

}

// ═══════════════════════════════════════════════════════════════════════
//  Deploy — all multi-call app contracts + proxies
// ═══════════════════════════════════════════════════════════════════════

/// @title MultiCallDeploy
/// @dev Deploys Counter (x2), CallTwice, CallTwoDifferent, and proxies.
///   forge script script/e2e/multi-call/MultiCallE2E.s.sol:MultiCallDeploy \
///     --rpc-url $RPC --broadcast --private-key $PK \
///     --sig "run(address)" $ROLLUPS
contract MultiCallDeploy is Script {
    function run(address rollupsAddr) external {
        vm.startBroadcast();

        Rollups rollups = Rollups(rollupsAddr);

        // Deploy L2 counters
        Counter counterA = new Counter();
        Counter counterB = new Counter();

        // Deploy L1 caller contracts
        CallTwice callTwice = new CallTwice();
        CallTwoDifferent callTwoDiff = new CallTwoDifferent();

        // Create proxies on L1 for both counters
        address proxyA = rollups.createCrossChainProxy(address(counterA), 1);
        address proxyB = rollups.createCrossChainProxy(address(counterB), 1);

        console.log("COUNTER_A=%s", address(counterA));
        console.log("COUNTER_B=%s", address(counterB));
        console.log("CALL_TWICE=%s", address(callTwice));
        console.log("CALL_TWO_DIFF=%s", address(callTwoDiff));
        console.log("PROXY_A=%s", proxyA);
        console.log("PROXY_B=%s", proxyB);

        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Execute — local mode (Batcher wraps postBatch + user action)
// ═══════════════════════════════════════════════════════════════════════

/// @title MultiCallExecuteCallTwice — Test A: same proxy called twice
///   forge script script/e2e/multi-call/MultiCallE2E.s.sol:MultiCallExecuteCallTwice \
///     --rpc-url $RPC --broadcast --private-key $PK \
///     --sig "run(address,address,address,address)" $ROLLUPS $COUNTER_A $CALL_TWICE $PROXY_A
contract MultiCallExecuteCallTwice is Script {
    function run(
        address rollupsAddr,
        address counterAAddr,
        address callTwiceAddr,
        address proxyAAddr
    ) external {
        vm.startBroadcast();

        CallTwiceBatcher batcher = new CallTwiceBatcher();
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // Both calls produce the SAME action: same source(CallTwice), dest(counterA), data(increment)
        Action memory callAction = MultiCallLib.buildCallAction(counterAAddr, callTwiceAddr, incrementCallData);
        Action memory result1 = MultiCallLib.buildResultAction(1);
        Action memory result2 = MultiCallLib.buildResultAction(2);

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-multicall-after-first");
        bytes32 s2 = keccak256("l2-state-multicall-after-second");

        // 2 entries with SAME action hash, DIFFERENT state deltas
        StateDelta[] memory deltas1 = new StateDelta[](1);
        deltas1[0] = StateDelta({ rollupId: 1, currentState: s0, newState: s1, etherDelta: 0 });

        StateDelta[] memory deltas2 = new StateDelta[](1);
        deltas2[0] = StateDelta({ rollupId: 1, currentState: s1, newState: s2, etherDelta: 0 });

        bytes32 actionHash = keccak256(abi.encode(callAction));

        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0].stateDeltas = deltas1;
        entries[0].actionHash = actionHash;
        entries[0].nextAction = result1;

        entries[1].stateDeltas = deltas2;
        entries[1].actionHash = actionHash;
        entries[1].nextAction = result2;

        (uint256 first, uint256 second) = batcher.execute(
            Rollups(rollupsAddr), entries, CallTwice(callTwiceAddr), proxyAAddr
        );

        console.log("done");
        console.log("first=%s", first);
        console.log("second=%s", second);

        vm.stopBroadcast();
    }
}

/// @title MultiCallExecuteTwoDiff — Test B: two different proxies
///   forge script script/e2e/multi-call/MultiCallE2E.s.sol:MultiCallExecuteTwoDiff \
///     --rpc-url $RPC --broadcast --private-key $PK \
///     --sig "run(address,address,address,address,address,address)" $ROLLUPS $COUNTER_A $COUNTER_B $CALL_TWO_DIFF $PROXY_A $PROXY_B
contract MultiCallExecuteTwoDiff is Script {
    function run(
        address rollupsAddr,
        address counterAAddr,
        address counterBAddr,
        address callTwoDiffAddr,
        address proxyAAddr,
        address proxyBAddr
    ) external {
        vm.startBroadcast();

        CallTwoDiffBatcher batcher = new CallTwoDiffBatcher();
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // Different destinations -> different action hashes
        Action memory callA = MultiCallLib.buildCallAction(counterAAddr, callTwoDiffAddr, incrementCallData);
        Action memory callB = MultiCallLib.buildCallAction(counterBAddr, callTwoDiffAddr, incrementCallData);
        Action memory result1 = MultiCallLib.buildResultAction(1);

        bytes32 s0 = keccak256("l2-initial-state");
        bytes32 s1 = keccak256("l2-state-twodiff-after-A");
        bytes32 s2 = keccak256("l2-state-twodiff-after-B");

        StateDelta[] memory deltas1 = new StateDelta[](1);
        deltas1[0] = StateDelta({ rollupId: 1, currentState: s0, newState: s1, etherDelta: 0 });

        StateDelta[] memory deltas2 = new StateDelta[](1);
        deltas2[0] = StateDelta({ rollupId: 1, currentState: s1, newState: s2, etherDelta: 0 });

        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0].stateDeltas = deltas1;
        entries[0].actionHash = keccak256(abi.encode(callA));
        entries[0].nextAction = result1;

        entries[1].stateDeltas = deltas2;
        entries[1].actionHash = keccak256(abi.encode(callB));
        entries[1].nextAction = result1;

        (uint256 a, uint256 b) = batcher.execute(
            Rollups(rollupsAddr), entries, CallTwoDifferent(callTwoDiffAddr), proxyAAddr, proxyBAddr
        );

        console.log("done");
        console.log("counterA=%s", a);
        console.log("counterB=%s", b);

        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Execute — network mode (no Batcher, system handles batch posting)
// ═══════════════════════════════════════════════════════════════════════

/// @title MultiCallExecuteNetworkCallTwice
///   forge script script/e2e/multi-call/MultiCallE2E.s.sol:MultiCallExecuteNetworkCallTwice \
///     --rpc-url $RPC --broadcast --private-key $PK \
///     --sig "run(address,address)" $CALL_TWICE $PROXY_A
contract MultiCallExecuteNetworkCallTwice is Script {
    function run(address callTwiceAddr, address proxyAAddr) external {
        vm.startBroadcast();
        CallTwice(callTwiceAddr).callCounterTwice(proxyAAddr);
        console.log("done");
        vm.stopBroadcast();
    }
}

/// @title MultiCallExecuteNetworkTwoDiff
///   forge script script/e2e/multi-call/MultiCallE2E.s.sol:MultiCallExecuteNetworkTwoDiff \
///     --rpc-url $RPC --broadcast --private-key $PK \
///     --sig "run(address,address,address)" $CALL_TWO_DIFF $PROXY_A $PROXY_B
contract MultiCallExecuteNetworkTwoDiff is Script {
    function run(address callTwoDiffAddr, address proxyAAddr, address proxyBAddr) external {
        vm.startBroadcast();
        CallTwoDifferent(callTwoDiffAddr).callBothCounters(proxyAAddr, proxyBAddr);
        console.log("done");
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected — compute expected hashes for verification
// ═══════════════════════════════════════════════════════════════════════

/// @title MultiCallComputeExpected — hashes for both scenarios
///   forge script script/e2e/multi-call/MultiCallE2E.s.sol:MultiCallComputeExpected \
///     --sig "run(address,address,address,address)" $COUNTER_A $COUNTER_B $CALL_TWICE $CALL_TWO_DIFF
contract MultiCallComputeExpected is Script {
    function run(
        address counterAAddr,
        address counterBAddr,
        address callTwiceAddr,
        address callTwoDiffAddr
    ) external pure {
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // ── CallTwice: same action hash appears twice ──
        Action memory callTwiceAction = MultiCallLib.buildCallAction(counterAAddr, callTwiceAddr, incrementCallData);
        bytes32 hashTwice = keccak256(abi.encode(callTwiceAction));

        // ── CallTwoDifferent: two different action hashes ──
        Action memory callDiffA = MultiCallLib.buildCallAction(counterAAddr, callTwoDiffAddr, incrementCallData);
        Action memory callDiffB = MultiCallLib.buildCallAction(counterBAddr, callTwoDiffAddr, incrementCallData);
        bytes32 hashDiffA = keccak256(abi.encode(callDiffA));
        bytes32 hashDiffB = keccak256(abi.encode(callDiffB));

        // Parseable lines
        console.log("HASH_CALL_TWICE=%s", vm.toString(hashTwice));
        console.log("HASH_DIFF_A=%s", vm.toString(hashDiffA));
        console.log("HASH_DIFF_B=%s", vm.toString(hashDiffB));

        // CallTwice expected hashes (same hash repeated for 2 entries)
        console.log("EXPECTED_HASHES_CALL_TWICE=[%s,%s]", vm.toString(hashTwice), vm.toString(hashTwice));

        // CallTwoDifferent expected hashes
        console.log("EXPECTED_HASHES_TWO_DIFF=[%s,%s]", vm.toString(hashDiffA), vm.toString(hashDiffB));

        // Human-readable tables
        console.log("");
        console.log("=== EXPECTED: CallTwice (2 entries, same action hash) ===");
        console.log("  [0] DEFERRED  actionHash: %s", vm.toString(hashTwice));
        console.log("      nextAction: RESULT(rollup 1, ok, data=encode(1))");
        console.log("  [1] DEFERRED  actionHash: %s", vm.toString(hashTwice));
        console.log("      nextAction: RESULT(rollup 1, ok, data=encode(2))");

        console.log("");
        console.log("=== EXPECTED: CallTwoDifferent (2 entries, different action hashes) ===");
        console.log("  [0] DEFERRED  actionHash: %s", vm.toString(hashDiffA));
        console.log("      nextAction: RESULT(rollup 1, ok, data=encode(1))");
        console.log("  [1] DEFERRED  actionHash: %s", vm.toString(hashDiffB));
        console.log("      nextAction: RESULT(rollup 1, ok, data=encode(1))");
    }
}
