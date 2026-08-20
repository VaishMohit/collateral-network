// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {TestBase} from "../TestBase.sol";
import {CashToken} from "../../src/CashToken.sol";
import {LibConstants as C} from "../../script/LibConstants.sol";

contract CashTokenTest is TestBase {
    function setUp() public {
        _deployNetwork();
    }

    function test_deployerSeedsBalances() public {
        assertEq(cash.balanceOf(bankA), C.BANK_A_CASH);
        assertEq(cash.balanceOf(bankB), C.BANK_B_CASH);
        assertEq(cash.decimals(), 2);
    }

    function test_adminMints() public {
        vm.prank(admin);
        cash.mint(bankA, 1_000);
        assertEq(cash.balanceOf(bankA), C.BANK_A_CASH + 1_000);
    }

    function test_nonAdminCannotMint() public {
        vm.prank(bankA);
        vm.expectRevert(CashToken.Unauthorized.selector);
        cash.mint(bankA, 1_000);
    }

    function test_transfer() public {
        vm.prank(bankA);
        assertTrue(cash.transfer(bankB, 1_000));
        assertEq(cash.balanceOf(bankA), C.BANK_A_CASH - 1_000);
        assertEq(cash.balanceOf(bankB), C.BANK_B_CASH + 1_000);
    }

    function test_transferInsufficientReverts() public {
        vm.prank(bankA);
        vm.expectRevert(CashToken.InsufficientBalance.selector);
        cash.transfer(bankB, C.BANK_A_CASH + 1);
    }

    function test_approveAndTransferFrom() public {
        vm.prank(bankA);
        cash.approve(bankB, 500);
        vm.prank(bankB);
        assertTrue(cash.transferFrom(bankA, bankB, 500));
        assertEq(cash.balanceOf(bankB), C.BANK_B_CASH + 500);
        assertEq(cash.allowance(bankA, bankB), 0);
    }

    function test_transferFromInsufficientAllowanceReverts() public {
        vm.prank(bankA);
        cash.approve(bankB, 100);
        vm.prank(bankB);
        vm.expectRevert(CashToken.InsufficientAllowance.selector);
        cash.transferFrom(bankA, bankB, 101);
    }

    function test_transferFromUnlimitedAllowance() public {
        vm.prank(bankA);
        cash.approve(bankB, type(uint256).max);
        vm.prank(bankB);
        assertTrue(cash.transferFrom(bankA, bankB, 1_000));
        assertEq(cash.allowance(bankA, bankB), type(uint256).max);
    }
}
