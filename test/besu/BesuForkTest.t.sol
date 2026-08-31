// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
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
import {LibConstants as C} from "../../script/LibConstants.sol";

/**
 * @title BesuForkTest
 * @notice Runs the complete institutional-collateral lifecycle (both phases)
 *         against a FORK of the live Besu QBFT devnet, using the addresses
 *         recorded in deployments/besu.json. No transactions are broadcast — the
 *         fork executes everything and discards state on completion. This lets
 *         Phase 2's 7-day maturity jump work (via vm.warp), which a live QBFT
 *         chain cannot do.
 *
 *   Usage (Besu devnet must be running):
 *     forge test --match-contract BesuForkTest -vvv
 */
contract BesuForkTest is Test {
    ProtocolAccessManager access;
    AuditRegistry audit;
    AssetRegistry assetRegistry;
    AttestationRegistry attestationRegistry;
    CustodyRegistry custodyRegistry;
    ComplianceAttestationRegistry complianceRegistry;
    CashToken cash;
    ValuationOracle oracle;
    EligibilityPolicy eligibility;
    CollateralManager collateralManager;
    PledgeManager pledgeManager;
    MarginManager marginManager;
    SettlementCoordinator settlement;
    RepoManager repoManager;
    TokenizedSecurity tBondToken;
    TokenizedSecurity corpBondToken;

    address admin;
    address bankA;
    address bankB;
    address custodianA;
    address collateralAgent;
    address valuationProvider;
    address complianceProvider;

    bytes32 constant T_BOND = C.T_BOND;
    bytes32 constant CORP_BOND = C.CORP_BOND;

    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8545");

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
        collateralAgent = vm.parseJsonAddress(json, "$.collateralAgent.address");
        valuationProvider = vm.parseJsonAddress(json, "$.valuationProvider.address");
        complianceProvider = vm.parseJsonAddress(json, "$.complianceProvider.address");
    }

    function test_fullBesuLifecycle() public {
        bytes32 repoId = keccak256(abi.encode("REPO", uint256(1), bankA, bankB));

        // Phase 1 ------------------------------------------------------------
        // Custody attestation
        bytes32 attId = keccak256("CUSTODY_T_BOND_001_V1");
        _submitCustodyAttestation(
            AttestationRegistry.AssetAttestation({
                attestationId: attId,
                assetId: T_BOND,
                subject: bankA,
                owner: bankA,
                custodian: custodianA,
                quantity: C.T_BOND_QUANTITY,
                encumberedQuantity: 0,
                timestamp: block.timestamp,
                expiry: block.timestamp + C.ATTESTATION_TTL,
                dataHash: keccak256("CSD-RECORD-US-TBOND-001"),
                attestor: custodianA
            }),
            C.PK_CUSTODIAN_A
        );

        // Compliance attestations
        _submitCompliance(bankA, "COMPLIANCE_BANK_A");
        _submitCompliance(bankB, "COMPLIANCE_BANK_B");

        // Mint tokens
        vm.prank(admin);
        tBondToken.mint(bankA, C.T_BOND_QUANTITY);
        vm.prank(admin);
        corpBondToken.mint(bankA, C.CORP_BOND_QUANTITY);
        assertEq(tBondToken.balanceOf(bankA), C.T_BOND_QUANTITY, "mint balance");

        // Prices
        _submitPrice(T_BOND, C.T_BOND_PRICE, 1);
        _submitPrice(CORP_BOND, C.CORP_BOND_PRICE, 2);

        // Requirement
        vm.prank(bankB);
        marginManager.setRequirement(repoId, C.REQUIREMENT);

        // Pledge
        vm.prank(bankA);
        bytes32 positionId = pledgeManager.requestPledge(T_BOND, C.T_BOND_QUANTITY, bankB, repoId);
        vm.prank(collateralAgent);
        pledgeManager.verifyCollateral(positionId);
        vm.prank(bankA);
        pledgeManager.reserveCollateral(positionId);
        vm.prank(bankB);
        pledgeManager.approvePledge(positionId);
        vm.prank(collateralAgent);
        pledgeManager.finalizePledge(positionId);

        CollateralManager.CollateralPosition memory p = collateralManager.getPosition(positionId);
        assertEq(uint8(p.status), uint8(CollateralManager.CollateralStatus.PLEDGED), "status PLEDGED");
        assertEq(p.marketValue, 100_000_000, "marketValue");
        assertEq(p.haircutBps, 500, "haircut 5%");
        assertEq(p.collateralValue, 95_000_000, "collateralValue");
        assertEq(custodyRegistry.availableQuantity(T_BOND, bankA), 0, "custody fully encumbered");
        assertEq(tBondToken.balanceOf(bankA), 0, "treasury locked in vault");

        // Repo settle (DvP)
        vm.prank(bankA);
        repoId = repoManager.createRepo(bankA, bankB, positionId, C.REPO_CASH, C.REPO_RATE_BPS, C.REPO_TENOR);
        vm.prank(bankB);
        cash.approve(address(settlement), C.REPO_CASH);
        vm.prank(bankA);
        repoManager.settleRepo(repoId);
        assertEq(uint8(repoManager.getRepo(repoId).status), uint8(RepoManager.RepoStatus.ACTIVE), "repo ACTIVE");
        assertEq(cash.balanceOf(bankA), C.BANK_A_CASH + C.REPO_CASH, "cash received by borrower");

        // Margin automation
        // STEP 12: price falls to $92, then evaluateAll raises a call
        _submitPrice(T_BOND, C.T_BOND_PRICE_DOWN, 3);
        bytes32[] memory obligations = new bytes32[](1);
        obligations[0] = repoId;
        vm.prank(collateralAgent);
        MarginManager.MarginEvaluation[] memory evals = marginManager.evaluateAll(obligations);
        assertTrue(evals[0].shortfall == 2_600_000, "margin call $26,000");

        // Substitution
        _submitCustodyAttestation(
            AttestationRegistry.AssetAttestation({
                attestationId: keccak256("CUSTODY_CORP_BOND_001_V1"),
                assetId: CORP_BOND,
                subject: bankA,
                owner: bankA,
                custodian: custodianA,
                quantity: C.CORP_BOND_QUANTITY,
                encumberedQuantity: 0,
                timestamp: block.timestamp,
                expiry: block.timestamp + C.ATTESTATION_TTL,
                dataHash: keccak256("CSD-RECORD-US-CORP-001"),
                attestor: custodianA
            }),
            C.PK_CUSTODIAN_A
        );

        vm.prank(bankA);
        bytes32 replacementId =
            pledgeManager.requestSubstitution(positionId, CORP_BOND, C.CORP_BOND_QUANTITY);
        vm.prank(collateralAgent);
        pledgeManager.validateReplacement(replacementId);
        vm.prank(bankA);
        pledgeManager.reserveReplacement(replacementId);
        vm.prank(collateralAgent);
        pledgeManager.activateSubstitution(positionId);

        assertEq(
            uint8(collateralManager.getPosition(positionId).status),
            uint8(CollateralManager.CollateralStatus.RELEASED),
            "old released"
        );
        assertEq(
            uint8(collateralManager.getPosition(replacementId).status),
            uint8(CollateralManager.CollateralStatus.PLEDGED),
            "replacement pledged"
        );

        vm.prank(bankB);
        assertTrue(marginManager.satisfyMarginCall(repoId), "margin call satisfied");

        // Phase 2 ------------------------------------------------------------
        // Bank A approves repayment, then we jump the fork clock past maturity.
        vm.prank(bankA);
        cash.approve(address(repoManager), C.REPO_CASH + 1_000_000);
        vm.warp(repoManager.getRepo(repoId).maturity + 1);
        vm.prank(bankA);
        repoManager.repayAndClose(repoId);

        assertEq(uint8(repoManager.getRepo(repoId).status), uint8(RepoManager.RepoStatus.CLOSED), "repo CLOSED");
        assertEq(
            uint8(collateralManager.getPosition(replacementId).status),
            uint8(CollateralManager.CollateralStatus.RELEASED),
            "collateral released"
        );
        assertEq(corpBondToken.balanceOf(bankA), C.CORP_BOND_QUANTITY, "corp tokens back to Bank A");
        assertEq(custodyRegistry.availableQuantity(CORP_BOND, bankA), C.CORP_BOND_QUANTITY, "custody unencumbered");

        emit log("==============================================");
        emit log("BESU FORK DEMO COMPLETE: full lifecycle OK");
        emit log("==============================================");
    }

    function _submitCustodyAttestation(AttestationRegistry.AssetAttestation memory a, uint256 signerKey) internal {
        bytes32 digest = attestationRegistry.attestationDigest(a);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        vm.prank(vm.addr(signerKey));
        attestationRegistry.createAttestation(a, v, r, s);
        vm.prank(vm.addr(signerKey));
        custodyRegistry.updateCustodyAttestation(a.attestationId);
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
        vm.prank(complianceProvider);
        complianceRegistry.submitComplianceAttestation(c, v, r, s);
    }

    function _submitPrice(bytes32 assetId, uint256 price, uint256 nonce) internal {
        bytes32 digest = oracle.priceDigest(assetId, price, block.timestamp, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(C.PK_VALUATION_PROVIDER, digest);
        vm.prank(valuationProvider);
        oracle.updatePrice(assetId, price, block.timestamp, v, r, s);
    }
}
