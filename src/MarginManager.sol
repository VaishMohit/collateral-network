// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ProtocolAccessManager} from "./ProtocolAccessManager.sol";
import {Roles} from "./libs/Roles.sol";
import {AuditRegistry} from "./AuditRegistry.sol";
import {ICollateralManager} from "./interfaces/ICollateralManager.sol";

/**
 * @title MarginManager
 * @notice Maintains collateral requirements (obligations) and generates /
 *         satisfies margin calls.
 *
 * @dev A requirement is attached to an obligation id (e.g. a repo). The current
 *      collateral value is always computed live, mark-to-market, and therefore
 *      requires fresh oracle prices.
 *
 *      Example (from the spec):
 *        required  = $900,000
 *        price drop to $92 on 10,000 T-BOND-001
 *        market    = $920,000, haircut 5% -> collateral $874,000
 *        shortfall = $26,000  ->  MARGIN_CALL
 */
contract MarginManager {
    struct MarginCall {
        bytes32 obligationId;
        uint256 requiredValue;
        uint256 currentValue;
        uint256 shortfall;
        uint256 createdAt;
        bool active;
        bool satisfied;
    }

    ProtocolAccessManager public immutable access;
    ICollateralManager public immutable collateral;
    AuditRegistry public immutable audit;

    mapping(bytes32 => uint256) public requirements; // obligationId => required collateral value
    mapping(bytes32 => MarginCall) public marginCalls;

    event RequirementSet(bytes32 indexed obligationId, uint256 requiredValue);
    event MarginCallCreated(bytes32 indexed obligationId, uint256 requiredValue, uint256 currentValue, uint256 shortfall);
    event MarginCallSatisfied(bytes32 indexed obligationId, uint256 currentValue);
    event MarginCallCancelled(bytes32 indexed obligationId);

    error Unauthorized();
    error NoRequirement();
    error NoShortfall();
    error ZeroRequirement();

    constructor(ProtocolAccessManager access_, ICollateralManager collateral_, AuditRegistry audit_) {
        access = access_;
        collateral = collateral_;
        audit = audit_;
    }

    modifier onlyBankOrAgent() {
        bool isBank = access.hasRole(Roles.BANK, msg.sender);
        bool isAgent = access.hasRole(Roles.COLLATERAL_AGENT, msg.sender);
        if (!isBank && !isAgent) revert Unauthorized();
        _;
    }

    /// @notice Set the collateral requirement for an obligation (receiver/agent).
    function setRequirement(bytes32 obligationId, uint256 requiredValue) external onlyBankOrAgent {
        if (requiredValue == 0) revert ZeroRequirement();
        requirements[obligationId] = requiredValue;
        emit RequirementSet(obligationId, requiredValue);
    }

    /**
     * @notice Evaluate the obligation against the current collateral and issue a
     *         margin call if there is a shortfall.
     */
    function createMarginCall(bytes32 obligationId) external onlyBankOrAgent returns (uint256 shortfall) {
        uint256 required = requirements[obligationId];
        if (required == 0) revert NoRequirement();

        uint256 current = collateral.liveCollateralValueForObligation(obligationId);
        if (current >= required) {
            revert NoShortfall();
        }
        shortfall = required - current;

        MarginCall storage mc = marginCalls[obligationId];
        mc.obligationId = obligationId;
        mc.requiredValue = required;
        mc.currentValue = current;
        mc.shortfall = shortfall;
        mc.createdAt = block.timestamp;
        mc.active = true;
        mc.satisfied = false;

        audit.log(
            AuditRegistry.AuditEventType.MARGIN_CALL_CREATED,
            msg.sender,
            obligationId,
            shortfall,
            current,
            bytes32("ADEQUATE"),
            bytes32("MARGIN_CALL")
        );
        emit MarginCallCreated(obligationId, required, current, shortfall);
    }

    /**
     * @notice Re-evaluate after the provider has posted additional/replacement
     *         collateral. Marks the call satisfied once the shortfall is covered.
     */
    function satisfyMarginCall(bytes32 obligationId) external onlyBankOrAgent returns (bool satisfied) {
        MarginCall storage mc = marginCalls[obligationId];
        if (!mc.active) revert NoRequirement();

        uint256 current = collateral.liveCollateralValueForObligation(obligationId);
        uint256 required = mc.requiredValue;
        if (current < required) return false;

        mc.active = false;
        mc.satisfied = true;
        mc.currentValue = current;

        audit.log(
            AuditRegistry.AuditEventType.MARGIN_CALL_SATISFIED,
            msg.sender,
            obligationId,
            0,
            current,
            bytes32("MARGIN_CALL"),
            bytes32("SATISFIED")
        );
        emit MarginCallSatisfied(obligationId, current);
        return true;
    }

    function cancelMarginCall(bytes32 obligationId) external onlyBankOrAgent {
        MarginCall storage mc = marginCalls[obligationId];
        delete marginCalls[obligationId];
        emit MarginCallCancelled(obligationId);
    }

    /* ------------------------------------------------------------------ */
    /* Views                                                               */
    /* ------------------------------------------------------------------ */

    function getRequirement(bytes32 obligationId) external view returns (uint256) {
        return requirements[obligationId];
    }

    function getMarginStatus(bytes32 obligationId) external view returns (MarginCall memory) {
        return marginCalls[obligationId];
    }

    /// @notice True if the obligation currently has adequate collateral.
    function isAdequatelyCollateralized(bytes32 obligationId) external view returns (bool) {
        uint256 required = requirements[obligationId];
        if (required == 0) return true;
        return collateral.liveCollateralValueForObligation(obligationId) >= required;
    }
}
