// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Rollups, Action, ActionType} from "./Rollups.sol";

/// @title L2Proxy
/// @notice Implementation contract for L2 proxy functionality
/// @dev Reads configuration from storage slots set by Proxy contract
/// @dev Storage layout matches Proxy: slot 0 = implementation, slot 1 = rollups, slot 2 = originalAddress, slot 3 = originalRollupId
contract L2Proxy {
    /// @notice Error when caller is not authorized
    error Unauthorized();

    /// @notice Error when a call execution fails
    error CallExecutionFailed();

    /// @notice Gets the Rollups contract address from storage slot 1
    function _getRollups() internal view returns (Rollups) {
        address rollupsAddr;
        assembly {
            rollupsAddr := sload(1)
        }
        return Rollups(rollupsAddr);
    }

    /// @notice Gets the original address from storage slot 2
    function _getOriginalAddress() internal view returns (address) {
        address addr;
        assembly {
            addr := sload(2)
        }
        return addr;
    }

    /// @notice Gets the original rollup ID from storage slot 3
    function _getOriginalRollupId() internal view returns (uint256) {
        uint256 id;
        assembly {
            id := sload(3)
        }
        return id;
    }

    /// @notice Returns the original rollup ID for this proxy
    /// @return The original rollup ID
    function originalRollupId() external view returns (uint256) {
        return _getOriginalRollupId();
    }

    /// @notice Returns the original address for this proxy
    /// @return The original address this proxy represents
    function originalAddress() external view returns (address) {
        return _getOriginalAddress();
    }

    /// @notice Converts an address to its equivalent in this L2Proxy's rollup domain
    /// @dev If addr is an existing proxy, uses its original address and original rollup ID as origin
    /// @dev If addr is not a proxy, uses the address directly with block.chainid as origin
    /// @param addr The address to convert
    /// @return The proxy address in this L2Proxy's rollup domain
    function convertAddress(address addr) external view returns (address) {
        Rollups rollupsContract = _getRollups();
        address originalAddr;
        uint256 origin;

        // Check if the address is an authorized proxy
        if (rollupsContract.authorizedProxies(addr)) {
            // It's a proxy - get its original address and rollup ID
            originalAddr = L2Proxy(payable(addr)).originalAddress();
            origin = L2Proxy(payable(addr)).originalRollupId();
        } else {
            // Not a proxy - use the address directly with current chain ID
            originalAddr = addr;
            origin = block.chainid;
        }

        // Return the proxy address for this original address in our rollup's domain
        return rollupsContract.computeL2ProxyAddress(originalAddr, origin, _getOriginalRollupId());
    }

    /// @notice Fallback function that handles all calls to the proxy
    /// @dev Computes actionHash from a CALL action and executes the L2 execution
    fallback() external payable {
        Rollups rollupsContract = _getRollups();
        uint256 rollupId = _getOriginalRollupId();

        // Deposit received ETH to the rollup's balance
        if (msg.value > 0) {
            rollupsContract.depositEther{value: msg.value}(rollupId);
        }

        // Build the CALL action from the incoming call
        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: _getOriginalAddress(),
            value: msg.value,
            data: msg.data,
            failed: false,
            sourceAddress: address(this),
            sourceRollup: rollupId,
            scope: new uint256[](0)
        });

        // Compute action hash
        bytes32 actionHash = keccak256(abi.encode(action));

        // Execute and get next action
        bytes memory result = _execute(actionHash, rollupsContract, rollupId);

        // Return the result
        assembly {
            return(add(result, 0x20), mload(result))
        }
    }

    // NOTE: No receive() function - all calls (including plain ETH transfers) go to fallback()
    // This ensures the bridging logic is always triggered.

    /// @notice Executes a call on behalf of another authorized proxy
    /// @dev Only callable by the Rollups contract or other authorized proxies
    /// @param destination The address to call
    /// @param data The calldata
    /// @return success Whether the call succeeded
    /// @return returnData The return data from the call
    function executeOnBehalf(
        address destination,
        bytes calldata data
    ) external payable returns (bool success, bytes memory returnData) {
        Rollups rollupsContract = _getRollups();

        // Only Rollups contract or authorized proxies can call this
        if (msg.sender != address(rollupsContract) && !rollupsContract.authorizedProxies(msg.sender)) {
            revert Unauthorized();
        }

        // Execute the call from this proxy using msg.value
        (success, returnData) = destination.call{value: msg.value}(data);
    }

    /// @notice Decodes the nextAction from ScopeReverted error data
    /// @dev At root level, state restoration is not needed (handled by Rollups contract)
    /// @param revertData The raw revert data (includes 4-byte selector)
    /// @return nextAction The decoded action
    function _decodeScopeRevert(bytes memory revertData) private pure returns (Action memory nextAction) {
        // Skip 4-byte selector, decode parameters
        require(revertData.length > 4, "Invalid revert data");
        bytes memory withoutSelector = new bytes(revertData.length - 4);
        for (uint256 i = 4; i < revertData.length; i++) {
            withoutSelector[i - 4] = revertData[i];
        }
        // Decode: (bytes nextAction, bytes32 stateRoot, uint256 rollupId)
        // State restoration is handled by Rollups._handleScopeRevert, not needed here at root
        (bytes memory actionBytes,,) = abi.decode(withoutSelector, (bytes, bytes32, uint256));
        return abi.decode(actionBytes, (Action));
    }

    /// @notice Internal function to execute an L2 action through the Rollups contract
    /// @param actionHash The action hash to execute
    /// @param rollupsContract The Rollups contract instance
    /// @param rollupId The rollup ID (unused, kept for interface compatibility)
    /// @return result The result of the execution
    function _execute(bytes32 actionHash, Rollups rollupsContract, uint256 rollupId) private returns (bytes memory result) {
        rollupId; // Silence unused variable warning

        // Get first action
        Action memory nextAction = rollupsContract.executeL2Execution(actionHash);

        if (nextAction.actionType == ActionType.CALL) {
            // Delegate all scope handling to Rollups.newScope with try/catch for reverts
            // Start with empty scope, action.scope contains target
            uint256[] memory emptyScope = new uint256[](0);
            try rollupsContract.newScope(emptyScope, nextAction) returns (Action memory retAction) {
                nextAction = retAction;
            } catch (bytes memory revertData) {
                // Root scope caught a revert - decode and continue
                nextAction = _decodeScopeRevert(revertData);
            }
        }

        // At this point nextAction should be a successful RESULT
        if (nextAction.actionType != ActionType.RESULT || nextAction.failed) {
            revert CallExecutionFailed();
        }
        return nextAction.data;
    }
}
