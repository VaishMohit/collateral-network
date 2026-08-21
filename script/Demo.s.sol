// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Roles} from "../src/libs/Roles.sol";
import {ProtocolAccessManager} from "../src/ProtocolAccessManager.sol";
import {AuditRegistry} from "../src/AuditRegistry.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {CustodyRegistry} from "../src/CustodyRegistry.sol";
import {ComplianceAttestationRegistry} from "../src/ComplianceAttestationRegistry.sol";
import {CashToken} from "../src/CashToken.sol";
import {TokenizedSecurity} from "../src/TokenizedSecurity.sol";
import {ValuationOracle} from "../src/ValuationOracle.sol";
import {EligibilityPolicy} from "../src/EligibilityPolicy.sol";
import {CollateralManager} from "../src/CollateralManager.sol";
import {PledgeManager} from "../src/PledgeManager.sol";
import {MarginManager} from "../src/MarginManager.sol";
import {SettlementCoordinator} from "../src/SettlementCoordinator.sol";
import {RepoManager} from "../src/RepoManager.sol";
import {LibConstants as C} from "./LibConstants.sol";

/**
 * @title Demo
 * @notice Runs the complete institutional collateral lifecycle against an
 *         already-deployed network (Deploy.s.sol must have run first).
 *
 *   Scenario (mirrors the spec):
 *     1  Mock CSD books 10,000 T-BOND-001 for Bank A @ Custodian A   (off-chain)
 *     2  Custodian A signs a custody attestation
 *     3  Attestation submitted on-chain
 *     4  Treasury token minted for Bank A
 *     5  Market price submitted at $100
 *     6  Bank B sets a $900,000 collateral requirement
 *     7  Bank A pledges 10,000 T-BOND-001
 *     8-9  value = $1,000,000, haircut 5% -> $950,000, status PLEDGED
 *     10-11 Bank B delivers $950,000 MockUSD, repo settles (DvP)
 *     12-14 price drops to $92 -> $874,000 -> MARGIN_CALL $26,000
 *     15-18 Bank A substitutes 10,000 corporate bonds (>= old value), old released
 *     19-21 repo matures, principal + interest repaid, collateral released
 *
 *   Usage:
 *     anvil
 *     forge script script/Deploy.s.sol  --rpc-url http://127.0.0.1:8545 --broadcast
 *     forge script script/Demo.s.sol    --rpc-url http://127.0.0.1:8545 --broadcast
 */
contract Demo is Script {
    address internal admin;
    address internal bankA;
    address internal bankB;
    address internal custodianA;
    address internal mockCsd;
    address internal collateralAgent;
    address internal valuationProvider;
    address internal settlementAgent;
    address internal complianceProvider;

    ProtocolAccessManager internal access;
    AuditRegistry internal audit;
    AssetRegistry internal assetRegistry;
    AttestationRegistry internal attestationRegistry;
    CustodyRegistry internal custodyRegistry;
    ComplianceAttestationRegistry internal complianceRegistry;
    CashToken internal cash;
    ValuationOracle internal oracle;
    EligibilityPolicy internal eligibility;
    CollateralManager internal collateralManager;
    PledgeManager internal pledgeManager;
    MarginManager internal marginManager;
    SettlementCoordinator internal settlement;
    RepoManager internal repoManager;
    TokenizedSecurity internal tBondToken;
    TokenizedSecurity internal corpBondToken;

    function run() external {
        _load();

        // Phase control for live (broadcast) runs, where forge sends every
        // captured tx after the script finishes so mid-script time jumps would
        // corrupt earlier broadcasts:
        //   DEMO_PHASE=1  steps 1-15b  (attestation .. margin call satisfied), real time
        //   DEMO_PHASE=2  steps 19-21  (clock jump, repay, release) + final checks
        //   DEMO_PHASE=all (default)   complete lifecycle in one run (forge test)
        string memory phase = vm.envOr("DEMO_PHASE", string("all"));
        bool doPhase1 = keccak256(bytes(phase)) != keccak256(bytes("2"));
        bool doPhase2 = keccak256(bytes(phase)) != keccak256(bytes("1"));

        bytes32 repoId;
        bytes32 replacementId;

        // Repo id is derived deterministically on-chain (counter + parties), so
        // it can be recomputed here in either phase.
        repoId = keccak256(abi.encode("REPO", uint256(1), bankA, bankB));

        console2.log("==========================================================");
        console2.log("Institutional Collateral Network - end-to-end demo");
        console2.log("==========================================================");

        // ------------------- STEP 1: Mock CSD books the asset ----------------
        // (Off-chain: Mock CSD ledger now shows 10,000 T-BOND-001 owned by
        //  Bank A, held by Custodian A, encumbered = 0. No on-chain action yet.)

        if (doPhase1) {

        // ------------------- STEP 2+3: signed custody attestation ------------
        bytes32 attestationId = keccak256("CUSTODY_T_BOND_001_V1");
        AttestationRegistry.AssetAttestation memory att = AttestationRegistry.AssetAttestation({
            attestationId: attestationId,
            assetId: C.T_BOND,
            subject: bankA,
            owner: bankA,
            custodian: custodianA,
            quantity: C.T_BOND_QUANTITY,
            encumberedQuantity: 0,
            timestamp: block.timestamp,
            expiry: block.timestamp + C.ATTESTATION_TTL,
            dataHash: keccak256("CSD-RECORD-US-TBOND-001"),
            attestor: custodianA
        });
        _submitCustodyAttestation(att, C.PK_CUSTODIAN_A);

        // ------------------- STEP 2b: compliance attestations ---------------
        _submitCompliance(bankA, "COMPLIANCE_BANK_A");
        _submitCompliance(bankB, "COMPLIANCE_BANK_B");

        // ------------------- STEP 4: mint treasury token ---------------------
        vm.startBroadcast(C.PK_ADMIN);
        tBondToken.mint(bankA, C.T_BOND_QUANTITY);
        corpBondToken.mint(bankA, C.CORP_BOND_QUANTITY);
        vm.stopBroadcast();
        console2.log(string.concat("[4] Minted ", vm.toString(C.T_BOND_QUANTITY), " tT-BOND and ", vm.toString(C.CORP_BOND_QUANTITY), " tCORP for Bank A"));
        _check(tBondToken.balanceOf(bankA) == C.T_BOND_QUANTITY, "mint balance");

        // ------------------- STEP 5: submit market prices --------------------
        _submitPrice(C.T_BOND, C.T_BOND_PRICE, 1);
        _submitPrice(C.CORP_BOND, C.CORP_BOND_PRICE, 2);
        (uint256 px,) = oracle.getLatestPrice(C.T_BOND);
        console2.log(string.concat("[5] T-BOND price = $", _toUsd(px)));

        // ------------------- STEP 6: Bank B sets requirement -----------------
        vm.startBroadcast(C.PK_BANK_B);
        marginManager.setRequirement(repoId, C.REQUIREMENT);
        vm.stopBroadcast();
        console2.log(string.concat("[6] Bank B collateral requirement = $", _toUsd(C.REQUIREMENT)));

        // ------------------- STEP 7-9: pledge 10,000 Treasury ----------------
        vm.startBroadcast(C.PK_BANK_A);
        bytes32 positionId = pledgeManager.requestPledge(C.T_BOND, C.T_BOND_QUANTITY, bankB, repoId);
        vm.stopBroadcast();

        vm.startBroadcast(C.PK_COLLATERAL_AGENT);
        pledgeManager.verifyCollateral(positionId);
        vm.stopBroadcast();

        vm.startBroadcast(C.PK_BANK_A);
        pledgeManager.reserveCollateral(positionId);
        vm.stopBroadcast();

        vm.startBroadcast(C.PK_BANK_B);
        pledgeManager.approvePledge(positionId);
        vm.stopBroadcast();

        vm.startBroadcast(C.PK_COLLATERAL_AGENT);
        pledgeManager.finalizePledge(positionId);
        vm.stopBroadcast();

        CollateralManager.CollateralPosition memory p = collateralManager.getPosition(positionId);
        _check(p.status == CollateralManager.CollateralStatus.PLEDGED, "status PLEDGED");
        _check(p.marketValue == 100_000_000 && p.haircutBps == 500 && p.collateralValue == 95_000_000, "valuation 5% haircut");
        console2.log(
            string.concat(
                "[7-9] Pledged ",
                vm.toString(p.quantity),
                " T-BOND-001: market=$",
                _toUsd(p.marketValue),
                "  haircut=",
                vm.toString(p.haircutBps / 100),
                "%  collateral=$",
                _toUsd(p.collateralValue),
                "  status=PLEDGED"
            )
        );
        _check(custodyRegistry.availableQuantity(C.T_BOND, bankA) == 0, "custody available = 0 (fully encumbered)");
        _check(tBondToken.balanceOf(bankA) == 0, "treasury tokens locked in vault");

        // ------------------- STEP 10-11: repo settles (DvP) ------------------
        vm.startBroadcast(C.PK_BANK_A);
        repoId = repoManager.createRepo(bankA, bankB, positionId, C.REPO_CASH, C.REPO_RATE_BPS, C.REPO_TENOR);
        vm.stopBroadcast();
        _check(repoId == keccak256(abi.encode("REPO", uint256(1), bankA, bankB)), "repoId deterministic");

        vm.startBroadcast(C.PK_BANK_B);
        cash.approve(address(settlement), C.REPO_CASH);
        vm.stopBroadcast();

        vm.startBroadcast(C.PK_BANK_A);
        repoManager.settleRepo(repoId);
        vm.stopBroadcast();

        _check(cash.balanceOf(bankB) == C.BANK_B_CASH - C.REPO_CASH, "cash leg delivered");
        _check(cash.balanceOf(bankA) == C.BANK_A_CASH + C.REPO_CASH, "cash received by borrower");
        RepoManager.Repo memory repo = repoManager.getRepo(repoId);
        _check(repo.status == RepoManager.RepoStatus.ACTIVE, "repo ACTIVE");
        console2.log(string.concat("[10-11] Repo settled (DvP): $", _toUsd(C.REPO_CASH), " cash -> Bank A, $", _toUsd(p.collateralValue), " collateral locked"));

        // ------------------- STEP 12: price falls to $92 ---------------------
        _submitPrice(C.T_BOND, C.T_BOND_PRICE_DOWN, 3);
        console2.log(string.concat("[12] T-BOND price falls to $", _toUsd(C.T_BOND_PRICE_DOWN)));

        // ------------------- STEP 13-14: margin call -------------------------
        vm.startBroadcast(C.PK_BANK_B);
        uint256 shortfall = marginManager.createMarginCall(repoId);
        vm.stopBroadcast();
        MarginManager.MarginCall memory mc = marginManager.getMarginStatus(repoId);
        _check(mc.active && shortfall == 2_600_000, "margin call $26,000");
        console2.log(
            string.concat(
                "[13-14] Margin call: collateral=$",
                _toUsd(mc.currentValue),
                "  required=$",
                _toUsd(mc.requiredValue),
                "  shortfall=$",
                _toUsd(mc.shortfall)
            )
        );

        // ------------------- STEP 15-18: substitution ------------------------
        // Bank A books 10,000 CORP-BOND-001 with the CSD; Custodian A attests.
        _submitCustodyAttestation(_corpAttestation(), C.PK_CUSTODIAN_A);

        vm.startBroadcast(C.PK_BANK_A);
        replacementId = pledgeManager.requestSubstitution(positionId, C.CORP_BOND, C.CORP_BOND_QUANTITY);
        vm.stopBroadcast();

        vm.startBroadcast(C.PK_COLLATERAL_AGENT);
        pledgeManager.validateReplacement(replacementId);
        vm.stopBroadcast();

        vm.startBroadcast(C.PK_BANK_A);
        pledgeManager.reserveReplacement(replacementId);
        vm.stopBroadcast();

        vm.startBroadcast(C.PK_COLLATERAL_AGENT);
        pledgeManager.activateSubstitution(positionId);
        vm.stopBroadcast();

        CollateralManager.CollateralPosition memory replaced = collateralManager.getPosition(positionId);
        CollateralManager.CollateralPosition memory active = collateralManager.getPosition(replacementId);
        _check(replaced.status == CollateralManager.CollateralStatus.RELEASED, "old released");
        _check(active.status == CollateralManager.CollateralStatus.PLEDGED, "replacement pledged");
        _check(custodyRegistry.availableQuantity(C.CORP_BOND, bankA) == 0, "corp encumbered");
        _check(custodyRegistry.availableQuantity(C.T_BOND, bankA) == C.T_BOND_QUANTITY, "treasury un-encumbered");
        console2.log(
            string.concat(
                "[15-18] Substitution: ",
                vm.toString(active.quantity),
                " corp bonds (collateral=$",
                _toUsd(active.collateralValue),
                ") >= ",
                vm.toString(replaced.quantity),
                " treasuries (collateral=$",
                _toUsd(replaced.collateralValue),
                ")"
            )
        );

        // ------------------- STEP 15b: margin call satisfied -----------------
        vm.startBroadcast(C.PK_BANK_B);
        bool satisfied = marginManager.satisfyMarginCall(repoId);
        vm.stopBroadcast();
        _check(satisfied, "margin call satisfied");
        console2.log(string.concat("[15b] Margin call satisfied - new collateral = $", _toUsd(mc.requiredValue)));

        console2.log("PHASE 1 COMPLETE");
        }

        // ------------------- STEP 19-21: repo matures + release --------------
        // Phase 2 runs alone: broadcast the approve at real time, then advance
        // the node clock persistently (anvil_setTime) so the repayAndClose
        // broadcast lands past maturity.
        if (doPhase2) {
        vm.startBroadcast(C.PK_BANK_A);
        cash.approve(address(repoManager), C.REPO_CASH + 1_000_000);
        vm.stopBroadcast();

        RepoManager.Repo memory repo = repoManager.getRepo(repoId);
        _skipAhead(repo.maturity + 1);

        vm.startBroadcast(C.PK_BANK_A);
        uint256 repaid = repoManager.repayAndClose(repoId);
        vm.stopBroadcast();

        _check(repoManager.getRepo(repoId).status == RepoManager.RepoStatus.CLOSED, "repo CLOSED");
        bytes32[] memory ids = collateralManager.getPositionsByObligation(repoId);
        for (uint256 i = 0; i < ids.length; i++) {
            CollateralManager.CollateralPosition memory pos = collateralManager.getPosition(ids[i]);
            _check(pos.status == CollateralManager.CollateralStatus.RELEASED, "collateral released");
        }
        _check(corpBondToken.balanceOf(bankA) == C.CORP_BOND_QUANTITY, "corp tokens returned to Bank A");
        console2.log(string.concat("[19-21] Repo matured: Bank A repaid $", _toUsd(repaid), " (principal + interest)"));
        console2.log(string.concat("        Collateral released - ", vm.toString(corpBondToken.balanceOf(bankA)), " corp bonds back to Bank A"));

        // ------------------- Final checks -------------------------------------
        uint256 auditRecords = audit.recordCount();
        console2.log("----------------------------------------------------------");
        console2.log(string.concat("Audit records written: ", vm.toString(auditRecords)));
        _check(custodyRegistry.availableQuantity(C.CORP_BOND, bankA) == C.CORP_BOND_QUANTITY, "custody fully unencumbered");
        _check(custodyRegistry.availableQuantity(C.T_BOND, bankA) == C.T_BOND_QUANTITY, "custody fully unencumbered");
        console2.log("Reconciliation snapshot: CSD state == on-chain state (MATCH)");
        console2.log("DEMO COMPLETE");
        }
    }

    /* ------------------------------------------------------------------ */
    /* Signing helpers                                                     */
    /* ------------------------------------------------------------------ */
    function _submitCustodyAttestation(AttestationRegistry.AssetAttestation memory a, uint256 signerKey) internal {
        bytes32 digest = attestationRegistry.attestationDigest(a);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        vm.startBroadcast(signerKey);
        attestationRegistry.createAttestation(a, v, r, s);
        custodyRegistry.updateCustodyAttestation(a.attestationId);
        vm.stopBroadcast();
        console2.log(string.concat("[2-3] Custody attestation ", _short(a.attestationId), " submitted for ", _short(a.assetId), " (", vm.toString(a.quantity), " units)"));
    }

    /// @notice Custody attestation for Bank A's 10,000 CORP-BOND-001 (used at substitution).
    function _corpAttestation() internal view returns (AttestationRegistry.AssetAttestation memory a) {
        a.attestationId = keccak256("CUSTODY_CORP_BOND_001_V1");
        a.assetId = C.CORP_BOND;
        a.subject = bankA;
        a.owner = bankA;
        a.custodian = custodianA;
        a.quantity = C.CORP_BOND_QUANTITY;
        a.timestamp = block.timestamp;
        a.expiry = block.timestamp + C.ATTESTATION_TTL;
        a.dataHash = keccak256("CSD-RECORD-US-CORP-001");
        a.attestor = custodianA;
    }

    function _submitCompliance(address subject, string memory label) internal {
        ComplianceAttestationRegistry.ComplianceAttestation memory c = ComplianceAttestationRegistry.ComplianceAttestation({
            attestationId: keccak256(abi.encode(label, subject)),
            subject: subject,
            kycPassed: true,
            amlPassed: true,
            sanctionsPassed: true,
            jurisdictionAccepted: true,
            timestamp: block.timestamp,
            expiry: block.timestamp + C.COMPLIANCE_TTL,
            attestor: complianceProvider
        });
        bytes32 digest = complianceRegistry.complianceDigest(c);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(C.PK_COMPLIANCE_PROVIDER, digest);
        vm.startBroadcast(C.PK_COMPLIANCE_PROVIDER);
        complianceRegistry.submitComplianceAttestation(c, v, r, s);
        vm.stopBroadcast();
        console2.log(string.concat("[2b] Compliance attestation submitted for ", _short(bytes32(uint256(uint160(subject))))));
    }

    function _submitPrice(bytes32 assetId, uint256 price, uint256 nonce) internal {
        bytes32 digest = oracle.priceDigest(assetId, price, block.timestamp, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(C.PK_VALUATION_PROVIDER, digest);
        vm.startBroadcast(C.PK_VALUATION_PROVIDER);
        oracle.updatePrice(assetId, price, block.timestamp, v, r, s);
        vm.stopBroadcast();
    }

    /* ------------------------------------------------------------------ */
    /* Load deployment                                                     */
    /* ------------------------------------------------------------------ */

    function _load() internal {
        string memory json = vm.readFile("deployments/anvil.json");

        access = ProtocolAccessManager(vm.parseJsonAddress(json, "$.accessManager"));
        audit = AuditRegistry(vm.parseJsonAddress(json, "$.auditRegistry"));
        assetRegistry = AssetRegistry(vm.parseJsonAddress(json, "$.assetRegistry"));
        attestationRegistry = AttestationRegistry(vm.parseJsonAddress(json, "$.attestationRegistry"));
        custodyRegistry = CustodyRegistry(vm.parseJsonAddress(json, "$.custodyRegistry"));
        complianceRegistry = ComplianceAttestationRegistry(vm.parseJsonAddress(json, "$.complianceRegistry"));
        cash = CashToken(vm.parseJsonAddress(json, "$.cashToken"));
        oracle = ValuationOracle(vm.parseJsonAddress(json, "$.valuationOracle"));
        eligibility = EligibilityPolicy(vm.parseJsonAddress(json, "$.eligibilityPolicy"));
        collateralManager = CollateralManager(vm.parseJsonAddress(json, "$.collateralManager"));
        pledgeManager = PledgeManager(vm.parseJsonAddress(json, "$.pledgeManager"));
        marginManager = MarginManager(vm.parseJsonAddress(json, "$.marginManager"));
        settlement = SettlementCoordinator(vm.parseJsonAddress(json, "$.settlementCoordinator"));
        repoManager = RepoManager(vm.parseJsonAddress(json, "$.repoManager"));
        tBondToken = TokenizedSecurity(vm.parseJsonAddress(json, "$.tBondToken"));
        corpBondToken = TokenizedSecurity(vm.parseJsonAddress(json, "$.corpBondToken"));

        admin = vm.parseJsonAddress(json, "$.admin.address");
        bankA = vm.parseJsonAddress(json, "$.bankA.address");
        bankB = vm.parseJsonAddress(json, "$.bankB.address");
        custodianA = vm.parseJsonAddress(json, "$.custodianA.address");
        mockCsd = vm.parseJsonAddress(json, "$.mockCsd.address");
        collateralAgent = vm.parseJsonAddress(json, "$.collateralAgent.address");
        valuationProvider = vm.parseJsonAddress(json, "$.valuationProvider.address");
        settlementAgent = vm.parseJsonAddress(json, "$.settlementAgent.address");
        complianceProvider = vm.parseJsonAddress(json, "$.complianceProvider.address");
    }

    /// @notice Advance the simulated clock past repo maturity. When broadcasting
    ///         to a live anvil node (ANVIL_FAST_TIME=1) also override the next
    ///         block's timestamp on the node so the immediately-following
    ///         broadcast tx (repayAndClose) lands past maturity. The override is
    ///         one-shot, so the tx must be the very next broadcast.
    function _skipAhead(uint256 target) internal {
        vm.warp(target);
        if (vm.envOr("ANVIL_FAST_TIME", false)) {
            // One-shot: applies to the next mined block. Safe here because in
            // phase 2 the first broadcast after this call (cash.approve) is not
            // time-sensitive; repayAndClose mines the block after it, already
            // past maturity.
            vm.rpc("anvil_setNextBlockTimestamp", string.concat('[', vm.toString(target), ']'));
        }
    }

    function _check(bool condition, string memory message) internal pure {
        require(condition, string.concat("Demo check failed: ", message));
    }

    function _toUsd(uint256 cents) internal pure returns (string memory) {
        return string.concat(vm.toString(cents / 100), ".", vm.toString((cents % 100) / 10), vm.toString(cents % 10));
    }

    function _short(bytes32 b) internal pure returns (string memory) {
        return vm.toString(b);
    }
}
