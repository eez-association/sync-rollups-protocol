// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFlashLoanReceiver, FlashLoan} from "./FlashLoan.sol";
import {FlashLoanersNFT} from "./FlashLoanersNFT.sol";
import {Bridge} from "../Bridge.sol";

contract FlashLoanBridgeExecutor is IFlashLoanReceiver {
    using SafeERC20 for IERC20;

    FlashLoan public immutable flashLoanPool;
    Bridge public immutable bridge;
    address public immutable executorL2Proxy;
    address public immutable executorL2;
    address public immutable wrappedTokenL2;
    address public immutable nftL2;
    address public immutable bridgeL2;
    uint256 public immutable l2RollupId;
    address public immutable token;

    address transient caller;

    constructor(
        address _flashLoanPool,
        address _bridge,
        address _executorL2Proxy,
        address _executorL2,
        address _wrappedTokenL2,
        address _nftL2,
        address _bridgeL2,
        uint256 _l2RollupId,
        address _token
    ) {
        flashLoanPool = FlashLoan(_flashLoanPool);
        bridge = Bridge(_bridge);
        executorL2Proxy = _executorL2Proxy;
        executorL2 = _executorL2;
        wrappedTokenL2 = _wrappedTokenL2;
        nftL2 = _nftL2;
        bridgeL2 = _bridgeL2;
        l2RollupId = _l2RollupId;
        token = _token;
    }

    function execute() external {
        caller = msg.sender;
        flashLoanPool.flashLoan(token, 10_000e18);
    }

    function onFlashLoan(
        address _token,
        uint256 amount
    ) external override {
        require(msg.sender == address(flashLoanPool), "Unauthorized");

        address nftRecipient = caller;

        // 1. Bridge tokens to executor on L2
        IERC20(_token).approve(address(bridge), amount);
        bridge.bridgeTokens(_token, amount, l2RollupId, executorL2);

        // 2. Trigger executor(L2) to claim NFT and bridge tokens back
        (bool success,) = executorL2Proxy.call(
            abi.encodeCall(
                this.claimAndBridgeBack, (wrappedTokenL2, nftL2, bridgeL2, 0, address(this), nftRecipient)
            )
        );
        require(success, "Cross-chain call failed");

        // 3. Repay (tokens are back from bridge release)
        IERC20(_token).safeTransfer(msg.sender, amount);
    }

    /// @notice Called cross-chain on L2 by the executor proxy.
    ///         Claims a token-gated NFT and bridges wrapped tokens back to L1.
    /// @param wrappedToken  The wrapped ERC20 on L2 (used for NFT balance gate + bridge burn)
    /// @param nftContract   The FlashLoanersNFT contract on L2
    /// @param _bridge       The Bridge contract on L2
    /// @param destRollupId  The rollup to bridge tokens back to (L1 = 0)
    /// @param returnTo      The address on L1 that receives the bridged-back tokens
    /// @param nftRecipient  The address that receives the claimed NFT (msg.sender of execute() on L1)
    function claimAndBridgeBack(
        address wrappedToken,
        address nftContract,
        address _bridge,
        uint256 destRollupId,
        address returnTo,
        address nftRecipient
    ) external {
        // Snapshot the next token ID before claim() increments it
        uint256 tokenId = FlashLoanersNFT(nftContract).nextTokenId();

        // Claim the NFT (minted to this contract since we hold >= MIN_BALANCE wrapped tokens)
        FlashLoanersNFT(nftContract).claim();
        // Transfer the NFT to the original caller of execute() on L1
        FlashLoanersNFT(nftContract).transferFrom(address(this), nftRecipient, tokenId);

        // Bridge all wrapped tokens back to L1
        uint256 balance = IERC20(wrappedToken).balanceOf(address(this));
        Bridge(_bridge).bridgeTokens(wrappedToken, balance, destRollupId, returnTo);
    }
}
