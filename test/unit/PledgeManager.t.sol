// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {TestBase} from "../TestBase.sol";
import {PledgeManager} from "../../src/PledgeManager.sol";
import {CollateralManager} from "../../src/CollateralManager.sol";
import {LibConstants as C} from "../../script/LibConstants.sol";

contract PledgeManagerTest is TestBase {
    function setUp() public {
        _deployNetwork();
    }

    function test_onlyBankCanRequestPledge() public {
        vm.prank(mockCsd);
        vm.expectRevert(PledgeManager.Unauthorized.selector);
        pledgeManager.requestPledge(C.T_BOND, 100, bankB, bytes32(0));
    }

    function test_requestPledgeInsufficientAvailable() public {
        vm.prank(bankA);
        vm.expectRevert(CollateralManager.InsufficientAvailable.selector);
        pledgeManager.requestPledge(C.T_BOND, 100, bankB, bytes32(0));
    }

    function test_verifyCollateralOnlyAgent() public {
        _setupBankAReady(1);
        bytes32 positionId = _requestPosition();
        vm.prank(bankA);
        vm.expectRevert(PledgeManager.Unauthorized.selector);
        pledgeManager.verifyCollateral(positionId);
    }

    function _requestPosition() internal returns (bytes32 positionId) {
        vm.prank(bankA);
        positionId = pledgeManager.requestPledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));
    }

    function test_fullPledgeFlowLocksCollateral() public {
        _setupBankAReady(1);
        bytes32 positionId = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));

        CollateralManager.CollateralPosition memory p = collateralManager.getPosition(positionId);
        assertEq(uint256(p.status), uint256(CollateralManager.CollateralStatus.PLEDGED));
        assertEq(p.provider, bankA);
        assertEq(p.receiver, bankB);
        assertEq(p.collateralValue, 95_000_000);

        // Tokens are locked in the vault; custody mirror encumbered.
        assertEq(tBondToken.balanceOf(address(collateralManager)), C.T_BOND_QUANTITY);
        assertEq(tBondToken.balanceOf(bankA), 0);
        assertEq(custodyRegistry.getCustodyState(C.T_BOND, bankA).encumberedQuantity, C.T_BOND_QUANTITY);
    }

    function test_reserveBeforeVerifyReverts() public {
        _setupBankAReady(1);
        bytes32 positionId = _requestPosition();
        vm.prank(bankA);
        vm.expectRevert(CollateralManager.NotValidated.selector);
        pledgeManager.reserveCollateral(positionId);
    }

    function test_doubleReserveReverts() public {
        _setupBankAReady(1);
        bytes32 positionId = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));
        vm.prank(bankA);
        vm.expectRevert(CollateralManager.InvalidStatus.selector);
        pledgeManager.reserveCollateral(positionId);
    }

    function test_approveOnlyByReceiver() public {
        _setupBankAReady(1);
        bytes32 positionId = _requestPosition();
        vm.prank(collateralAgent);
        pledgeManager.verifyCollateral(positionId);
        vm.prank(bankA);
        pledgeManager.reserveCollateral(positionId);

        vm.prank(bankA);
        vm.expectRevert(PledgeManager.NotReceiver.selector);
        pledgeManager.approvePledge(positionId);
    }

    function test_finalizeBeforeApprovalReverts() public {
        _setupBankAReady(1);
        bytes32 positionId = _requestPosition();
        vm.prank(collateralAgent);
        pledgeManager.verifyCollateral(positionId);
        vm.prank(bankA);
        pledgeManager.reserveCollateral(positionId);

        vm.prank(bankA);
        vm.expectRevert(CollateralManager.NotApproved.selector);
        pledgeManager.finalizePledge(positionId);
    }

    function test_rejectPledgeReturnsCollateral() public {
        _setupBankAReady(1);
        bytes32 positionId = _requestPosition();
        vm.prank(collateralAgent);
        pledgeManager.verifyCollateral(positionId);
        vm.prank(bankA);
        pledgeManager.reserveCollateral(positionId);
        assertEq(tBondToken.balanceOf(bankA), 0);

        vm.prank(bankA);
        pledgeManager.rejectPledge(positionId);

        CollateralManager.CollateralPosition memory p = collateralManager.getPosition(positionId);
        assertEq(uint256(p.status), uint256(CollateralManager.CollateralStatus.AVAILABLE));
        assertEq(tBondToken.balanceOf(bankA), C.T_BOND_QUANTITY);
        assertEq(custodyRegistry.getCustodyState(C.T_BOND, bankA).encumberedQuantity, 0);
    }

    function test_doublePledgeSameCollateralReverts() public {
        _setupBankAReady(1);
        _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));
        vm.prank(bankA);
        vm.expectRevert(CollateralManager.InsufficientAvailable.selector);
        pledgeManager.requestPledge(C.T_BOND, 1, bankB, bytes32(0));
    }

    function test_releaseRequiresBothParties() public {
        _setupBankAReady(1);
        bytes32 positionId = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));

        vm.prank(bankA);
        pledgeManager.requestRelease(positionId);
        CollateralManager.CollateralPosition memory p = collateralManager.getPosition(positionId);
        assertEq(uint256(p.status), uint256(CollateralManager.CollateralStatus.RELEASE_REQUESTED));

        vm.prank(bankB);
        pledgeManager.approveRelease(positionId);
        CollateralManager.CollateralPosition memory afterRelease = collateralManager.getPosition(positionId);
        assertEq(uint256(afterRelease.status), uint256(CollateralManager.CollateralStatus.RELEASED));
        assertEq(tBondToken.balanceOf(bankA), C.T_BOND_QUANTITY);
    }

    function test_agentCanApproveRelease() public {
        _setupBankAReady(1);
        bytes32 positionId = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));
        vm.prank(bankA);
        pledgeManager.requestRelease(positionId);
        vm.prank(collateralAgent);
        pledgeManager.approveRelease(positionId);
        assertEq(uint256(collateralManager.getPosition(positionId).status), uint256(CollateralManager.CollateralStatus.RELEASED));
    }

    function test_strangerCannotRequestRelease() public {
        _setupBankAReady(1);
        bytes32 positionId = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));
        vm.prank(mockCsd);
        vm.expectRevert(PledgeManager.Unauthorized.selector);
        pledgeManager.requestRelease(positionId);
    }
}
