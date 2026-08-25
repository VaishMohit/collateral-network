// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {BaseHandler} from "./BaseHandler.sol";
import {CustodyRegistry} from "../../src/CustodyRegistry.sol";

/**
 * @title CustodyInvariant
 * @notice Step 3.2: the custody mirror never over-encumbers and never drifts
 *         from the collateral layer, for every (assetId, owner) pair the fuzzer
 *         touches — including two banks holding the same ISIN.
 */
contract CustodyInvariant is BaseHandler {
    function invariant_custodyEncumbranceBoundedAndMirrored() public {
        uint256 numKeys = custodyKeysA.length;

        for (uint256 k = 0; k < numKeys; k++) {
            bytes32 asset = custodyKeysA[k];
            address owner = custodyKeysO[k];

            CustodyRegistry.CustodyState memory cs = custodyRegistry.getCustodyState(asset, owner);

            // Core bound: encumbrance can never exceed the attested total.
            assertLe(cs.encumberedQuantity, cs.totalQuantity, "encumbered > total");

            // Derived view must stay consistent with stored state.
            if (cs.totalQuantity > 0) {
                assertEq(
                    custodyRegistry.availableQuantity(asset, owner),
                    cs.totalQuantity - cs.encumberedQuantity,
                    "availableQuantity drifted from stored state"
                );
            } else {
                assertEq(cs.encumberedQuantity, 0, "encumbrance on zero-quantity state");
            }

            // Cross-layer consistency: encumbrance equals exactly the units
            // the ghost believes are locked (RESERVED + pledged-family).
            uint256 lockedGhost;
            for (uint256 i = 0; i < positionIds.length; i++) {
                GhostPosition storage g = ghosts[positionIds[i]];
                if (!g.exists || g.assetId != asset || g.provider != owner) continue;
                if (
                    g.status == S_RESERVED || g.status == S_PLEDGED || g.status == S_RELEASE_REQUESTED
                        || g.status == S_DEFAULTED
                ) {
                    lockedGhost += g.quantity;
                }
            }
            assertEq(cs.encumberedQuantity, lockedGhost, "custody mirror != token-layer lock");
        }
    }
}
