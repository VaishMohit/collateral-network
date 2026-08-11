// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/**
 * @title ICollateralManager
 * @notice Interface over the collateral state machine used by the workflow
 *         contracts (PledgeManager, RepoManager, SettlementCoordinator,
 *         MarginManager). Encapsulates the collateral layer so it can be
 *         implemented against this or another chain's settlement/asset layers.
 */
interface ICollateralManager {
    enum CollateralStatus {
        AVAILABLE,
        RESERVED,
        PLEDGED,
        RELEASE_REQUESTED,
        RELEASED,
        DEFAULTED,
        RECOVERY
    }

    struct CollateralPosition {
        bytes32 positionId;
        address provider;
        address receiver;
        bytes32 assetId;
        uint256 quantity;
        uint256 marketValue;
        uint256 haircutBps;
        uint256 collateralValue;
        CollateralStatus status;
        bytes32 obligationId;
        uint256 createdAt;
    }

    // Pledge workflow (operator-facing; authorization enforced by the managers)
    function createPosition(
        address provider,
        address receiver,
        bytes32 assetId,
        uint256 quantity,
        bytes32 obligationId
    ) external returns (bytes32 positionId);

    function verifyCollateral(bytes32 positionId) external;

    function reserveCollateral(bytes32 positionId) external;

    function cancelReservation(bytes32 positionId) external;

    function markApproved(bytes32 positionId) external;

    function finalizePledge(bytes32 positionId) external;

    function requestRelease(bytes32 positionId) external;

    function approveRelease(bytes32 positionId) external;

    function release(bytes32 positionId) external;

    function linkObligation(bytes32 positionId, bytes32 obligationId) external;

    function markDefault(bytes32 positionId) external;

    function enforceCollateral(bytes32 positionId, address to) external;

    // Substitution
    function createReplacementPosition(
        bytes32 oldPositionId,
        address provider,
        address receiver,
        bytes32 assetId,
        uint256 quantity,
        bytes32 obligationId
    ) external returns (bytes32 replacementId);

    function validateReplacement(bytes32 replacementId) external;

    function reserveReplacement(bytes32 replacementId) external;

    function activateSubstitution(bytes32 oldPositionId) external;

    function cancelSubstitution(bytes32 oldPositionId) external;

    // Views
    function availableQuantity(bytes32 assetId, address provider) external view returns (uint256);

    function getPosition(bytes32 positionId) external view returns (CollateralPosition memory);

    function totalCollateralValueForObligation(bytes32 obligationId) external view returns (uint256);

    function liveCollateralValueForObligation(bytes32 obligationId) external view returns (uint256);

    function getPositionsByObligation(bytes32 obligationId) external view returns (bytes32[] memory);

    function positionApproved(bytes32 positionId) external view returns (bool);
}
