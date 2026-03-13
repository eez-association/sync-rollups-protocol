// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Bridge} from "../src/periphery/Bridge.sol";

/// @title BridgeDeployL1 — Deploy and initialize Bridge on L1
/// @dev Usage:
///   forge script script/DeployBridge.s.sol:BridgeDeployL1 \
///     --rpc-url $L1_RPC --broadcast --private-key $L1_PK \
///     --sig "run(address)" $ROLLUPS
contract BridgeDeployL1 is Script {
    function run(address rollups) external {
        vm.startBroadcast();

        Bridge bridge = new Bridge();
        bridge.initialize(rollups, 0, msg.sender);

        console.log("BRIDGE_L1=%s", address(bridge));

        vm.stopBroadcast();
    }
}

/// @title BridgeDeployL2 — Deploy and initialize Bridge on L2
/// @dev Usage:
///   forge script script/DeployBridge.s.sol:BridgeDeployL2 \
///     --rpc-url $L2_RPC --broadcast --private-key $L2_PK \
///     --sig "run(address,uint256,address)" $MANAGER_L2 $ROLLUP_ID $BRIDGE_L1
contract BridgeDeployL2 is Script {
    function run(address managerL2, uint256 rollupId, address bridgeL1) external {
        vm.startBroadcast();

        Bridge bridge = new Bridge();
        bridge.initialize(managerL2, rollupId, msg.sender);
        bridge.setCanonicalBridgeAddress(bridgeL1);

        console.log("BRIDGE_L2=%s", address(bridge));

        vm.stopBroadcast();
    }
}
