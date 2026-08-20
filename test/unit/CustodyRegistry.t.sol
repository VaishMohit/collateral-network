// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {TestBase} from "../TestBase.sol";
import {CustodyRegistry} from "../../src/CustodyRegistry.sol";
import {AttestationRegistry} from "../../src/AttestationRegistry.sol";
import {LibConstants as C} from "../../script/LibConstants.sol";

contract CustodyRegistryTest is TestBase {
    function setUp() public {
        _deployNetwork();
    }

    function test_updateFromAttestationRecordsState() public {
        _attest(C.T_BOND, bankA, 10_000, custodianA, C.PK_CUSTODIAN_A);
        CustodyRegistry.CustodyState memory cs = custodyRegistry.getCustodyState(C.T_BOND);
        assertEq(cs.owner, bankA);
        assertEq(cs.custodian, custodianA);
        assertEq(cs.totalQuantity, 10_000);
        assertEq(cs.encumberedQuantity, 0);
        assertTrue(cs.lastAttestationId != bytes32(0));
    }

    function test_bankCannotUpdateCustody() public {
        _submitCustodyAttestation(_custodyAttestation(C.T_BOND, bankA, custodianA, 10_000), C.PK_CUSTODIAN_A);
        AttestationRegistry.AssetAttestation memory a = _custodyAttestation(C.T_BOND, bankA, custodianA, 9_000);
        a.attestationId = keccak256("SECOND");
        _submitCustodyAttestation(a, C.PK_CUSTODIAN_A);
        vm.prank(bankA);
        vm.expectRevert("CustodyRegistry: unauthorized");
        custodyRegistry.updateCustodyAttestation(a.attestationId);
    }

    function test_encumbranceOnlyCollateralManager() public {
        _attest(C.T_BOND, bankA, 10_000, custodianA, C.PK_CUSTODIAN_A);
        vm.prank(bankA);
        vm.expectRevert(CustodyRegistry.OnlyCollateralManager.selector);
        custodyRegistry.applyEncumbrance(C.T_BOND, 100);
    }

    function test_applyAndReleaseEncumbrance() public {
        _attest(C.T_BOND, bankA, 10_000, custodianA, C.PK_CUSTODIAN_A);
        vm.prank(address(collateralManager));
        custodyRegistry.applyEncumbrance(C.T_BOND, 4_000);
        assertEq(custodyRegistry.availableQuantity(C.T_BOND), 6_000);
        assertEq(custodyRegistry.getCustodyState(C.T_BOND).encumberedQuantity, 4_000);
        vm.prank(address(collateralManager));
        custodyRegistry.applyEncumbrance(C.T_BOND, -4_000);
        assertEq(custodyRegistry.availableQuantity(C.T_BOND), 10_000);
    }

    function test_overEncumbranceReverts() public {
        _attest(C.T_BOND, bankA, 10_000, custodianA, C.PK_CUSTODIAN_A);
        vm.prank(address(collateralManager));
        vm.expectRevert(CustodyRegistry.InvalidEncumbrance.selector);
        custodyRegistry.applyEncumbrance(C.T_BOND, 10_001);
    }

    function test_negativeEncumbranceBelowZeroReverts() public {
        _attest(C.T_BOND, bankA, 10_000, custodianA, C.PK_CUSTODIAN_A);
        vm.prank(address(collateralManager));
        vm.expectRevert(CustodyRegistry.InvalidEncumbrance.selector);
        custodyRegistry.applyEncumbrance(C.T_BOND, -1);
    }

    function test_encumbranceOnUnattestedAssetReverts() public {
        vm.prank(address(collateralManager));
        vm.expectRevert(CustodyRegistry.AssetNotAttested.selector);
        custodyRegistry.applyEncumbrance(C.CORP_BOND, 100);
    }

    function test_isAvailableForCollateral() public {
        _attest(C.T_BOND, bankA, 10_000, custodianA, C.PK_CUSTODIAN_A);
        assertTrue(custodyRegistry.isAvailableForCollateral(C.T_BOND, bankA, 10_000));
        assertFalse(custodyRegistry.isAvailableForCollateral(C.T_BOND, bankA, 10_001));
        assertFalse(custodyRegistry.isAvailableForCollateral(C.T_BOND, bankB, 100));
        assertFalse(custodyRegistry.isAvailableForCollateral(C.T_BOND, bankA, 0));
        vm.prank(address(collateralManager));
        custodyRegistry.applyEncumbrance(C.T_BOND, 10_000);
        assertFalse(custodyRegistry.isAvailableForCollateral(C.T_BOND, bankA, 1));
    }

    function test_revokeOnCustodyDoesNotUnsetState() public {
        _attest(C.T_BOND, bankA, 10_000, custodianA, C.PK_CUSTODIAN_A);
        AttestationRegistry.StoredAttestation memory stored = attestationRegistry.getAttestation(
            custodyRegistry.getCustodyState(C.T_BOND).lastAttestationId
        );
        vm.prank(custodianA);
        attestationRegistry.revokeAttestation(stored.data.attestationId);
        // The custody mirror keeps the last attested state; eligibility checks the attestation
        // freshness through CustodyRegistry's own state (attestation id), not re-verification.
        assertEq(custodyRegistry.getCustodyState(C.T_BOND).totalQuantity, 10_000);
    }
}
