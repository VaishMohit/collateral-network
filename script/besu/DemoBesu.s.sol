// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Roles} from "../../src/libs/Roles.sol";
import {ProtocolAccessManager} from "../../src/ProtocolAccessManager.sol";
import {AuditRegistry} from "../../src/AuditRegistry.sol";
import {AssetRegistry} from "../../src/AssetRegistry.sol";
import {AttestationRegistry} from "../../src/AttestationRegistry.sol";
import {CustodyRegistry} from "../../src/CustodyRegistry.sol";
import {ComplianceAttestationRegistry} from "../../src/ComplianceAttestationRegistry.sol";
import {CashToken} from "../../src/CashToken.sol";
import {TokenizedSecurity} from "../../src/TokenizedSecurity.sol";
import {ValuationOracle} from "../../src/ValuationOracle.sol";
import {EligibilityPolicy} from "../../src/EligibilityPolicy.sol";
import {CollateralManager} from "../../src/CollateralManager.sol";
import {PledgeManager} from "../../src/PledgeManager.sol";
import {MarginManager} from "../../src/MarginManager.sol";
import {SettlementCoordinator} from "../../src/SettlementCoordinator.sol";
import {RepoManager} from "../../src/RepoManager.sol";
import {LibConstants as C} from "../LibConstants.sol";

/**
 * @title DemoBesu
 * @notice Runs the core institutional collateral lifecycle on a live Besu QBFT
 *         chain (infra/besu). Mirrors script/Demo.s.sol Phase 1 only (steps 1-15b).
 *
 *   Phase 2 (repo maturity + repayment) requires a 7-day time jump that is not
 *   available on a live QBFT network. The full two-phase lifecycle is validated
 *   by test/besu/BesuForkTest.t.sol, which forks this chain and runs both phases
 *   (using vm.warp for maturity) against the deployment in deployments/besu.json.
 *
 *   NOTE: the monolithic --broadcast run of this script can hit a forge OOG bug
 *   on live Besu; prefer the fork test for a definitive full-lifecycle check, or
 *   drive individual steps via cast.
 *
 *   Steps covered:
 *     1   Mock CSD books 10,000 T-BOND-001 for Bank A at Custodian A (off-chain)
 *     2+3 Custodian A signs custody attestation, submitted on-chain
 *     2b  Compliance attestations for Bank A and Bank B
 *     4   Treasury + corporate tokens minted for Bank A
 *     5   Market prices submitted ($100 T-BOND, $85 CORP)
 *     6   Bank B sets $950,000 collateral requirement
 *     7-9 Bank A pledges 10,000 T-BOND → 5% haircut → $950,000 collateral value
 *     10-11 Repo settled (DvP): $950,000 cash transferred, collateral locked
 *     12  T-BOND price drops to $92
 *     13  Operator previews margin call (shortfall $26,000)
 *     14  Collateral agent raises margin call
 *     15-18 Bank A substitutes corporate bonds for treasury bonds
 *     15b Margin call satisfied
 *
 *   Usage:
 *     docker compose up -d                                          # infra/besu
 *     forge script script/besu/DeployBesu.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
 *     forge script script/besu/DemoBesu.s.sol   --rpc-url http://127.0.0.1:8545 --broadcast
 */
contract DemoBesu is Script {
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

        bytes32 repoId = keccak256(abi.encode("REPO", uint256(1), bankA, bankB));

        console2.log("==========================================================");
        console2.log("Institutional Collateral Network - end-to-end demo (Besu)");
        console2.log("==========================================================");

        // STEP 1: Mock CSD books asset (off-chain, no on-chain action)

        // STEP 2+3: Custody attestation
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

        // STEP 2b: Compliance attestations
        _submitCompliance(bankA, "COMPLIANCE_BANK_A");
        _submitCompliance(bankB, "COMPLIANCE_BANK_B");

        // STEP 4: Mint tokens
        vm.startBroadcast(C.PK_ADMIN);
        tBondToken.mint(bankA, C.T_BOND_QUANTITY);
        corpBondToken.mint(bankA, C.CORP_BOND_QUANTITY);
        vm.stopBroadcast();
        console2.log(
            string.concat(
                "[4] Minted ",
                vm.toString(C.T_BOND_QUANTITY),
                " tT-BOND and ",
                vm.toString(C.CORP_BOND_QUANTITY),
                " tCORP for Bank A"
            )
        );
        _check(tBondToken.balanceOf(bankA) == C.T_BOND_QUANTITY, "mint balance");

        // STEP 5: Submit market prices
        _submitPrice(C.T_BOND, C.T_BOND_PRICE, 1);
        _submitPrice(C.CORP_BOND, C.CORP_BOND_PRICE, 2);
        (uint256 px,) = oracle.getLatestPrice(C.T_BOND);
        console2.log(string.concat("[5] T-BOND price = $", _toUsd(px)));

        // STEP 6: Bank B sets collateral requirement
        vm.startBroadcast(C.PK_BANK_B);
        marginManager.setRequirement(repoId, C.REQUIREMENT);
        vm.stopBroadcast();
        console2.log(string.concat("[6] Bank B collateral requirement = $", _toUsd(C.REQUIREMENT)));

        // STEP 7-9: Pledge 10,000 T-BOND
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
        _check(
            p.marketValue == 100_000_000 && p.haircutBps == 500 && p.collateralValue == 95_000_000,
            "valuation 5% haircut"
        );
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

        // STEP 10-11: Repo settles (DvP)
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
        console2.log(
            string.concat(
                "[10-11] Repo settled (DvP): $",
                _toUsd(C.REPO_CASH),
                " cash -> Bank A, $",
                _toUsd(p.collateralValue),
                " collateral locked"
            )
        );

        // STEP 12-15b: Margin automation
        _runMarginAutomation(repoId, positionId);

        console2.log("PHASE 1 COMPLETE");
        console2.log("Note: Phase 2 (repo maturity + repayment) requires a 7-day time jump");
        console2.log("      which is not available on a live QBFT network. Run Demo.s.sol on");
        console2.log("      an Anvil devnet for the full lifecycle.");
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
        console2.log(
            string.concat(
                "[2-3] Custody attestation ",
                _short(a.attestationId),
                " submitted for ",
                _short(a.assetId),
                " (",
                vm.toString(a.quantity),
                " units)"
            )
        );
    }

    function _submitCompliance(address subject, string memory label) internal {
        ComplianceAttestationRegistry.ComplianceAttestation memory c =
            ComplianceAttestationRegistry.ComplianceAttestation({
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
        console2.log(
            string.concat("[2b] Compliance attestation submitted for ", _short(bytes32(uint256(uint160(subject)))))
        );
    }

    function _submitPrice(bytes32 assetId, uint256 price, uint256 nonce) internal {
        bytes32 digest = oracle.priceDigest(assetId, price, block.timestamp, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(C.PK_VALUATION_PROVIDER, digest);
        vm.startBroadcast(C.PK_VALUATION_PROVIDER);
        oracle.updatePrice(assetId, price, block.timestamp, v, r, s);
        vm.stopBroadcast();
    }

    function _runMarginAutomation(bytes32 repoId, bytes32 positionId) internal {
        // STEP 12: Price falls to $92
        _submitPrice(C.T_BOND, C.T_BOND_PRICE_DOWN, 3);
        console2.log(string.concat("[12] T-BOND price falls to $", _toUsd(C.T_BOND_PRICE_DOWN)));

        // STEP 13: Operator previews margin call
        MarginManager.MarginEvaluation memory eval = marginManager.previewMarginCall(repoId);
        console2.log(
            string.concat(
                "[13] Preview: collateral=$",
                _toUsd(eval.currentValue),
                "  required=$",
                _toUsd(eval.requiredValue),
                "  shortfall=$",
                _toUsd(eval.shortfall),
                eval.isAdequate ? "  ADEQUATE" : "  SHORTFALL"
            )
        );

        // STEP 14: Collateral agent raises margin call
        bytes32[] memory obligations = new bytes32[](1);
        obligations[0] = repoId;
        vm.startBroadcast(C.PK_COLLATERAL_AGENT);
        MarginManager.MarginEvaluation[] memory evals = marginManager.evaluateAll(obligations);
        vm.stopBroadcast();

        MarginManager.MarginCall memory mc = marginManager.getMarginStatus(repoId);
        _check(mc.active && evals[0].shortfall == 2_600_000, "margin call $26,000");
        console2.log(
            string.concat(
                "[14] Margin call raised: collateral=$",
                _toUsd(mc.currentValue),
                "  required=$",
                _toUsd(mc.requiredValue),
                "  shortfall=$",
                _toUsd(mc.shortfall)
            )
        );

        // STEP 15-18: Substitution — Bank A books corporate bonds, custodian attests
        AttestationRegistry.AssetAttestation memory corpAtt = AttestationRegistry.AssetAttestation({
            attestationId: keccak256("CUSTODY_CORP_BOND_001_V1"),
            assetId: C.CORP_BOND,
            subject: bankA,
            owner: bankA,
            custodian: custodianA,
            quantity: C.CORP_BOND_QUANTITY,
            encumberedQuantity: 0,
            timestamp: block.timestamp,
            expiry: block.timestamp + C.ATTESTATION_TTL,
            dataHash: keccak256("CSD-RECORD-US-CORP-001"),
            attestor: custodianA
        });
        _submitCustodyAttestation(corpAtt, C.PK_CUSTODIAN_A);

        vm.startBroadcast(C.PK_BANK_A);
        bytes32 replacementId = pledgeManager.requestSubstitution(positionId, C.CORP_BOND, C.CORP_BOND_QUANTITY);
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

        // STEP 15b: Margin call satisfied
        MarginManager.MarginEvaluation memory evalAfter = marginManager.evaluateMargin(repoId);
        vm.startBroadcast(C.PK_BANK_B);
        bool satisfied = marginManager.satisfyMarginCall(repoId);
        vm.stopBroadcast();
        _check(satisfied, "margin call satisfied");
        _check(evalAfter.isAdequate, "obligation adequate after substitution");

        MarginManager.MarginCallRecord[] memory histAfter = marginManager.getMarginCallHistory(repoId);
        _check(
            histAfter.length >= 2 && histAfter[0].satisfied && !histAfter[1].satisfied,
            "history holds create then satisfy"
        );
        console2.log(
            string.concat(
                "[15b] Margin call satisfied - new collateral = $",
                _toUsd(mc.requiredValue),
                "  (history ",
                vm.toString(histAfter.length),
                " records, newest satisfied)"
            )
        );
    }

    /* ------------------------------------------------------------------ */
    /* Load deployment                                                     */
    /* ------------------------------------------------------------------ */

    function _load() internal {
        string memory json = vm.readFile("deployments/besu.json");

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

    function _check(bool condition, string memory message) internal pure {
        require(condition, string.concat("Demo check failed: ", message));
    }

    function _toUsd(uint256 cents) internal pure returns (string memory) {
        return string.concat(vm.toString(cents / 100), ".", vm.toString((cents % 100) / 10), vm.toString(cents % 10));
    }

    function _short(bytes32 b) internal pure returns (string memory) {
        bytes16 left;
        assembly {
            left := mload(add(b, 16))
        }
        return vm.toString(left);
    }
}