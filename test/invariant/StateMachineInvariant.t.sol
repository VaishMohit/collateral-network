// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {BaseHandler} from "./BaseHandler.sol";
import {CollateralManager} from "../../src/CollateralManager.sol";

/**
 * @title StateMachineInvariant
 * @notice Step 3.3: on-chain position status always equals the ghost mirror.
 *
 * @dev Edge legality is enforced at the transition site: every ghost update
 *      goes through BaseHandler._setStatus, which reverts on any edge outside
 *      the legal set — and fail_on_revert turns that into a failed run. The
 *      invariant here closes the loop by proving the chain never drifted from
 *      the (legally-transitioned) ghost. Terminal freeze is double-checked via
 *      a snapshot: RELEASED / RECOVERY positions must never change again.
 */
contract StateMachineInvariant is BaseHandler {
    mapping(bytes32 => bytes32) internal terminalSnapshot;

    function invariant_positionStatusNeverDriftsFromLegalMachine() public {
        for (uint256 i = 0; i < positionIds.length; i++) {
            bytes32 positionId = positionIds[i];
            GhostPosition storage g = ghosts[positionId];
            assertTrue(g.exists, "tracked position lost ghost");

            CollateralManager.CollateralPosition memory p = collateralManager.getPosition(positionId);
            assertTrue(p.createdAt != 0, "position missing on-chain");
            assertEq(uint8(p.status), g.status, "on-chain status != ghost status");

            bytes32 snap = keccak256(abi.encode(uint8(p.status), p.quantity));
            if (g.status == S_RELEASED || g.status == S_RECOVERY) {
                bytes32 recorded = terminalSnapshot[positionId];
                if (recorded == bytes32(0)) {
                    // First observation of the terminal state: record it.
                    terminalSnapshot[positionId] = snap;
                } else {
                    assertEq(recorded, snap, "terminal position mutated");
                }
            } else {
                delete terminalSnapshot[positionId];
            }
        }
    }
}
