// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {TestBase} from "../TestBase.sol";
import {EligibilityPolicy} from "../../src/EligibilityPolicy.sol";
import {AssetRegistry} from "../../src/AssetRegistry.sol";
import {LibConstants as C} from "../../script/LibConstants.sol";

contract EligibilityPolicyTest is TestBase {
    function setUp() public {
        _deployNetwork();
    }

    function test_bootstrappedPolicies() public view {
        (bool tEligible, uint256 tHaircut,) = eligibility.policies(AssetRegistry.AssetType.TREASURY);
        assertTrue(tEligible);
        assertEq(tHaircut, 500);
        (bool cEligible, uint256 cHaircut,) = eligibility.policies(AssetRegistry.AssetType.CORPORATE_BOND);
        assertTrue(cEligible);
        assertEq(cHaircut, 1000);
    }

    function test_onlyPolicyAdminCanSetPolicy() public {
        vm.prank(bankA);
        vm.expectRevert(EligibilityPolicy.Unauthorized.selector);
        eligibility.setPolicy(AssetRegistry.AssetType.TREASURY, false, 500, 0);
    }

    function test_setPolicyUpdatesState() public {
        vm.prank(admin);
        eligibility.setPolicy(AssetRegistry.AssetType.TREASURY, false, 700, 0);
        (bool eligible, uint256 haircutBps,) = eligibility.policies(AssetRegistry.AssetType.TREASURY);
        assertFalse(eligible);
        assertEq(haircutBps, 700);
    }

    function test_haircutAtOrAboveFullReverts() public {
        vm.prank(admin);
        vm.expectRevert("Eligibility: haircut >= 100%");
        eligibility.setPolicy(AssetRegistry.AssetType.TREASURY, true, 10_000, 0);
    }

    function test_setDefaultMinimumTerm() public {
        vm.prank(admin);
        eligibility.setDefaultMinimumTerm(30 days);
        assertEq(eligibility.defaultMinimumTerm(), 30 days);
    }

    function test_notEligibleWithoutCustody() public view {
        assertFalse(eligibility.isEligible(C.T_BOND, bankA));
    }

    function test_unknownAssetReverts() public {
        vm.expectRevert(AssetRegistry.NotRegistered.selector);
        eligibility.isEligible(keccak256("GHOST"), bankA);
    }

    function test_treasuryEligibleAfterAttestation() public {
        _attest(C.T_BOND, bankA, 10_000, custodianA, C.PK_CUSTODIAN_A);
        assertTrue(eligibility.isEligible(C.T_BOND, bankA));
        assertFalse(eligibility.isEligible(C.T_BOND, bankB));
    }

    function test_notEligibleWhenQuantityExhausted() public {
        _attest(C.T_BOND, bankA, 10_000, custodianA, C.PK_CUSTODIAN_A);
        vm.prank(address(collateralManager));
        custodyRegistry.applyEncumbrance(C.T_BOND, bankA, 10_000);
        assertFalse(eligibility.isEligible(C.T_BOND, bankA));
    }

    function test_corporateBondEligibleWithAARating() public {
        _attest(C.CORP_BOND, bankA, 10_000, custodianA, C.PK_CUSTODIAN_A);
        assertTrue(eligibility.isEligible(C.CORP_BOND, bankA));
    }

    function test_corporateBondFailsWhenMatured() public {
        _attest(C.CORP_BOND, bankA, 10_000, custodianA, C.PK_CUSTODIAN_A);
        vm.warp(C.CORP_BOND_MATURITY + 1);
        assertFalse(eligibility.isEligible(C.CORP_BOND, bankA));
    }

    function test_inactiveAssetNotEligible() public {
        _attest(C.T_BOND, bankA, 10_000, custodianA, C.PK_CUSTODIAN_A);
        vm.prank(admin);
        assetRegistry.deactivateAsset(C.T_BOND);
        assertFalse(eligibility.isEligible(C.T_BOND, bankA));
    }

    function test_haircuts() public view {
        assertEq(eligibility.getHaircut(C.T_BOND), 500);
        assertEq(eligibility.getHaircut(C.CORP_BOND), 1000);
    }

    function test_collateralValueAppliesHaircut() public {
        _submitPrice(C.T_BOND, 10_000, 1);
        (uint256 marketValue, uint256 collateralValue) = eligibility.getCollateralValue(C.T_BOND, 10_000);
        assertEq(marketValue, 100_000_000);
        assertEq(collateralValue, 95_000_000);
    }

    function test_collateralValueStalePriceReverts() public {
        _submitPrice(C.T_BOND, 10_000, 1);
        vm.warp(block.timestamp + oracle.MAX_PRICE_AGE() + 1);
        vm.expectRevert();
        eligibility.getCollateralValue(C.T_BOND, 10_000);
    }

    function test_assessCollateralHappyPath() public {
        _attest(C.T_BOND, bankA, 10_000, custodianA, C.PK_CUSTODIAN_A);
        _submitPrice(C.T_BOND, 10_000, 1);
        (uint256 marketValue, uint256 collateralValue, uint256 haircutBps) =
            eligibility.assessCollateral(C.T_BOND, bankA, 10_000);
        assertEq(marketValue, 100_000_000);
        assertEq(collateralValue, 95_000_000);
        assertEq(haircutBps, 500);
    }

    function test_assessCollateralNotEligibleReverts() public {
        _submitPrice(C.T_BOND, 10_000, 1);
        vm.expectRevert("Eligibility: not eligible");
        eligibility.assessCollateral(C.T_BOND, bankA, 10_000);
    }

    function test_assessCollateralUnavailableReverts() public {
        _attest(C.T_BOND, bankA, 10_000, custodianA, C.PK_CUSTODIAN_A);
        _submitPrice(C.T_BOND, 10_000, 1);
        vm.expectRevert("Eligibility: custody unavailable");
        eligibility.assessCollateral(C.T_BOND, bankA, 10_001);
    }
}
