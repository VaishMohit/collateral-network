// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {TestBase} from "../TestBase.sol";
import {LibConstants as C} from "../../script/LibConstants.sol";

/**
 * @title GasBenchmarks
 * @notice Step 3.6: gas cost of each critical path, measured as gasleft()
 *         deltas on the in-memory network. Results are transcribed by hand
 *         into docs/gas.md (documentation only — no CI gate this phase).
 */
contract GasBenchmarks is TestBase {
    function setUp() public {
        _deployNetwork();
        _setupBankAReady(1);
    }

    function test_bench_pledgeFlow() public {
        uint256 start = gasleft();
        _pledge(C.T_BOND, 1_000, bankB, bytes32(0));
        _log("pledge flow (request->verify->reserve->approve->finalize)", start);
    }

    function test_bench_dvpSettlement() public {
        bytes32 positionId = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));
        vm.prank(bankA);
        bytes32 repoId =
            repoManager.createRepo(bankA, bankB, positionId, C.REPO_CASH, C.REPO_RATE_BPS, C.REPO_TENOR);
        vm.prank(bankB);
        cash.approve(address(settlement), C.REPO_CASH);

        uint256 start = gasleft();
        vm.prank(bankA);
        repoManager.settleRepo(repoId);
        _log("DvP settlement (settleRepo incl. cash leg)", start);
    }

    function test_bench_substitution() public {
        bytes32 oldId = _pledge(C.CORP_BOND, C.CORP_BOND_QUANTITY, bankB, bytes32(0));

        // Fund Bank A with enough free T-BOND value to cover the old position.
        vm.startPrank(admin);
        tBondToken.mint(bankA, C.T_BOND_QUANTITY);
        vm.stopPrank();
        _attest(C.T_BOND, bankA, 2 * C.T_BOND_QUANTITY, custodianA, C.PK_CUSTODIAN_A);

        vm.prank(bankA);
        bytes32 replId = pledgeManager.requestSubstitution(oldId, C.T_BOND, 10_000);
        vm.prank(collateralAgent);
        pledgeManager.validateReplacement(replId);
        vm.prank(bankA);
        pledgeManager.reserveReplacement(replId);

        uint256 start = gasleft();
        vm.prank(bankA);
        pledgeManager.activateSubstitution(oldId);
        _log("substitution activate (release old + pledge replacement)", start);
    }

    function test_bench_marginCall() public {
        _pledge(C.T_BOND, C.T_BOND_QUANTITY / 2, bankB, _obligation());
        vm.prank(bankB);
        marginManager.setRequirement(_obligation(), 45_000_000);
        // Nonces 1-2 consumed by setup; next provider nonce is 3.
        _submitPrice(C.T_BOND, C.T_BOND_PRICE_DOWN, 3); // drop below requirement

        uint256 start = gasleft();
        vm.prank(bankB);
        marginManager.createMarginCall(_obligation());
        _log("margin call creation (live valuation over obligation)", start);
    }

    function test_bench_repayAndClose() public {
        bytes32 positionId = _pledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, bytes32(0));
        vm.prank(bankA);
        bytes32 repoId =
            repoManager.createRepo(bankA, bankB, positionId, C.REPO_CASH, C.REPO_RATE_BPS, C.REPO_TENOR);
        vm.prank(bankB);
        cash.approve(address(settlement), C.REPO_CASH);
        vm.prank(bankA);
        repoManager.settleRepo(repoId);

        vm.warp(block.timestamp + C.REPO_TENOR + 1);
        vm.startPrank(bankA);
        cash.approve(address(repoManager), type(uint256).max);
        uint256 start = gasleft();
        repoManager.repayAndClose(repoId);
        vm.stopPrank();
        _log("repayAndClose (interest calc + release)", start);
    }

    /* ------------------------------------------------------------------ */

    bytes32 internal constant BENCH_OBLIGATION = keccak256(abi.encode("BENCH-OBLIGATION"));

    function _obligation() internal pure returns (bytes32) {
        return BENCH_OBLIGATION;
    }

    function _log(string memory label, uint256 startGas) internal {
        // forge test -vv to see measurements.
        emit BenchResult(label, startGas - gasleft());
    }

    event BenchResult(string label, uint256 gas);
}
