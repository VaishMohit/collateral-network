// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ProtocolAccessManager} from "./ProtocolAccessManager.sol";
import {Roles} from "./libs/Roles.sol";
import {AuditRegistry} from "./AuditRegistry.sol";
import {ICollateralManager} from "./interfaces/ICollateralManager.sol";

/**
 * @title PledgeManager
 * @notice Workflow orchestration for the collateral pledge lifecycle and
 *         collateral substitution.
 *
 * @dev This contract enforces *who* may do *what* (provider / receiver /
 *      collateral agent) and delegates all state transitions to the
 *      CollateralManager. CollateralManager itself refuses direct calls from
 *      participants, keeping the state machine tamper-proof.
 *
 *      Pledge flow (each step gated):
 *        1. provider   requestPledge
 *        2. agent      verifyCollateral   (eligibility + custody + price + haircut)
 *        3. provider   reserveCollateral  (locks tokens, mirrors CSD encumbrance)
 *        4. receiver   approvePledge
 *        5. provider   finalizePledge     (status = PLEDGED)
 *
 *      Substitution flow (atomicity: old stays locked until replacement is reserved):
 *        1. provider   requestSubstitution
 *        2. agent      validateReplacement (replacement value >= old value)
 *        3. provider   reserveReplacement  (locks replacement)
 *        4. provider   activateSubstitution (releases OLD, activates NEW)
 */
contract PledgeManager {
    ProtocolAccessManager public immutable access;
    ICollateralManager public immutable collateral;
    AuditRegistry public immutable audit;

    error Unauthorized();
    error PositionDoesNotExist();
    error NotProvider();
    error NotReceiver();

    constructor(ProtocolAccessManager access_, ICollateralManager collateral_, AuditRegistry audit_) {
        access = access_;
        collateral = collateral_;
        audit = audit_;
    }

    modifier onlyRole(bytes32 role) {
        if (!access.hasRole(role, msg.sender)) revert Unauthorized();
        _;
    }

    /* ------------------------------------------------------------------ */
    /* Pledge                                                              */
    /* ------------------------------------------------------------------ */

    /// @notice Bank (provider) opens a pledge request. Owner-only.
    function requestPledge(
        bytes32 assetId,
        uint256 quantity,
        address receiver,
        bytes32 obligationId
    ) external onlyRole(Roles.BANK) returns (bytes32 positionId) {
        return collateral.createPosition(msg.sender, receiver, assetId, quantity, obligationId);
    }

    /// @notice Collateral agent verifies eligibility, custody, price and haircut.
    function verifyCollateral(bytes32 positionId) external onlyRole(Roles.COLLATERAL_AGENT) {
        collateral.verifyCollateral(positionId);
    }

    /// @notice Reserve the collateral: locks tokenized securities in the vault
    ///         and mirrors the encumbrance in the custody state.
    function reserveCollateral(bytes32 positionId) external {
        ICollateralManager.CollateralPosition memory p = _getPosition(positionId);
        _isProviderOrAgent(p);
        collateral.reserveCollateral(positionId);
    }

    /// @notice Receiver (e.g. Bank B) accepts the pledged collateral.
    function approvePledge(bytes32 positionId) external {
        ICollateralManager.CollateralPosition memory p = _getPosition(positionId);
        if (msg.sender != p.receiver) revert NotReceiver();
        if (!access.hasRole(Roles.BANK, msg.sender)) revert Unauthorized();
        collateral.markApproved(positionId);
    }

    /// @notice Provider or agent completes the pledge -> PLEDGED.
    function finalizePledge(bytes32 positionId) external {
        ICollateralManager.CollateralPosition memory p = _getPosition(positionId);
        _isProviderOrAgent(p);
        collateral.finalizePledge(positionId);
    }

    /// @notice Abort a reservation (returns tokens, un-encumbers).
    function rejectPledge(bytes32 positionId) external {
        ICollateralManager.CollateralPosition memory p = _getPosition(positionId);
        _isProviderOrAgent(p);
        collateral.cancelReservation(positionId);
    }

    /* ------------------------------------------------------------------ */
    /* Release                                                             */
    /* ------------------------------------------------------------------ */

    function requestRelease(bytes32 positionId) external {
        ICollateralManager.CollateralPosition memory p = _getPosition(positionId);
        if (msg.sender != p.provider && msg.sender != p.receiver) revert Unauthorized();
        if (!access.hasRole(Roles.BANK, msg.sender)) revert Unauthorized();
        collateral.requestRelease(positionId);
    }

    /// @notice The counterparty (or the agent) approves the release.
    function approveRelease(bytes32 positionId) external {
        ICollateralManager.CollateralPosition memory p = _getPosition(positionId);
        bool isAgent = access.hasRole(Roles.COLLATERAL_AGENT, msg.sender);
        bool isProvider = msg.sender == p.provider;
        bool isReceiver = msg.sender == p.receiver;
        // provider can approve if receiver requested; receiver if provider requested;
        // agent can always approve.
        if (isAgent) {
            collateral.approveRelease(positionId);
            return;
        }
        if (isProvider || isReceiver) {
            collateral.approveRelease(positionId);
            return;
        }
        revert Unauthorized();
    }

    /* ------------------------------------------------------------------ */
    /* Substitution                                                        */
    /* ------------------------------------------------------------------ */

    /// @notice Provider requests to substitute a pledged position with a new one.
    function requestSubstitution(
        bytes32 oldPositionId,
        bytes32 assetId,
        uint256 quantity
    ) external returns (bytes32 replacementId) {
        ICollateralManager.CollateralPosition memory old = _getPosition(oldPositionId);
        _isProviderOrAgent(old);
        return collateral.createReplacementPosition(
            oldPositionId,
            old.provider,
            old.receiver,
            assetId,
            quantity,
            old.obligationId
        );
    }

    /// @notice Agent validates replacement eligibility/value (>= old value).
    function validateReplacement(bytes32 replacementId) external onlyRole(Roles.COLLATERAL_AGENT) {
        collateral.validateReplacement(replacementId);
    }

    function reserveReplacement(bytes32 replacementId) external {
        ICollateralManager.CollateralPosition memory r = collateral.getPosition(replacementId);
        if (r.positionId == bytes32(0)) revert PositionDoesNotExist();
        _isProviderOrAgent(r);
        collateral.reserveReplacement(replacementId);
    }

    function activateSubstitution(bytes32 oldPositionId) external {
        ICollateralManager.CollateralPosition memory old = _getPosition(oldPositionId);
        _isProviderOrAgent(old);
        collateral.activateSubstitution(oldPositionId);
    }

    function cancelSubstitution(bytes32 oldPositionId) external {
        ICollateralManager.CollateralPosition memory old = _getPosition(oldPositionId);
        _isProviderOrAgent(old);
        collateral.cancelSubstitution(oldPositionId);
    }

    /* ------------------------------------------------------------------ */
    /* Internal                                                            */
    /* ------------------------------------------------------------------ */

    function _getPosition(bytes32 positionId) internal view returns (ICollateralManager.CollateralPosition memory p) {
        p = collateral.getPosition(positionId);
        if (p.positionId == bytes32(0)) revert PositionDoesNotExist();
    }

    function _isProviderOrAgent(ICollateralManager.CollateralPosition memory p) internal view {
        bool isAgent = access.hasRole(Roles.COLLATERAL_AGENT, msg.sender);
        if (msg.sender != p.provider && !isAgent) revert NotProvider();
    }
}
