// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ProtocolAccessManager} from "./ProtocolAccessManager.sol";
import {Roles} from "./libs/Roles.sol";
import {AuditRegistry} from "./AuditRegistry.sol";
import {ICollateralManager} from "./interfaces/ICollateralManager.sol";
import {ICashToken} from "./interfaces/ICashToken.sol";

/**
 * @title SettlementCoordinator
 * @notice Orchestrates the asset (collateral) and cash legs of settlement.
 *
 * @dev The coordinator does NOT reach into every contract's internals — it
 *      drives the CollateralManager and CashToken through their interfaces.
 *
 *      Settlement sequence (atomic in one transaction for the POC):
 *        1. Verify collateral is PLEDGED
 *        2. Verify collateral value covers the cash amount (haircut already applied)
 *        3. Verify the cash provider's balance
 *        4. Lock collateral        (already locked at reserve; confirmed here)
 *        5. Lock cash              (transferFrom into the DvP)
 *        6. Record collateral entitlement (position stays PLEDGED under the repo)
 *        7. Transfer cash          (delivery to the cash borrower)
 *        8. Emit settlement event
 */
contract SettlementCoordinator {
    ProtocolAccessManager public immutable access;
    ICollateralManager public immutable collateral;
    ICashToken public immutable cash;
    AuditRegistry public immutable audit;

    error Unauthorized();
    error CollateralNotPledged();
    error InsufficientCollateralValue();
    error InsufficientCash();
    error PositionDoesNotExist();

    constructor(
        ProtocolAccessManager access_,
        ICollateralManager collateral_,
        ICashToken cash_,
        AuditRegistry audit_
    ) {
        access = access_;
        collateral = collateral_;
        cash = cash_;
        audit = audit_;
    }

    modifier onlySettlementAgent() {
        if (!access.hasRole(Roles.SETTLEMENT_AGENT, msg.sender)) revert Unauthorized();
        _;
    }

    /**
     * @notice Atomic DvP: settle the cash leg of a repo against pledged collateral.
     */
    function settleRepo(
        bytes32 repoId,
        address borrower,
        address lender,
        bytes32 collateralPositionId,
        uint256 cashAmount
    ) external onlySettlementAgent {
        ICollateralManager.CollateralPosition memory p = collateral.getPosition(collateralPositionId);
        if (p.positionId == bytes32(0)) revert PositionDoesNotExist();
        if (p.status != ICollateralManager.CollateralStatus.PLEDGED) revert CollateralNotPledged();
        if (p.collateralValue < cashAmount) revert InsufficientCollateralValue();
        if (cash.balanceOf(lender) < cashAmount) revert InsufficientCash();

        // Collateral is already locked in the CollateralManager vault (reserve).
        // Lock + deliver the cash leg atomically:
        require(cash.transferFrom(lender, borrower, cashAmount), "Settlement: cash transfer failed");

        audit.log(
            AuditRegistry.AuditEventType.SETTLEMENT_COMPLETED,
            borrower,
            repoId,
            p.quantity,
            cashAmount,
            bytes32("PENDING"),
            bytes32("SETTLED")
        );
    }

    /// @notice Release collateral back to the provider (repo maturity repayment).
    function releaseCollateral(bytes32 collateralPositionId) external onlySettlementAgent {
        collateral.release(collateralPositionId);
    }

    /// @notice Mark a collateral position defaulted (repo default).
    function markCollateralDefault(bytes32 collateralPositionId) external onlySettlementAgent {
        collateral.markDefault(collateralPositionId);
    }

    /// @notice Post-default enforcement: forceTransfer locked securities.
    function enforceCollateral(bytes32 collateralPositionId, address to) external onlySettlementAgent {
        collateral.enforceCollateral(collateralPositionId, to);
    }
}
