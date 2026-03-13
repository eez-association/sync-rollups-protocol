// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IFlashLoanReceiver, FlashLoan} from "./FlashLoan.sol";
import {FreeNFT} from "./FreeNFT.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract FlashLoanUser is IFlashLoanReceiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    FlashLoan public immutable flashLoanPool;
    FreeNFT public immutable nft;
    uint256 transient claimedTokenId;

    constructor(address _flashLoanPool, address _nft) {
        flashLoanPool = FlashLoan(_flashLoanPool);
        nft = FreeNFT(_nft);
    }

    function execute() external nonReentrant {
        address token = address(nft.token());
        flashLoanPool.flashLoan(token, 10_000e18);

        IERC721(address(nft)).transferFrom(address(this), msg.sender, claimedTokenId);
    }

    function onFlashLoan(address token, uint256 amount) external override {
        require(msg.sender == address(flashLoanPool), "Unauthorized");

        nft.claim();
        claimedTokenId = nft.nextTokenId() - 1;

        // Repay the flash loan
        IERC20(token).safeTransfer(msg.sender, amount);
    }
}
