// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
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
import {ICollateralManager} from "../src/interfaces/ICollateralManager.sol";
import {ICashToken} from "../src/interfaces/ICashToken.sol";
import {LibConstants as C} from "../script/LibConstants.sol";

/**
 * @title TestBase
 * @notice Shared harness: deploys the full Institutional Collateral Network
 *         in-memory and exposes signing / attestation / pricing helpers used by
 *         every unit, integration and invariant test.
 */
abstract contract TestBase is Test {
    // Participants
    address internal admin;
    address internal bankA;
    address internal bankB;
    address internal custodianA;
    address internal mockCsd;
    address internal collateralAgent;
    address internal valuationProvider;
    address internal settlementAgent;
    address internal complianceProvider;

    // Contracts
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

    bytes32 internal constant REPO_ID = keccak256(abi.encode("REPO", uint256(1), address(0), address(0)));

    /* ------------------------------------------------------------------ */
    /* Deployment                                                          */
    /* ------------------------------------------------------------------ */

    function _deployNetwork() internal {
        admin = vm.addr(C.PK_ADMIN);
        bankA = vm.addr(C.PK_BANK_A);
        bankB = vm.addr(C.PK_BANK_B);
        custodianA = vm.addr(C.PK_CUSTODIAN_A);
        mockCsd = vm.addr(C.PK_MOCK_CSD);
        collateralAgent = vm.addr(C.PK_COLLATERAL_AGENT);
        valuationProvider = vm.addr(C.PK_VALUATION_PROVIDER);
        settlementAgent = vm.addr(C.PK_SETTLEMENT_AGENT);
        complianceProvider = vm.addr(C.PK_COMPLIANCE_PROVIDER);

        vm.startPrank(admin);
        access = new ProtocolAccessManager(admin);
        audit = new AuditRegistry();
        assetRegistry = new AssetRegistry(access, audit);
        attestationRegistry = new AttestationRegistry(access, assetRegistry, audit);
        custodyRegistry = new CustodyRegistry(access, attestationRegistry, audit);
        complianceRegistry = new ComplianceAttestationRegistry(access, audit);
        cash = new CashToken(access);

        assetRegistry.registerAsset(
            C.T_BOND,
            C.T_BOND_ISIN,
            AssetRegistry.AssetType.TREASURY,
            address(0x1111111111111111111111111111111111111111),
            C.FACE_VALUE,
            C.T_BOND_MATURITY,
            AssetRegistry.Rating.UNRATED
        );
        assetRegistry.registerAsset(
            C.CORP_BOND,
            C.CORP_BOND_ISIN,
            AssetRegistry.AssetType.CORPORATE_BOND,
            address(0x2222222222222222222222222222222222222222),
            C.FACE_VALUE,
            C.CORP_BOND_MATURITY,
            AssetRegistry.Rating.AA
        );

        tBondToken = new TokenizedSecurity(access, C.T_BOND, "Tokenized US Treasury T-BOND-001", "tT-BOND");
        corpBondToken = new TokenizedSecurity(access, C.CORP_BOND, "Tokenized Corporate Bond CORP-BOND-001", "tCORP");
        assetRegistry.setToken(C.T_BOND, address(tBondToken));
        assetRegistry.setToken(C.CORP_BOND, address(corpBondToken));
        assetRegistry.activateAsset(C.T_BOND);
        assetRegistry.activateAsset(C.CORP_BOND);

        oracle = new ValuationOracle(access);
        eligibility = new EligibilityPolicy(access, assetRegistry, custodyRegistry, oracle);

        collateralManager =
            new CollateralManager(access, assetRegistry, custodyRegistry, eligibility, complianceRegistry, audit);
        pledgeManager = new PledgeManager(access, ICollateralManager(address(collateralManager)), audit);
        marginManager = new MarginManager(access, ICollateralManager(address(collateralManager)), audit);
        settlement =
            new SettlementCoordinator(access, ICollateralManager(address(collateralManager)), ICashToken(address(cash)), audit);
        repoManager = new RepoManager(
            access,
            ICollateralManager(address(collateralManager)),
            ICashToken(address(cash)),
            settlement,
            audit
        );

        access.grantRole(Roles.BANK, bankA);
        access.grantRole(Roles.BANK, bankB);
        access.grantRole(Roles.CSD, mockCsd);
        access.grantRole(Roles.CUSTODIAN, custodianA);
        access.grantRole(Roles.COLLATERAL_AGENT, collateralAgent);
        access.grantRole(Roles.VALUATION_PROVIDER, valuationProvider);
        access.grantRole(Roles.SETTLEMENT_AGENT, settlementAgent);
        access.grantRole(Roles.SETTLEMENT_AGENT, address(repoManager));
        access.grantRole(Roles.COMPLIANCE_PROVIDER, complianceProvider);
        access.grantRole(Roles.POLICY_ADMIN, admin);
        access.grantRole(Roles.TOKEN_CONTROLLER, admin);
        access.grantRole(Roles.TOKEN_CONTROLLER, address(collateralManager));
        access.grantRole(custodyRegistry.COLLATERAL_MANAGER_ROLE(), address(collateralManager));

        collateralManager.setOperator(address(pledgeManager), true);
        collateralManager.setOperator(address(marginManager), true);
        collateralManager.setOperator(address(settlement), true);
        collateralManager.setOperator(address(repoManager), true);

        eligibility.setPolicy(AssetRegistry.AssetType.TREASURY, true, 500, 0);
        eligibility.setPolicy(AssetRegistry.AssetType.CORPORATE_BOND, true, 1000, 90 days);

        cash.mint(bankA, C.BANK_A_CASH);
        cash.mint(bankB, C.BANK_B_CASH);
        vm.stopPrank();
    }

    /* ------------------------------------------------------------------ */
    /* Attestation / pricing helpers                                       */
    /* ------------------------------------------------------------------ */

    function _custodyAttestation(bytes32 assetId, address owner, address custodian, uint256 quantity)
        internal
        view
        returns (AttestationRegistry.AssetAttestation memory a)
    {
        a.attestationId = keccak256(abi.encode("CUSTODY", assetId, owner, quantity, block.timestamp));
        a.assetId = assetId;
        a.subject = owner;
        a.owner = owner;
        a.custodian = custodian;
        a.quantity = quantity;
        a.encumberedQuantity = 0;
        a.timestamp = block.timestamp;
        a.expiry = block.timestamp + C.ATTESTATION_TTL;
        a.dataHash = keccak256(abi.encode("CSD-RECORD", assetId, owner, quantity));
        a.attestor = custodian;
    }

    /// @notice Submits and activates a signed custody attestation for `owner`.
    function _attest(bytes32 assetId, address owner, uint256 quantity, address signer, uint256 signerPk) internal {
        AttestationRegistry.AssetAttestation memory a = _custodyAttestation(assetId, owner, signer, quantity);
        _submitCustodyAttestation(a, signerPk);
    }

    function _submitCustodyAttestation(AttestationRegistry.AssetAttestation memory a, uint256 signerPk) internal {
        bytes32 digest = attestationRegistry.attestationDigest(a);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        vm.startPrank(a.attestor);
        attestationRegistry.createAttestation(a, v, r, s);
        custodyRegistry.updateCustodyAttestation(a.attestationId);
        vm.stopPrank();
    }

    function _complianceAttestation(address subject)
        internal
        view
        returns (ComplianceAttestationRegistry.ComplianceAttestation memory c)
    {
        c.attestationId = keccak256(abi.encode("COMPLIANCE", subject, block.timestamp));
        c.subject = subject;
        c.kycPassed = true;
        c.amlPassed = true;
        c.sanctionsPassed = true;
        c.jurisdictionAccepted = true;
        c.timestamp = block.timestamp;
        c.expiry = block.timestamp + C.COMPLIANCE_TTL;
        c.attestor = complianceProvider;
    }

    function _submitCompliance(address subject) internal {
        ComplianceAttestationRegistry.ComplianceAttestation memory c = _complianceAttestation(subject);
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

    /* ------------------------------------------------------------------ */
    /* Scenario setup                                                      */
    /* ------------------------------------------------------------------ */

    /// @notice Attests both assets to Bank A, mints tokens, submits prices and
    ///         compliance attestations, and sets the repo requirement. Leaves
    ///         Bank A ready to pledge either asset.
    function _setupBankAReady(uint256 nonceStart) internal {
        _attest(C.T_BOND, bankA, C.T_BOND_QUANTITY, custodianA, C.PK_CUSTODIAN_A);
        _attest(C.CORP_BOND, bankA, C.CORP_BOND_QUANTITY, custodianA, C.PK_CUSTODIAN_A);
        _submitCompliance(bankA);
        _submitCompliance(bankB);
        vm.startPrank(admin);
        tBondToken.mint(bankA, C.T_BOND_QUANTITY);
        corpBondToken.mint(bankA, C.CORP_BOND_QUANTITY);
        vm.stopPrank();
        _submitPrice(C.T_BOND, C.T_BOND_PRICE, nonceStart);
        _submitPrice(C.CORP_BOND, C.CORP_BOND_PRICE, nonceStart + 1);
        vm.prank(bankB);
        marginManager.setRequirement(_repoId(), C.REQUIREMENT);
    }

    function _repoId() internal view returns (bytes32) {
        return keccak256(abi.encode("REPO", uint256(1), bankA, bankB));
    }

    /// @notice Runs the standard pledge flow for Bank A -> Bank B (T-BOND).
    /// @return positionId of the pledged position.
    function _pledge(bytes32 assetId, uint256 quantity, address receiver, bytes32 obligationId)
        internal
        returns (bytes32 positionId)
    {
        vm.prank(bankA);
        positionId = pledgeManager.requestPledge(assetId, quantity, receiver, obligationId);
        vm.prank(collateralAgent);
        pledgeManager.verifyCollateral(positionId);
        vm.prank(bankA);
        pledgeManager.reserveCollateral(positionId);
        vm.prank(receiver);
        pledgeManager.approvePledge(positionId);
        vm.prank(collateralAgent);
        pledgeManager.finalizePledge(positionId);
    }

    /// @notice Creates and settles a repo against an existing pledged position.
    function _repoAndSettle(bytes32 positionId, uint256 cashAmount) internal returns (bytes32 repoId) {
        vm.prank(bankA);
        repoId = repoManager.createRepo(bankA, bankB, positionId, cashAmount, C.REPO_RATE_BPS, C.REPO_TENOR);
        vm.prank(bankB);
        cash.approve(address(settlement), cashAmount);
        vm.prank(bankA);
        repoManager.settleRepo(repoId);
    }
}
