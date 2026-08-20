// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {TestBase} from "../TestBase.sol";
import {SettlementCoordinator} from "../../src/SettlementCoordinator.sol";
import {CollateralManager} from "../../src/CollateralManager.sol";
import {LibConstants as C} from "../../script/LibConstants.sol";

contract SettlementCoordinatorTest is TestBase {
    function setUp() public {
        _deployNetwork();
    }

    function _pledgedPosition() internal returns (bytes32 positionId) {
        _setupBankAReady(1);
        positionId = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));
    }

    function test_onlySettlementAgentCanSettle() public {
        bytes32 positionId = _pledgedPosition();
        vm.prank(bankA);
        vm.expectRevert(SettlementCoordinator.Unauthorized.selector);
        settlement.settleRepo(keccak256("repo"), bankA, bankB, positionId, 1);
    }

    function test_settleRequiresPledgedCollateral() public {
        _setupBankAReady(1);
        vm.prank(bankA);
        bytes32 positionId = pledgeManager.requestPledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));
        vm.prank(address(repoManager));
        vm.expectRevert(SettlementCoordinator.CollateralNotPledged.selector);
        settlement.settleRepo(keccak256("repo"), bankA, bankB, positionId, 1);
    }

    function test_settleRequiresSufficientCollateralValue() public {
        bytes32 positionId = _pledgedPosition();
        vm.prank(address(repoManager));
        vm.expectRevert(SettlementCoordinator.InsufficientCollateralValue.selector);
        settlement.settleRepo(keccak256("repo"), bankA, bankB, positionId, 96_000_000);
    }

    function test_settleRequiresLenderCash() public {
        bytes32 positionId = _pledgedPosition();
        // Drain the lender so the balance check triggers (value check passes first).
        vm.startPrank(bankB);
        assertTrue(cash.transfer(bankA, cash.balanceOf(bankB)));
        vm.stopPrank();
        vm.prank(address(repoManager));
        vm.expectRevert(SettlementCoordinator.InsufficientCash.selector);
        settlement.settleRepo(keccak256("repo"), bankA, bankB, positionId, C.REPO_CASH);
    }

    function test_settleMovesCashLenderToBorrower() public {
        bytes32 positionId = _pledgedPosition();
        vm.prank(bankB);
        cash.approve(address(settlement), C.REPO_CASH);
        vm.prank(address(repoManager));
        settlement.settleRepo(keccak256("repo"), bankA, bankB, positionId, C.REPO_CASH);
        assertEq(cash.balanceOf(bankA), C.BANK_A_CASH + C.REPO_CASH);
        assertEq(cash.balanceOf(bankB), C.BANK_B_CASH - C.REPO_CASH);
    }

    function test_releaseCollateral() public {
        bytes32 positionId = _pledgedPosition();
        vm.prank(address(repoManager));
        settlement.releaseCollateral(positionId);
        assertEq(uint256(collateralManager.getPosition(positionId).status), uint256(CollateralManager.CollateralStatus.RELEASED));
        assertEq(tBondToken.balanceOf(bankA), C.T_BOND_QUANTITY);
    }

    function test_markAndEnforceCollateral() public {
        bytes32 positionId = _pledgedPosition();
        vm.prank(address(repoManager));
        settlement.markCollateralDefault(positionId);
        assertEq(uint256(collateralManager.getPosition(positionId).status), uint256(CollateralManager.CollateralStatus.DEFAULTED));

        vm.prank(address(repoManager));
        settlement.enforceCollateral(positionId, bankB);
        assertEq(uint256(collateralManager.getPosition(positionId).status), uint256(CollateralManager.CollateralStatus.RECOVERY));
        assertEq(tBondToken.balanceOf(bankB), C.T_BOND_QUANTITY);
    }

    function test_unknownPositionReverts() public {
        vm.prank(address(repoManager));
        vm.expectRevert(SettlementCoordinator.PositionDoesNotExist.selector);
        settlement.settleRepo(keccak256("repo"), bankA, bankB, keccak256("nope"), 1);
    }
}
