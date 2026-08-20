// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {TestBase} from "../TestBase.sol";
import {RepoManager} from "../../src/RepoManager.sol";
import {CollateralManager} from "../../src/CollateralManager.sol";
import {LibConstants as C} from "../../script/LibConstants.sol";

contract RepoManagerTest is TestBase {
    function setUp() public {
        _deployNetwork();
    }

    function _pledgedPosition() internal returns (bytes32 positionId) {
        _setupBankAReady(1);
        positionId = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));
    }

    function _createRepo(bytes32 positionId, uint256 cashAmount) internal returns (bytes32 repoId) {
        vm.prank(bankA);
        repoId = repoManager.createRepo(bankA, bankB, positionId, cashAmount, C.REPO_RATE_BPS, C.REPO_TENOR);
    }

    function test_onlyBorrowerCanCreateRepo() public {
        bytes32 positionId = _pledgedPosition();
        vm.prank(bankB);
        vm.expectRevert(RepoManager.Unauthorized.selector);
        repoManager.createRepo(bankA, bankB, positionId, C.REPO_CASH, C.REPO_RATE_BPS, C.REPO_TENOR);
    }

    function test_createRepoRequiresPledgedCollateral() public {
        _setupBankAReady(1);
        vm.prank(bankA);
        bytes32 positionId = pledgeManager.requestPledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));
        vm.prank(bankA);
        vm.expectRevert(RepoManager.CollateralNotPledged.selector);
        repoManager.createRepo(bankA, bankB, positionId, C.REPO_CASH, C.REPO_RATE_BPS, C.REPO_TENOR);
    }

    function test_createRepoCollateralValueTooLow() public {
        bytes32 positionId = _pledgedPosition();
        vm.prank(bankA);
        vm.expectRevert(RepoManager.CollateralValueTooLow.selector);
        repoManager.createRepo(bankA, bankB, positionId, 96_000_000, C.REPO_RATE_BPS, C.REPO_TENOR);
    }

    function test_createRepoTiesObligationAndSetsMaturity() public {
        bytes32 positionId = _pledgedPosition();
        bytes32 repoId = _createRepo(positionId, C.REPO_CASH);
        RepoManager.Repo memory r = repoManager.getRepo(repoId);
        assertEq(uint256(r.status), uint256(RepoManager.RepoStatus.CREATED));
        assertEq(r.borrower, bankA);
        assertEq(r.lender, bankB);
        assertEq(r.cashAmount, C.REPO_CASH);
        assertEq(r.maturity, block.timestamp + C.REPO_TENOR);
        assertEq(r.collateralPositionId, positionId);
        assertEq(collateralManager.getPosition(positionId).obligationId, repoId);
    }

    function test_settleRepoMovesCashAndActivates() public {
        bytes32 positionId = _pledgedPosition();
        bytes32 repoId = _repoAndSettle(positionId, C.REPO_CASH);
        RepoManager.Repo memory r = repoManager.getRepo(repoId);
        assertEq(uint256(r.status), uint256(RepoManager.RepoStatus.ACTIVE));
        assertEq(cash.balanceOf(bankA), C.BANK_A_CASH + C.REPO_CASH);
        assertEq(cash.balanceOf(bankB), C.BANK_B_CASH - C.REPO_CASH);
    }

    function test_amountOwedIncludesInterest() public {
        bytes32 positionId = _pledgedPosition();
        bytes32 repoId = _createRepo(positionId, C.REPO_CASH);
        uint256 owed = repoManager.amountOwed(repoId);
        // 95,000,000 * 500bps * 7 days / (365 days * 10000)
        assertEq(owed, 95_000_000 + 91_095);
    }

    function test_repayTooEarlyReverts() public {
        bytes32 positionId = _pledgedPosition();
        bytes32 repoId = _repoAndSettle(positionId, C.REPO_CASH);
        vm.prank(bankA);
        vm.expectRevert(RepoManager.TooEarly.selector);
        repoManager.repayAndClose(repoId);
    }

    function test_fullRepoLifecycle() public {
        bytes32 positionId = _pledgedPosition();
        bytes32 repoId = _repoAndSettle(positionId, C.REPO_CASH);

        vm.warp(block.timestamp + C.REPO_TENOR);
        vm.startPrank(bankA);
        cash.approve(address(repoManager), type(uint256).max);
        uint256 repaid = repoManager.repayAndClose(repoId);
        vm.stopPrank();

        uint256 owed = 95_000_000 + 91_095;
        assertEq(repaid, owed);
        assertEq(uint256(repoManager.getRepo(repoId).status), uint256(RepoManager.RepoStatus.CLOSED));
        assertEq(uint256(collateralManager.getPosition(positionId).status), uint256(CollateralManager.CollateralStatus.RELEASED));
        assertEq(tBondToken.balanceOf(bankA), C.T_BOND_QUANTITY);
        assertEq(custodyRegistry.getCustodyState(C.T_BOND).encumberedQuantity, 0);
        assertEq(cash.balanceOf(bankB), C.BANK_B_CASH - C.REPO_CASH + owed);
    }

    function test_defaultBeforeMaturityReverts() public {
        bytes32 positionId = _pledgedPosition();
        bytes32 repoId = _repoAndSettle(positionId, C.REPO_CASH);
        vm.prank(bankB);
        vm.expectRevert(RepoManager.TooEarly.selector);
        repoManager.defaultRepo(repoId);
    }

    function test_defaultRepoAtMaturityFlagsCollateral() public {
        bytes32 positionId = _pledgedPosition();
        bytes32 repoId = _repoAndSettle(positionId, C.REPO_CASH);
        vm.warp(block.timestamp + C.REPO_TENOR);
        vm.prank(bankB);
        repoManager.defaultRepo(repoId);
        assertEq(uint256(repoManager.getRepo(repoId).status), uint256(RepoManager.RepoStatus.DEFAULTED));
        assertEq(uint256(collateralManager.getPosition(positionId).status), uint256(CollateralManager.CollateralStatus.DEFAULTED));
    }

    function test_defaultRepoOnlyLenderOrAgent() public {
        bytes32 positionId = _pledgedPosition();
        bytes32 repoId = _repoAndSettle(positionId, C.REPO_CASH);
        vm.warp(block.timestamp + C.REPO_TENOR);
        vm.prank(bankA);
        vm.expectRevert(RepoManager.Unauthorized.selector);
        repoManager.defaultRepo(repoId);
    }

    function test_enforcementAfterDefault() public {
        bytes32 positionId = _pledgedPosition();
        bytes32 repoId = _repoAndSettle(positionId, C.REPO_CASH);
        vm.warp(block.timestamp + C.REPO_TENOR);
        vm.prank(bankB);
        repoManager.defaultRepo(repoId);

        vm.prank(address(repoManager));
        settlement.enforceCollateral(positionId, bankB);
        assertEq(tBondToken.balanceOf(bankB), C.T_BOND_QUANTITY);
        assertEq(uint256(collateralManager.getPosition(positionId).status), uint256(CollateralManager.CollateralStatus.RECOVERY));
    }
}
