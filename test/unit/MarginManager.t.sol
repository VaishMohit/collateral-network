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
        vm.expectRevert("Margin: zero requirement");
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
}
