// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/**
 * @title Roles
 * @notice Role identifiers shared across the Institutional Collateral Network.
 *         Referenced via `Roles.X` (library constants are inlined at compile
 *         time), which keeps role checks consistent and typo-resistant.
 */
library Roles {
    bytes32 internal constant ADMIN = keccak256("ADMIN");
    bytes32 internal constant CSD = keccak256("CSD");
    bytes32 internal constant CUSTODIAN = keccak256("CUSTODIAN");
    bytes32 internal constant BANK = keccak256("BANK");
    bytes32 internal constant COLLATERAL_AGENT = keccak256("COLLATERAL_AGENT");
    bytes32 internal constant VALUATION_PROVIDER = keccak256("VALUATION_PROVIDER");
    bytes32 internal constant SETTLEMENT_AGENT = keccak256("SETTLEMENT_AGENT");
    bytes32 internal constant COMPLIANCE_PROVIDER = keccak256("COMPLIANCE_PROVIDER");
    bytes32 internal constant POLICY_ADMIN = keccak256("POLICY_ADMIN");
    bytes32 internal constant TOKEN_CONTROLLER = keccak256("TOKEN_CONTROLLER");
}
