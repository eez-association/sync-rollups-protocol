// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IProofSystem} from "./IProofSystem.sol";

/// @title ProofSystemRegistry
/// @notice Permissionless registry of proof-verifying systems
/// @dev Any address may register an `IProofSystem` contract. Once registered, the proof-system
///      address can be referenced directly by rollups and by `postBatch`.
abstract contract ProofSystemRegistry {
    /// @notice Whether a given proof-system address is registered
    mapping(address proofSystem => bool registered) public isProofSystem;

    /// @notice Enumeration of all registered proof-system addresses (append-only)
    address[] public proofSystems;

    /// @notice Emitted when a new proof system is registered
    event ProofSystemRegistered(address indexed proofSystem, address indexed registrant);

    /// @notice Error when proof-system address is zero
    error InvalidProofSystem();

    /// @notice Error when attempting to register a proof system that is already registered
    error ProofSystemAlreadyRegistered(address proofSystem);

    /// @notice Error when referencing a proof system that was never registered
    error ProofSystemNotRegistered(address proofSystem);

    /// @notice Registers a new proof system
    /// @param proofSystem The proof-system contract (must implement IProofSystem)
    function registerProofSystem(IProofSystem proofSystem) external {
        address addr = address(proofSystem);
        if (addr == address(0)) revert InvalidProofSystem();
        if (isProofSystem[addr]) revert ProofSystemAlreadyRegistered(addr);
        isProofSystem[addr] = true;
        proofSystems.push(addr);
        emit ProofSystemRegistered(addr, msg.sender);
    }

    /// @notice Number of registered proof systems
    function proofSystemCount() external view returns (uint256) {
        return proofSystems.length;
    }
}
