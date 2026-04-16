// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title StaticCall E2E — Cross-chain STATICCALL lookup
/// @dev Three flows exercised in a single L1 Batcher tx:
///
///   Flow A: PriceReader.readPrice(oracleProxy)
///     oracleProxy.staticcall(price()) -> staticCallLookup -> 42
///
///   Flow B: Combiner.combine(oracleProxy)
///     oracleProxy.staticcall(price()) -> staticCallLookup -> 42
///     oracleProxy.call(bump())         -> executeCrossChainCall -> 7
///     returns 42 + 7 = 49
///
///   Flow C: derivedProxy.staticcall(getDerivedPrice())
///     staticCallLookup matches the DerivedPriceReaderL2 outer entry (returnData = abi.encode(84))
///       whose `calls` list declares two sub-call STATICCALL dependencies:
///         (1) oracleProxy.price()  -> inner staticCallLookup -> abi.encode(42)
///         (2) scaleProxy.scale()   -> inner staticCallLookup -> abi.encode(2)
///     `_processNStaticCalls` re-runs both sub-calls through the sub-call source proxy, folds
///     (success=true, rawReturnData) into the rolling hash, and compares it to `rollingHash`.
///     Returns 84 (= 42 * 2).

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

/// @notice L2 view returning a constant scale factor — only its address matters on L1 (action hashing).
contract ScaleFactorL2 {
    function scale() external pure returns (uint256) {
        return 2;
    }
}

/// @notice Placeholder for the L2 view whose returnData is derived from sub-calls.
///         Never actually executed — only its address is needed as the outer CALL destination
///         so `_hashOuterDerivedAction` matches what the Batcher's staticcall will hash.
contract DerivedPriceReaderL2 {
    function getDerivedPrice() external pure returns (uint256) {
        return 84;
    }
}

contract PriceReader {
    function readPrice(address oracleProxy) external view returns (uint256) {
        // Cap forwarded gas: the proxy's static-detection self-call burns 63/64 of whatever
        // is forwarded (StateChangeDuringStaticCall consumes the full allowance). Without an
        // explicit cap, `.staticcall` forwards all-but-64th of the caller's gas, which can
        // push the tx above the block gas limit during estimation.
        (bool ok, bytes memory ret) =
            oracleProxy.staticcall{gas: 2_000_000}(abi.encodeWithSelector(OracleL2.price.selector));
        require(ok, "static lookup failed");
        uint256 p = abi.decode(ret, (uint256));
        require(p == 42, "bad price");
        return p;
    }
}

/// @notice L1 wrapper that performs the outer STATICCALL into the DerivedPriceReaderL2 proxy.
///         Its address is the `sourceAddress` in the outer StaticCall entry.
contract DerivedReader {
    function readDerivedPrice(address derivedProxy) external view returns (uint256) {
        // Forward a large explicit gas budget: the outer lookup recurses through two nested
        // STATICCALL -> staticCallLookup frames (one per sub-call), and each hop sheds 1/64 of
        // the forwarded gas. Default Solidity `.staticcall()` forwards all-but-one-64th of
        // remaining, but forge's eth_estimateGas can under-allocate the enclosing tx so the
        // inner frames OOG. Passing a generous floor ensures the recursion completes.
        (bool ok, bytes memory ret) = derivedProxy.staticcall{gas: 50_000_000}(
            abi.encodeWithSelector(DerivedPriceReaderL2.getDerivedPrice.selector)
        );
        require(ok, "outer derived lookup failed");
        uint256 v = abi.decode(ret, (uint256));
        require(v == 84, "bad derived price");
        return v;
    }
}

contract Combiner {
    function combine(address oracleProxy) external returns (uint256) {
        // Cap forwarded gas for the static leg (see PriceReader.readPrice comment).
        (bool s, bytes memory rs) =
            oracleProxy.staticcall{gas: 2_000_000}(abi.encodeWithSelector(OracleL2.price.selector));
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
    //  Flow C — nested static sub-call dependencies
    // ──────────────────────────────────────────────

    /// @dev Outer action: DerivedReader.staticcall(derivedProxy.getDerivedPrice()).
    ///      rollupId = DerivedPriceReaderL2's original rollup (L2).
    function _derivedOuterAction(address derivedL2, address derivedReader) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: derivedL2,
            value: 0,
            data: abi.encodeWithSelector(DerivedPriceReaderL2.getDerivedPrice.selector),
            failed: false,
            isStatic: true,
            sourceAddress: derivedReader,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });
    }

    /// @dev Inner action reconstructed by staticCallLookup when a sub-call hits an authorized proxy.
    ///      When `_processNStaticCalls` replays a sub-call via `derivedSourceProxy`, msg.sender at
    ///      the inner proxy is `derivedSourceProxy` — the manager will hash an Action with
    ///      sourceAddress = derivedSourceProxy, sourceRollup = MAINNET_ROLLUP_ID.
    function _innerLookupAction(address destL2, bytes4 sel, address derivedSourceProxy)
        internal
        pure
        returns (Action memory)
    {
        return Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: destL2,
            value: 0,
            data: abi.encodeWithSelector(sel),
            failed: false,
            isStatic: true,
            sourceAddress: derivedSourceProxy,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });
    }

    /// @dev Folds sub-call (success, rawReturnData) into the rolling keccak chain matching
    ///      `Rollups._processNStaticCalls`. For proxy-routed sub-calls whose inner staticCallLookup
    ///      returns `abi.encode(x)`, the raw bytes folded in are exactly those 32 bytes.
    function _derivedRollingHash() internal pure returns (bytes32) {
        bytes32 h = keccak256(abi.encodePacked(bytes32(0), true, abi.encode(uint256(42))));
        h = keccak256(abi.encodePacked(h, true, abi.encode(uint256(2))));
        return h;
    }

    /// @dev Outer + two inner StaticCall entries for Flow C. `derivedSourceProxy` is the address
    ///      that both inner lookups see as msg.sender (= compute(DerivedReader, MAINNET)).
    function _derivedStaticCalls(
        address oracleL2,
        address scaleL2,
        address derivedL2,
        address derivedReader,
        address derivedSourceProxy,
        address oracleProxy,
        address scaleProxy
    ) internal pure returns (StaticCall[] memory sc) {
        Action memory outer = _derivedOuterAction(derivedL2, derivedReader);
        Action memory innerPrice = _innerLookupAction(oracleL2, OracleL2.price.selector, derivedSourceProxy);
        Action memory innerScale = _innerLookupAction(scaleL2, ScaleFactorL2.scale.selector, derivedSourceProxy);

        StaticSubCall[] memory subs = new StaticSubCall[](2);
        subs[0] = StaticSubCall({
            destination: oracleProxy,
            data: abi.encodeWithSelector(OracleL2.price.selector),
            sourceAddress: derivedReader,
            sourceRollup: MAINNET_ROLLUP_ID
        });
        subs[1] = StaticSubCall({
            destination: scaleProxy,
            data: abi.encodeWithSelector(ScaleFactorL2.scale.selector),
            sourceAddress: derivedReader,
            sourceRollup: MAINNET_ROLLUP_ID
        });

        sc = new StaticCall[](3);
        sc[0] = StaticCall({
            actionHash: keccak256(abi.encode(outer)),
            returnData: abi.encode(uint256(84)),
            failed: false,
            calls: subs,
            rollingHash: _derivedRollingHash(),
            stateRoots: new RollupStateRoot[](0)
        });
        sc[1] = StaticCall({
            actionHash: keccak256(abi.encode(innerPrice)),
            returnData: abi.encode(uint256(42)),
            failed: false,
            calls: new StaticSubCall[](0),
            rollingHash: bytes32(0),
            stateRoots: new RollupStateRoot[](0)
        });
        sc[2] = StaticCall({
            actionHash: keccak256(abi.encode(innerScale)),
            returnData: abi.encode(uint256(2)),
            failed: false,
            calls: new StaticSubCall[](0),
            rollingHash: bytes32(0),
            stateRoots: new RollupStateRoot[](0)
        });
    }

    /// @dev Concatenate the existing Flow A/B static calls with the Flow C entries.
    function _allStaticCalls(
        address oracleL2,
        address priceReader,
        address combiner,
        address scaleL2,
        address derivedL2,
        address derivedReader,
        address derivedSourceProxy,
        address oracleProxy,
        address scaleProxy
    ) internal pure returns (StaticCall[] memory out) {
        StaticCall[] memory ab = _staticCalls(oracleL2, priceReader, combiner);
        StaticCall[] memory c = _derivedStaticCalls(
            oracleL2, scaleL2, derivedL2, derivedReader, derivedSourceProxy, oracleProxy, scaleProxy
        );
        out = new StaticCall[](ab.length + c.length);
        for (uint256 i = 0; i < ab.length; i++) out[i] = ab[i];
        for (uint256 j = 0; j < c.length; j++) out[ab.length + j] = c[j];
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

/// Outputs: ORACLE_L2, SCALE_L2, DERIVED_L2
contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();

        OracleL2 oracleL2 = new OracleL2();
        ScaleFactorL2 scaleL2 = new ScaleFactorL2();
        DerivedPriceReaderL2 derivedL2 = new DerivedPriceReaderL2();
        console.log("ORACLE_L2=%s", address(oracleL2));
        console.log("SCALE_L2=%s", address(scaleL2));
        console.log("DERIVED_L2=%s", address(derivedL2));

        vm.stopBroadcast();
    }
}

// ──────────────────────────────────────────────
//  Deploy — Deploy PriceReader + Combiner on L1 + create proxy for OracleL2
// ──────────────────────────────────────────────

/// @dev Env: ROLLUPS, ORACLE_L2, SCALE_L2, DERIVED_L2
/// Outputs: ORACLE_PROXY_L1, SCALE_PROXY_L1, DERIVED_PROXY_L1, PRICE_READER, COMBINER,
///          DERIVED_READER, DERIVED_SOURCE_PROXY
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address oracleL2Addr = vm.envAddress("ORACLE_L2");
        address scaleL2Addr = vm.envAddress("SCALE_L2");
        address derivedL2Addr = vm.envAddress("DERIVED_L2");

        vm.startBroadcast();

        Rollups rollups = Rollups(rollupsAddr);

        address oracleProxy = getOrCreateProxy(rollups, oracleL2Addr, 1);
        address scaleProxy = getOrCreateProxy(rollups, scaleL2Addr, 1);
        address derivedProxy = getOrCreateProxy(rollups, derivedL2Addr, 1);
        PriceReader reader = new PriceReader();
        Combiner combiner = new Combiner();
        DerivedReader derivedReader = new DerivedReader();

        // Sub-call replay in `_processNStaticCalls` needs a deployed source proxy for
        // (DerivedReader, MAINNET_ROLLUP_ID=0). Register it up-front.
        address derivedSourceProxy = getOrCreateProxy(rollups, address(derivedReader), 0);

        console.log("ORACLE_PROXY_L1=%s", oracleProxy);
        console.log("SCALE_PROXY_L1=%s", scaleProxy);
        console.log("DERIVED_PROXY_L1=%s", derivedProxy);
        console.log("PRICE_READER=%s", address(reader));
        console.log("COMBINER=%s", address(combiner));
        console.log("DERIVED_READER=%s", address(derivedReader));
        console.log("DERIVED_SOURCE_PROXY=%s", derivedSourceProxy);

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

/// @dev Env: ROLLUPS, ORACLE_L2, SCALE_L2, DERIVED_L2, ORACLE_PROXY_L1, SCALE_PROXY_L1,
///      DERIVED_PROXY_L1, PRICE_READER, COMBINER, DERIVED_READER, DERIVED_SOURCE_PROXY
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

/// @dev Env: ORACLE_L2, SCALE_L2, DERIVED_L2, ORACLE_PROXY_L1, SCALE_PROXY_L1, DERIVED_PROXY_L1,
///      PRICE_READER, COMBINER, DERIVED_READER, DERIVED_SOURCE_PROXY
contract ComputeExpected is ComputeExpectedBase, StaticCallActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("ORACLE_L2")) return "OracleL2";
        if (a == vm.envAddress("SCALE_L2")) return "ScaleFactorL2";
        if (a == vm.envAddress("DERIVED_L2")) return "DerivedPriceReaderL2";
        if (a == vm.envAddress("PRICE_READER")) return "PriceReader";
        if (a == vm.envAddress("COMBINER")) return "Combiner";
        if (a == vm.envAddress("DERIVED_READER")) return "DerivedReader";
        if (a == vm.envAddress("DERIVED_SOURCE_PROXY")) return "DerivedSourceProxy";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == OracleL2.price.selector) return "price";
        if (sel == OracleL2.bump.selector) return "bump";
        if (sel == ScaleFactorL2.scale.selector) return "scale";
        if (sel == DerivedPriceReaderL2.getDerivedPrice.selector) return "getDerivedPrice";
        if (sel == PriceReader.readPrice.selector) return "readPrice";
        if (sel == Combiner.combine.selector) return "combine";
        if (sel == DerivedReader.readDerivedPrice.selector) return "readDerivedPrice";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address oracleL2Addr = vm.envAddress("ORACLE_L2");
        address scaleL2Addr = vm.envAddress("SCALE_L2");
        address derivedL2Addr = vm.envAddress("DERIVED_L2");
        address oracleProxy = vm.envAddress("ORACLE_PROXY_L1");
        address scaleProxy = vm.envAddress("SCALE_PROXY_L1");
        address priceReaderAddr = vm.envAddress("PRICE_READER");
        address combinerAddr = vm.envAddress("COMBINER");
        address derivedReaderAddr = vm.envAddress("DERIVED_READER");
        address derivedSourceProxy = vm.envAddress("DERIVED_SOURCE_PROXY");

        // Actions
        Action memory bumpCall = _bumpCallAction(oracleL2Addr, combinerAddr);
        Action memory bumpResult = _bumpResultAction();
        Action memory priceStaticReader = _priceStaticAction(oracleL2Addr, priceReaderAddr);
        Action memory priceStaticCombiner = _priceStaticAction(oracleL2Addr, combinerAddr);
        Action memory derivedOuter = _derivedOuterAction(derivedL2Addr, derivedReaderAddr);
        Action memory derivedInnerPrice =
            _innerLookupAction(oracleL2Addr, OracleL2.price.selector, derivedSourceProxy);
        Action memory derivedInnerScale =
            _innerLookupAction(scaleL2Addr, ScaleFactorL2.scale.selector, derivedSourceProxy);

        // Entries + static calls
        ExecutionEntry[] memory l1 = _l1Entries(oracleL2Addr, combinerAddr);
        StaticCall[] memory sc = _allStaticCalls(
            oracleL2Addr,
            priceReaderAddr,
            combinerAddr,
            scaleL2Addr,
            derivedL2Addr,
            derivedReaderAddr,
            derivedSourceProxy,
            oracleProxy,
            scaleProxy
        );

        bytes32 l1Hash = _entryHash(l1[0].actionHash, l1[0].nextAction);

        // Parseable lines
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log(
            string.concat(
                "EXPECTED_STATIC_HASHES=[",
                vm.toString(sc[0].actionHash),
                ",",
                vm.toString(sc[1].actionHash),
                ",",
                vm.toString(sc[2].actionHash),
                ",",
                vm.toString(sc[3].actionHash),
                ",",
                vm.toString(sc[4].actionHash),
                "]"
            )
        );
        console.log("EXPECTED_ROLLING_HASH=%s", vm.toString(_derivedRollingHash()));

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
        console.log("=== EXPECTED STATIC CALLS (5 entries) ===");
        _logL2Call(0, sc[0].actionHash, priceStaticReader);
        _logL2Call(1, sc[1].actionHash, priceStaticCombiner);
        _logL2Call(2, sc[2].actionHash, derivedOuter);
        _logL2Call(3, sc[3].actionHash, derivedInnerPrice);
        _logL2Call(4, sc[4].actionHash, derivedInnerScale);
    }
}
