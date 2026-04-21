// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {IZKVerifier} from "../../../src/IZKVerifier.sol";

/// @notice Mock verifier that accepts all proofs.
contract AcceptAllVerifier is IZKVerifier {
    function verify(bytes calldata, bytes32) external pure override returns (bool) {
        return true;
    }
}

/// @title DeployRollupsL1
/// @notice Deploys AcceptAllVerifier + Rollups + creates L2 rollup (id=1).
/// Outputs: ROLLUPS, VERIFIER, L2_ROLLUP_ID
contract DeployRollupsL1 is Script {
    bytes32 constant DEFAULT_VK = keccak256("verificationKey");

    function run() external {
        vm.startBroadcast();

        AcceptAllVerifier verifier = new AcceptAllVerifier();
        Rollups rollups = new Rollups(address(verifier), 1);

        // Create L2 rollup with id=1
        rollups.createRollup(keccak256("l2-initial-state"), DEFAULT_VK, msg.sender);

        console.log("VERIFIER=%s", address(verifier));
        console.log("ROLLUPS=%s", address(rollups));
        console.log("L2_ROLLUP_ID=1");

        vm.stopBroadcast();
    }
}

/// @title DeployManagerL2
/// @notice Deploys CrossChainManagerL2 for the given rollup ID / system address.
/// Outputs: MANAGER_L2
contract DeployManagerL2 is Script {
    function run(uint256 rollupId, address systemAddress) external {
        vm.startBroadcast();
        CrossChainManagerL2 manager = new CrossChainManagerL2(rollupId, systemAddress);
        console.log("MANAGER_L2=%s", address(manager));
        vm.stopBroadcast();
    }
}
