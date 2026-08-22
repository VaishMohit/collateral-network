// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ProtocolAccessManager} from "./ProtocolAccessManager.sol";
import {Roles} from "./libs/Roles.sol";
import {AssetRegistry} from "./AssetRegistry.sol";
import {CustodyRegistry} from "./CustodyRegistry.sol";
import {EligibilityPolicy} from "./EligibilityPolicy.sol";
import {ComplianceAttestationRegistry} from "./ComplianceAttestationRegistry.sol";
import {AuditRegistry} from "./AuditRegistry.sol";
import {ITokenizedSecurity} from "./interfaces/ITokenizedSecurity.sol";
import {ReentrancyGuard} from "./libs/ReentrancyGuard.sol";

/**
 * @title CollateralManager
 * @notice Core collateral state machine and position ledger.
 *
 * @dev This contract holds collateral *state* and enforces the lifecycle:
 *
 *      AVAILABLE -> RESERVED -> PLEDGED -> RELEASE_REQUESTED -> RELEASED
 *                                   \--> DEFAULTED -> RECOVERY
 *
 *      Participants never call this contract directly: only registered operator
 *      contracts (PledgeManager, RepoManager, SettlementCoordinator, MarginManager)
 *      may mutate collateral state. Those workflow contracts enforce the actor
 *      authorization rules (provider / receiver / agent). This separation is
 *      deliberate: state vs. workflow.
 *
 *      Collateral accounting is per (asset, provider):
 *        total tokenized balance  ==  reserved + pledged + available
 *      and every reservation/pledge/release keeps the Mock CSD's encumbrance
 *      mirror in CustodyRegistry in sync, which is what blocks double pledging
 *      across both the token layer and the custody layer.
 */
contract CollateralManager is ReentrancyGuard {
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

    /// Per (asset, provider) encumbrance ledger.
    struct CollateralLedger {
        uint256 reserved;
        uint256 pledged;
        uint256 released; // cumulative released quantity (audit)
    }

    ProtocolAccessManager public immutable access;
    AssetRegistry public immutable assetRegistry;
    CustodyRegistry public immutable custodyRegistry;
    EligibilityPolicy public immutable eligibility;
    ComplianceAttestationRegistry public immutable compliance;
    AuditRegistry public immutable audit;

    mapping(bytes32 => CollateralPosition) public positions;
    mapping(bytes32 => CollateralLedger) public ledgerByAssetProvider;
    mapping(address => bool) public operators;
    mapping(bytes32 => bool) public approved;
    mapping(bytes32 => bool) public validated;
    mapping(bytes32 => bytes32) public pendingSubstitution; // old => replacement
    mapping(bytes32 => bytes32) public substitutionSource; // replacement => old
    mapping(bytes32 => bytes32[]) public positionsByObligation;

    uint256 public positionCounter;
    uint256 public constant MAX_OBLIGATION_POSITIONS = 64;

    event OperatorSet(address indexed operator, bool enabled);
    event PositionCreated(bytes32 indexed positionId, address indexed provider, address indexed receiver, bytes32 assetId, uint256 quantity);
    event CollateralLocked(bytes32 indexed positionId, uint256 quantity);
    event CollateralUnlocked(bytes32 indexed positionId, uint256 quantity);
    event ReservationCancelled(bytes32 indexed positionId);
    event PositionApproved(bytes32 indexed positionId);
    event PositionDefaulted(bytes32 indexed positionId);

    error Unauthorized();
    error NotOperator();
    error InvalidStatus();
    error InsufficientAvailable();
    error PositionDoesNotExist();
    error NotValidated();
    error NotApproved();
    error NoPendingSubstitution();
    error InvalidValueRelation();
    error ZeroAddress();
    error NoToken();
    error ObligationCapReached();

    modifier onlyOperator() {
        if (!operators[msg.sender]) revert NotOperator();
        _;
    }

    constructor(
        ProtocolAccessManager access_,
        AssetRegistry assetRegistry_,
        CustodyRegistry custodyRegistry_,
        EligibilityPolicy eligibility_,
        ComplianceAttestationRegistry compliance_,
        AuditRegistry audit_
    ) {
        access = access_;
        assetRegistry = assetRegistry_;
        custodyRegistry = custodyRegistry_;
        eligibility = eligibility_;
        compliance = compliance_;
        audit = audit_;
    }

    /* ------------------------------------------------------------------ */
    /* Admin                                                               */
    /* ------------------------------------------------------------------ */

    function setOperator(address operator, bool enabled) external {
        if (!access.hasRole(Roles.ADMIN, msg.sender)) revert Unauthorized();
        operators[operator] = enabled;
        emit OperatorSet(operator, enabled);
    }

    /* ------------------------------------------------------------------ */
    /* Accounting                                                          */
    /* ------------------------------------------------------------------ */

    function getLedger(bytes32 assetId, address provider) external view returns (CollateralLedger memory) {
        return ledgerByAssetIdProvider(assetId, provider);
    }

    function ledgerByAssetIdProvider(bytes32 assetId, address provider) internal view returns (CollateralLedger storage l) {
        l = ledgerByAssetProvider[keccak256(abi.encode(assetId, provider))];
    }

    /**
     * @notice Units of `assetId` the `provider` can still pledge.
     * @dev The binding constraint is the minimum of:
     *        - the provider's free tokenized balance, and
     *        - the CSD's attested available quantity (authoritative custody state).
     */
    function availableQuantity(bytes32 assetId, address provider) public view returns (uint256) {
        address token = assetRegistry.getToken(assetId);
        if (token == address(0)) return 0;

        CollateralLedger storage l = ledgerByAssetIdProvider(assetId, provider);
        uint256 tokenBalance = ITokenizedSecurity(token).balanceOf(provider);
        uint256 used = l.reserved + l.pledged;
        uint256 tokenAvailable = tokenBalance > used ? tokenBalance - used : 0;

        uint256 custodyAvailable = custodyRegistry.availableQuantity(assetId, provider);

        return tokenAvailable < custodyAvailable ? tokenAvailable : custodyAvailable;
    }

    function positionExists(bytes32 positionId) internal view returns (bool) {
        return positions[positionId].createdAt != 0;
    }

    function _newPositionId() internal returns (bytes32) {
        positionCounter++;
        // Deterministic (no block.timestamp): scripts that capture the id during
        // simulation produce the same id as the broadcast transaction, so
        // multi-step live workflows do not go stale across broadcasts.
        return keccak256(abi.encode(msg.sender, positionCounter));
    }

    /* ------------------------------------------------------------------ */
    /* Pledge lifecycle                                                    */
    /* ------------------------------------------------------------------ */

    function createPosition(
        address provider,
        address receiver,
        bytes32 assetId,
        uint256 quantity,
        bytes32 obligationId
    ) external onlyOperator returns (bytes32 positionId) {
        if (provider == address(0) || receiver == address(0)) revert ZeroAddress();
        if (availableQuantity(assetId, provider) < quantity) revert InsufficientAvailable();
        if (obligationId != bytes32(0) && positionsByObligation[obligationId].length >= MAX_OBLIGATION_POSITIONS) revert ObligationCapReached();

        positionId = _newPositionId();
        positions[positionId] = CollateralPosition({
            positionId: positionId,
            provider: provider,
            receiver: receiver,
            assetId: assetId,
            quantity: quantity,
            marketValue: 0,
            haircutBps: 0,
            collateralValue: 0,
            status: CollateralStatus.AVAILABLE,
            obligationId: obligationId,
            createdAt: block.timestamp
        });

        if (obligationId != bytes32(0)) positionsByObligation[obligationId].push(positionId);

        audit.log(
            AuditRegistry.AuditEventType.COLLATERAL_REQUESTED,
            provider,
            positionId,
            quantity,
            0,
            bytes32(0),
            bytes32("AVAILABLE")
        );
        emit PositionCreated(positionId, provider, receiver, assetId, quantity);
    }

    /**
     * @notice Full eligibility, custody, compliance and valuation check.
     * @dev Reverts if the oracle price is stale (EligibilityPolicy.getCollateralValue).
     */
    function verifyCollateral(bytes32 positionId) external onlyOperator {
        CollateralPosition storage p = positions[positionId];
        if (!positionExists(positionId)) revert PositionDoesNotExist();
        if (p.status != CollateralStatus.AVAILABLE) revert InvalidStatus();

        (uint256 marketValue, uint256 collateralValue, uint256 haircutBps) =
            eligibility.assessCollateral(p.assetId, p.provider, p.quantity);

        if (!compliance.isCompliant(p.provider)) revert Unauthorized();

        p.marketValue = marketValue;
        p.collateralValue = collateralValue;
        p.haircutBps = haircutBps;
        validated[positionId] = true;

        audit.log(
            AuditRegistry.AuditEventType.COLLATERAL_VERIFIED,
            p.provider,
            positionId,
            p.quantity,
            collateralValue,
            bytes32("AVAILABLE"),
            bytes32("VERIFIED")
        );
    }

    function reserveCollateral(bytes32 positionId) external onlyOperator nonReentrant {
        CollateralPosition storage p = positions[positionId];
        if (!positionExists(positionId)) revert PositionDoesNotExist();
        if (p.status != CollateralStatus.AVAILABLE) revert InvalidStatus();
        if (!validated[positionId]) revert NotValidated();
        if (availableQuantity(p.assetId, p.provider) < p.quantity) revert InsufficientAvailable();

        _lock(positionId);
        p.status = CollateralStatus.RESERVED;

        audit.log(
            AuditRegistry.AuditEventType.COLLATERAL_RESERVED,
            p.provider,
            positionId,
            p.quantity,
            p.collateralValue,
            bytes32("AVAILABLE"),
            bytes32("RESERVED")
        );
    }

    function cancelReservation(bytes32 positionId) external onlyOperator nonReentrant {
        CollateralPosition storage p = positions[positionId];
        if (!positionExists(positionId)) revert PositionDoesNotExist();
        if (p.status != CollateralStatus.RESERVED) revert InvalidStatus();

        _unlock(positionId);
        p.status = CollateralStatus.AVAILABLE;
        delete validated[positionId];
        emit ReservationCancelled(positionId);
    }

    function markApproved(bytes32 positionId) external onlyOperator {
        CollateralPosition storage p = positions[positionId];
        if (!positionExists(positionId)) revert PositionDoesNotExist();
        if (p.status != CollateralStatus.RESERVED) revert InvalidStatus();
        approved[positionId] = true;
        emit PositionApproved(positionId);
    }

    function finalizePledge(bytes32 positionId) external onlyOperator {
        CollateralPosition storage p = positions[positionId];
        if (!positionExists(positionId)) revert PositionDoesNotExist();
        if (p.status != CollateralStatus.RESERVED) revert InvalidStatus();
        if (!approved[positionId]) revert NotApproved();

        CollateralLedger storage l = ledgerByAssetIdProvider(p.assetId, p.provider);
        l.reserved -= p.quantity;
        l.pledged += p.quantity;

        p.status = CollateralStatus.PLEDGED;

        audit.log(
            AuditRegistry.AuditEventType.COLLATERAL_PLEDGED,
            p.provider,
            positionId,
            p.quantity,
            p.collateralValue,
            bytes32("RESERVED"),
            bytes32("PLEDGED")
        );
    }

    function requestRelease(bytes32 positionId) external onlyOperator {
        CollateralPosition storage p = positions[positionId];
        if (!positionExists(positionId)) revert PositionDoesNotExist();
        if (p.status != CollateralStatus.PLEDGED) revert InvalidStatus();
        p.status = CollateralStatus.RELEASE_REQUESTED;

        audit.log(
            AuditRegistry.AuditEventType.COLLATERAL_RELEASE_REQUESTED,
            p.provider,
            positionId,
            p.quantity,
            p.collateralValue,
            bytes32("PLEDGED"),
            bytes32("RELEASE_REQUESTED")
        );
    }

    /// @notice Releases a position that is in RELEASE_REQUESTED state.
    function approveRelease(bytes32 positionId) external onlyOperator {
        CollateralPosition storage p = positions[positionId];
        if (!positionExists(positionId)) revert PositionDoesNotExist();
        if (p.status != CollateralStatus.RELEASE_REQUESTED) revert InvalidStatus();
        _release(positionId);
    }

    /// @notice Direct release of a PLEDGED position (e.g. repo maturity).
    function release(bytes32 positionId) external onlyOperator {
        CollateralPosition storage p = positions[positionId];
        if (!positionExists(positionId)) revert PositionDoesNotExist();
        if (p.status != CollateralStatus.PLEDGED) revert InvalidStatus();
        _release(positionId);
    }

    function linkObligation(bytes32 positionId, bytes32 obligationId) external onlyOperator {
        CollateralPosition storage p = positions[positionId];
        if (!positionExists(positionId)) revert PositionDoesNotExist();
        if (p.obligationId == bytes32(0)) {
            if (positionsByObligation[obligationId].length >= MAX_OBLIGATION_POSITIONS) revert ObligationCapReached();
            p.obligationId = obligationId;
            positionsByObligation[obligationId].push(positionId);
        }
    }

    function markDefault(bytes32 positionId) external onlyOperator {
        CollateralPosition storage p = positions[positionId];
        if (!positionExists(positionId)) revert PositionDoesNotExist();
        if (p.status != CollateralStatus.PLEDGED && p.status != CollateralStatus.RELEASE_REQUESTED) {
            revert InvalidStatus();
        }
        p.status = CollateralStatus.DEFAULTED;
        emit PositionDefaulted(positionId);

        audit.log(
            AuditRegistry.AuditEventType.COLLATERAL_DEFAULTED,
            p.provider,
            positionId,
            p.quantity,
            p.collateralValue,
            bytes32("PLEDGED"),
            bytes32("DEFAULTED")
        );
    }

    /**
     * @notice Post-default enforcement: forceTransfer the locked tokens out of
     *         the vault to the entitled party and mark RECOVERY.
     */
    function enforceCollateral(bytes32 positionId, address to) external onlyOperator nonReentrant {
        CollateralPosition storage p = positions[positionId];
        if (!positionExists(positionId)) revert PositionDoesNotExist();
        if (p.status != CollateralStatus.DEFAULTED) revert InvalidStatus();

        address token = assetRegistry.getToken(p.assetId);
        ITokenizedSecurity(token).forceTransfer(address(this), to, p.quantity);

        CollateralLedger storage l = ledgerByAssetIdProvider(p.assetId, p.provider);
        l.pledged -= p.quantity;
        l.released += p.quantity;

        // Clear the encumbrance mirror: the securities have left the collateral pool.
        custodyRegistry.applyEncumbrance(p.assetId, p.provider, -int256(p.quantity));

        p.status = CollateralStatus.RECOVERY;

        audit.log(
            AuditRegistry.AuditEventType.COLLATERAL_ENFORCED,
            p.provider,
            positionId,
            p.quantity,
            p.collateralValue,
            bytes32("DEFAULTED"),
            bytes32("RECOVERY")
        );
    }

    /* ------------------------------------------------------------------ */
    /* Substitution                                                        */
    /* ------------------------------------------------------------------ */

    function createReplacementPosition(
        bytes32 oldPositionId,
        address provider,
        address receiver,
        bytes32 assetId,
        uint256 quantity,
        bytes32 obligationId
    ) external onlyOperator returns (bytes32 replacementId) {
        CollateralPosition storage old = positions[oldPositionId];
        if (!positionExists(oldPositionId)) revert PositionDoesNotExist();
        if (old.status != CollateralStatus.PLEDGED) revert InvalidStatus();
        if (pendingSubstitution[oldPositionId] != bytes32(0)) revert NoPendingSubstitution();

        if (provider != old.provider || receiver != old.receiver) revert Unauthorized();
        if (availableQuantity(assetId, provider) < quantity) revert InsufficientAvailable();
        if (obligationId != bytes32(0) && positionsByObligation[obligationId].length >= MAX_OBLIGATION_POSITIONS) revert ObligationCapReached();

        replacementId = _newPositionId();
        positions[replacementId] = CollateralPosition({
            positionId: replacementId,
            provider: provider,
            receiver: receiver,
            assetId: assetId,
            quantity: quantity,
            marketValue: 0,
            haircutBps: 0,
            collateralValue: 0,
            status: CollateralStatus.AVAILABLE,
            obligationId: obligationId,
            createdAt: block.timestamp
        });

        pendingSubstitution[oldPositionId] = replacementId;
        substitutionSource[replacementId] = oldPositionId;

        if (obligationId != bytes32(0)) positionsByObligation[obligationId].push(replacementId);

        audit.log(
            AuditRegistry.AuditEventType.COLLATERAL_SUBSTITUTION_REQUESTED,
            provider,
            oldPositionId,
            quantity,
            0,
            bytes32("PLEDGED"),
            bytes32("SUBSTITUTING")
        );
    }

    function validateReplacement(bytes32 replacementId) external onlyOperator {
        CollateralPosition storage r = positions[replacementId];
        if (!positionExists(replacementId)) revert PositionDoesNotExist();
        if (r.status != CollateralStatus.AVAILABLE) revert InvalidStatus();

        bytes32 oldId = substitutionSource[replacementId];
        if (oldId == bytes32(0)) revert NoPendingSubstitution();
        CollateralPosition storage old = positions[oldId];

        // Replacement is valued with current (fresh) prices; reverts if stale.
        (uint256 marketValue, uint256 collateralValue, uint256 haircutBps) =
            eligibility.assessCollateral(r.assetId, r.provider, r.quantity);
        (, uint256 oldValue) = eligibility.getCollateralValue(old.assetId, old.quantity);

        // Atomicity rule: replacement must cover the CURRENT value of the old collateral.
        if (collateralValue < oldValue) revert InvalidValueRelation();

        r.marketValue = marketValue;
        r.collateralValue = collateralValue;
        r.haircutBps = haircutBps;
        validated[replacementId] = true;
    }

    function reserveReplacement(bytes32 replacementId) external onlyOperator nonReentrant {
        CollateralPosition storage r = positions[replacementId];
        if (!positionExists(replacementId)) revert PositionDoesNotExist();
        if (r.status != CollateralStatus.AVAILABLE) revert InvalidStatus();
        if (!validated[replacementId]) revert NotValidated();
        if (availableQuantity(r.assetId, r.provider) < r.quantity) revert InsufficientAvailable();

        _lock(replacementId);
        r.status = CollateralStatus.RESERVED;
    }

    /**
     * @notice Swap the old pledged position for the reserved replacement.
     * @dev Ordering guarantees: the old collateral is only released AFTER the
     *      replacement is reserved (locked). The old stays encumbered until now.
     */
    function activateSubstitution(bytes32 oldPositionId) external onlyOperator nonReentrant {
        bytes32 replacementId = pendingSubstitution[oldPositionId];
        if (replacementId == bytes32(0)) revert NoPendingSubstitution();

        CollateralPosition storage old = positions[oldPositionId];
        CollateralPosition storage r = positions[replacementId];

        if (old.status != CollateralStatus.PLEDGED) revert InvalidStatus();
        if (r.status != CollateralStatus.RESERVED) revert InvalidStatus();
        if (!validated[replacementId]) revert NotValidated();

        // Release old collateral.
        _release(oldPositionId);

        // Activate replacement.
        CollateralLedger storage l = ledgerByAssetIdProvider(r.assetId, r.provider);
        l.reserved -= r.quantity;
        l.pledged += r.quantity;
        r.status = CollateralStatus.PLEDGED;

        delete pendingSubstitution[oldPositionId];

        audit.log(
            AuditRegistry.AuditEventType.COLLATERAL_SUBSTITUTED,
            r.provider,
            oldPositionId,
            r.quantity,
            r.collateralValue,
            bytes32("PLEDGED"),
            bytes32("SUBSTITUTED")
        );
    }

    function cancelSubstitution(bytes32 oldPositionId) external onlyOperator {
        bytes32 replacementId = pendingSubstitution[oldPositionId];
        if (replacementId == bytes32(0)) revert NoPendingSubstitution();

        CollateralPosition storage r = positions[replacementId];
        if (r.status == CollateralStatus.RESERVED) {
            _unlock(replacementId);
            r.status = CollateralStatus.AVAILABLE;
        }
        delete pendingSubstitution[oldPositionId];
        delete substitutionSource[replacementId];
    }

    /* ------------------------------------------------------------------ */
    /* Internal helpers                                                    */
    /* ------------------------------------------------------------------ */

    /// @notice Lock collateral: transfer the tokenized securities into the vault
    ///         and apply the encumbrance delta in the custody mirror.
    function _lock(bytes32 positionId) internal {
        CollateralPosition storage p = positions[positionId];
        address token = assetRegistry.getToken(p.assetId);
        if (token == address(0)) revert NoToken();
        ITokenizedSecurity(token).forceTransfer(p.provider, address(this), p.quantity);
        custodyRegistry.applyEncumbrance(p.assetId, p.provider, int256(p.quantity));
        CollateralLedger storage l = ledgerByAssetIdProvider(p.assetId, p.provider);
        l.reserved += p.quantity;
        emit CollateralLocked(positionId, p.quantity);
    }

    function _unlock(bytes32 positionId) internal {
        CollateralPosition storage p = positions[positionId];
        address token = assetRegistry.getToken(p.assetId);
        if (token == address(0)) revert NoToken();
        ITokenizedSecurity(token).forceTransfer(address(this), p.provider, p.quantity);
        custodyRegistry.applyEncumbrance(p.assetId, p.provider, -int256(p.quantity));
        CollateralLedger storage l = ledgerByAssetIdProvider(p.assetId, p.provider);
        l.reserved -= p.quantity;
        emit CollateralUnlocked(positionId, p.quantity);
    }

    function _release(bytes32 positionId) internal {
        CollateralPosition storage p = positions[positionId];

        // A pledged position's quantity lives in `pledged` (moved there at
        // finalizePledge), so release moves it out of `pledged` directly rather
        // than via _unlock (which only applies to RESERVED positions).
        address token = assetRegistry.getToken(p.assetId);
        if (token == address(0)) revert NoToken();
        ITokenizedSecurity(token).forceTransfer(address(this), p.provider, p.quantity);
        custodyRegistry.applyEncumbrance(p.assetId, p.provider, -int256(p.quantity));

        CollateralLedger storage l = ledgerByAssetIdProvider(p.assetId, p.provider);
        l.pledged -= p.quantity;
        l.released += p.quantity;

        p.status = CollateralStatus.RELEASED;

        audit.log(
            AuditRegistry.AuditEventType.COLLATERAL_RELEASED,
            p.provider,
            positionId,
            p.quantity,
            p.collateralValue,
            bytes32("PLEDGED"),
            bytes32("RELEASED")
        );
    }

    /* ------------------------------------------------------------------ */
    /* Valuation views                                                     */
    /* ------------------------------------------------------------------ */

    function getPosition(bytes32 positionId) external view returns (CollateralPosition memory) {
        return positions[positionId];
    }

    function positionApproved(bytes32 positionId) external view returns (bool) {
        return approved[positionId];
    }

    function getPositionsByObligation(bytes32 obligationId) external view returns (bytes32[] memory) {
        return positionsByObligation[obligationId];
    }

    /// @notice Paginated view of positions linked to an obligation.
    function getPositionsByObligationPaginated(bytes32 obligationId, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory)
    {
        bytes32[] storage all = positionsByObligation[obligationId];
        if (offset >= all.length) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > all.length) end = all.length;
        uint256 size = end - offset;
        bytes32[] memory result = new bytes32[](size);
        for (uint256 i = 0; i < size; i++) {
            result[i] = all[offset + i];
        }
        return result;
    }

    /// @notice Sum of *stored* collateral values for an obligation.
    function totalCollateralValueForObligation(bytes32 obligationId) external view returns (uint256) {
        bytes32[] memory ids = positionsByObligation[obligationId];
        uint256 total;
        for (uint256 i = 0; i < ids.length; i++) {
            CollateralPosition storage p = positions[ids[i]];
            if (_isEncumbered(p.status)) total += p.collateralValue;
        }
        return total;
    }

    /// @notice Live mark-to-market value of all encumbered positions for an obligation.
    /// @dev Reverts if any price is stale — margin evaluation requires fresh prices.
    function liveCollateralValueForObligation(bytes32 obligationId) external view returns (uint256) {
        bytes32[] memory ids = positionsByObligation[obligationId];
        uint256 total;
        for (uint256 i = 0; i < ids.length; i++) {
            CollateralPosition storage p = positions[ids[i]];
            if (!_isEncumbered(p.status)) continue;
            (, uint256 live) = eligibility.getCollateralValue(p.assetId, p.quantity);
            total += live;
        }
        return total;
    }

    function _isEncumbered(CollateralStatus s) internal pure returns (bool) {
        return s == CollateralStatus.RESERVED || s == CollateralStatus.PLEDGED || s == CollateralStatus.RELEASE_REQUESTED;
    }
}
