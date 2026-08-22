// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/**
 * @title ProtocolAccessManager
 * @notice Central role-based access control for the Institutional Collateral Network.
 *
 * @dev Roles are expressed as `keccak256("ROLE_NAME")` constants so that the same
 *      registry can be shared across every contract in the network. Participant
 *      accounts (banks, custodians, the CSD) hold roles here; nothing else grants
 *      or revokes authorization.
 *
 *      Design notes:
 *        - A single ADMIN account bootstraps the system and can grant/revoke roles.
 *        - Banks must NOT be granted ADMIN or any privileged role.
 *        - The CSD/Custodian only receive signing/attestation roles, never the
 *          ability to mutate collateral state directly (that lives in the
 *          workflow managers and is restricted to operators).
 */
contract ProtocolAccessManager {
    /* ------------------------------------------------------------------ */
    /* Role identifiers                                                    */
    /* ------------------------------------------------------------------ */

    bytes32 public constant ADMIN = keccak256("ADMIN");
    bytes32 public constant CSD = keccak256("CSD");
    bytes32 public constant CUSTODIAN = keccak256("CUSTODIAN");
    bytes32 public constant BANK = keccak256("BANK");
    bytes32 public constant COLLATERAL_AGENT = keccak256("COLLATERAL_AGENT");
    bytes32 public constant VALUATION_PROVIDER = keccak256("VALUATION_PROVIDER");
    bytes32 public constant SETTLEMENT_AGENT = keccak256("SETTLEMENT_AGENT");
    bytes32 public constant COMPLIANCE_PROVIDER = keccak256("COMPLIANCE_PROVIDER");
    bytes32 public constant POLICY_ADMIN = keccak256("POLICY_ADMIN");
    bytes32 public constant TOKEN_CONTROLLER = keccak256("TOKEN_CONTROLLER");

    /* ------------------------------------------------------------------ */
    /* State                                                               */
    /* ------------------------------------------------------------------ */

    address public admin;

    /// role => account => has role
    mapping(bytes32 role => mapping(address account => bool)) public hasRole;

    /* ------------------------------------------------------------------ */
    /* Events                                                              */
    /* ------------------------------------------------------------------ */

    event RoleGranted(bytes32 indexed role, address indexed account, address indexed grantedBy);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed revokedBy);
    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);

    /* ------------------------------------------------------------------ */
    /* Modifiers                                                           */
    /* ------------------------------------------------------------------ */

    error NotAdmin();
    error MissingRole();
    error ZeroAdmin();
    error ZeroAccount();
    error AdminOnlyViaSetAdmin();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier onlyRole(bytes32 role) {
        if (!hasRole[role][msg.sender]) revert MissingRole();
        _;
    }

    /* ------------------------------------------------------------------ */
    /* Constructor                                                         */
    /* ------------------------------------------------------------------ */

    constructor(address initialAdmin) {
        if (initialAdmin == address(0)) revert ZeroAdmin();
        admin = initialAdmin;
        hasRole[ADMIN][initialAdmin] = true;
        emit RoleGranted(ADMIN, initialAdmin, address(0));
    }

    /* ------------------------------------------------------------------ */
    /* Admin management                                                    */
    /* ------------------------------------------------------------------ */

    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAdmin();
        address previousAdmin = admin;
        emit AdminChanged(previousAdmin, newAdmin);
        admin = newAdmin;
        hasRole[ADMIN][newAdmin] = true;
        emit RoleGranted(ADMIN, newAdmin, msg.sender);
        if (previousAdmin != newAdmin) {
            hasRole[ADMIN][previousAdmin] = false;
            emit RoleRevoked(ADMIN, previousAdmin, msg.sender);
        }
    }

    /* ------------------------------------------------------------------ */
    /* Role management                                                     */
    /* ------------------------------------------------------------------ */

    function grantRole(bytes32 role, address account) external onlyAdmin {
        if (account == address(0)) revert ZeroAccount();
        if (role == ADMIN && account != admin) revert AdminOnlyViaSetAdmin();
        if (!hasRole[role][account]) {
            hasRole[role][account] = true;
            emit RoleGranted(role, account, msg.sender);
        }
    }

    function revokeRole(bytes32 role, address account) external onlyAdmin {
        if (hasRole[role][account]) {
            hasRole[role][account] = false;
            emit RoleRevoked(role, account, msg.sender);
        }
    }

    function requireRole(bytes32 role, address account) external view {
        if (!hasRole[role][account]) revert MissingRole();
    }

    function isAdmin(address account) external view returns (bool) {
        return account == admin;
    }
}
