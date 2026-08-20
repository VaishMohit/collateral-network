// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {TestBase} from "../TestBase.sol";
import {AttestationRegistry} from "../../src/AttestationRegistry.sol";
import {Roles} from "../../src/libs/Roles.sol";
import {LibConstants as C} from "../../script/LibConstants.sol";

contract AttestationRegistryTest is TestBase {
    function setUp() public {
        _deployNetwork();
    }

    function _attestation() internal view returns (AttestationRegistry.AssetAttestation memory a) {
        a = _custodyAttestation(C.T_BOND, bankA, custodianA, 10_000);
    }

    function test_custodianCanSubmitSignedAttestation() public {
        AttestationRegistry.AssetAttestation memory a = _attestation();
        bytes32 digest = attestationRegistry.attestationDigest(a);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(C.PK_CUSTODIAN_A, digest);
        vm.prank(custodianA);
        assertTrue(attestationRegistry.createAttestation(a, v, r, s));
        AttestationRegistry.StoredAttestation memory stored = attestationRegistry.getAttestation(a.attestationId);
        assertTrue(stored.exists);
        assertFalse(stored.revoked);
    }

    function test_csdCanSubmitSignedAttestation() public {
        AttestationRegistry.AssetAttestation memory a = _custodyAttestation(C.T_BOND, bankA, mockCsd, 5_000);
        bytes32 digest = attestationRegistry.attestationDigest(a);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(C.PK_MOCK_CSD, digest);
        vm.prank(mockCsd);
        assertTrue(attestationRegistry.createAttestation(a, v, r, s));
    }

    function test_bankCannotAttest() public {
        AttestationRegistry.AssetAttestation memory a = _custodyAttestation(C.T_BOND, bankA, bankA, 10_000);
        bytes32 digest = attestationRegistry.attestationDigest(a);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(C.PK_BANK_A, digest);
        vm.prank(bankA);
        vm.expectRevert(AttestationRegistry.NotAuthorizedAttestor.selector);
        attestationRegistry.createAttestation(a, v, r, s);
    }

    function test_forgedSignatureReverts() public {
        AttestationRegistry.AssetAttestation memory a = _attestation();
        // Sign with a random key, not the declared attestor.
        bytes32 digest = attestationRegistry.attestationDigest(a);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xABCDEF, digest);
        vm.prank(custodianA);
        vm.expectRevert(AttestationRegistry.NotAuthorizedAttestor.selector);
        attestationRegistry.createAttestation(a, v, r, s);
    }

    function test_attestationIdReuseReverts() public {
        AttestationRegistry.AssetAttestation memory a = _attestation();
        _submitCustodyAttestation(a, C.PK_CUSTODIAN_A);
        bytes32 digest = attestationRegistry.attestationDigest(a);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(C.PK_CUSTODIAN_A, digest);
        vm.expectRevert(AttestationRegistry.AttestationAlreadyUsed.selector);
        vm.prank(custodianA);
        attestationRegistry.createAttestation(a, v, r, s);
    }

    function test_expiredAttestationReverts() public {
        AttestationRegistry.AssetAttestation memory a = _attestation();
        a.expiry = block.timestamp; // already expired at submission
        bytes32 digest = attestationRegistry.attestationDigest(a);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(C.PK_CUSTODIAN_A, digest);
        vm.prank(custodianA);
        vm.expectRevert(AttestationRegistry.AttestationExpired.selector);
        attestationRegistry.createAttestation(a, v, r, s);
    }

    function test_unregisteredAssetReverts() public {
        AttestationRegistry.AssetAttestation memory a = _attestation();
        a.assetId = keccak256("NOT-REGISTERED");
        bytes32 digest = attestationRegistry.attestationDigest(a);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(C.PK_CUSTODIAN_A, digest);
        vm.prank(custodianA);
        vm.expectRevert(AttestationRegistry.AssetNotRegistered.selector);
        attestationRegistry.createAttestation(a, v, r, s);
    }

    function test_verifyAttestationFailsAfterExpiry() public {
        _submitCustodyAttestation(_attestation(), C.PK_CUSTODIAN_A);
        AttestationRegistry.AssetAttestation memory a = _attestation();
        vm.warp(block.timestamp + C.ATTESTATION_TTL + 1);
        vm.expectRevert(AttestationRegistry.AttestationExpired.selector);
        attestationRegistry.verifyAttestation(a.attestationId);
    }

    function test_revokeAttestation() public {
        _submitCustodyAttestation(_attestation(), C.PK_CUSTODIAN_A);
        AttestationRegistry.AssetAttestation memory a = _attestation();
        vm.prank(custodianA);
        attestationRegistry.revokeAttestation(a.attestationId);
        vm.expectRevert(AttestationRegistry.RevokedAttestation.selector);
        attestationRegistry.verifyAttestation(a.attestationId);
    }

    function test_adminCanRevokeAnyAttestation() public {
        _submitCustodyAttestation(_attestation(), C.PK_CUSTODIAN_A);
        AttestationRegistry.AssetAttestation memory a = _attestation();
        vm.prank(admin);
        attestationRegistry.revokeAttestation(a.attestationId);
    }

    function test_unauthorizedRevokeReverts() public {
        _submitCustodyAttestation(_attestation(), C.PK_CUSTODIAN_A);
        AttestationRegistry.AssetAttestation memory a = _attestation();
        vm.prank(bankA);
        vm.expectRevert(AttestationRegistry.NotAuthorizedAttestor.selector);
        attestationRegistry.revokeAttestation(a.attestationId);
    }
}
