// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Rollups} from "../../src/Rollups.sol";
import {IZKVerifier} from "../../src/IZKVerifier.sol";

/// @notice Mock ZK verifier — defaults to accepting all proofs.
///         Call setVerifyResult(false) to test rejection.
contract MockZKVerifier is IZKVerifier {
    bool public shouldVerify = true;

    function setVerifyResult(bool _shouldVerify) external {
        shouldVerify = _shouldVerify;
    }

    function verify(bytes calldata, bytes32) external view override returns (bool) {
        return shouldVerify;
    }
}

/// @notice Shared base for integration tests — constants, rollups infra, and helpers.
abstract contract IntegrationTestBase is Test {
    uint256 constant L2_ROLLUP_ID = 1;
    uint256 constant MAINNET_ROLLUP_ID = 0;
    address constant SYSTEM_ADDRESS = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
    bytes32 constant DEFAULT_VK = keccak256("verificationKey");
    uint256 constant TX_SIGNER_PK = 0xA11CE;

    Rollups public rollups;
    MockZKVerifier public verifier;

    function _getRollupState(uint256 rollupId) internal view returns (bytes32) {
        (,, bytes32 stateRoot,) = rollups.rollups(rollupId);
        return stateRoot;
    }
}
