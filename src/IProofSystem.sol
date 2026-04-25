// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IProofSystem
/// @notice Interface for proof-verifying systems registered in a `ProofSystemRegistry`
/// @dev A proof system is any contract that can check `(proof, publicInputsHash)` — ZK, ECDSA, etc.
interface IProofSystem {
    /// @notice Verifies a proof against a single public input hash
    /// @param proof The proof bytes (interpretation is proof-system-specific)
    /// @param publicInputsHash Hash of all public inputs for the proof
    /// @return valid True if the proof is valid, false otherwise
    function verify(bytes calldata proof, bytes32 publicInputsHash) external view returns (bool valid);
}
