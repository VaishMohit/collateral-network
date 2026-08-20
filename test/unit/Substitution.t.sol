// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {TestBase} from "../TestBase.sol";
import {CollateralManager} from "../../src/CollateralManager.sol";
import {PledgeManager} from "../../src/PledgeManager.sol";
import {LibConstants as C} from "../../script/LibConstants.sol";

contract SubstitutionTest is TestBase {
    function setUp() public {
        _deployNetwork();
    }

    /// @notice Top up Bank A's corporate bond position so it can replace the
    ///         full T-BOND position at equal or higher value.
    function _topUpCorpForSubstitution() internal {
        vm.prank(admin);
        corpBondToken.mint(bankA, 1_000);
        _attest(C.CORP_BOND, bankA, 11_000, custodianA, C.PK_CUSTODIAN_A);
    }

    function test_fullSubstitutionFlow() public {
        _setupBankAReady(1);
        bytes32 oldId = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));
        _topUpCorpForSubstitution();

        vm.prank(bankA);
        bytes32 replacementId = pledgeManager.requestSubstitution(oldId, C.CORP_BOND, 11_000);

        vm.prank(collateralAgent);
        pledgeManager.validateReplacement(replacementId);
        vm.prank(bankA);
        pledgeManager.reserveReplacement(replacementId);
        vm.prank(bankA);
        pledgeManager.activateSubstitution(oldId);

        CollateralManager.CollateralPosition memory old = collateralManager.getPosition(oldId);
        CollateralManager.CollateralPosition memory rep = collateralManager.getPosition(replacementId);
        assertEq(uint256(old.status), uint256(CollateralManager.CollateralStatus.RELEASED));
        assertEq(uint256(rep.status), uint256(CollateralManager.CollateralStatus.PLEDGED));
        assertEq(rep.assetId, C.CORP_BOND);
        assertEq(rep.quantity, 11_000);

        // Old collateral returned; replacement locked; encumbrance mirrors swap.
        assertEq(tBondToken.balanceOf(bankA), C.T_BOND_QUANTITY);
        assertEq(corpBondToken.balanceOf(bankA), 0);
        assertEq(corpBondToken.balanceOf(address(collateralManager)), 11_000);
        assertEq(custodyRegistry.getCustodyState(C.T_BOND).encumberedQuantity, 0);
        assertEq(custodyRegistry.getCustodyState(C.CORP_BOND).encumberedQuantity, 11_000);
    }

    function test_substitutionOnlyByProviderOrAgent() public {
        _setupBankAReady(1);
        bytes32 oldId = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));
        vm.prank(bankB);
        vm.expectRevert(PledgeManager.NotProvider.selector);
        pledgeManager.requestSubstitution(oldId, C.CORP_BOND, 100);
    }

    function test_validateReplacementValueTooLowReverts() public {
        _setupBankAReady(1);
        bytes32 oldId = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));
        // 10,000 CORP = $900k collateral < $950k T-BOND collateral.
        vm.prank(bankA);
        bytes32 replacementId = pledgeManager.requestSubstitution(oldId, C.CORP_BOND, 10_000);
        vm.prank(collateralAgent);
        vm.expectRevert(CollateralManager.InvalidValueRelation.selector);
        pledgeManager.validateReplacement(replacementId);
    }

    function test_validateReplacementOnlyAgent() public {
        _setupBankAReady(1);
        bytes32 oldId = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));
        _topUpCorpForSubstitution();
        vm.prank(bankA);
        bytes32 replacementId = pledgeManager.requestSubstitution(oldId, C.CORP_BOND, 11_000);
        vm.prank(bankA);
        vm.expectRevert(PledgeManager.Unauthorized.selector);
        pledgeManager.validateReplacement(replacementId);
    }

    function test_cancelSubstitutionUnlocksReplacement() public {
        _setupBankAReady(1);
        bytes32 oldId = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));
        _topUpCorpForSubstitution();

        vm.prank(bankA);
        bytes32 replacementId = pledgeManager.requestSubstitution(oldId, C.CORP_BOND, 11_000);
        vm.prank(collateralAgent);
        pledgeManager.validateReplacement(replacementId);
        vm.prank(bankA);
        pledgeManager.reserveReplacement(replacementId);

        vm.prank(bankA);
        pledgeManager.cancelSubstitution(oldId);

        // Old still pledged; replacement unlocked back to provider.
        assertEq(uint256(collateralManager.getPosition(oldId).status), uint256(CollateralManager.CollateralStatus.PLEDGED));
        assertEq(uint256(collateralManager.getPosition(replacementId).status), uint256(CollateralManager.CollateralStatus.AVAILABLE));
        assertEq(corpBondToken.balanceOf(bankA), 11_000);
        assertEq(corpBondToken.balanceOf(address(collateralManager)), 0);
        assertEq(custodyRegistry.getCustodyState(C.CORP_BOND).encumberedQuantity, 0);
    }
}
