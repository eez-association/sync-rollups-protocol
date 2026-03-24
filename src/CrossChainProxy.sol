// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICrossChainManager} from "./ICrossChainManager.sol";

/// @title CrossChainProxy
/// @notice Proxy contract for cross-chain addresses, deployed via CREATE2
/// @dev Stores manager address, original address, and original rollup ID as immutables.
///      Uses the OZ TransparentProxy pattern: the manager (admin) calling executeOnBehalf
///      gets the direct forwarding behavior; any other caller hitting executeOnBehalf
///      is routed through the cross-chain execution path via _fallback().
contract CrossChainProxy {
    /// @notice The manager contract address
    address internal immutable MANAGER;

    /// @notice The original address this proxy represents
    address internal immutable ORIGINAL_ADDRESS;

    /// @notice The original rollup ID
    uint256 internal immutable ORIGINAL_ROLLUP_ID;

    /// @dev Dummy transient variable used to detect STATICCALL context.
    ///      Writing to it reverts in a static context; the self-call in _fallback catches this.
    uint256 private transient _staticDetector;

    /// @param _manager The manager contract address (Rollups on L1, CrossChainManagerL2 on L2)
    /// @param _originalAddress The original address this proxy represents
    /// @param _originalRollupId The original rollup ID
    constructor(
        address _manager,
        address _originalAddress,
        uint256 _originalRollupId
    ) {
        MANAGER = _manager;
        ORIGINAL_ADDRESS = _originalAddress;
        ORIGINAL_ROLLUP_ID = _originalRollupId;
    }

    /// @notice Fallback function that forwards all calls to the manager contract
    /// @dev Uses abi.encodeCall for type-safe encoding, low-level call to preserve raw return/revert data
    fallback() external payable {
        _fallback();
    }

    /// @notice Attempts a tstore to detect STATICCALL context
    /// @dev In a static context, tstore reverts. Called via self-call so the revert is caught.
    ///      When called by anyone other than self, routes through _fallback() (same transparent proxy pattern).
    function staticCheck() external {
        if (msg.sender == address(this)) {
            _staticDetector = 0;
        } else {
            _fallback();
        }
    }

    /// @notice Executes a call on behalf of this proxy identity
    /// @dev When called by the manager, forwards the call to the destination.
    ///      When called by anyone else, routes through _fallback() (cross-chain path),
    ///      similar to OZ's TransparentProxy admin pattern.
    /// @param destination The address to call
    /// @param data The calldata
    function executeOnBehalf(
        address destination,
        bytes calldata data
    ) external payable {
        if (msg.sender == MANAGER) {
            (bool success, bytes memory result) = destination.call{value: msg.value}(data);

            assembly {
                switch success
                case 0 { revert(add(result, 0x20), mload(result)) }
                default { return(add(result, 0x20), mload(result)) }
            }
        } else {
            _fallback();
        }
    }

    /// @dev Internal fallback that forwards the call to the manager as a cross-chain execution.
    ///      Detects static context via a tstore probe: a self-call to `staticCheck()` attempts TSTORE,
    ///      which fails in STATICCALL context (TSTORE is disallowed, TLOAD is fine).
    ///      In static context, routes to `staticCallLookup()` (view); otherwise `executeCrossChainCall()`.
    ///
    ///      Result decoding:
    ///      The low-level `.call()` returns ABI-encoded return data. Since both manager functions
    ///      return `bytes memory`, the raw `result` is double-encoded: the outer ABI encoding
    ///      wraps the inner `bytes` return value. We must `abi.decode(result, (bytes))` to unwrap
    ///      the inner bytes before returning them to the caller.
    ///      On revert, the raw revert data is not ABI-wrapped, so we forward it directly.
    function _fallback() internal {
        // Detect STATICCALL context: CALL with value=0 is allowed in static context,
        // but the callee inherits the static flag, so staticCheck()'s TSTORE will fail.
        // Note: an OOG on this self-call would also return false, but that's safe — if 63/64
        // of remaining gas can't cover a single TSTORE (~100 gas), the subsequent MANAGER call
        // will also revert due to insufficient gas.
        (bool notStaticCall,) = address(this).call(abi.encodeCall(this.staticCheck, ()));

        bool success;
        bytes memory result;

        if (notStaticCall) {
            // Non-static context — use execution path
            (success, result) = MANAGER.call{
                value: msg.value
            }(abi.encodeCall(ICrossChainManager.executeCrossChainCall, (msg.sender, msg.data)));
        } else {
            // Static context — use view lookup for pre-computed result
            (success, result) = MANAGER.staticcall(
                abi.encodeCall(ICrossChainManager.staticCallLookup, (msg.sender, msg.data))
            );
        }

        if (success) {
            // Decode the inner `bytes` from the ABI-encoded return value
            // TODO: should we also decode for reverted errors (e.g. ScopeReverted carrying ABI-encoded data)?
            result = abi.decode(result, (bytes));
        }

        assembly {
            switch success
            case 0 { revert(add(result, 0x20), mload(result)) }
            default { return(add(result, 0x20), mload(result)) }
        }
    }
}
