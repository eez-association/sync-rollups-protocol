// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IZKVerifier
/// @notice Interface for external ZK proof verification
/// @dev Used by both postBatch and loadL2Executions in Rollups contract
interface IZKVerifier {
    /// @notice Verifies a ZK proof against a single public input hash
    /// @param proof The ZK proof bytes
    /// @param publicInputsHash Hash of all public inputs for the proof
    /// @return valid True if the proof is valid, false otherwise
    function verify(bytes calldata proof, bytes32 publicInputsHash) external view returns (bool valid);
}
