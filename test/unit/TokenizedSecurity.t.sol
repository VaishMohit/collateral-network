// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {TestBase} from "../TestBase.sol";
import {TokenizedSecurity} from "../../src/TokenizedSecurity.sol";
import {LibConstants as C} from "../../script/LibConstants.sol";

contract TokenizedSecurityTest is TestBase {
    function setUp() public {
        _deployNetwork();
    }

    function _mintForAdmin() internal {
        vm.startPrank(admin);
        tBondToken.mint(bankA, 100);
        vm.stopPrank();
    }

    function test_metadata() public {
        assertEq(tBondToken.name(), "Tokenized US Treasury T-BOND-001");
        assertEq(tBondToken.symbol(), "tT-BOND");
        assertEq(tBondToken.decimals(), 0);
        assertEq(tBondToken.assetId(), C.T_BOND);
    }

    function test_onlyControllerCanMint() public {
        vm.prank(bankA);
        vm.expectRevert(TokenizedSecurity.Unauthorized.selector);
        tBondToken.mint(bankA, 100);
    }

    function test_adminCanMint() public {
        vm.startPrank(admin);
        tBondToken.mint(bankA, 100);
        tBondToken.mint(bankB, 50);
        vm.stopPrank();
        assertEq(tBondToken.balanceOf(bankA), 100);
        assertEq(tBondToken.balanceOf(bankB), 50);
        assertEq(tBondToken.totalSupply(), 150);
    }

    function test_mintToZeroReverts() public {
        vm.prank(admin);
        vm.expectRevert(TokenizedSecurity.ZeroAddress.selector);
        tBondToken.mint(address(0), 100);
    }

    function test_onlyControllerCanBurn() public {
        vm.prank(bankA);
        vm.expectRevert(TokenizedSecurity.Unauthorized.selector);
        tBondToken.burn(bankA, 10);
    }

    function test_burn() public {
        _mintForAdmin();
        vm.startPrank(admin);
        tBondToken.burn(bankA, 40);
        vm.stopPrank();
        assertEq(tBondToken.balanceOf(bankA), 60);
        assertEq(tBondToken.totalSupply(), 60);
    }

    function test_burnInsufficientReverts() public {
        _mintForAdmin();
        vm.prank(admin);
        vm.expectRevert(TokenizedSecurity.InsufficientBalance.selector);
        tBondToken.burn(bankA, 101);
    }

    function test_transferMovesBalance() public {
        _mintForAdmin();
        vm.prank(bankA);
        assertTrue(tBondToken.transfer(bankB, 30));
        assertEq(tBondToken.balanceOf(bankA), 70);
        assertEq(tBondToken.balanceOf(bankB), 30);
    }

    function test_transferInsufficientReverts() public {
        _mintForAdmin();
        vm.prank(bankA);
        vm.expectRevert(TokenizedSecurity.InsufficientBalance.selector);
        tBondToken.transfer(bankB, 101);
    }

    function test_freezeBlocksOrdinaryTransfer() public {
        _mintForAdmin();
        vm.startPrank(admin);
        tBondToken.freeze(bankA);
        vm.stopPrank();
        vm.prank(bankA);
        vm.expectRevert(TokenizedSecurity.AccountFrozen.selector);
        tBondToken.transfer(bankB, 10);
    }

    function test_forceTransferBypassesFreeze() public {
        _mintForAdmin();
        vm.startPrank(admin);
        tBondToken.freeze(bankA);
        tBondToken.forceTransfer(bankA, bankB, 10);
        vm.stopPrank();
        assertEq(tBondToken.balanceOf(bankB), 10);
    }

    function test_unfreezeRestoresTransfers() public {
        _mintForAdmin();
        vm.startPrank(admin);
        tBondToken.freeze(bankA);
        tBondToken.unfreeze(bankA);
        vm.stopPrank();
        vm.prank(bankA);
        assertTrue(tBondToken.transfer(bankB, 10));
    }

    function test_forceTransferOnlyController() public {
        _mintForAdmin();
        vm.prank(bankA);
        vm.expectRevert(TokenizedSecurity.Unauthorized.selector);
        tBondToken.forceTransfer(bankA, bankB, 10);
    }

    function test_approveAndTransferFrom() public {
        _mintForAdmin();
        vm.prank(bankA);
        tBondToken.approve(bankB, 25);
        vm.prank(bankB);
        assertTrue(tBondToken.transferFrom(bankA, address(this), 25));
        assertEq(tBondToken.balanceOf(address(this)), 25);
        assertEq(tBondToken.allowance(bankA, bankB), 0);
    }

    function test_transferFromFrozenReverts() public {
        _mintForAdmin();
        vm.prank(bankA);
        tBondToken.approve(bankB, 25);
        vm.startPrank(admin);
        tBondToken.freeze(bankA);
        vm.stopPrank();
        vm.prank(bankB);
        vm.expectRevert(TokenizedSecurity.AccountFrozen.selector);
        tBondToken.transferFrom(bankA, address(this), 25);
    }
}
