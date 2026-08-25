// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {BaseHandler} from "./BaseHandler.sol";
import {LibConstants as C} from "../../script/LibConstants.sol";
import {CollateralManager} from "../../src/CollateralManager.sol";
import {CustodyRegistry} from "../../src/CustodyRegistry.sol";

/**
 * @title AccountingInvariant
 * @notice Step 3.1: after ANY action sequence the collateral accounting holds:
 *         per (asset, provider), the ledger buckets exactly mirror the ghost
 *         positions, custody mirrors the lock, and the token inventory identity
 *         `minted == free + locked(vault) + enforced out` survives enforcement.
 */
contract AccountingInvariant is BaseHandler {
    function invariant_accountingIdentityHolds() public {
        uint256 numKeys = custodyKeysA.length;
        uint256[] memory reservedG = new uint256[](numKeys);
        uint256[] memory pledgedG = new uint256[](numKeys);
        uint256[] memory releasedG = new uint256[](numKeys);

        for (uint256 i = 0; i < positionIds.length; i++) {
            GhostPosition storage g = ghosts[positionIds[i]];
            CollateralManager.CollateralPosition memory p = collateralManager.getPosition(g.positionId);

            assertTrue(p.createdAt != 0, "ghost position missing on-chain");
            assertEq(uint8(p.status), g.status, "on-chain status drifted from ghost");
            assertEq(p.quantity, g.quantity, "position quantity mutated");
            assertEq(p.provider, g.provider, "position provider mutated");
            assertEq(p.assetId, g.assetId, "position asset mutated");

            for (uint256 k = 0; k < numKeys; k++) {
                if (custodyKeysA[k] == g.assetId && custodyKeysO[k] == g.provider) {
                    if (g.status == S_RESERVED) {
                        reservedG[k] += g.quantity;
                    } else if (
                        g.status == S_PLEDGED || g.status == S_RELEASE_REQUESTED || g.status == S_DEFAULTED
                    ) {
                        pledgedG[k] += g.quantity;
                    } else if (g.status == S_RELEASED || g.status == S_RECOVERY) {
                        releasedG[k] += g.quantity;
                    }
                    break;
                }
            }
        }

        uint256[] memory vaultByAsset = new uint256[](2);
        vaultByAsset[0] = tBondToken.balanceOf(address(collateralManager));
        vaultByAsset[1] = corpBondToken.balanceOf(address(collateralManager));

        for (uint256 k = 0; k < numKeys; k++) {
            bytes32 asset = custodyKeysA[k];
            address owner = custodyKeysO[k];
            uint256 assetIdx = asset == C.T_BOND ? 0 : 1;

            CollateralManager.CollateralLedger memory l = collateralManager.getLedger(asset, owner);
            assertEq(l.reserved, reservedG[k], "ledger.reserved != ghost reserved");
            assertEq(l.pledged, pledgedG[k], "ledger.pledged != ghost pledged");
            assertEq(l.released, releasedG[k], "ledger.released != ghost released");

            CustodyRegistry.CustodyState memory cs = custodyRegistry.getCustodyState(asset, owner);
            assertLe(cs.encumberedQuantity, cs.totalQuantity, "custody encumbrance exceeds total");
            assertEq(cs.encumberedQuantity, reservedG[k] + pledgedG[k], "custody mirror != locked ghost");

            if (cs.totalQuantity > 0) {
                assertEq(
                    custodyRegistry.availableQuantity(asset, owner),
                    cs.totalQuantity - cs.encumberedQuantity,
                    "available != total - encumbered"
                );
            }

            // Token inventory identity. Both banks were minted the full
            // quantity of each asset; locked units sit in the vault and
            // enforced units moved out to the entitled party (who may be the
            // other bank, hence enforcedIn).
            uint256 minted = assetIdx == 0 ? C.T_BOND_QUANTITY : C.CORP_BOND_QUANTITY;
            uint256 freeBalance =
                assetIdx == 0 ? tBondToken.balanceOf(owner) : corpBondToken.balanceOf(owner);
            assertEq(
                freeBalance + reservedG[k] + pledgedG[k] + enforcedOut[asset][owner],
                minted + enforcedIn[asset][owner],
                "token inventory broken"
            );

            vaultByAsset[assetIdx] -= reservedG[k] + pledgedG[k];
        }

        assertEq(vaultByAsset[0], 0, "vault T-BOND balance != sum of locks");
        assertEq(vaultByAsset[1], 0, "vault CORP-BOND balance != sum of locks");
    }
}
