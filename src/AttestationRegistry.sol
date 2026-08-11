// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ProtocolAccessManager} from "./ProtocolAccessManager.sol";
import {Roles} from "./libs/Roles.sol";
import {AssetRegistry} from "./AssetRegistry.sol";
import {AuditRegistry} from "./AuditRegistry.sol";
import {SignatureVerifier} from "./libs/SignatureVerifier.sol";

/**
 * @title AttestationRegistry
 * @notice Generic signed-attestation model bridging the off-chain financial
 *         system (CSD / Custodian) into the on-chain collateral network.
 *
 * @dev The blockchain is NOT the authoritative CSD. The Mock CSD and the
 *      Custodian remain authoritative for the underlying securities. All they do
 *      on-chain is publish cryptographically signed attestations describing the
 *      custody state (owner, quantity, encumbrance). On-chain logic reads these
 *      attestations and never calls `setOwner()`-style setters directly.
 *
 *      Verification performed at submission:
 *        - the recovered signer equals the declared attestor
 *        - the attestor holds the CSD or CUSTODIAN role
 *        - the attestation is not already used, is not expired, and references
 *          a registered asset
 *
 *      `verifyAttestation` additionally rejects revoked attestations.
 */
contract AttestationRegistry {
    struct AssetAttestation {
        bytes32 attestationId;
        bytes32 assetId;
        address subject; // institution the attestation is about (e.g. the bank)
        address owner; // beneficial owner per the CSD
        address custodian; // custody account holding the securities
        uint256 quantity; // total quantity held
        uint256 encumberedQuantity; // quantity already encumbered (repo/pledge)
        uint256 timestamp; // time the CSD/custodian recorded this state
        uint256 expiry; // after this time the attestation is stale
        bytes32 dataHash; // free-form reference to off-chain CSD record
        address attestor; // authorized signer (CSD or Custodian account)
    }

    struct StoredAttestation {
        AssetAttestation data;
        bool exists;
        bool revoked;
    }

    ProtocolAccessManager public immutable access;
    AssetRegistry public immutable assetRegistry;
    AuditRegistry public immutable audit;

    /// attestationId => stored attestation
    mapping(bytes32 => StoredAttestation) public attestations;

    event AttestationCreated(bytes32 indexed attestationId, bytes32 indexed assetId, address indexed attestor);
    event AttestationRevoked(bytes32 indexed attestationId, address indexed revokedBy);

    error NotAuthorizedAttestor();
    error AttestationAlreadyUsed();
    error AttestationExpired();
    error AssetNotRegistered();
    error AttestationDoesNotExist();
    error RevokedAttestation();

    constructor(
        ProtocolAccessManager access_,
        AssetRegistry assetRegistry_,
        AuditRegistry audit_
    ) {
        access = access_;
        assetRegistry = assetRegistry_;
        audit = audit_;
    }

    /* ------------------------------------------------------------------ */
    /* Hashing / verification helpers                                      */
    /* ------------------------------------------------------------------ */

    /// @notice Canonical struct hash used for both signing and verifying.
    function attestationHash(AssetAttestation memory a) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                a.attestationId,
                a.assetId,
                a.subject,
                a.owner,
                a.custodian,
                a.quantity,
                a.encumberedQuantity,
                a.timestamp,
                a.expiry,
                a.dataHash
            )
        );
    }

    /// @notice The digest an off-chain signer must sign (ERC-191 envelope).
    function attestationDigest(AssetAttestation memory a) public pure returns (bytes32) {
        return SignatureVerifier.signedDigest(attestationHash(a));
    }

    /* ------------------------------------------------------------------ */
    /* Write paths                                                         */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Submit a signed custody/asset attestation.
     * @dev The attestor (CSD or Custodian) signs off-chain; anyone may relay, but
     *      the signature must be valid and the attestor must hold an authorized role.
     */
    function createAttestation(
        AssetAttestation calldata a,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (bool) {
        // 1. Recover and authorize the attestor.
        address signer = SignatureVerifier.recoverSigner(attestationHash(a), v, r, s);
        if (signer != a.attestor) revert NotAuthorizedAttestor();
        if (!access.hasRole(Roles.CSD, signer) && !access.hasRole(Roles.CUSTODIAN, signer)) {
            revert NotAuthorizedAttestor();
        }

        // 2. The attestation must be unique.
        if (attestations[a.attestationId].exists) revert AttestationAlreadyUsed();

        // 3. It must reference a registered, active asset.
        if (!assetRegistry.assetExists(a.assetId)) revert AssetNotRegistered();

        // 4. It must not be expired at submission time (nor future-dated beyond a
        //    small clock-skew window of 5 minutes).
        if (a.expiry <= block.timestamp) revert AttestationExpired();
        if (a.timestamp > block.timestamp + 5 minutes) revert AttestationExpired();

        attestations[a.attestationId] = StoredAttestation(a, true, false);

        audit.log(
            AuditRegistry.AuditEventType.CUSTODY_ATTESTED,
            a.attestor,
            a.assetId,
            a.quantity,
            a.encumberedQuantity,
            bytes32(0),
            bytes32("ATTESTED")
        );
        emit AttestationCreated(a.attestationId, a.assetId, a.attestor);
        return true;
    }

    /**
     * @notice Verify an attestation is currently usable (exists, not revoked, not expired).
     */
    function verifyAttestation(bytes32 attestationId) public view returns (bool) {
        StoredAttestation storage stored = attestations[attestationId];
        if (!stored.exists) revert AttestationDoesNotExist();
        if (stored.revoked) revert RevokedAttestation();
        if (stored.data.expiry <= block.timestamp) revert AttestationExpired();
        return true;
    }

    /// @notice Revoke an attestation. Allowed for the attestor or ADMIN.
    function revokeAttestation(bytes32 attestationId) external {
        StoredAttestation storage stored = attestations[attestationId];
        if (!stored.exists) revert AttestationDoesNotExist();
        if (msg.sender != stored.data.attestor && !access.hasRole(Roles.ADMIN, msg.sender)) {
            revert NotAuthorizedAttestor();
        }
        stored.revoked = true;

        audit.log(
            AuditRegistry.AuditEventType.ATTESTATION_REVOKED,
            msg.sender,
            attestationId,
            0,
            0,
            bytes32("ACTIVE"),
            bytes32("REVOKED")
        );
        emit AttestationRevoked(attestationId, msg.sender);
    }

    function getAttestation(bytes32 attestationId) external view returns (StoredAttestation memory) {
        return attestations[attestationId];
    }
}
