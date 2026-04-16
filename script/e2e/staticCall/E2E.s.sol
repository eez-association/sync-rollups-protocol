// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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

// ═══════════════════════════════════════════════════════════════════════
//  staticCall — L1 -> L2 top-level static read (ONE flow)
//
//  Batcher(L1) --staticcall--> OracleL2'(proxy on L1)
//    --> Rollups.staticCallLookup matches pre-committed StaticCall
//    --> returns abi.encode(uint256(42))
//  No state changes, no L2 execution, no ExecutionEntries.
// ═══════════════════════════════════════════════════════════════════════

// ── App contracts ──

contract OracleL2 {
    function price() external pure returns (uint256) {
        return 42;
    }
}

contract PriceReader {
    function readPrice(address proxy) external view returns (uint256) {
        (bool ok, bytes memory ret) = proxy.staticcall(abi.encodeWithSelector(OracleL2.price.selector));
        require(ok, "staticcall failed");
        return abi.decode(ret, (uint256));
    }
}

// ── Actions base ──

abstract contract StaticCallActions {
    uint256 internal constant L2_ROLLUP_ID = 1;
    uint256 internal constant MAINNET_ROLLUP_ID = 0;

    function _staticCallAction(address oracleL2, address sourceAddr) internal pure returns (Action memory) {
        return Action({
            actionType: ActionType.CALL,
            rollupId: L2_ROLLUP_ID,
            destination: oracleL2,
            value: 0,
            data: abi.encodeWithSelector(OracleL2.price.selector),
            failed: false,
            isStatic: true,
            sourceAddress: sourceAddr,
            sourceRollup: MAINNET_ROLLUP_ID,
            scope: new uint256[](0)
        });
    }

    function _staticCalls(address oracleL2, address sourceAddr)
        internal
        pure
        returns (StaticCall[] memory scs)
    {
        Action memory action = _staticCallAction(oracleL2, sourceAddr);
        scs = new StaticCall[](1);
        scs[0].actionHash = keccak256(abi.encode(action));
        scs[0].returnData = abi.encode(uint256(42));
        scs[0].failed = false;
        scs[0].calls = new StaticSubCall[](0);
        scs[0].rollingHash = bytes32(0);
        scs[0].stateRoots = new RollupStateRoot[](0);
    }
}

// ── Batcher: postBatch + staticcall read in one tx ──

contract Batcher {
    function execute(
        Rollups rollups,
        StaticCall[] calldata staticCalls,
        PriceReader reader,
        address oracleProxy
    ) external returns (uint256) {
        rollups.postBatch(new ExecutionEntry[](0), staticCalls, 0, "", "proof");
        return reader.readPrice(oracleProxy);
    }
}

// ── Deploy contracts ──

contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        OracleL2 oracle = new OracleL2();
        console.log("ORACLE_L2=%s", address(oracle));
        vm.stopBroadcast();
    }
}

contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address oracleL2Addr = vm.envAddress("ORACLE_L2");

        vm.startBroadcast();

        Rollups rollups = Rollups(rollupsAddr);
        address oracleProxy = getOrCreateProxy(rollups, oracleL2Addr, 1);
        PriceReader reader = new PriceReader();

        console.log("ORACLE_PROXY=%s", oracleProxy);
        console.log("PRICE_READER=%s", address(reader));

        vm.stopBroadcast();
    }
}

// ── ExecuteL2 — load empty table (L2 not involved) ──

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

// ── Execute (L1) — single tx via pre-deployed Batcher ──

contract Execute is Script, StaticCallActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address oracleL2Addr = vm.envAddress("ORACLE_L2");
        address oracleProxyAddr = vm.envAddress("ORACLE_PROXY");
        address priceReaderAddr = vm.envAddress("PRICE_READER");

        vm.startBroadcast();

        // Create Batcher in Execute (same forge script tx — matches counter pattern)
        Batcher batcher = new Batcher();
        // sourceAddress = PriceReader (it's msg.sender when calling the proxy via readPrice)
        uint256 val = batcher.execute(
            Rollups(rollupsAddr),
            _staticCalls(oracleL2Addr, priceReaderAddr),
            PriceReader(priceReaderAddr),
            oracleProxyAddr
        );

        require(val == 42, "expected 42");
        console.log("done");
        console.log("price=%s", val);

        vm.stopBroadcast();
    }
}

// ── ExecuteNetwork ──

contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("PRICE_READER");
        bytes memory data = abi.encodeWithSelector(
            PriceReader.readPrice.selector, vm.envAddress("ORACLE_PROXY")
        );
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

// ── ComputeExpected ──

contract ComputeExpected is ComputeExpectedBase, StaticCallActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("ORACLE_L2")) return "OracleL2";
        if (a == vm.envAddress("PRICE_READER")) return "PriceReader";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == OracleL2.price.selector) return "price";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        console.log("EXPECTED_L1_HASHES=[]");
        console.log("EXPECTED_L2_HASHES=[]");
        console.log("EXPECTED_L2_CALL_HASHES=[]");

        address oracleL2Addr = vm.envAddress("ORACLE_L2");
        address priceReaderAddr = vm.envAddress("PRICE_READER");
        Action memory action = _staticCallAction(oracleL2Addr, priceReaderAddr);
        console.log("EXPECTED_STATIC_CALL_HASHES=[%s]", vm.toString(keccak256(abi.encode(action))));

        console.log("");
        console.log("=== STATIC CALL SUMMARY ===");
        console.log("  L1->L2 static read: OracleL2.price() = 42");
        console.log("  No execution entries. No state changes.");
    }
}
