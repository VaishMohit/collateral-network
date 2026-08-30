// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {TestBase} from "../TestBase.sol";
import {MarginManager} from "../../src/MarginManager.sol";
import {CollateralManager} from "../../src/CollateralManager.sol";
import {RepoManager} from "../../src/RepoManager.sol";
import {LibConstants as C} from "../../script/LibConstants.sol";

/**
 * @title MarginAutomationTest
 * @notice Phase 4 end-to-end: an operator (COLLATERAL_AGENT) evaluates pledged
 *         obligations after a price update and the system raises a margin call
 *         asking for more collateral; satisfies and records history.
 */
contract MarginAutomationTest is TestBase {
    function setUp() public {
        _deployNetwork();
    }

    function test_priceDropThenEvaluateAllRaisesMarginCall() public {
        _setupBankAReady(1);
        bytes32 pos = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, _repoId());
        bytes32 repoId = _repoAndSettle(pos, C.REPO_CASH);
        assertFalse(marginManager.getMarginStatus(repoId).active);

        // Provider submits a lower market price (data-in).
        _submitPrice(C.T_BOND, C.T_BOND_PRICE_DOWN, 3);

        // Operator evaluates all active obligations as the collateral agent.
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = repoId;
        vm.prank(collateralAgent);
        MarginManager.MarginEvaluation[] memory results = marginManager.evaluateAll(ids);

        assertFalse(results[0].isAdequate);
        assertEq(results[0].shortfall, 2_600_000);
        assertEq(results[0].currentValue, 87_400_000);

        // The system has asked for more collateral.
        MarginManager.MarginCall memory mc = marginManager.getMarginStatus(repoId);
        assertTrue(mc.active);
        assertEq(mc.shortfall, 2_600_000);
        assertFalse(marginManager.isAdequatelyCollateralized(repoId));

        // History holds the created-call record.
        MarginManager.MarginCallRecord[] memory history = marginManager.getMarginCallHistory(repoId);
        assertEq(history.length, 1);
        assertFalse(history[0].satisfied);
        assertFalse(history[0].cancelled);
    }

    function test_evaluateAllSatisfyAndRepay() public {
        _setupBankAReady(1);
        bytes32 pos = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, _repoId());
        bytes32 repoId = _repoAndSettle(pos, C.REPO_CASH);

        _submitPrice(C.T_BOND, C.T_BOND_PRICE_DOWN, 3);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = repoId;
        vm.prank(collateralAgent);
        marginManager.evaluateAll(ids);
        assertTrue(marginManager.getMarginStatus(repoId).active);

        // Borrower cures the shortfall with corporate bonds, then satisfies.
        bytes32 corpPos = _pledge(C.CORP_BOND, C.CORP_BOND_QUANTITY, bankB, repoId);
        vm.prank(collateralAgent);
        assertTrue(marginManager.satisfyMarginCall(repoId));
        assertTrue(marginManager.isAdequatelyCollateralized(repoId));
        assertFalse(marginManager.getMarginStatus(repoId).active);

        // History: create (not satisfied) then satisfy.
        MarginManager.MarginCallRecord[] memory history = marginManager.getMarginCallHistory(repoId);
        assertEq(history.length, 2);
        assertTrue(history[0].satisfied); // newest first
        assertFalse(history[1].satisfied);

        // Repay at maturity; both positions release.
        vm.warp(block.timestamp + C.REPO_TENOR);
        vm.startPrank(bankA);
        cash.approve(address(repoManager), type(uint256).max);
        repoManager.repayAndClose(repoId);
        vm.stopPrank();

        assertEq(uint256(repoManager.getRepo(repoId).status), uint256(RepoManager.RepoStatus.CLOSED));
        assertEq(
            uint256(collateralManager.getPosition(pos).status), uint256(CollateralManager.CollateralStatus.RELEASED)
        );
        assertEq(
            uint256(collateralManager.getPosition(corpPos).status), uint256(CollateralManager.CollateralStatus.RELEASED)
        );
    }

    function test_operatorMustBeBankOrAgent() public {
        _setupBankAReady(1);
        bytes32[] memory ids = new bytes32[](0);

        // A non-operator (mockCsd) cannot drive evaluation.
        vm.prank(mockCsd);
        vm.expectRevert(MarginManager.Unauthorized.selector);
        marginManager.evaluateAll(ids);
    }

    function test_cancelRecordedInHistory() public {
        _setupBankAReady(1);
        bytes32 pos = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, _repoId());
        bytes32 repoId = _repoAndSettle(pos, C.REPO_CASH);

        _submitPrice(C.T_BOND, C.T_BOND_PRICE_DOWN, 3);
        vm.prank(collateralAgent);
        marginManager.createMarginCall(repoId);

        vm.prank(collateralAgent);
        marginManager.cancelMarginCall(repoId);

        MarginManager.MarginCallRecord[] memory history = marginManager.getMarginCallHistory(repoId);
        assertEq(history.length, 2);
        assertTrue(history[0].cancelled); // cancel is newest
        assertFalse(history[1].cancelled);
        assertEq(marginManager.getMarginStatus(repoId).obligationId, bytes32(0));
    }
}
