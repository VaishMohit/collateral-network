// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {TestBase} from "../TestBase.sol";
import {RepoManager} from "../../src/RepoManager.sol";
import {CollateralManager} from "../../src/CollateralManager.sol";
import {MarginManager} from "../../src/MarginManager.sol";
import {LibConstants as C} from "../../script/LibConstants.sol";

/**
 * @title RepoFlowTest
 * @notice End-to-end repo collateral lifecycle against the in-memory network:
 *         pledge -> settle (DvP) -> margin call -> repay / default -> enforcement.
 */
contract RepoFlowTest is TestBase {
    function setUp() public {
        _deployNetwork();
    }

    function test_fullRepoLifecycleWithRepayment() public {
        _setupBankAReady(1);
        bytes32 positionId = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));

        // Create + settle a $950k repo; lender's cash moves to the borrower.
        bytes32 repoId = _repoAndSettle(positionId, C.REPO_CASH);
        assertEq(uint256(repoManager.getRepo(repoId).status), uint256(RepoManager.RepoStatus.ACTIVE));
        assertEq(cash.balanceOf(bankA), C.BANK_A_CASH + C.REPO_CASH);
        assertEq(cash.balanceOf(bankB), C.BANK_B_CASH - C.REPO_CASH);
        assertEq(uint256(collateralManager.getPosition(positionId).status), uint256(CollateralManager.CollateralStatus.PLEDGED));

        // At maturity the borrower repays principal + interest and gets its
        // collateral back.
        vm.warp(block.timestamp + C.REPO_TENOR);
        vm.startPrank(bankA);
        cash.approve(address(repoManager), type(uint256).max);
        uint256 repaid = repoManager.repayAndClose(repoId);
        vm.stopPrank();

        uint256 owed = 95_000_000 + 91_095;
        assertEq(repaid, owed);
        assertEq(uint256(repoManager.getRepo(repoId).status), uint256(RepoManager.RepoStatus.CLOSED));
        assertEq(uint256(collateralManager.getPosition(positionId).status), uint256(CollateralManager.CollateralStatus.RELEASED));
        assertEq(tBondToken.balanceOf(bankA), C.T_BOND_QUANTITY);
        assertEq(custodyRegistry.getCustodyState(C.T_BOND, bankA).encumberedQuantity, 0);
        assertEq(cash.balanceOf(bankB), C.BANK_B_CASH - C.REPO_CASH + owed);
        assertEq(cash.balanceOf(bankA), C.BANK_A_CASH + C.REPO_CASH - owed);
    }

    function test_marginCallTriggeredByPriceDropThenSatisfiedAndRepaid() public {
        _setupBankAReady(1);
        // First position: T-BOND, no obligation yet (linked at repo creation).
        bytes32 tBondPosition = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));

        bytes32 repoId = _repoAndSettle(tBondPosition, 30_000_000);

        // Market drops to $92.00 -> collateral value $874k vs $900k requirement.
        _submitPrice(C.T_BOND, C.T_BOND_PRICE_DOWN, 3);
        vm.prank(bankA);
        uint256 shortfall = marginManager.createMarginCall(repoId);
        assertEq(shortfall, 2_600_000);
        assertFalse(marginManager.isAdequatelyCollateralized(repoId));

        // Borrower posts the corporate bond under the same obligation.
        bytes32 corpPosition = _pledge(C.CORP_BOND, C.CORP_BOND_QUANTITY, bankB, repoId);
        vm.prank(bankA);
        assertTrue(marginManager.satisfyMarginCall(repoId));
        assertTrue(marginManager.isAdequatelyCollateralized(repoId));

        // Repay at maturity; every pledged position under the obligation is released.
        vm.warp(block.timestamp + C.REPO_TENOR);
        vm.startPrank(bankA);
        cash.approve(address(repoManager), type(uint256).max);
        repoManager.repayAndClose(repoId);
        vm.stopPrank();

        assertEq(uint256(repoManager.getRepo(repoId).status), uint256(RepoManager.RepoStatus.CLOSED));
        assertEq(uint256(collateralManager.getPosition(tBondPosition).status), uint256(CollateralManager.CollateralStatus.RELEASED));
        assertEq(uint256(collateralManager.getPosition(corpPosition).status), uint256(CollateralManager.CollateralStatus.RELEASED));
        assertEq(tBondToken.balanceOf(bankA), C.T_BOND_QUANTITY);
        assertEq(corpBondToken.balanceOf(bankA), C.CORP_BOND_QUANTITY);
        assertEq(custodyRegistry.getCustodyState(C.T_BOND, bankA).encumberedQuantity, 0);
        assertEq(custodyRegistry.getCustodyState(C.CORP_BOND, bankA).encumberedQuantity, 0);
    }

    function test_repoDefaultAndCollateralEnforcement() public {
        _setupBankAReady(1);
        bytes32 positionId = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));
        bytes32 repoId = _repoAndSettle(positionId, C.REPO_CASH);

        // Borrower never repays; the lender declares default at maturity.
        vm.warp(block.timestamp + C.REPO_TENOR);
        vm.prank(bankB);
        repoManager.defaultRepo(repoId);

        assertEq(uint256(repoManager.getRepo(repoId).status), uint256(RepoManager.RepoStatus.DEFAULTED));
        assertEq(uint256(collateralManager.getPosition(positionId).status), uint256(CollateralManager.CollateralStatus.DEFAULTED));

        // Enforcement delivers the locked securities to the lender and clears
        // the custody encumbrance mirror.
        vm.prank(address(repoManager));
        settlement.enforceCollateral(positionId, bankB);
        assertEq(uint256(collateralManager.getPosition(positionId).status), uint256(CollateralManager.CollateralStatus.RECOVERY));
        assertEq(tBondToken.balanceOf(bankB), C.T_BOND_QUANTITY);
        assertEq(tBondToken.balanceOf(address(collateralManager)), 0);
        assertEq(custodyRegistry.getCustodyState(C.T_BOND, bankA).encumberedQuantity, 0);
    }

    function test_doubleSettlementAttemptReverts() public {
        _setupBankAReady(1);
        bytes32 positionId = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));
        bytes32 repoId = _repoAndSettle(positionId, C.REPO_CASH);
        // The repo is already ACTIVE; a second settle must revert.
        vm.prank(bankA);
        vm.expectRevert(RepoManager.InvalidStatus.selector);
        repoManager.settleRepo(repoId);
    }
}
