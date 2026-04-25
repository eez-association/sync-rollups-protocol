// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {IProofSystem} from "../../../src/IProofSystem.sol";

contract MockZKVerifier is IProofSystem {
    function verify(bytes calldata, bytes32) external pure override returns (bool) {
        return true;
    }
}

/// @title DeployRollupsL1 — Deploy MockZKVerifier + Rollups + register validator + create L2 rollup
/// @dev Usage:
///   forge script script/e2e/shared/DeployInfra.s.sol:DeployRollupsL1 \
///     --rpc-url $L1_RPC --broadcast --private-key $PK
contract DeployRollupsL1 is Script {
    function run() external {
        vm.startBroadcast();

        MockZKVerifier proofSystem = new MockZKVerifier();
        Rollups rollups = new Rollups(1);
        rollups.registerProofSystem(IProofSystem(address(proofSystem)));

        rollups.createRollup(
            keccak256("l2-initial-state"),
            address(proofSystem),
            keccak256("verificationKey"),
            msg.sender
        );

        console.log("PROOF_SYSTEM=%s", address(proofSystem));
        console.log("ROLLUPS=%s", address(rollups));

        vm.stopBroadcast();
    }
}

/// @title DeployManagerL2 — Deploy CrossChainManagerL2
/// @dev Usage:
///   forge script script/e2e/shared/DeployInfra.s.sol:DeployManagerL2 \
///     --rpc-url $L2_RPC --broadcast --private-key $PK \
///     --sig "run(uint256,address)" $L2_ROLLUP_ID $SYSTEM_ADDRESS
contract DeployManagerL2 is Script {
    function run(uint256 rollupId, address systemAddress) external {
        vm.startBroadcast();

        CrossChainManagerL2 manager = new CrossChainManagerL2(rollupId, systemAddress);
        console.log("MANAGER_L2=%s", address(manager));

        vm.stopBroadcast();
    }
}
