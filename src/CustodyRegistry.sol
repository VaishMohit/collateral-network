// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ProtocolAccessManager} from "./ProtocolAccessManager.sol";
import {Roles} from "./libs/Roles.sol";
import {AttestationRegistry} from "./AttestationRegistry.sol";
import {AuditRegistry} from "./AuditRegistry.sol";

/**
 * @title CustodyRegistry
 * @notice On-chain mirror of the *current custody relationship* for each asset.
 *
 * @dev This contract does NOT claim to be the CSD. It holds the latest state
 *      attested by the CSD/Custodian plus the encumbrance delta that on-chain
 *      collateral operations (pledges, releases, substitutions) apply.
 *
 *      Ownership and quantity can ONLY change through a valid signed
 *      attestation. Encumbrance can ONLY change through the CollateralManager
 *      (the one contract holding the `COLLATERAL_MANAGER` role), i.e. as a
 *      consequence of a collateral operation — never directly by a bank.
 */
contract CustodyRegistry {
    bytes32 public constant COLLATERAL_MANAGER_ROLE = keccak256("COLLATERAL_MANAGER");

    struct CustodyState {
        bytes32 assetId;
        address csd; // institution that attested the state
        address owner;
        address custodian;
        uint256 totalQuantity;
        uint256 encumberedQuantity;
        bytes32 lastAttestationId;
        uint256 lastUpdate;
    }

    ProtocolAccessManager public immutable access;
    AttestationRegistry public immutable attestationRegistry;
    AuditRegistry public immutable audit;

    mapping(bytes32 => CustodyState) public custodyStates;

    event CustodyStateUpdated(bytes32 indexed assetId, bytes32 indexed attestationId);
    event EncumbranceChanged(bytes32 indexed assetId, int256 delta, uint256 newEncumbered);

    error AssetNotAttested();
    error OnlyCollateralManager();
    error InvalidEncumbrance();

    constructor(
        ProtocolAccessManager access_,
        AttestationRegistry attestationRegistry_,
        AuditRegistry audit_
    ) {
        access = access_;
        attestationRegistry = attestationRegistry_;
        audit = audit_;
    }

    /**
     * @notice Refresh the custody state from a freshly verified attestation.
     * @dev Called by the CSD/Custodian after submitting the signed attestation.
     */
    function updateCustodyAttestation(bytes32 attestationId) external {
        bool isCsd = access.hasRole(Roles.CSD, msg.sender);
        bool isCustodian = access.hasRole(Roles.CUSTODIAN, msg.sender);
        require(isCsd || isCustodian, "CustodyRegistry: unauthorized");

        // Full validity check (exists, not revoked, not expired).
        attestationRegistry.verifyAttestation(attestationId);

        AttestationRegistry.StoredAttestation memory stored = attestationRegistry.getAttestation(attestationId);
        AttestationRegistry.AssetAttestation memory a = stored.data;
        CustodyState storage cs = custodyStates[a.assetId];
        cs.assetId = a.assetId;
        cs.csd = msg.sender;
        cs.owner = a.owner;
        cs.custodian = a.custodian;
        cs.totalQuantity = a.quantity;
        cs.encumberedQuantity = a.encumberedQuantity;
        cs.lastAttestationId = attestationId;
        cs.lastUpdate = block.timestamp;

        emit CustodyStateUpdated(a.assetId, attestationId);
    }

    /**
     * @notice Adjust the on-chain encumbrance mirror as collateral is reserved
     *         or released. Only the CollateralManager holds this role.
     */
    function applyEncumbrance(bytes32 assetId, int256 delta) external {
        if (!access.hasRole(COLLATERAL_MANAGER_ROLE, msg.sender)) revert OnlyCollateralManager();

        CustodyState storage cs = custodyStates[assetId];
        if (cs.totalQuantity == 0 && cs.lastAttestationId == bytes32(0)) revert AssetNotAttested();

        if (delta < 0) {
            if (uint256(-delta) > cs.encumberedQuantity) revert InvalidEncumbrance();
            cs.encumberedQuantity -= uint256(-delta);
        } else {
            cs.encumberedQuantity += uint256(delta);
        }
        if (cs.encumberedQuantity > cs.totalQuantity) revert InvalidEncumbrance();

        emit EncumbranceChanged(assetId, delta, cs.encumberedQuantity);
    }

    /* ------------------------------------------------------------------ */
    /* Views                                                               */
    /* ------------------------------------------------------------------ */

    function getCustodyState(bytes32 assetId) external view returns (CustodyState memory) {
        return custodyStates[assetId];
    }

    function availableQuantity(bytes32 assetId) public view returns (uint256) {
        CustodyState storage cs = custodyStates[assetId];
        if (cs.totalQuantity == 0) return 0;
        if (cs.encumberedQuantity >= cs.totalQuantity) return 0;
        return cs.totalQuantity - cs.encumberedQuantity;
    }

    function isAvailableForCollateral(bytes32 assetId, address owner, uint256 quantity) external view returns (bool) {
        CustodyState storage cs = custodyStates[assetId];
        if (cs.owner != owner) return false;
        if (quantity == 0) return false;
        return quantity <= availableQuantity(assetId);
    }
}
