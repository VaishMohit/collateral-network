// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {TestBase} from "../TestBase.sol";
import {ProtocolAccessManager} from "../../src/ProtocolAccessManager.sol";
import {Roles} from "../../src/libs/Roles.sol";

contract ProtocolAccessManagerTest is TestBase {
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed grantedBy);
    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);

    function setUp() public {
        _deployNetwork();
    }

    function test_bootstrapGrantsAdminToDeployer() public {
        assertTrue(access.isAdmin(admin));
        assertTrue(access.hasRole(Roles.ADMIN, admin));
        assertEq(access.admin(), admin);
    }

    function test_constructorRevertsOnZeroAdmin() public {
        vm.expectRevert(ProtocolAccessManager.ZeroAdmin.selector);
        new ProtocolAccessManager(address(0));
    }

    function test_grantRole_emitsAndEnables() public {
        address stranger = vm.addr(0x1234);
        vm.expectEmit(true, true, true, true);
        emit RoleGranted(Roles.BANK, stranger, admin);
        vm.prank(admin);
        access.grantRole(Roles.BANK, stranger);
        assertTrue(access.hasRole(Roles.BANK, stranger));
    }

    function test_grantRole_nonAdminReverts() public {
        vm.prank(bankA);
        vm.expectRevert(ProtocolAccessManager.NotAdmin.selector);
        access.grantRole(Roles.BANK, vm.addr(0x1234));
    }

    function test_grantRole_doesNotDoubleGrant() public {
        vm.prank(admin);
        access.grantRole(Roles.BANK, bankA);
        assertTrue(access.hasRole(Roles.BANK, bankA));
    }

    function test_grantRole_adminRoleOnlyViaSetAdmin() public {
        vm.prank(admin);
        vm.expectRevert(ProtocolAccessManager.AdminOnlyViaSetAdmin.selector);
        access.grantRole(Roles.ADMIN, bankA);
    }

    function test_revokeRole() public {
        vm.prank(admin);
        access.revokeRole(Roles.BANK, bankA);
        assertFalse(access.hasRole(Roles.BANK, bankA));
        assertEq(access.hasRole(Roles.ADMIN, admin), true);
    }

    function test_setAdminTransfersAndGrants() public {
        address newAdmin = vm.addr(0x9999);
        vm.expectEmit(true, true, true, true);
        emit AdminChanged(admin, newAdmin);
        vm.prank(admin);
        access.setAdmin(newAdmin);
        assertEq(access.admin(), newAdmin);
        assertTrue(access.hasRole(Roles.ADMIN, newAdmin));
        assertTrue(access.isAdmin(newAdmin));
        assertFalse(access.isAdmin(admin));
        // The previous admin loses the ADMIN role.
        assertFalse(access.hasRole(Roles.ADMIN, admin));
        // The new admin can revoke the old admin's remaining roles.
        vm.prank(newAdmin);
        access.revokeRole(Roles.BANK, admin);
    }

    function test_setAdmin_nonAdminReverts() public {
        vm.prank(bankA);
        vm.expectRevert(ProtocolAccessManager.NotAdmin.selector);
        access.setAdmin(vm.addr(0x9999));
    }

    function test_setAdmin_zeroReverts() public {
        vm.prank(admin);
        vm.expectRevert(ProtocolAccessManager.ZeroAdmin.selector);
        access.setAdmin(address(0));
    }

    function test_bankIsNotAdmin() public {
        assertFalse(access.hasRole(Roles.ADMIN, bankA));
        assertFalse(access.isAdmin(bankA));
    }

    function test_requireRole() public {
        vm.prank(admin);
        access.requireRole(Roles.BANK, bankA);
        vm.expectRevert(ProtocolAccessManager.MissingRole.selector);
        vm.prank(admin);
        access.requireRole(Roles.BANK, vm.addr(0xdead));
    }
}
