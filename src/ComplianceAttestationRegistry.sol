// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ProtocolAccessManager} from "./ProtocolAccessManager.sol";
import {Roles} from "./libs/Roles.sol";
import {AuditRegistry} from "./AuditRegistry.sol";
import {SignatureVerifier} from "./libs/SignatureVerifier.sol";

/**
 * @title ComplianceAttestationRegistry
 * @notice Simplified on-chain record of off-chain KYC/AML/sanctions/jurisdiction
 *         checks. Identity material NEVER lives on-chain.
 *
 * @dev Pattern required by the architecture:
 *            Off-chain KYC/AML  ->  signed compliance attestation  ->  on-chain gate.
 *      Only a boolean "compliant until <expiry>" flag is stored, produced from a
 *      signature by an authorized COMPLIANCE_PROVIDER.
 */
contract ComplianceAttestationRegistry {
    struct ComplianceAttestation {
        bytes32 attestationId;
        address subject; // institution checked off-chain
        bool kycPassed;
        bool amlPassed;
        bool sanctionsPassed;
        bool jurisdictionAccepted;
        uint256 timestamp;
        uint256 expiry;
        address attestor;
    }

    ProtocolAccessManager public immutable access;
    AuditRegistry public immutable audit;

    /// subject => current active attestation id
    mapping(address => bytes32) public subjectAttestation;
    /// attestationId => stored attestation
    mapping(bytes32 => ComplianceAttestation) public attestations;

    event ComplianceAttestationSubmitted(bytes32 indexed attestationId, address indexed subject);
    event ComplianceAttestationRevoked(bytes32 indexed attestationId, address indexed subject);

    error NotAuthorizedAttestor();
    error ComplianceAttestationExpired();

    constructor(ProtocolAccessManager access_, AuditRegistry audit_) {
        access = access_;
        audit = audit_;
    }

    function complianceHash(ComplianceAttestation memory c) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                c.attestationId,
                c.subject,
                c.kycPassed,
                c.amlPassed,
                c.sanctionsPassed,
                c.jurisdictionAccepted,
                c.timestamp,
                c.expiry
            )
        );
    }

    function complianceDigest(ComplianceAttestation memory c) public pure returns (bytes32) {
        return SignatureVerifier.signedDigest(complianceHash(c));
    }

    function submitComplianceAttestation(
        ComplianceAttestation calldata c,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        address signer = SignatureVerifier.recoverSigner(complianceHash(c), v, r, s);
        if (signer != c.attestor) revert NotAuthorizedAttestor();
        if (!access.hasRole(Roles.COMPLIANCE_PROVIDER, signer)) revert NotAuthorizedAttestor();

        require(c.expiry > block.timestamp, "Compliance: expired");
        require(c.kycPassed && c.amlPassed && c.sanctionsPassed && c.jurisdictionAccepted, "Compliance: not passed");

        attestations[c.attestationId] = c;
        subjectAttestation[c.subject] = c.attestationId;

        audit.log(
            AuditRegistry.AuditEventType.COMPLIANCE_ATTESTED,
            c.subject,
            c.attestationId,
            0,
            0,
            bytes32(0),
            bytes32("COMPLIANT")
        );
        emit ComplianceAttestationSubmitted(c.attestationId, c.subject);
    }

    function revokeComplianceAttestation(bytes32 attestationId) external {
        ComplianceAttestation storage c = attestations[attestationId];
        require(c.attestor != address(0), "Compliance: missing");
        bool isAttestor = msg.sender == c.attestor;
        bool isAdmin = access.hasRole(Roles.ADMIN, msg.sender);
        require(isAttestor || isAdmin, "Compliance: unauthorized");

        if (subjectAttestation[c.subject] == attestationId) subjectAttestation[c.subject] = bytes32(0);
        delete attestations[attestationId];

        emit ComplianceAttestationRevoked(attestationId, c.subject);
    }

    /**
     * @notice True if `subject` currently holds a valid, all-green compliance attestation.
     */
    function isCompliant(address subject) public view returns (bool) {
        bytes32 id = subjectAttestation[subject];
        if (id == bytes32(0)) return false;
        ComplianceAttestation storage c = attestations[id];
        if (c.expiry <= block.timestamp) revert ComplianceAttestationExpired();
        return c.kycPassed && c.amlPassed && c.sanctionsPassed && c.jurisdictionAccepted;
    }
}
