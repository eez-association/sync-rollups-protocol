// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FlashLoan} from "../../../src/periphery/defiMock/FlashLoan.sol";
import {FlashLoanersNFT} from "../../../src/periphery/defiMock/FlashLoanersNFT.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {
        _mint(msg.sender, 1_000_000e18);
    }
}

contract FlashLoanNFTTest is Test {
    MockToken token;
    FlashLoan pool;
    FlashLoanersNFT nft;

    address alice = makeAddr("alice");

    function setUp() public {
        token = new MockToken();
        pool = new FlashLoan();
        nft = new FlashLoanersNFT(address(token));

        // Fund the flash loan pool with liquidity
        token.transfer(address(pool), 100_000e18);
    }

    function test_flashLoanRepaymentEnforced() public {
        // Not enough liquidity
        vm.expectRevert("Not enough liquidity");
        vm.prank(alice);
        pool.flashLoan(address(token), 200_000e18);
    }

    function test_legitimateClaim() public {
        // Give alice real tokens
        token.transfer(alice, 10_000e18);

        // Alice claims directly (no flash loan needed)
        vm.prank(alice);
        nft.claim();

        assertEq(nft.balanceOf(alice), 1);
    }

    function test_cannotClaimBelowMinBalance() public {
        token.transfer(alice, 9_999e18);

        vm.expectRevert("Balance too low");
        vm.prank(alice);
        nft.claim();
    }
}
