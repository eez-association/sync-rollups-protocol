// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RLP} from "@openzeppelin/contracts/utils/RLP.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title RLPTxEncoder
/// @notice Builds real EIP-155 Legacy (Type 0) RLP-encoded signed Ethereum transactions
///         for use in test and e2e scenarios.
library RLPTxEncoder {
    using RLP for RLP.Encoder;

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct LegacyTx {
        uint256 nonce;
        uint256 gasPrice;
        uint256 gasLimit;
        address to;
        uint256 value;
        bytes data;
        uint256 chainId;
    }

    /// @notice Encode and sign a legacy EIP-155 transaction.
    function signLegacyTx(LegacyTx memory tx_, uint256 privateKey) internal pure returns (bytes memory) {
        // 1. Unsigned RLP for signing: [nonce, gasPrice, gasLimit, to, value, data, chainId, 0, 0]
        bytes memory unsignedRlp = RLP.encode(
            RLP.encoder()
                .push(tx_.nonce)
                .push(tx_.gasPrice)
                .push(tx_.gasLimit)
                .push(tx_.to)
                .push(tx_.value)
                .push(tx_.data)
                .push(tx_.chainId)
                .push(uint256(0))
                .push(uint256(0))
        );

        // 2. Sign
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, keccak256(unsignedRlp));

        // 3. EIP-155 v: recovery_id + chainId * 2 + 35
        uint256 vEip155 = uint256(v) - 27 + tx_.chainId * 2 + 35;

        // 4. Signed RLP: [nonce, gasPrice, gasLimit, to, value, data, v, r, s]
        return RLP.encode(
            RLP.encoder()
                .push(tx_.nonce)
                .push(tx_.gasPrice)
                .push(tx_.gasLimit)
                .push(tx_.to)
                .push(tx_.value)
                .push(tx_.data)
                .push(vEip155)
                .push(uint256(r))
                .push(uint256(s))
        );
    }

    /// @notice Build a signed tx for a contract call with sensible defaults.
    function signedCallTx(address to, bytes memory callData, uint256 nonce, uint256 privateKey)
        internal
        pure
        returns (bytes memory)
    {
        return signLegacyTx(
            LegacyTx({nonce: nonce, gasPrice: 1 gwei, gasLimit: 100_000, to: to, value: 0, data: callData, chainId: 1}),
            privateKey
        );
    }
}
