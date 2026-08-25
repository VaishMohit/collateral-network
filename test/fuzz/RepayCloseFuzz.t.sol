// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {TestBase} from "../TestBase.sol";
import {LibConstants as C} from "../../script/LibConstants.sol";
import {CollateralManager} from "../../src/CollateralManager.sol";
import {RepoManager} from "../../src/RepoManager.sol";

/**
 * @title RepayCloseFuzz
 * @notice Step 3.5: random principals, rates and tenors against repayAndClose —
 *         exact interest math, cash conservation, and revert paths.
 */
contract RepayCloseFuzz is TestBase {
    function setUp() public {
        _deployNetwork();
        _setupBankAReady(1);
    }

    function _pledgeFullTreasury() internal returns (bytes32 positionId) {
        return _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));
    }

    function _ensureCash(address who, uint256 amount) internal {
        uint256 bal = cash.balanceOf(who);
        if (bal < amount) {
            vm.prank(admin);
            cash.mint(who, amount - bal);
        }
    }

    /// principal + simple interest with the contract's ACT/365 convention.
    function _expectedOwed(uint256 cashAmount, uint256 rateBps, uint256 tenor)
        internal
        pure
        returns (uint256)
    {
        return cashAmount + (cashAmount * rateBps * tenor) / (365 days * 10_000);
    }

    function testFuzz_repayAndClose_exactMathAndConservation(
        uint256 amountSeed,
        uint256 rateSeed,
        uint256 tenorSeed
    ) public {
        bytes32 positionId = _pledgeFullTreasury();
        CollateralManager.CollateralPosition memory p = collateralManager.getPosition(positionId);

        uint256 cashAmount = bound(amountSeed, 1, p.collateralValue);
        uint256 rateBps = bound(rateSeed, 0, 5000); // <= 50% annual
        uint256 tenor = bound(tenorSeed, 1 hours, 365 days);

        vm.prank(bankA);
        bytes32 repoId =
            repoManager.createRepo(bankA, bankB, positionId, cashAmount, rateBps, tenor);
        vm.prank(bankB);
        cash.approve(address(settlement), cashAmount);
        vm.prank(bankA);
        repoManager.settleRepo(repoId);

        assertEq(cash.balanceOf(bankA), C.BANK_A_CASH + cashAmount, "borrower did not receive principal");
        assertEq(cash.balanceOf(bankB), C.BANK_B_CASH - cashAmount, "lender balance wrong after settle");

        uint256 owed = _expectedOwed(cashAmount, rateBps, tenor);
        _ensureCash(bankA, owed);
        uint256 lenderBefore = cash.balanceOf(bankB);

        vm.warp(block.timestamp + tenor + 1);
        vm.startPrank(bankA);
        cash.approve(address(repoManager), owed);
        uint256 repaid = repoManager.repayAndClose(repoId);
        vm.stopPrank();

        assertEq(repaid, owed, "repaid != principal + interest");
        assertEq(cash.balanceOf(bankB), lenderBefore + owed, "cash not conserved");
        assertEq(
            uint8(collateralManager.getPosition(positionId).status),
            uint8(CollateralManager.CollateralStatus.RELEASED),
            "collateral not released"
        );
        assertEq(
            uint8(repoManager.getRepo(repoId).status), uint8(RepoManager.RepoStatus.CLOSED), "repo not closed"
        );
    }

    /// Overflow probe: maximal rate and tenor must not overflow or truncate.
    function testFuzz_repayAndClose_maxRateMaxTenorNoOverflow(uint256 amountSeed) public {
        bytes32 positionId = _pledgeFullTreasury();
        CollateralManager.CollateralPosition memory p = collateralManager.getPosition(positionId);
        uint256 cashAmount = bound(amountSeed, 1, p.collateralValue);
        uint256 rateBps = 10_000; // 100%
        uint256 tenor = 100 * 365 days;

        vm.prank(bankA);
        bytes32 repoId =
            repoManager.createRepo(bankA, bankB, positionId, cashAmount, rateBps, tenor);
        vm.prank(bankB);
        cash.approve(address(settlement), cashAmount);
        vm.prank(bankA);
        repoManager.settleRepo(repoId);

        uint256 owed = _expectedOwed(cashAmount, rateBps, tenor);
        assertTrue(owed > cashAmount, "interest lost");
        assertTrue(owed < type(uint256).max / 2, "overflow risk");

        _ensureCash(bankA, owed);
        vm.warp(block.timestamp + tenor + 1);
        vm.prank(bankA);
        cash.approve(address(repoManager), owed);
        uint256 repaid = repoManager.repayAndClose(repoId);
        assertEq(repaid, owed);
    }

    function testFuzz_repayAndClose_tooEarlyReverts(uint256 warpSeed) public {
        bytes32 positionId = _pledgeFullTreasury();
        uint256 tenor = 7 days;

        vm.prank(bankA);
        bytes32 repoId = repoManager.createRepo(bankA, bankB, positionId, C.REPO_CASH, C.REPO_RATE_BPS, tenor);
        vm.prank(bankB);
        cash.approve(address(settlement), C.REPO_CASH);
        vm.prank(bankA);
        repoManager.settleRepo(repoId);

        uint256 warp = bound(warpSeed, 0, tenor - 1);
        if (warp > 0) vm.warp(block.timestamp + warp);

        vm.prank(bankA);
        cash.approve(address(repoManager), type(uint256).max);
        vm.prank(bankA);
        vm.expectRevert(RepoManager.TooEarly.selector);
        repoManager.repayAndClose(repoId);
    }

    function test_doubleRepayReverts() public {
        bytes32 positionId = _pledgeFullTreasury();

        vm.prank(bankA);
        bytes32 repoId = repoManager.createRepo(bankA, bankB, positionId, C.REPO_CASH, C.REPO_RATE_BPS, C.REPO_TENOR);
        vm.prank(bankB);
        cash.approve(address(settlement), C.REPO_CASH);
        vm.prank(bankA);
        repoManager.settleRepo(repoId);

        vm.warp(block.timestamp + C.REPO_TENOR + 1);
        vm.startPrank(bankA);
        cash.approve(address(repoManager), type(uint256).max);
        repoManager.repayAndClose(repoId);
        vm.expectRevert(RepoManager.InvalidStatus.selector);
        repoManager.repayAndClose(repoId);
        vm.stopPrank();
    }
}
