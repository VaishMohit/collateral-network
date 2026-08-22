// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ProtocolAccessManager} from "./ProtocolAccessManager.sol";
import {Roles} from "./libs/Roles.sol";
import {AssetRegistry} from "./AssetRegistry.sol";
import {CustodyRegistry} from "./CustodyRegistry.sol";
import {AttestationRegistry} from "./AttestationRegistry.sol";
import {ValuationOracle} from "./ValuationOracle.sol";

/**
 * @title EligibilityPolicy
 * @notice Configurable collateral-eligibility engine.
 *
 * @dev V1 policy matrix:
 *   TREASURY       — eligible if asset active, custody attestation valid,
 *                    available quantity > 0.  Haircut 5%.
 *   CORPORATE_BOND — additionally requires rating >= AA and remaining term
 *                    >= minimumTerm. Haircut 10%.
 *
 * The matrix is configurable only by POLICY_ADMIN. Haircuts are expressed in
 * basis points (500 == 5%). Collateral value = market value * (1 - haircut).
 */
contract EligibilityPolicy {
    struct AssetPolicy {
        bool eligible;
        uint256 haircutBps; // 10000 == no haircut, 500 == 5%
        uint256 minimumTerm; // minimum remaining term for corporate bonds (seconds)
    }

    ProtocolAccessManager public immutable access;
    AssetRegistry public immutable assetRegistry;
    CustodyRegistry public immutable custodyRegistry;
    AttestationRegistry public immutable attestationRegistry;
    ValuationOracle public immutable valuationOracle;

    mapping(AssetRegistry.AssetType => AssetPolicy) public policies;
    uint256 public defaultMinimumTerm;

    event PolicyUpdated(AssetRegistry.AssetType indexed assetType, bool eligible, uint256 haircutBps, uint256 minimumTerm);

    error Unauthorized();
    error InvalidHaircut();
    error PolicyNotSet();
    error AssetUnknown();
    error HaircutTooHigh();
    error NotEligible();
    error CustodyUnavailable();

    constructor(
        ProtocolAccessManager access_,
        AssetRegistry assetRegistry_,
        CustodyRegistry custodyRegistry_,
        AttestationRegistry attestationRegistry_,
        ValuationOracle valuationOracle_
    ) {
        access = access_;
        assetRegistry = assetRegistry_;
        custodyRegistry = custodyRegistry_;
        attestationRegistry = attestationRegistry_;
        valuationOracle = valuationOracle_;
        defaultMinimumTerm = 90 days;
    }

    modifier onlyPolicyAdmin() {
        if (!access.hasRole(Roles.POLICY_ADMIN, msg.sender)) revert Unauthorized();
        _;
    }

    /**
     * @notice Set the eligibility policy for an asset type.
     */
    function setPolicy(
        AssetRegistry.AssetType assetType,
        bool eligible,
        uint256 haircutBps,
        uint256 minimumTerm
    ) external onlyPolicyAdmin {
        if (haircutBps >= 10000) revert HaircutTooHigh();
        policies[assetType] = AssetPolicy({eligible: eligible, haircutBps: haircutBps, minimumTerm: minimumTerm});
        emit PolicyUpdated(assetType, eligible, haircutBps, minimumTerm);
    }

    function setDefaultMinimumTerm(uint256 term) external onlyPolicyAdmin {
        defaultMinimumTerm = term;
    }

    /* ------------------------------------------------------------------ */
    /* Eligibility                                                         */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Is `owner` eligible to pledge `assetId` right now?
     */
    function isEligible(bytes32 assetId, address owner) public view returns (bool) {
        AssetRegistry.Asset memory asset = assetRegistry.getAsset(assetId);

        if (!asset.active) return false;
        if (!assetRegistry.assetExists(assetId)) return false;

        AssetPolicy memory policy = policies[asset.assetType];
        if (!policy.eligible) return false;

        if (asset.assetType == AssetRegistry.AssetType.CORPORATE_BOND) {
            if (asset.rating < AssetRegistry.Rating.AA) return false;
            uint256 minTerm = policy.minimumTerm == 0 ? defaultMinimumTerm : policy.minimumTerm;
            if (asset.maturity < block.timestamp + minTerm) return false;
        }

        // Custody attestation must be recorded for this asset under this owner,
        // with positive available quantity.
        CustodyRegistry.CustodyState memory cs = custodyRegistry.getCustodyState(assetId, owner);
        if (cs.lastAttestationId == bytes32(0)) return false;
        if (custodyRegistry.availableQuantity(assetId, owner) == 0) return false;

        // The underlying attestation must still be valid (not expired, not revoked).
        // Reverts are caught so that a stale attestation simply makes the asset ineligible
        // rather than reverting the entire read call.
        try attestationRegistry.verifyAttestation(cs.lastAttestationId) {
            // valid — continue
        } catch {
            return false;
        }

        return true;
    }

    /**
     * @notice Haircut (in bps) for an asset, per its type policy.
     */
    function getHaircut(bytes32 assetId) public view returns (uint256) {
        AssetRegistry.Asset memory asset = assetRegistry.getAsset(assetId);
        AssetPolicy memory policy = policies[asset.assetType];
        return policy.haircutBps;
    }

    /**
     * @notice Mark-to-market valuation with haircut applied.
     * @return marketValue  price * quantity (in USD cents)
     * @return collateralValue  marketValue * (10000 - haircutBps) / 10000
     * @dev Reverts if the oracle price is stale.
     */
    function getCollateralValue(
        bytes32 assetId,
        uint256 quantity
    ) public view returns (uint256 marketValue, uint256 collateralValue) {
        (uint256 price, ) = valuationOracle.getLatestPrice(assetId);
        marketValue = price * quantity;
        uint256 haircutBps = getHaircut(assetId);
        collateralValue = (marketValue * (10000 - haircutBps)) / 10000;
    }

    /**
     * @notice Combined eligibility + availability + valuation used by managers.
     */
    function assessCollateral(
        bytes32 assetId,
        address owner,
        uint256 quantity
    ) external view returns (uint256 marketValue, uint256 collateralValue, uint256 haircutBps) {
        if (!isEligible(assetId, owner)) revert NotEligible();
        if (!custodyRegistry.isAvailableForCollateral(assetId, owner, quantity)) revert CustodyUnavailable();
        (marketValue, collateralValue) = getCollateralValue(assetId, quantity);
        haircutBps = getHaircut(assetId);
    }
}
