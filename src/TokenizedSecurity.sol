// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ProtocolAccessManager} from "./ProtocolAccessManager.sol";
import {Roles} from "./libs/Roles.sol";

/**
 * @title TokenizedSecurity
 * @notice Digital representation of an underlying security held at the Mock CSD.
 *
 * @dev This is deliberately NOT a generic unrestricted ERC-20. It is a controlled
 *      instrument:
 *        - `mint` / `burn` are restricted to `TOKEN_CONTROLLER` (the
 *          CollateralManager and Admin).
 *        - `forceTransfer` is restricted to `TOKEN_CONTROLLER` and is used for
 *          collateral locking/release and enforcement.
 *        - `freeze` / `unfreeze` restrict ordinary transfer activity.
 *
 *      The token represents the *digital form* of the security. The Mock CSD
 *      remains authoritative for the underlying instrument: a token can only be
 *      minted after a valid custody attestation has been recorded.
 */
contract TokenizedSecurity {
    bytes32 public immutable assetId;
    string public name;
    string public symbol;
    uint8 public constant decimals = 0;

    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public frozen;

    ProtocolAccessManager public immutable access;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Frozen(address indexed account);
    event Unfrozen(address indexed account);

    error ZeroAddress();
    error InsufficientBalance();
    error InsufficientAllowance();
    error AccountFrozen();
    error Unauthorized();

    modifier onlyController() {
        if (!access.hasRole(Roles.TOKEN_CONTROLLER, msg.sender)) revert Unauthorized();
        _;
    }

    constructor(
        ProtocolAccessManager access_,
        bytes32 assetId_,
        string memory name_,
        string memory symbol_
    ) {
        access = access_;
        assetId = assetId_;
        name = name_;
        symbol = symbol_;
    }

    /* ------------------------------------------------------------------ */
    /* Controlled supply                                                   */
    /* ------------------------------------------------------------------ */

    function mint(address to, uint256 amount) external onlyController {
        if (to == address(0)) revert ZeroAddress();
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyController {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        totalSupply -= amount;
        balanceOf[from] -= amount;
        emit Transfer(from, address(0), amount);
    }

    /// @notice Enforcement transfer that ignores the freeze flag (controller only).
    function forceTransfer(address from, address to, uint256 amount) external onlyController {
        if (to == address(0)) revert ZeroAddress();
        _transfer(from, to, amount);
    }

    /* ------------------------------------------------------------------ */
    /* Freeze / unfreeze                                                   */
    /* ------------------------------------------------------------------ */

    function freeze(address account) external onlyController {
        frozen[account] = true;
        emit Frozen(account);
    }

    function unfreeze(address account) external onlyController {
        frozen[account] = false;
        emit Unfrozen(account);
    }

    /* ------------------------------------------------------------------ */
    /* Ordinary transfers (respect freeze)                                 */
    /* ------------------------------------------------------------------ */

    function transfer(address to, uint256 amount) external returns (bool) {
        if (to == address(0)) revert ZeroAddress();
        if (frozen[msg.sender] || frozen[to]) revert AccountFrozen();
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (frozen[from] || frozen[to]) revert AccountFrozen();
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
