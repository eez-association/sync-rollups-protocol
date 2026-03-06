// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title CrossChainProxy
/// @notice Proxy contract for cross-chain addresses, deployed via CREATE2
/// @dev Stores manager address, original address, and original rollup ID as immutables
contract CrossChainProxy {
    /// @notice Error when caller is not authorized
    error Unauthorized();

    /// @notice The manager contract address
    address public immutable MANAGER;

    /// @notice The original address this proxy represents
    address public immutable ORIGINAL_ADDRESS;

    /// @notice The original rollup ID
    uint256 public immutable ORIGINAL_ROLLUP_ID;

    /// @param _manager The manager contract address (Rollups on L1, CrossChainManagerL2 on L2)
    /// @param _originalAddress The original address this proxy represents
    /// @param _originalRollupId The original rollup ID
    constructor(address _manager, address _originalAddress, uint256 _originalRollupId) {
        MANAGER = _manager;
        ORIGINAL_ADDRESS = _originalAddress;
        ORIGINAL_ROLLUP_ID = _originalRollupId;
    }

    /// @notice Fallback function that forwards all calls to the manager contract
    /// @dev Uses low-level call to bubble both returns and reverts
    fallback() external payable {
        (bool success, bytes memory result) = MANAGER.call{value: msg.value}(
            abi.encodeWithSignature("executeCrossChainCall(address,bytes)", msg.sender, msg.data)
        );

        assembly {
            switch success
            case 0 { revert(add(result, 0x20), mload(result)) }
            default { return(add(result, 0x20), mload(result)) }
        }
    }

    /// @notice Executes a call on behalf of another authorized proxy
    /// @dev Only callable by the manager contract. Reverts bubble up.
    /// @param destination The address to call
    /// @param data The calldata
    /// @return returnData The return data from the call
    function executeOnBehalf(
        address destination,
        bytes calldata data
    ) external payable returns (bytes memory returnData) {
        if (msg.sender != MANAGER) {
            revert Unauthorized();
        }

        bool success;
        (success, returnData) = destination.call{value: msg.value}(data);

        if (!success) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }
}
