// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ProtocolAccessManager} from "./ProtocolAccessManager.sol";
import {Roles} from "./libs/Roles.sol";
import {AuditRegistry} from "./AuditRegistry.sol";
import {ICollateralManager} from "./interfaces/ICollateralManager.sol";
import {ICashToken} from "./interfaces/ICashToken.sol";
import {SettlementCoordinator} from "./SettlementCoordinator.sol";

/**
 * @title RepoManager
 * @notice Simplified repo (sell-and-repurchase) facility.
 *
 * @dev
 *   Borrower (Bank A) = collateral seller / cash borrower
 *   Lender   (Bank B) = cash provider / collateral receiver
 *
 *   Example: $1,000,000 Treasury, 5% haircut -> $950,000 financing, 5% rate,
 *   tenor 7 days. At maturity the borrower repays principal + interest and the
 *   collateral is released. On failure to repay the repo is marked DEFAULTED and
 *   the collateral position marked DEFAULTED (V1 records the state, no real
 *   liquidation mechanics).
 */
contract RepoManager {
    enum RepoStatus {
        NONE,
        CREATED,
        ACTIVE,
        CLOSED,
        DEFAULTED
    }

    struct Repo {
        bytes32 repoId;
        address borrower;
        address lender;
        bytes32 collateralPositionId;
        uint256 cashAmount;
        uint256 repoRate; // annual rate in bps (500 == 5%)
        uint256 maturity; // unix timestamp
        uint256 created;
        RepoStatus status;
    }

    ProtocolAccessManager public immutable access;
    ICollateralManager public immutable collateral;
    ICashToken public immutable cash;
    SettlementCoordinator public immutable settlement;
    AuditRegistry public immutable audit;

    uint256 public repoCounter;
    mapping(bytes32 => Repo) public repos;

    event RepoCreated(bytes32 indexed repoId, address indexed borrower, address indexed lender);
    event RepoSettled(bytes32 indexed repoId);
    event RepoMatured(bytes32 indexed repoId, uint256 repaid);
    event RepoDefaulted(bytes32 indexed repoId);

    error Unauthorized();
    error RepoDoesNotExist();
    error InvalidStatus();
    error PositionDoesNotExist();
    error CollateralNotPledged();
    error CollateralValueTooLow();
    error TooEarly();
    error RepoOverdue();

    constructor(
        ProtocolAccessManager access_,
        ICollateralManager collateral_,
        ICashToken cash_,
        SettlementCoordinator settlement_,
        AuditRegistry audit_
    ) {
        access = access_;
        collateral = collateral_;
        cash = cash_;
        settlement = settlement_;
        audit = audit_;
    }

    modifier onlyRole(bytes32 role) {
        if (!access.hasRole(role, msg.sender)) revert Unauthorized();
        _;
    }

    /* ------------------------------------------------------------------ */
    /* Lifecycle                                                           */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Create a repo against an already-pledged collateral position.
     */
    function createRepo(
        address borrower,
        address lender,
        bytes32 collateralPositionId,
        uint256 cashAmount,
        uint256 repoRateBps,
        uint256 tenor
    ) external onlyRole(Roles.BANK) returns (bytes32 repoId) {
        if (msg.sender != borrower) revert Unauthorized();

        ICollateralManager.CollateralPosition memory p = collateral.getPosition(collateralPositionId);
        if (p.positionId == bytes32(0)) revert PositionDoesNotExist();
        if (p.status != ICollateralManager.CollateralStatus.PLEDGED) revert CollateralNotPledged();
        if (p.provider != borrower || p.receiver != lender) revert Unauthorized();
        if (p.collateralValue < cashAmount) revert CollateralValueTooLow();

        repoCounter++;
        repoId = keccak256(abi.encode("REPO", repoCounter, borrower, lender));
        repos[repoId] = Repo({
            repoId: repoId,
            borrower: borrower,
            lender: lender,
            collateralPositionId: collateralPositionId,
            cashAmount: cashAmount,
            repoRate: repoRateBps,
            maturity: block.timestamp + tenor,
            created: block.timestamp,
            status: RepoStatus.CREATED
        });

        // Tie the collateral position to this repo obligation.
        collateral.linkObligation(collateralPositionId, repoId);

        audit.log(
            AuditRegistry.AuditEventType.REPO_CREATED,
            borrower,
            repoId,
            p.quantity,
            cashAmount,
            bytes32(0),
            bytes32("CREATED")
        );
        emit RepoCreated(repoId, borrower, lender);
    }

    /**
     * @notice Settle the repo (DvP): lender's cash -> borrower; collateral stays
     *         locked under the repo.
     */
    function settleRepo(bytes32 repoId) external {
        Repo storage r = repos[repoId];
        if (r.repoId == bytes32(0)) revert RepoDoesNotExist();
        if (r.status != RepoStatus.CREATED) revert InvalidStatus();
        bool isParty = msg.sender == r.borrower || msg.sender == r.lender;
        bool isAgent = access.hasRole(Roles.SETTLEMENT_AGENT, msg.sender);
        if (!isParty && !isAgent) revert Unauthorized();

        settlement.settleRepo(r.repoId, r.borrower, r.lender, r.collateralPositionId, r.cashAmount);

        r.status = RepoStatus.ACTIVE;

        audit.log(
            AuditRegistry.AuditEventType.REPO_SETTLED,
            r.borrower,
            repoId,
            0,
            r.cashAmount,
            bytes32("CREATED"),
            bytes32("ACTIVE")
        );
        emit RepoSettled(repoId);
    }

    /**
     * @notice Repay principal + interest at maturity; release collateral.
     */
    function repayAndClose(bytes32 repoId) external returns (uint256 repaid) {
        Repo storage r = repos[repoId];
        if (r.repoId == bytes32(0)) revert RepoDoesNotExist();
        if (r.status != RepoStatus.ACTIVE) revert InvalidStatus();
        if (block.timestamp < r.maturity) revert TooEarly();

        repaid = _amountOwed(r);
        require(cash.transferFrom(r.borrower, r.lender, repaid), "Repo: repayment failed");

        // Release the collateral back to the borrower. Substitution may have
        // replaced the original position, so release every currently-pledged
        // position linked to this repo obligation.
        bytes32[] memory ids = collateral.getPositionsByObligation(repoId);
        for (uint256 i = 0; i < ids.length; i++) {
            ICollateralManager.CollateralPosition memory p = collateral.getPosition(ids[i]);
            if (p.status == ICollateralManager.CollateralStatus.PLEDGED) {
                settlement.releaseCollateral(ids[i]);
            }
        }

        r.status = RepoStatus.CLOSED;

        audit.log(
            AuditRegistry.AuditEventType.REPO_MATURED,
            r.borrower,
            repoId,
            0,
            repaid,
            bytes32("ACTIVE"),
            bytes32("CLOSED")
        );
        emit RepoMatured(repoId, repaid);
    }

    /**
     * @notice Mark the repo defaulted once overdue and unpaid. V1 only records
     *         the state and flags the collateral; no liquidation mechanics.
     */
    function defaultRepo(bytes32 repoId) external {
        Repo storage r = repos[repoId];
        if (r.repoId == bytes32(0)) revert RepoDoesNotExist();
        if (r.status != RepoStatus.ACTIVE) revert InvalidStatus();

        bool isLender = msg.sender == r.lender;
        bool isAgent = access.hasRole(Roles.COLLATERAL_AGENT, msg.sender);
        if (!isLender && !isAgent) revert Unauthorized();

        // Allow defaulting immediately after maturity if still ACTIVE (repay not called).
        if (block.timestamp < r.maturity) revert TooEarly();

        r.status = RepoStatus.DEFAULTED;
        bytes32[] memory ids = collateral.getPositionsByObligation(repoId);
        for (uint256 i = 0; i < ids.length; i++) {
            ICollateralManager.CollateralPosition memory p = collateral.getPosition(ids[i]);
            if (p.status == ICollateralManager.CollateralStatus.PLEDGED) {
                settlement.markCollateralDefault(ids[i]);
            }
        }

        audit.log(
            AuditRegistry.AuditEventType.REPO_DEFAULTED,
            r.borrower,
            repoId,
            0,
            r.cashAmount,
            bytes32("ACTIVE"),
            bytes32("DEFAULTED")
        );
        emit RepoDefaulted(repoId);
    }

    /* ------------------------------------------------------------------ */
    /* Views                                                               */
    /* ------------------------------------------------------------------ */

    function getRepo(bytes32 repoId) external view returns (Repo memory) {
        return repos[repoId];
    }

    function amountOwed(bytes32 repoId) external view returns (uint256) {
        Repo storage r = repos[repoId];
        if (r.repoId == bytes32(0)) revert RepoDoesNotExist();
        return _amountOwed(r);
    }

    /// @notice principal + simple interest over the tenor.
    function _amountOwed(Repo storage r) internal view returns (uint256) {
        uint256 tenor = r.maturity - r.created;
        uint256 interest = (r.cashAmount * r.repoRate * tenor) / (365 days * 10000);
        return r.cashAmount + interest;
    }
}
