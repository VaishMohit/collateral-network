// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {TestBase} from "../TestBase.sol";
import {AssetRegistry} from "../../src/AssetRegistry.sol";
import {Roles} from "../../src/libs/Roles.sol";
import {LibConstants as C} from "../../script/LibConstants.sol";

contract AssetRegistryTest is TestBase {
    function setUp() public {
        _deployNetwork();
    }

    function test_registerAssetCreatesInactiveAsset() public {
        bytes32 assetId = keccak256("X");
        vm.prank(admin);
        assetRegistry.registerAsset(assetId, "US-X", AssetRegistry.AssetType.TREASURY, address(0x123), 100, 1_700_000_000, AssetRegistry.Rating.UNRATED);
        assertTrue(assetRegistry.assetExists(assetId));
        assertFalse(assetRegistry.isActive(assetId));
        AssetRegistry.Asset memory a = assetRegistry.getAsset(assetId);
        assertEq(a.isin, "US-X");
        assertEq(uint256(a.assetType), uint256(AssetRegistry.AssetType.TREASURY));
        assertEq(a.token, address(0));
    }

    function test_csdCanRegister() public {
        bytes32 assetId = keccak256("Y");
        vm.prank(mockCsd);
        assetRegistry.registerAsset(assetId, "US-Y", AssetRegistry.AssetType.CORPORATE_BOND, address(0x123), 100, 1_700_000_000, AssetRegistry.Rating.A);
        assertTrue(assetRegistry.assetExists(assetId));
    }

    function test_bankCannotRegister() public {
        vm.prank(bankA);
        vm.expectRevert("AssetRegistry: unauthorized");
        assetRegistry.registerAsset(keccak256("Z"), "US-Z", AssetRegistry.AssetType.TREASURY, address(0x123), 100, 1_700_000_000, AssetRegistry.Rating.UNRATED);
    }

    function test_duplicateRegistrationReverts() public {
        vm.prank(admin);
        vm.expectRevert(AssetRegistry.AlreadyRegistered.selector);
        assetRegistry.registerAsset(C.T_BOND, "dup", AssetRegistry.AssetType.TREASURY, address(0x123), 100, 1_700_000_000, AssetRegistry.Rating.UNRATED);
    }

    function test_unknownTypeReverts() public {
        vm.prank(admin);
        vm.expectRevert("AssetRegistry: unknown type");
        assetRegistry.registerAsset(keccak256("U"), "US-U", AssetRegistry.AssetType.UNKNOWN, address(0x123), 100, 1_700_000_000, AssetRegistry.Rating.UNRATED);
    }

    function test_setTokenOnlyAdmin() public {
        vm.prank(bankA);
        vm.expectRevert("AssetRegistry: not admin");
        assetRegistry.setToken(C.T_BOND, address(0xdead));
    }

    function test_setTokenOnUnknownAssetReverts() public {
        vm.prank(admin);
        vm.expectRevert(AssetRegistry.NotRegistered.selector);
        assetRegistry.setToken(keccak256("NOPE"), address(0xdead));
    }

    function test_setToken() public {
        address newToken = address(0xdead);
        vm.prank(admin);
        assetRegistry.setToken(C.T_BOND, newToken);
        assertEq(assetRegistry.getToken(C.T_BOND), newToken);
    }

    function test_activateAndDeactivate() public {
        vm.prank(admin);
        assetRegistry.activateAsset(C.T_BOND);
        assertTrue(assetRegistry.isActive(C.T_BOND));
        vm.prank(admin);
        assetRegistry.deactivateAsset(C.T_BOND);
        assertFalse(assetRegistry.isActive(C.T_BOND));
    }

    function test_activateOnlyAdmin() public {
        vm.prank(bankA);
        vm.expectRevert("AssetRegistry: not admin");
        assetRegistry.activateAsset(C.T_BOND);
    }

    function test_getAssetUnknownReverts() public {
        vm.expectRevert(AssetRegistry.NotRegistered.selector);
        assetRegistry.getAsset(keccak256("GHOST"));
    }
}
