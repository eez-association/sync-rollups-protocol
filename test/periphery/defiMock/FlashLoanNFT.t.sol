// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {FlashLoan} from "../../../src/periphery/defiMock/FlashLoan.sol";
import {FreeNFT} from "../../../src/periphery/defiMock/FreeNFT.sol";
import {FlashLoanUser} from "../../../src/periphery/defiMock/FlashLoanUser.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {
        _mint(msg.sender, 1_000_000e18);
    }
}

contract FlashLoanNFTTest is Test {
    MockToken token;
    FlashLoan pool;
    FreeNFT nft;
    FlashLoanUser user;

    address alice = makeAddr("alice");

    function setUp() public {
        token = new MockToken();
        pool = new FlashLoan();
        nft = new FreeNFT(address(token));
        user = new FlashLoanUser(address(pool), address(nft));

        // Fund the flash loan pool with liquidity
        token.transfer(address(pool), 100_000e18);
    }

    function test_flashLoanExploit() public {
        // Alice has 0 tokens and 0 NFTs
        assertEq(token.balanceOf(alice), 0);
        assertEq(IERC721(address(nft)).balanceOf(alice), 0);

        // Alice exploits: flash loan 10k tokens -> claim NFT -> repay
        vm.prank(alice);
        user.execute();

        // Alice now owns the NFT despite never holding any tokens
        assertEq(IERC721(address(nft)).balanceOf(alice), 1);
        assertEq(IERC721(address(nft)).ownerOf(0), alice);

        // Flash loan pool is whole — no tokens lost
        assertEq(token.balanceOf(address(pool)), 100_000e18);

        // Alice still has 0 tokens
        assertEq(token.balanceOf(alice), 0);
    }

    function test_flashLoanRepaymentEnforced() public {
        // Not enough liquidity
        vm.expectRevert("Not enough liquidity");
        vm.prank(alice);
        pool.flashLoan(address(token), 200_000e18);
    }

    function test_cannotClaimTwice() public {
        // First exploit works
        vm.prank(alice);
        user.execute();

        // Second attempt reverts — already claimed
        vm.expectRevert("Already claimed");
        vm.prank(alice);
        user.execute();
    }

    function test_legitimateClaim() public {
        // Give alice real tokens
        token.transfer(alice, 10_000e18);

        // Alice claims directly (no flash loan needed)
        vm.prank(alice);
        nft.claim();

        assertEq(IERC721(address(nft)).balanceOf(alice), 1);
    }

    function test_cannotClaimBelowMinBalance() public {
        token.transfer(alice, 9_999e18);

        vm.expectRevert("Balance too low");
        vm.prank(alice);
        nft.claim();
    }
}
