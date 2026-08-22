// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ProtocolAccessManager} from "./ProtocolAccessManager.sol";
import {Roles} from "./libs/Roles.sol";
import {AuditRegistry} from "./AuditRegistry.sol";

/**
 * @title AssetRegistry
 * @notice Maintains the on-chain identity/reference model of a security.
 *
 * @dev The registry holds a *reference* to an asset — it does not hold the
 *      securities themselves. The Mock CSD remains authoritative for the
 *      underlying instruments. Each registered asset is linked to a
 *      TokenizedSecurity contract that represents the digital form of the
 *      security for collateral workflows.
 */
contract AssetRegistry {
    enum AssetType {
        UNKNOWN,
        TREASURY,
        CORPORATE_BOND
    }

    /// Ratings used by the eligibility policy (higher is better).
    enum Rating {
        UNRATED,
        BBB,
        A,
        AA,
        AAA
    }

    struct Asset {
        bytes32 assetId;
        string isin;
        AssetType assetType;
        address issuer;
        address token; // TokenizedSecurity contract representing this asset
        uint256 faceValue;
        uint256 maturity; // unix timestamp of maturity
        Rating rating; // only meaningful for corporate bonds
        bool active;
    }

    ProtocolAccessManager public immutable access;
    AuditRegistry public immutable audit;

    mapping(bytes32 => Asset) public assets;
    mapping(bytes32 => bool) public registered;

    event AssetRegistered(bytes32 indexed assetId, string isin, AssetType indexed assetType);
    event AssetActivated(bytes32 indexed assetId);
    event AssetDeactivated(bytes32 indexed assetId);
    event TokenLinked(bytes32 indexed assetId, address indexed token);

    error NotRegistered();
    error AlreadyRegistered();
    error NotActive();
    error NotAdminOrCsd();
    error UnknownAssetType();
    error ZeroAssetId();

    constructor(ProtocolAccessManager access_, AuditRegistry audit_) {
        access = access_;
        audit = audit_;
    }

    modifier onlyAdmin() {
        if (!access.hasRole(Roles.ADMIN, msg.sender)) revert NotAdminOrCsd();
        _;
    }

    /**
     * @notice Register a new asset identity. Admin or CSD may register.
     */
    function registerAsset(
        bytes32 assetId,
        string calldata isin,
        AssetType assetType,
        address issuer,
        uint256 faceValue,
        uint256 maturity,
        Rating rating
    ) external {
        bool isAdmin = access.hasRole(Roles.ADMIN, msg.sender);
        bool isCsd = access.hasRole(Roles.CSD, msg.sender);
        if (!isAdmin && !isCsd) revert NotAdminOrCsd();

        if (registered[assetId]) revert AlreadyRegistered();
        if (assetType == AssetType.UNKNOWN) revert UnknownAssetType();
        if (assetId == bytes32(0)) revert ZeroAssetId();

        assets[assetId] = Asset({
            assetId: assetId,
            isin: isin,
            assetType: assetType,
            issuer: issuer,
            token: address(0),
            faceValue: faceValue,
            maturity: maturity,
            rating: rating,
            active: false
        });
        registered[assetId] = true;

        audit.log(
            AuditRegistry.AuditEventType.ASSET_REGISTERED,
            msg.sender,
            assetId,
            faceValue,
            0,
            bytes32(0),
            bytes32("REGISTERED")
        );
        emit AssetRegistered(assetId, isin, assetType);
    }

    /// @notice Link the TokenizedSecurity contract for an asset (Admin only).
    function setToken(bytes32 assetId, address token) external onlyAdmin {
        if (!registered[assetId]) revert NotRegistered();
        assets[assetId].token = token;
        emit TokenLinked(assetId, token);
    }

    function activateAsset(bytes32 assetId) external onlyAdmin {
        if (!registered[assetId]) revert NotRegistered();
        assets[assetId].active = true;
        emit AssetActivated(assetId);
    }

    function deactivateAsset(bytes32 assetId) external onlyAdmin {
        if (!registered[assetId]) revert NotRegistered();
        assets[assetId].active = false;
        emit AssetDeactivated(assetId);
    }

    /* ------------------------------------------------------------------ */
    /* Views                                                               */
    /* ------------------------------------------------------------------ */

    function getAsset(bytes32 assetId) external view returns (Asset memory) {
        if (!registered[assetId]) revert NotRegistered();
        return assets[assetId];
    }

    function assetExists(bytes32 assetId) public view returns (bool) {
        return registered[assetId];
    }

    function isActive(bytes32 assetId) external view returns (bool) {
        if (!registered[assetId]) revert NotRegistered();
        return assets[assetId].active;
    }

    function getToken(bytes32 assetId) external view returns (address) {
        if (!registered[assetId]) revert NotRegistered();
        return assets[assetId].token;
    }
}
