// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {TestBase} from "../TestBase.sol";
import {ComplianceAttestationRegistry} from "../../src/ComplianceAttestationRegistry.sol";
import {Roles} from "../../src/libs/Roles.sol";
import {LibConstants as C} from "../../script/LibConstants.sol";

contract ComplianceAttestationRegistryTest is TestBase {
    function setUp() public {
        _deployNetwork();
    }

    function test_submitMakesSubjectCompliant() public {
        _submitCompliance(bankA);
        assertTrue(complianceRegistry.isCompliant(bankA));
    }

    function test_unauthorizedAttestorReverts() public {
        ComplianceAttestationRegistry.ComplianceAttestation memory c = _complianceAttestation(bankA);
        // Sign with bankA's key instead of the compliance provider.
        bytes32 digest = complianceRegistry.complianceDigest(c);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(C.PK_BANK_A, digest);
        vm.prank(bankA);
        vm.expectRevert(ComplianceAttestationRegistry.NotAuthorizedAttestor.selector);
        complianceRegistry.submitComplianceAttestation(c, v, r, s);
    }

    function test_failedChecksRevert() public {
        ComplianceAttestationRegistry.ComplianceAttestation memory c = _complianceAttestation(bankA);
        c.amlPassed = false;
        bytes32 digest = complianceRegistry.complianceDigest(c);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(C.PK_COMPLIANCE_PROVIDER, digest);
        vm.prank(complianceProvider);
        vm.expectRevert("Compliance: not passed");
        complianceRegistry.submitComplianceAttestation(c, v, r, s);
    }

    function test_expiredAttestationReverts() public {
        ComplianceAttestationRegistry.ComplianceAttestation memory c = _complianceAttestation(bankA);
        c.expiry = block.timestamp;
        bytes32 digest = complianceRegistry.complianceDigest(c);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(C.PK_COMPLIANCE_PROVIDER, digest);
        vm.prank(complianceProvider);
        vm.expectRevert("Compliance: expired");
        complianceRegistry.submitComplianceAttestation(c, v, r, s);
    }

    function test_expiryStopsCompliance() public {
        _submitCompliance(bankA);
        vm.warp(block.timestamp + C.COMPLIANCE_TTL + 1);
        vm.expectRevert(ComplianceAttestationRegistry.ComplianceAttestationExpired.selector);
        complianceRegistry.isCompliant(bankA);
    }

    function test_unattestedSubjectNotCompliant() public {
        assertFalse(complianceRegistry.isCompliant(vm.addr(0xbeef)));
    }

    function test_revokeClearsSubject() public {
        _submitCompliance(bankA);
        bytes32 id = complianceRegistry.subjectAttestation(bankA);
        vm.prank(complianceProvider);
        complianceRegistry.revokeComplianceAttestation(id);
        assertEq(complianceRegistry.subjectAttestation(bankA), bytes32(0));
        assertFalse(complianceRegistry.isCompliant(bankA));
    }

    function test_newerAttestationReplacesSubject() public {
        _submitCompliance(bankA);
        bytes32 first = complianceRegistry.subjectAttestation(bankA);
        // Second attestation for the same subject overrides the subject pointer.
        ComplianceAttestationRegistry.ComplianceAttestation memory c = _complianceAttestation(bankA);
        c.attestationId = keccak256("COMPLIANCE_V2");
        bytes32 digest = complianceRegistry.complianceDigest(c);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(C.PK_COMPLIANCE_PROVIDER, digest);
        vm.prank(complianceProvider);
        complianceRegistry.submitComplianceAttestation(c, v, r, s);
        bytes32 second = complianceRegistry.subjectAttestation(bankA);
        assertTrue(first != second);
        assertEq(second, c.attestationId);
    }
}
