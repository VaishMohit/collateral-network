// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {TestBase} from "../TestBase.sol";
import {LibConstants as C} from "../../script/LibConstants.sol";
import {CollateralManager} from "../../src/CollateralManager.sol";
import {PledgeManager} from "../../src/PledgeManager.sol";
import {AssetRegistry} from "../../src/AssetRegistry.sol";

/**
 * @title CreatePositionFuzz
 * @notice Step 3.4: random quantities, asset IDs and providers against
 *         createPosition (via PledgeManager.requestPledge).
 */
contract CreatePositionFuzz is TestBase {
    function setUp() public {
        _deployNetwork();
        _setupBankAReady(1);
        // Give Bank B its own attested inventory so provider selection varies.
        _attest(C.T_BOND, bankB, C.T_BOND_QUANTITY, custodianA, C.PK_CUSTODIAN_A);
        _attest(C.CORP_BOND, bankB, C.CORP_BOND_QUANTITY, custodianA, C.PK_CUSTODIAN_A);
        vm.startPrank(admin);
        tBondToken.mint(bankB, C.T_BOND_QUANTITY);
        corpBondToken.mint(bankB, C.CORP_BOND_QUANTITY);
        vm.stopPrank();
    }

    function testFuzz_createPosition_validInputs(uint256 quantitySeed, uint256 assetSeed, uint256 providerSeed)
        public
    {
        bytes32 asset = bound(assetSeed, 0, 1) == 0 ? C.T_BOND : C.CORP_BOND;
        address provider = bound(providerSeed, 0, 1) == 0 ? bankA : bankB;
        address receiver = provider == bankA ? bankB : bankA;

        uint256 avail = collateralManager.availableQuantity(asset, provider);
        uint256 quantity = bound(quantitySeed, 1, avail);

        vm.prank(provider);
        bytes32 positionId = pledgeManager.requestPledge(asset, quantity, receiver, bytes32(0));

        CollateralManager.CollateralPosition memory p = collateralManager.getPosition(positionId);
        assertTrue(p.createdAt != 0, "position not created");
        assertEq(p.positionId, positionId);
        assertEq(p.provider, provider);
        assertEq(p.receiver, receiver);
        assertEq(p.assetId, asset);
        assertEq(p.quantity, quantity);
        assertEq(uint8(p.status), uint8(CollateralManager.CollateralStatus.AVAILABLE));

        // Creation alone mutates nothing: no lock before reserve.
        assertEq(collateralManager.getLedger(asset, provider).reserved, 0, "reserved changed on create");
        assertEq(
            custodyRegistry.getCustodyState(asset, provider).encumberedQuantity,
            0,
            "custody encumbered on create"
        );
    }

    function testFuzz_createPosition_unregisteredAsset(uint256 quantitySeed, uint256 badSeed) public {
        uint256 quantity = bound(quantitySeed, 1, type(uint128).max);
        bytes32 bogus = keccak256(abi.encode("BOGUS", badSeed));

        vm.prank(bankA);
        vm.expectRevert(AssetRegistry.NotRegistered.selector);
        pledgeManager.requestPledge(bogus, quantity, bankB, bytes32(0));
    }

    function testFuzz_createPosition_unattestedProvider(uint256 quantitySeed) public {
        uint256 quantity = bound(quantitySeed, 1, type(uint128).max);
        address stranger = makeAddr("unattested-provider");

        vm.prank(stranger);
        vm.expectRevert(PledgeManager.Unauthorized.selector);
        pledgeManager.requestPledge(C.T_BOND, quantity, bankB, bytes32(0));
    }

    /**
     * @notice Documents CURRENT behavior: a zero-quantity position is created
     *         (availableQuantity >= 0 satisfies the check). Harmless — it can
     *         never lock value — but arguably should revert. Flagged for the
     *         follow-up hardening backlog; this test pins today's behavior so
     *         a future fix flips it deliberately.
     */
    function testFuzz_createPosition_zeroQuantityDocumentsBehavior() public {
        vm.prank(bankA);
        bytes32 positionId = pledgeManager.requestPledge(C.T_BOND, 0, bankB, bytes32(0));
        assertEq(collateralManager.getPosition(positionId).quantity, 0);
    }
}
