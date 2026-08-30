// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {TestBase} from "../TestBase.sol";
import {MarginManager} from "../../src/MarginManager.sol";
import {LibConstants as C} from "../../script/LibConstants.sol";

contract MarginManagerTest is TestBase {
    function setUp() public {
        _deployNetwork();
    }

    function test_setRequirementOnlyBankOrAgent() public {
        vm.prank(mockCsd);
        vm.expectRevert(MarginManager.Unauthorized.selector);
        marginManager.setRequirement(_repoId(), C.REQUIREMENT);
    }

    function test_setRequirementZeroReverts() public {
        vm.prank(bankB);
        vm.expectRevert(MarginManager.ZeroRequirement.selector);
        marginManager.setRequirement(_repoId(), 0);
    }

    function test_createMarginCallNoRequirementReverts() public {
        vm.prank(bankA);
        vm.expectRevert(MarginManager.NoRequirement.selector);
        marginManager.createMarginCall(_repoId());
    }

    function test_createMarginCallNoShortfallReverts() public {
        _setupBankAReady(1);
        _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, _repoId());
        vm.prank(bankA);
        vm.expectRevert(MarginManager.NoShortfall.selector);
        marginManager.createMarginCall(_repoId());
    }

    function test_createMarginCallOnPriceDrop() public {
        _setupBankAReady(1);
        _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, _repoId());

        _submitPrice(C.T_BOND, C.T_BOND_PRICE_DOWN, 3);
        vm.prank(bankA);
        uint256 shortfall = marginManager.createMarginCall(_repoId());

        // 90,000,000 required vs 87,400,000 collateral value.
        assertEq(shortfall, 2_600_000);
        MarginManager.MarginCall memory mc = marginManager.getMarginStatus(_repoId());
        assertTrue(mc.active);
        assertEq(mc.requiredValue, C.REQUIREMENT);
        assertEq(mc.currentValue, 87_400_000);
    }

    function test_satisfyMarginCallWithAdditionalCollateral() public {
        _setupBankAReady(1);
        _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, _repoId());
        _submitPrice(C.T_BOND, C.T_BOND_PRICE_DOWN, 3);
        vm.prank(bankA);
        marginManager.createMarginCall(_repoId());

        // Bank A posts the corporate bond under the same obligation.
        _pledge(C.CORP_BOND, C.CORP_BOND_QUANTITY, bankB, _repoId());

        vm.prank(bankA);
        assertTrue(marginManager.satisfyMarginCall(_repoId()));
        MarginManager.MarginCall memory mc = marginManager.getMarginStatus(_repoId());
        assertFalse(mc.active);
        assertTrue(mc.satisfied);
        assertTrue(marginManager.isAdequatelyCollateralized(_repoId()));
    }

    function test_satisfyMarginCallStillUnderwaterReturnsFalse() public {
        _setupBankAReady(1);
        _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, _repoId());
        _submitPrice(C.T_BOND, C.T_BOND_PRICE_DOWN, 3);
        vm.prank(bankA);
        marginManager.createMarginCall(_repoId());

        vm.prank(bankA);
        assertFalse(marginManager.satisfyMarginCall(_repoId()));
        assertTrue(marginManager.getMarginStatus(_repoId()).active);
    }

    function test_satisfyWithoutActiveCallReverts() public {
        _setupBankAReady(1);
        vm.prank(bankA);
        vm.expectRevert(MarginManager.NoRequirement.selector);
        marginManager.satisfyMarginCall(_repoId());
    }

    function test_cancelMarginCall() public {
        _setupBankAReady(1);
        _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, _repoId());
        _submitPrice(C.T_BOND, C.T_BOND_PRICE_DOWN, 3);
        vm.prank(bankA);
        marginManager.createMarginCall(_repoId());

        vm.prank(bankA);
        marginManager.cancelMarginCall(_repoId());
        MarginManager.MarginCall memory mc = marginManager.getMarginStatus(_repoId());
        assertEq(mc.obligationId, bytes32(0));
    }

    function test_isAdequatelyCollateralizedBaseline() public {
        _setupBankAReady(1);
        _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, _repoId());
        assertTrue(marginManager.isAdequatelyCollateralized(_repoId()));

        _submitPrice(C.T_BOND, C.T_BOND_PRICE_DOWN, 3);
        assertFalse(marginManager.isAdequatelyCollateralized(_repoId()));
    }

    /* ============================================================
     * Phase 4: evaluateMargin / previewMarginCall
     * ============================================================ */

    function test_evaluateMarginAdequate() public {
        _setupBankAReady(1);
        _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, _repoId());

        MarginManager.MarginEvaluation memory eval = marginManager.evaluateMargin(_repoId());
        assertTrue(eval.isAdequate);
        assertEq(eval.shortfall, 0);
        assertEq(eval.requiredValue, C.REQUIREMENT);
        assertEq(eval.currentValue, 95_000_000); // 10,000 * $100 * 0.95
    }

    function test_evaluateMarginShortfall() public {
        _setupBankAReady(1);
        _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, _repoId());
        _submitPrice(C.T_BOND, C.T_BOND_PRICE_DOWN, 3);

        // evaluation is non-mutating: no call created.
        MarginManager.MarginEvaluation memory eval = marginManager.evaluateMargin(_repoId());
        assertFalse(eval.isAdequate);
        assertEq(eval.shortfall, 2_600_000);
        assertEq(eval.requiredValue, C.REQUIREMENT);
        assertEq(eval.currentValue, 87_400_000);
        assertFalse(marginManager.getMarginStatus(_repoId()).active);
    }

    function test_evaluateMarginNoRequirementReverts() public {
        vm.expectRevert(MarginManager.NoRequirement.selector);
        marginManager.evaluateMargin(_repoId());
    }

    function test_evaluateMarginStalePriceReverts() public {
        _setupBankAReady(1);
        _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, _repoId());

        vm.warp(block.timestamp + 6 minutes);
        vm.expectRevert(); // ValuationOracle.PriceTooOld
        marginManager.evaluateMargin(_repoId());
    }

    function test_previewMarginCallAlias() public {
        _setupBankAReady(1);
        _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, _repoId());
        _submitPrice(C.T_BOND, C.T_BOND_PRICE_DOWN, 3);

        MarginManager.MarginEvaluation memory eval1 = marginManager.evaluateMargin(_repoId());
        MarginManager.MarginEvaluation memory eval2 = marginManager.previewMarginCall(_repoId());
        assertEq(eval1.isAdequate, eval2.isAdequate);
        assertEq(eval1.shortfall, eval2.shortfall);
        assertEq(eval1.requiredValue, eval2.requiredValue);
        assertEq(eval1.currentValue, eval2.currentValue);
    }

    /* ============================================================
     * Phase 4: evaluateAll
     * ============================================================ */

    function test_evaluateAllCreatesCallsForShortfallOnly() public {
        bytes32 repoId1 = _repoId();
        bytes32 repoId2 = keccak256(abi.encode("REPO", uint256(2), bankA, bankB));

        _setupBankAReady(1);
        _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, repoId1);
        _pledge(C.CORP_BOND, C.CORP_BOND_QUANTITY, bankB, repoId2);
        vm.prank(bankB);
        marginManager.setRequirement(repoId2, C.REQUIREMENT);

        // Drop T-BOND only (nonce 3 after setup). CORP_BOND stays at $100.
        _submitPrice(C.T_BOND, C.T_BOND_PRICE_DOWN, 3);
        vm.prank(bankB);

        bytes32[] memory obligations = new bytes32[](2);
        obligations[0] = repoId1;
        obligations[1] = repoId2;
        MarginManager.MarginEvaluation[] memory results = marginManager.evaluateAll(obligations);

        assertFalse(results[0].isAdequate);
        assertEq(results[0].shortfall, 2_600_000);
        assertTrue(results[1].isAdequate);
        assertEq(results[1].shortfall, 0);

        assertTrue(marginManager.getMarginStatus(repoId1).active);
        assertEq(marginManager.getMarginStatus(repoId2).obligationId, bytes32(0));
    }

    function test_evaluateAllUnauthorizedReverts() public {
        _setupBankAReady(1);
        bytes32[] memory obligations = new bytes32[](1);
        obligations[0] = _repoId();

        vm.prank(mockCsd); // not BANK or AGENT
        vm.expectRevert(MarginManager.Unauthorized.selector);
        marginManager.evaluateAll(obligations);
    }

    function test_evaluateAllGas() public {
        _setupBankAReady(1);
        _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, _repoId());
        _submitPrice(C.T_BOND, C.T_BOND_PRICE_DOWN, 3);

        bytes32[] memory obligations = new bytes32[](10);
        for (uint256 i = 0; i < 10; i++) {
            obligations[i] = keccak256(abi.encode("REPO", i, bankA, bankB));
            vm.prank(bankB);
            marginManager.setRequirement(obligations[i], C.REQUIREMENT);
        }
        vm.prank(bankB);
        marginManager.evaluateAll(obligations);
    }

    /* ============================================================
     * Phase 4: margin-call history (ring buffer)
     * ============================================================ */

    function test_historyStoresCreateAndSatisfy() public {
        _setupBankAReady(1);
        _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, _repoId());
        _submitPrice(C.T_BOND, C.T_BOND_PRICE_DOWN, 3);

        vm.prank(bankB);
        marginManager.createMarginCall(_repoId());

        MarginManager.MarginCallRecord[] memory history = marginManager.getMarginCallHistory(_repoId());
        assertEq(history.length, 1);
        assertFalse(history[0].satisfied);
        assertFalse(history[0].cancelled);
        assertEq(history[0].shortfall, 2_600_000);

        // Satisfy by posting corporate bonds (adequate at $100).
        _pledge(C.CORP_BOND, C.CORP_BOND_QUANTITY, bankB, _repoId());
        vm.prank(bankB);
        assertTrue(marginManager.satisfyMarginCall(_repoId()));

        history = marginManager.getMarginCallHistory(_repoId());
        assertEq(history.length, 2);
        assertTrue(history[0].satisfied); // newest first
        assertFalse(history[1].satisfied);
    }

    function test_historyRingBufferOverwrites() public {
        _setupBankAReady(1);
        _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, _repoId());

        uint256 nonce = 3;
        // 6 cycles * (create + satisfy + cancel) = 18 records > HISTORY_SIZE=16.
        for (uint256 i = 0; i < 6; i++) {
            _submitPrice(C.T_BOND, C.T_BOND_PRICE_DOWN, nonce++);
            vm.prank(bankB);
            marginManager.createMarginCall(_repoId());

            // Restore price -> the single T-BOND pledge becomes adequate again.
            _submitPrice(C.T_BOND, C.T_BOND_PRICE, nonce++);
            vm.prank(bankB);
            assertTrue(marginManager.satisfyMarginCall(_repoId()));

            vm.prank(bankB);
            marginManager.cancelMarginCall(_repoId());
        }

        MarginManager.MarginCallRecord[] memory history = marginManager.getMarginCallHistory(_repoId());
        assertEq(history.length, 16); // Capped at HISTORY_SIZE
        assertEq(marginManager.HISTORY_SIZE(), 16);
    }

    function test_historyPagination() public {
        _setupBankAReady(1);
        _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, _repoId());
        _submitPrice(C.T_BOND, C.T_BOND_PRICE_DOWN, 3);

        vm.prank(bankB);
        marginManager.createMarginCall(_repoId());
        _pledge(C.CORP_BOND, C.CORP_BOND_QUANTITY, bankB, _repoId());
        vm.prank(bankB);
        assertTrue(marginManager.satisfyMarginCall(_repoId()));

        MarginManager.MarginCallRecord[] memory page1 = marginManager.getMarginCallHistoryPaginated(_repoId(), 0, 1);
        assertEq(page1.length, 1);
        assertTrue(page1[0].satisfied); // newest first

        MarginManager.MarginCallRecord[] memory page2 = marginManager.getMarginCallHistoryPaginated(_repoId(), 1, 1);
        assertEq(page2.length, 1);
        assertFalse(page2[0].satisfied);

        MarginManager.MarginCallRecord[] memory page3 = marginManager.getMarginCallHistoryPaginated(_repoId(), 2, 1);
        assertEq(page3.length, 0);
    }

    function test_historyNewestFirst() public {
        _setupBankAReady(1);
        _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, _repoId());
        _submitPrice(C.T_BOND, C.T_BOND_PRICE_DOWN, 3);

        vm.prank(bankB);
        marginManager.createMarginCall(_repoId());
        uint256 firstShortfall = marginManager.getMarginCallHistory(_repoId())[0].shortfall;

        _pledge(C.CORP_BOND, C.CORP_BOND_QUANTITY, bankB, _repoId());
        vm.prank(bankB);
        assertTrue(marginManager.satisfyMarginCall(_repoId()));

        MarginManager.MarginCallRecord[] memory history = marginManager.getMarginCallHistory(_repoId());
        assertTrue(history[0].satisfied); // newest record
        assertFalse(history[1].satisfied);
        assertEq(history[1].shortfall, firstShortfall);
    }
}
