// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {TestBase} from "../TestBase.sol";
import {CollateralManager} from "../../src/CollateralManager.sol";
import {LibConstants as C} from "../../script/LibConstants.sol";

contract CollateralManagerTest is TestBase {
    function setUp() public {
        _deployNetwork();
    }

    function test_nonOperatorCannotCreatePosition() public {
        _setupBankAReady(1);
        vm.prank(bankA);
        vm.expectRevert(CollateralManager.NotOperator.selector);
        collateralManager.createPosition(bankA, bankB, C.T_BOND, 100, bytes32(0));
    }

    function test_setOperatorOnlyAdmin() public {
        vm.prank(bankA);
        vm.expectRevert(CollateralManager.Unauthorized.selector);
        collateralManager.setOperator(bankA, true);
    }

    function test_availableQuantityRequiresCustody() public {
        _setupBankAReady(1);
        // bankB has no custody attestation -> 0 available even with token balance.
        assertEq(collateralManager.availableQuantity(C.T_BOND, bankB), 0);
        assertEq(collateralManager.availableQuantity(C.T_BOND, bankA), C.T_BOND_QUANTITY);
    }

    function test_availableQuantityMinOfTokenAndCustody() public {
        _setupBankAReady(1);
        // Reduce token balance via ordinary transfer while custody stays full.
        vm.prank(bankA);
        assertTrue(tBondToken.transfer(bankB, 4_000));
        assertEq(collateralManager.availableQuantity(C.T_BOND, bankA), 6_000);
    }

    function test_createPositionWithObligationIsTracked() public {
        _setupBankAReady(1);
        bytes32 obligationId = keccak256("OBLIGATION-1");
        bytes32 positionId = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, obligationId);
        bytes32[] memory ids = collateralManager.getPositionsByObligation(obligationId);
        assertEq(ids.length, 1);
        assertEq(ids[0], positionId);
    }

    function test_liveValueReflectsPriceChanges() public {
        _setupBankAReady(1);
        bytes32 obligationId = keccak256("OBLIGATION-1");
        _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, obligationId);
        assertEq(collateralManager.liveCollateralValueForObligation(obligationId), 95_000_000);

        _submitPrice(C.T_BOND, C.T_BOND_PRICE_DOWN, 3);
        assertEq(collateralManager.liveCollateralValueForObligation(obligationId), 87_400_000);
    }

    function test_totalValueUsesStoredValuation() public {
        _setupBankAReady(1);
        bytes32 obligationId = keccak256("OBLIGATION-1");
        _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, obligationId);
        assertEq(collateralManager.totalCollateralValueForObligation(obligationId), 95_000_000);
        _submitPrice(C.T_BOND, C.T_BOND_PRICE_DOWN, 3);
        // Stored (verified at reserve time) value is unchanged.
        assertEq(collateralManager.totalCollateralValueForObligation(obligationId), 95_000_000);
    }

    function test_markDefaultOnlyFromPledgedOrReleaseRequested() public {
        _setupBankAReady(1);
        bytes32 positionId = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));
        vm.prank(address(settlement));
        collateralManager.markDefault(positionId);
        assertEq(uint256(collateralManager.getPosition(positionId).status), uint256(CollateralManager.CollateralStatus.DEFAULTED));
    }

    function test_markDefaultFromAvailableReverts() public {
        _setupBankAReady(1);
        bytes32 positionId = _requestPosition();
        vm.prank(address(settlement));
        vm.expectRevert(CollateralManager.InvalidStatus.selector);
        collateralManager.markDefault(positionId);
    }

    function _requestPosition() internal returns (bytes32 positionId) {
        vm.prank(bankA);
        positionId = pledgeManager.requestPledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));
    }

    function test_enforceCollateralDeliversToParty() public {
        _setupBankAReady(1);
        bytes32 positionId = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));
        vm.prank(address(settlement));
        collateralManager.markDefault(positionId);
        vm.prank(address(settlement));
        collateralManager.enforceCollateral(positionId, bankB);

        CollateralManager.CollateralPosition memory p = collateralManager.getPosition(positionId);
        assertEq(uint256(p.status), uint256(CollateralManager.CollateralStatus.RECOVERY));
        assertEq(tBondToken.balanceOf(bankB), C.T_BOND_QUANTITY);
        assertEq(tBondToken.balanceOf(address(collateralManager)), 0);
        assertEq(custodyRegistry.getCustodyState(C.T_BOND).encumberedQuantity, 0);
    }

    function test_enforceRequiresDefaulted() public {
        _setupBankAReady(1);
        bytes32 positionId = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));
        vm.prank(address(settlement));
        vm.expectRevert(CollateralManager.InvalidStatus.selector);
        collateralManager.enforceCollateral(positionId, bankB);
    }

    function test_releaseFromPledgedByOperator() public {
        _setupBankAReady(1);
        bytes32 positionId = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));
        vm.prank(address(settlement));
        collateralManager.release(positionId);
        assertEq(uint256(collateralManager.getPosition(positionId).status), uint256(CollateralManager.CollateralStatus.RELEASED));
        assertEq(tBondToken.balanceOf(bankA), C.T_BOND_QUANTITY);
        assertEq(custodyRegistry.getCustodyState(C.T_BOND).encumberedQuantity, 0);
    }

    function test_deterministicPositionIds() public {
        _setupBankAReady(1);
        bytes32 first = _requestPosition();
        bytes32 second = _requestPosition();
        assertTrue(first != second);
    }
}
