// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title StaticCall E2E — Cross-chain STATICCALL lookup
/// @dev Two flows exercised in a single L1 Batcher tx:
///
///   Flow A: PriceReader.readPrice(oracleProxy)
///     oracleProxy.staticcall(price()) -> staticCallLookup -> 42
///
///   Flow B: Combiner.combine(oracleProxy)
///     oracleProxy.staticcall(price()) -> staticCallLookup -> 42
///     oracleProxy.call(bump())         -> executeCrossChainCall -> 7
///     returns 42 + 7 = 49
///
/// TODO: Flow C — static call whose returnData depends on a sub-call through another proxy.
///                Parallel to `test_StaticFlatten_HappyPath` in test/StaticCall.t.sol. Left as a
///                follow-up to keep this phase focused on the struct-shape migration; the test-
///                suite Flow C equivalent already covers the on-chain semantics.

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {
    Action,
    ActionType,
    ExecutionEntry,
    StateDelta,
    StaticCall,
    StaticSubCall,
    RollupStateRoot
} from "../../../src/ICrossChainManager.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {getOrCreateProxy} from "../shared/E2EHelpers.sol";

// ──────────────────────────────────────────────
//  Inline mocks
// ──────────────────────────────────────────────

contract OracleL2 {
    function price() external pure returns (uint256) {
        return 42;
    }

    function bump() external pure returns (uint256) {
        return 7;
    }
}

contract PriceReader {
    function readPrice(address oracleProxy) external view returns (uint256) {
        (bool ok, bytes memory ret) = oracleProxy.staticcall(abi.encodeWithSelector(OracleL2.price.selector));
        require(ok, "static lookup failed");
        uint256 p = abi.decode(ret, (uint256));
        require(p == 42, "bad price");
        return p;
    }
}

contract Combiner {
    function combine(address oracleProxy) external returns (uint256) {
        (bool s, bytes memory rs) = oracleProxy.staticcall(abi.encodeWithSelector(OracleL2.price.selector));
        require(s, "static failed");
        uint256 p = abi.decode(rs, (uint256));
        require(p == 42, "bad static price");

        (bool c, bytes memory rc) = oracleProxy.call(abi.encodeWithSelector(OracleL2.bump.selector));
        require(c, "outer call failed");
        uint256 b = abi.decode(rc, (uint256));
        require(b == 7, "bad bump");

        return p + b;
    }
}

// ──────────────────────────────────────────────
//  Actions Base — single source of truth
// ──────────────────────────────────────────────

abstract contract StaticCallActions {
    uint256 internal constant L2_ROLLUP_ID = 1;
    uint256 internal constant MAINNET_ROLLUP_ID = 0;

    function _priceStaticAction(address oracleL2, address source) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: oracleL2,
            value: 0,
            data: abi.encodeWithSelector(OracleL2.price.selector),
            failed: false,
            isStatic: true,
            sourceAddress: source,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });
    }

    function _bumpCallAction(address oracleL2, address combiner) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: oracleL2,
            value: 0,
            data: abi.encodeWithSelector(OracleL2.bump.selector),
            failed: false,
            isStatic: false,
            sourceAddress: combiner,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });
    }

    function _bumpResultAction() internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.RESULT,
            rollupId: L2_ROLLUP_ID,
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(7)),
            failed: false,
            isStatic: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });
    }

    function _l1Entries(address oracleL2, address combiner)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        Action memory call_ = _bumpCallAction(oracleL2, combiner);
        Action memory result = _bumpResultAction();

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-bump"),
            etherDelta: 0
        });

        entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = keccak256(abi.encode(call_));
        entries[0].nextAction = result;
    }

    function _staticCalls(address oracleL2, address priceReader, address combiner)
        internal
        pure
        returns (StaticCall[] memory sc)
    {
        Action memory aReader = _priceStaticAction(oracleL2, priceReader);
        Action memory aCombiner = _priceStaticAction(oracleL2, combiner);

        sc = new StaticCall[](2);
        sc[0] = StaticCall({
            actionHash: keccak256(abi.encode(aReader)),
            returnData: abi.encode(uint256(42)),
            failed: false,
            calls: new StaticSubCall[](0),
            rollingHash: bytes32(0),
            stateRoots: new RollupStateRoot[](0)
        });
        sc[1] = StaticCall({
            actionHash: keccak256(abi.encode(aCombiner)),
            returnData: abi.encode(uint256(42)),
            failed: false,
            calls: new StaticSubCall[](0),
            rollingHash: bytes32(0),
            stateRoots: new RollupStateRoot[](0)
        });
    }

    // ──────────────────────────────────────────────
    //  Canonical hashing helpers — must mirror Rollups._hashStaticCall byte-for-byte
    // ──────────────────────────────────────────────

    function _hashSubCalls(StaticSubCall[] memory calls) internal pure returns (bytes32 h) {
        for (uint256 i = 0; i < calls.length; i++) {
            h = keccak256(
                abi.encodePacked(
                    h,
                    calls[i].destination,
                    keccak256(calls[i].data),
                    calls[i].sourceAddress,
                    calls[i].sourceRollup
                )
            );
        }
    }

    function _hashStateRoots(RollupStateRoot[] memory roots) internal pure returns (bytes32 h) {
        for (uint256 i = 0; i < roots.length; i++) {
            h = keccak256(abi.encodePacked(h, roots[i].rollupId, roots[i].stateRoot));
        }
    }

    function _hashStaticCall(StaticCall memory sc) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                sc.actionHash,
                keccak256(sc.returnData),
                sc.failed,
                _hashSubCalls(sc.calls),
                sc.rollingHash,
                _hashStateRoots(sc.stateRoots)
            )
        );
    }

    function _foldStaticCallsDigest(StaticCall[] memory scs) internal pure returns (bytes32 d) {
        for (uint256 i = 0; i < scs.length; i++) {
            d = keccak256(abi.encodePacked(d, _hashStaticCall(scs[i])));
        }
    }
}

// ──────────────────────────────────────────────
//  Batcher — postBatch + user calls in one tx
// ──────────────────────────────────────────────

contract Batcher {
    function execute(
        Rollups rollups,
        ExecutionEntry[] calldata entries,
        StaticCall[] calldata sc,
        PriceReader reader,
        Combiner combiner,
        address oracleProxy
    ) external returns (uint256 priceA, uint256 resultB) {
        rollups.postBatch(entries, sc, 0, "", "proof");
        priceA = reader.readPrice(oracleProxy);
        resultB = combiner.combine(oracleProxy);
    }
}

// ──────────────────────────────────────────────
//  DeployL2 — Deploy OracleL2 on L2
// ──────────────────────────────────────────────

/// Outputs: ORACLE_L2
contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();

        OracleL2 oracleL2 = new OracleL2();
        console.log("ORACLE_L2=%s", address(oracleL2));

        vm.stopBroadcast();
    }
}

// ──────────────────────────────────────────────
//  Deploy — Deploy PriceReader + Combiner on L1 + create proxy for OracleL2
// ──────────────────────────────────────────────

/// @dev Env: ROLLUPS, ORACLE_L2
/// Outputs: ORACLE_PROXY_L1, PRICE_READER, COMBINER
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address oracleL2Addr = vm.envAddress("ORACLE_L2");

        vm.startBroadcast();

        Rollups rollups = Rollups(rollupsAddr);

        address oracleProxy = getOrCreateProxy(rollups, oracleL2Addr, 1);
        PriceReader reader = new PriceReader();
        Combiner combiner = new Combiner();

        console.log("ORACLE_PROXY_L1=%s", oracleProxy);
        console.log("PRICE_READER=%s", address(reader));
        console.log("COMBINER=%s", address(combiner));

        vm.stopBroadcast();
    }
}

// ──────────────────────────────────────────────
//  ExecuteL2 — Load empty L2 tables (no L2 execution required for this scenario)
// ──────────────────────────────────────────────

/// @dev Env: MANAGER_L2
contract ExecuteL2 is Script {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");

        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2Addr);

        vm.startBroadcast();

        manager.loadExecutionTable(new ExecutionEntry[](0), new StaticCall[](0));

        console.log("done");

        vm.stopBroadcast();
    }
}

// ──────────────────────────────────────────────
//  Execute — Local mode L1 (Batcher)
// ──────────────────────────────────────────────

/// @dev Env: ROLLUPS, ORACLE_L2, ORACLE_PROXY_L1, PRICE_READER, COMBINER
contract Execute is Script, StaticCallActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address oracleL2Addr = vm.envAddress("ORACLE_L2");
        address oracleProxy = vm.envAddress("ORACLE_PROXY_L1");
        address priceReaderAddr = vm.envAddress("PRICE_READER");
        address combinerAddr = vm.envAddress("COMBINER");

        vm.startBroadcast();

        Batcher batcher = new Batcher();
        (uint256 priceA, uint256 resultB) = batcher.execute(
            Rollups(rollupsAddr),
            _l1Entries(oracleL2Addr, combinerAddr),
            _staticCalls(oracleL2Addr, priceReaderAddr, combinerAddr),
            PriceReader(priceReaderAddr),
            Combiner(combinerAddr),
            oracleProxy
        );

        require(priceA == 42, "priceA != 42");
        require(resultB == 49, "resultB != 49");

        console.log("priceA=%s", priceA);
        console.log("resultB=%s", resultB);
        console.log("done");

        vm.stopBroadcast();
    }
}

// ──────────────────────────────────────────────
//  ExecuteNetwork — Network mode
// ──────────────────────────────────────────────

/// @dev Env: COMBINER, ORACLE_PROXY_L1
contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("COMBINER");
        address oracleProxy = vm.envAddress("ORACLE_PROXY_L1");
        bytes memory data = abi.encodeWithSelector(Combiner.combine.selector, oracleProxy);
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

// ──────────────────────────────────────────────
//  ComputeExpected — Expected entry hashes
// ──────────────────────────────────────────────

/// @dev Env: ORACLE_L2, ORACLE_PROXY_L1, PRICE_READER, COMBINER
contract ComputeExpected is ComputeExpectedBase, StaticCallActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("ORACLE_L2")) return "OracleL2";
        if (a == vm.envAddress("PRICE_READER")) return "PriceReader";
        if (a == vm.envAddress("COMBINER")) return "Combiner";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == OracleL2.price.selector) return "price";
        if (sel == OracleL2.bump.selector) return "bump";
        if (sel == PriceReader.readPrice.selector) return "readPrice";
        if (sel == Combiner.combine.selector) return "combine";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address oracleL2Addr = vm.envAddress("ORACLE_L2");
        address priceReaderAddr = vm.envAddress("PRICE_READER");
        address combinerAddr = vm.envAddress("COMBINER");

        // Actions
        Action memory bumpCall = _bumpCallAction(oracleL2Addr, combinerAddr);
        Action memory bumpResult = _bumpResultAction();
        Action memory priceStaticReader = _priceStaticAction(oracleL2Addr, priceReaderAddr);
        Action memory priceStaticCombiner = _priceStaticAction(oracleL2Addr, combinerAddr);

        // Entries + static calls
        ExecutionEntry[] memory l1 = _l1Entries(oracleL2Addr, combinerAddr);
        StaticCall[] memory sc = _staticCalls(oracleL2Addr, priceReaderAddr, combinerAddr);

        bytes32 l1Hash = _entryHash(l1[0].actionHash, l1[0].nextAction);

        // Parseable lines
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("EXPECTED_STATIC_HASHES=[%s,%s]", vm.toString(sc[0].actionHash), vm.toString(sc[1].actionHash));

        // Summary
        console.log("");
        console.log("=== EXPECTED SUMMARY ===");
        _logEntrySummary(0, bumpCall, bumpResult, false);

        // Human-readable: L1 execution table
        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (1 entry) ===");
        _logEntry(0, l1Hash, l1[0].stateDeltas, _fmtCall(bumpCall), _fmtResult(bumpResult, "uint256(7)"));

        // Human-readable: static calls
        console.log("");
        console.log("=== EXPECTED STATIC CALLS (2 entries) ===");
        _logL2Call(0, sc[0].actionHash, priceStaticReader);
        _logL2Call(1, sc[1].actionHash, priceStaticCombiner);
    }
}
