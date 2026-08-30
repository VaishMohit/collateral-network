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

    /// @notice Non-mutating result of evaluating an obligation against its
    ///         requirement at the current mark-to-market value.
    struct MarginEvaluation {
        bool isAdequate;
        uint256 shortfall;
        uint256 requiredValue;
        uint256 currentValue;
    }

    /// @notice Immutable audit record of a margin-call lifecycle event, kept in
    ///         a per-obligation ring buffer.
    struct MarginCallRecord {
        bytes32 obligationId;
        uint256 shortfall;
        uint256 currentValue;
        uint256 requiredValue;
        uint256 timestamp;
        bool satisfied;
        bool cancelled;
    }

    /// @notice Bounded history depth held per obligation.
    uint256 public constant HISTORY_SIZE = 16;

    ProtocolAccessManager public immutable access;
    ICollateralManager public immutable collateral;
    AuditRegistry public immutable audit;

    mapping(bytes32 => uint256) public requirements; // obligationId => required collateral value
    mapping(bytes32 => MarginCall) public marginCalls;

    // Per-obligation ring buffer of the most recent {HISTORY_SIZE} records.
    mapping(bytes32 => MarginCallRecord[HISTORY_SIZE]) private marginCallHistory;
    mapping(bytes32 => uint256) private historyHead;
    mapping(bytes32 => uint256) private historyCount;

    event RequirementSet(bytes32 indexed obligationId, uint256 requiredValue);
    event MarginCallCreated(
        bytes32 indexed obligationId, uint256 requiredValue, uint256 currentValue, uint256 shortfall
    );
    event MarginCallSatisfied(bytes32 indexed obligationId, uint256 currentValue);
    event MarginCallCancelled(bytes32 indexed obligationId);
    event HistoryTrimmed(bytes32 indexed obligationId, uint256 trimmedRecords);

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

    /// @notice Evaluate an obligation against its requirement at current
    ///         mark-to-market value. View-only: never reverts on adequacy and
    ///         does not create a call.
    function evaluateMargin(bytes32 obligationId) external view returns (MarginEvaluation memory) {
        return _evaluateMargin(obligationId);
    }

    /// @notice Alias of `evaluateMargin` — previews the margin call that would be
    ///         raised (shortfall) without creating or mutating anything.
    function previewMarginCall(bytes32 obligationId) external view returns (MarginEvaluation memory) {
        return _evaluateMargin(obligationId);
    }

    /// @notice Evaluate a set of obligations and, where a shortfall exists, raise
    ///         a margin call. The caller (operator) supplies the obligation ids
    ///         to control gas scope.
    function evaluateAll(bytes32[] calldata obligationIds)
        external
        onlyBankOrAgent
        returns (MarginEvaluation[] memory)
    {
        MarginEvaluation[] memory evaluations = new MarginEvaluation[](obligationIds.length);
        for (uint256 i = 0; i < obligationIds.length; i++) {
            bytes32 obligationId = obligationIds[i];
            evaluations[i] = _evaluateMargin(obligationId);
            if (!evaluations[i].isAdequate) {
                _createMarginCall(
                    obligationId, evaluations[i].requiredValue, evaluations[i].currentValue, evaluations[i].shortfall
                );
            }
        }
        return evaluations;
    }

    function _evaluateMargin(bytes32 obligationId) internal view returns (MarginEvaluation memory evaluation) {
        uint256 required = requirements[obligationId];
        if (required == 0) revert NoRequirement();
        uint256 current = collateral.liveCollateralValueForObligation(obligationId);
        evaluation = MarginEvaluation({
            isAdequate: current >= required,
            shortfall: current >= required ? 0 : required - current,
            requiredValue: required,
            currentValue: current
        });
    }

    /**
     * @notice Evaluate the obligation against the current collateral and issue a
     *         margin call if there is a shortfall.
     */
    function createMarginCall(bytes32 obligationId) external onlyBankOrAgent returns (uint256 shortfall) {
        if (requirements[obligationId] == 0) revert NoRequirement();

        uint256 current = collateral.liveCollateralValueForObligation(obligationId);
        uint256 required = requirements[obligationId];
        if (current >= required) revert NoShortfall();
        shortfall = required - current;

        _createMarginCall(obligationId, required, current, shortfall);
    }

    function _createMarginCall(bytes32 obligationId, uint256 required, uint256 current, uint256 shortfall) internal {
        MarginCall storage mc = marginCalls[obligationId];
        mc.obligationId = obligationId;
        mc.requiredValue = required;
        mc.currentValue = current;
        mc.shortfall = shortfall;
        mc.createdAt = block.timestamp;
        mc.active = true;
        mc.satisfied = false;

        _recordMarginCall(obligationId, shortfall, current, required, false, false);

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

        _recordMarginCall(obligationId, 0, current, required, true, false);

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
        _recordMarginCall(obligationId, mc.shortfall, mc.currentValue, mc.requiredValue, mc.satisfied, true);
        delete marginCalls[obligationId];
        emit MarginCallCancelled(obligationId);
    }

    /* ------------------------------------------------------------------ */
    /* History                                                             */
    /* ------------------------------------------------------------------ */

    /// @notice Append a record to the per-obligation ring buffer (newest last),
    ///         trimming the oldest once `HISTORY_SIZE` is reached.
    function _recordMarginCall(
        bytes32 obligationId,
        uint256 shortfall,
        uint256 currentValue,
        uint256 requiredValue,
        bool satisfied,
        bool cancelled
    ) internal {
        MarginCallRecord[HISTORY_SIZE] storage ring = marginCallHistory[obligationId];
        uint256 head = historyHead[obligationId];
        uint256 count = historyCount[obligationId];

        uint256 trimmed = 0;
        if (count == HISTORY_SIZE) {
            trimmed = 1; // dropping the record at `head` when full
        }

        ring[head] = MarginCallRecord({
            obligationId: obligationId,
            shortfall: shortfall,
            currentValue: currentValue,
            requiredValue: requiredValue,
            timestamp: block.timestamp,
            satisfied: satisfied,
            cancelled: cancelled
        });

        historyHead[obligationId] = (head + 1) % HISTORY_SIZE;
        historyCount[obligationId] = count < HISTORY_SIZE ? count + 1 : HISTORY_SIZE;

        if (trimmed > 0) emit HistoryTrimmed(obligationId, trimmed);
    }

    /// @notice Return the per-obligation history newest-first, capped at
    ///         `HISTORY_SIZE`.
    function getMarginCallHistory(bytes32 obligationId) external view returns (MarginCallRecord[] memory) {
        return _history(obligationId);
    }

    function _history(bytes32 obligationId) internal view returns (MarginCallRecord[] memory result) {
        uint256 count = historyCount[obligationId];
        if (count == 0) {
            return new MarginCallRecord[](0);
        }
        uint256 head = historyHead[obligationId];
        MarginCallRecord[HISTORY_SIZE] storage ring = marginCallHistory[obligationId];

        result = new MarginCallRecord[](count);
        for (uint256 i = 0; i < count; i++) {
            // head-1 is newest, head-count is oldest (when not overflowed).
            uint256 idx = (head + HISTORY_SIZE - 1 - i) % HISTORY_SIZE;
            result[i] = ring[idx];
        }
    }

    /// @notice Paginated, newest-first history slice. `start`/`count` select a
    ///         window; returns fewer than `count` once the history is exhausted.
    function getMarginCallHistoryPaginated(bytes32 obligationId, uint256 start, uint256 count)
        external
        view
        returns (MarginCallRecord[] memory)
    {
        MarginCallRecord[] memory all = _history(obligationId);
        if (start >= all.length) {
            return new MarginCallRecord[](0);
        }
        uint256 end = start + count > all.length ? all.length : start + count;
        uint256 resultLen = end - start;
        MarginCallRecord[] memory result = new MarginCallRecord[](resultLen);
        for (uint256 i = 0; i < resultLen; i++) {
            result[i] = all[start + i];
        }
        return result;
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
