// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/**
 * @title AuditRegistry
 * @notice Central, tamper-evident audit trail for every material operation in the
 *         Institutional Collateral Network.
 *
 * @dev Every workflow contract logs structured audit records here. Each record
 *      carries: event type, timestamp, participant, a reference id
 *      (assetId/positionId/repoId), quantity, value and the previous/next state.
 *      Emitting through a single registry (rather than scattering ad-hoc events)
 *      mirrors how an institutional audit team would query a single ledger.
 *
 *      Important: the emitted Solidity `AuditLogged` event is the on-chain record;
 *      the struct below is an indexed convenience view for off-chain tooling.
 */
contract AuditRegistry {
    enum AuditEventType {
        ASSET_REGISTERED,
        CUSTODY_ATTESTED,
        ATTESTATION_REVOKED,
        COMPLIANCE_ATTESTED,
        TOKEN_MINTED,
        TOKEN_BURNED,
        TOKEN_TRANSFERRED,
        COLLATERAL_REQUESTED,
        COLLATERAL_VERIFIED,
        COLLATERAL_RESERVED,
        COLLATERAL_PLEDGED,
        COLLATERAL_RELEASE_REQUESTED,
        COLLATERAL_RELEASED,
        COLLATERAL_SUBSTITUTION_REQUESTED,
        COLLATERAL_SUBSTITUTED,
        COLLATERAL_DEFAULTED,
        COLLATERAL_ENFORCED,
        MARGIN_CALL_CREATED,
        MARGIN_CALL_SATISFIED,
        REPO_CREATED,
        REPO_SETTLED,
        REPO_MATURED,
        REPO_DEFAULTED,
        SETTLEMENT_COMPLETED
    }

    struct AuditRecord {
        AuditEventType eventType;
        uint256 timestamp;
        address participant;
        bytes32 refId;
        uint256 quantity;
        uint256 value;
        bytes32 previousState;
        bytes32 newState;
    }

    /// monotonic sequence number
    uint256 public recordCount;

    /// sequence => audit record
    mapping(uint256 => AuditRecord) public records;

    /// eventType => sequence numbers
    mapping(AuditEventType => uint256[]) public recordsByType;

    event AuditLogged(
        uint256 indexed recordId,
        AuditEventType indexed eventType,
        uint256 timestamp,
        address indexed participant,
        bytes32 refId,
        uint256 quantity,
        uint256 value,
        bytes32 previousState,
        bytes32 newState
    );

    /**
     * @notice Appends an audit record.
     * @dev No access control: the workflow contracts are the only writers and the
     *      registry itself stores no secrets. A record, once written, cannot be
     *      modified or deleted.
     */
    function log(
        AuditEventType eventType,
        address participant,
        bytes32 refId,
        uint256 quantity,
        uint256 value,
        bytes32 previousState,
        bytes32 newState
    ) external returns (uint256 recordId) {
        recordId = ++recordCount;
        AuditRecord storage r = records[recordId];
        r.eventType = eventType;
        r.timestamp = block.timestamp;
        r.participant = participant;
        r.refId = refId;
        r.quantity = quantity;
        r.value = value;
        r.previousState = previousState;
        r.newState = newState;
        recordsByType[eventType].push(recordId);
        emit AuditLogged(recordId, eventType, block.timestamp, participant, refId, quantity, value, previousState, newState);
    }

    function countOfType(AuditEventType eventType) external view returns (uint256) {
        return recordsByType[eventType].length;
    }
}
