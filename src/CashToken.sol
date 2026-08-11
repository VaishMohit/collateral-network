// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ProtocolAccessManager} from "./ProtocolAccessManager.sol";
import {Roles} from "./libs/Roles.sol";

/**
 * @title CashToken
 * @notice Mock tokenized cash instrument (MockUSD) used purely as settlement
 *         cash for the POC. NOT a stablecoin implementation.
 *
 * @dev Balances are seeded by the deployer (Admin) for the demo participants.
 *      A minimal allowance-based ERC-20.
 */
contract CashToken {
    string public constant name = "MockUSD";
    string public constant symbol = "MockUSD";
    uint8 public constant decimals = 2;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    ProtocolAccessManager public immutable access;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error Unauthorized();
    error InsufficientBalance();
    error InsufficientAllowance();

    constructor(ProtocolAccessManager access_) {
        access = access_;
    }

    modifier onlyMinter() {
        if (!access.hasRole(Roles.ADMIN, msg.sender)) revert Unauthorized();
        _;
    }

    /// @notice Admin mints test cash into participant balances.
    function mint(address to, uint256 amount) external onlyMinter {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
