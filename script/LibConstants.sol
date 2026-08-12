// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/**
 * @title LibConstants
 * @notice Deterministic accounts, asset identifiers and market parameters used by
 *         the deploy / configure / demo scripts. Accounts are derived from
 *         Anvil's well-known development private keys (never used in production).
 */
library LibConstants {
    // ----------------------------------------------------------------------
    // Anvil development keys (public, test-only — never use in production)
    // ----------------------------------------------------------------------
    uint256 internal constant PK_ADMIN = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant PK_BANK_A = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant PK_BANK_B = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 internal constant PK_CUSTODIAN_A = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint256 internal constant PK_MOCK_CSD = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;
    uint256 internal constant PK_COLLATERAL_AGENT = 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;
    uint256 internal constant PK_VALUATION_PROVIDER = 0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e;
    uint256 internal constant PK_SETTLEMENT_AGENT = 0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356;
    uint256 internal constant PK_COMPLIANCE_PROVIDER = 0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97;

    // ----------------------------------------------------------------------
    // Assets (V1: exactly two securities)
    // ----------------------------------------------------------------------
    bytes32 internal constant T_BOND = bytes32(abi.encodePacked("T-BOND-001"));
    bytes32 internal constant CORP_BOND = bytes32(abi.encodePacked("CORP-BOND-001"));

    string internal constant T_BOND_ISIN = "US-TBOND-001";
    string internal constant CORP_BOND_ISIN = "IN-CORP-001";

    // face value 100 USD, expressed in cents
    uint256 internal constant FACE_VALUE = 10000;
    // maturity: 2030 / 2029 (unix timestamps)
    uint256 internal constant T_BOND_MATURITY = 1_893_456_000; // 2030-01-01
    uint256 internal constant CORP_BOND_MATURITY = 1_861_920_000; // 2029-01-01

    // Initial holdings
    uint256 internal constant T_BOND_QUANTITY = 10_000;
    uint256 internal constant CORP_BOND_QUANTITY = 10_000;

    // Prices (USD cents) — $100.00
    uint256 internal constant T_BOND_PRICE = 10_000;
    uint256 internal constant CORP_BOND_PRICE = 10_000;
    uint256 internal constant T_BOND_PRICE_DOWN = 9_200; // $92.00

    // Margin requirement (cents) — $900,000
    uint256 internal constant REQUIREMENT = 90_000_000;

    // Repo parameters
    uint256 internal constant REPO_CASH = 95_000_000; // $950,000
    uint256 internal constant REPO_RATE_BPS = 500; // 5%
    uint256 internal constant REPO_TENOR = 7 days;

    // Cash seeding (units of 1/100 USD)
    uint256 internal constant BANK_A_CASH = 50_000_000; // $500,000
    uint256 internal constant BANK_B_CASH = 100_000_000; // $1,000,000

    // Attestation / pricing default window
    uint256 internal constant ATTESTATION_TTL = 24 hours;
    uint256 internal constant COMPLIANCE_TTL = 90 days;
}
