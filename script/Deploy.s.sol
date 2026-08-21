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
import {ICollateralManager} from "../src/interfaces/ICollateralManager.sol";
import {ICashToken} from "../src/interfaces/ICashToken.sol";
import {LibConstants as C} from "./LibConstants.sol";

/**
 * @title Deploy
 * @notice Deploys and fully configures the Institutional Collateral Network on a
 *         local Anvil node. No manual address editing: every participant is
 *         created from deterministic Anvil keys, wired together, and the full
 *         address map is written to deployments/anvil.json.
 *
 *   Usage:
 *     anvil
 *     forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
 */
contract Deploy is Script {
    address internal admin = vm.addr(C.PK_ADMIN);
    address internal bankA = vm.addr(C.PK_BANK_A);
    address internal bankB = vm.addr(C.PK_BANK_B);
    address internal custodianA = vm.addr(C.PK_CUSTODIAN_A);
    address internal mockCsd = vm.addr(C.PK_MOCK_CSD);
    address internal collateralAgent = vm.addr(C.PK_COLLATERAL_AGENT);
    address internal valuationProvider = vm.addr(C.PK_VALUATION_PROVIDER);
    address internal settlementAgent = vm.addr(C.PK_SETTLEMENT_AGENT);
    address internal complianceProvider = vm.addr(C.PK_COMPLIANCE_PROVIDER);

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
        vm.startBroadcast(C.PK_ADMIN);

        // ---- Core infrastructure ----
        access = new ProtocolAccessManager(admin);
        audit = new AuditRegistry(access);
        assetRegistry = new AssetRegistry(access, audit);
        attestationRegistry = new AttestationRegistry(access, assetRegistry, audit);
        custodyRegistry = new CustodyRegistry(access, attestationRegistry, audit);
        complianceRegistry = new ComplianceAttestationRegistry(access, audit);
        cash = new CashToken(access);

        // Register workflow contracts as allowed AuditRegistry writers before any log() calls.
        audit.addWriter(address(assetRegistry));
        audit.addWriter(address(attestationRegistry));
        audit.addWriter(address(complianceRegistry));

        // ---- Assets + tokens (V1: exactly two securities) ----
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

        // ---- Valuation + policy ----
        oracle = new ValuationOracle(access);
        eligibility = new EligibilityPolicy(access, assetRegistry, custodyRegistry, attestationRegistry, oracle);

        // ---- Collateral layer ----
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

        // Register remaining workflow contracts as allowed AuditRegistry writers.
        audit.addWriter(address(collateralManager));
        audit.addWriter(address(marginManager));
        audit.addWriter(address(repoManager));
        audit.addWriter(address(settlement));

        // ---- Roles ----
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

        // CustodyRegistry: only the CollateralManager may move the encumbrance mirror.
        access.grantRole(custodyRegistry.COLLATERAL_MANAGER_ROLE(), address(collateralManager));

        // CollateralManager operators: the workflow contracts.
        collateralManager.setOperator(address(pledgeManager), true);
        collateralManager.setOperator(address(marginManager), true);
        collateralManager.setOperator(address(settlement), true);
        collateralManager.setOperator(address(repoManager), true);

        // ---- Eligibility matrix (V1) ----
        eligibility.setPolicy(AssetRegistry.AssetType.TREASURY, true, 500, 0); // 5% haircut
        eligibility.setPolicy(AssetRegistry.AssetType.CORPORATE_BOND, true, 1000, 90 days); // 10% haircut

        // ---- Seed test cash ----
        cash.mint(bankA, C.BANK_A_CASH);
        cash.mint(bankB, C.BANK_B_CASH);

        vm.stopBroadcast();

        _writeDeployment();

        console2.log("=== Institutional Collateral Network deployed ===");
        console2.log(string.concat("accessManager: ", vm.toString(address(access))));
        console2.log(string.concat("collateralManager: ", vm.toString(address(collateralManager))));
        console2.log(string.concat("pledgeManager: ", vm.toString(address(pledgeManager))));
        console2.log(string.concat("marginManager: ", vm.toString(address(marginManager))));
        console2.log(string.concat("settlementCoordinator: ", vm.toString(address(settlement))));
        console2.log(string.concat("repoManager: ", vm.toString(address(repoManager))));
        console2.log(string.concat("attestationRegistry: ", vm.toString(address(attestationRegistry))));
        console2.log(string.concat("Bank A: ", vm.toString(bankA)));
        console2.log(string.concat("Bank B: ", vm.toString(bankB)));
        console2.log("address map: deployments/anvil.json");
    }

    /* ------------------------------------------------------------------ */
    /* Deployment artifact                                                 */
    /* ------------------------------------------------------------------ */

    function _writeDeployment() internal {
        string memory root = "deployment";

        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "accessManager", address(access));
        vm.serializeAddress(root, "auditRegistry", address(audit));
        vm.serializeAddress(root, "assetRegistry", address(assetRegistry));
        vm.serializeAddress(root, "attestationRegistry", address(attestationRegistry));
        vm.serializeAddress(root, "custodyRegistry", address(custodyRegistry));
        vm.serializeAddress(root, "complianceRegistry", address(complianceRegistry));
        vm.serializeAddress(root, "cashToken", address(cash));
        vm.serializeAddress(root, "valuationOracle", address(oracle));
        vm.serializeAddress(root, "eligibilityPolicy", address(eligibility));
        vm.serializeAddress(root, "collateralManager", address(collateralManager));
        vm.serializeAddress(root, "pledgeManager", address(pledgeManager));
        vm.serializeAddress(root, "marginManager", address(marginManager));
        vm.serializeAddress(root, "settlementCoordinator", address(settlement));
        vm.serializeAddress(root, "repoManager", address(repoManager));
        vm.serializeAddress(root, "tBondToken", address(tBondToken));
        vm.serializeAddress(root, "corpBondToken", address(corpBondToken));

        _writeParticipant(root, "admin", "ADMIN", C.PK_ADMIN, admin);
        _writeParticipant(root, "bankA", "COLLATERAL_PROVIDER", C.PK_BANK_A, bankA);
        _writeParticipant(root, "bankB", "COLLATERAL_RECEIVER", C.PK_BANK_B, bankB);
        _writeParticipant(root, "custodianA", "CUSTODIAN", C.PK_CUSTODIAN_A, custodianA);
        _writeParticipant(root, "mockCsd", "AUTHORITATIVE_ASSET_REGISTRY", C.PK_MOCK_CSD, mockCsd);
        _writeParticipant(root, "collateralAgent", "COLLATERAL_AGENT", C.PK_COLLATERAL_AGENT, collateralAgent);
        _writeParticipant(root, "valuationProvider", "VALUATION_PROVIDER", C.PK_VALUATION_PROVIDER, valuationProvider);
        _writeParticipant(root, "settlementAgent", "SETTLEMENT_AGENT", C.PK_SETTLEMENT_AGENT, settlementAgent);
        _writeParticipant(root, "complianceProvider", "COMPLIANCE_PROVIDER", C.PK_COMPLIANCE_PROVIDER, complianceProvider);

        vm.serializeString(root, "assets", _assetsJson());
        vm.serializeString(root, "roles", _rolesJson());

        string memory out = vm.serializeString(
            root, "note", "LOCAL ANVIL TESTNET ONLY - deterministic development keys. Never use in production."
        );
        vm.writeJson(out, "deployments/anvil.json");
    }

    function _writeParticipant(string memory root, string memory key, string memory role, uint256 pk, address who)
        internal
    {
        string memory obj = string.concat(key, "_obj");
        vm.serializeAddress(obj, "address", who);
        vm.serializeString(obj, "role", role);
        vm.serializeString(obj, "privateKey", vm.toString(pk));
        string memory participant = vm.serializeString(obj, "label", toUpper(key));
        vm.serializeString(root, key, participant);
    }

    function _assetsJson() internal returns (string memory) {
        string memory a = "assets";
        vm.serializeBytes32(a, "tBondAssetId", C.T_BOND);
        vm.serializeBytes32(a, "corpBondAssetId", C.CORP_BOND);
        return vm.serializeString(a, "note", "V1 asset universe: exactly two securities");
    }

    function _rolesJson() internal returns (string memory) {
        string memory r = "roles";
        vm.serializeString(r, "CSD", "can issue/revoke asset attestations");
        vm.serializeString(r, "CUSTODIAN", "can submit signed custody attestations");
        vm.serializeString(r, "COLLATERAL_AGENT", "verifies/approves collateral workflows");
        vm.serializeString(r, "VALUATION_PROVIDER", "submits signed market prices");
        vm.serializeString(r, "SETTLEMENT_AGENT", "executes settlement coordinator");
        return vm.serializeString(r, "BANK", "pledge / substitute / release own collateral, repo");
    }

    function toUpper(string memory s) internal pure returns (string memory) {
        bytes memory b = abi.encodePacked(s);
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] >= 0x61 && b[i] <= 0x7a) b[i] = bytes1(uint8(b[i]) - 32);
        }
        return string(b);
    }
}
