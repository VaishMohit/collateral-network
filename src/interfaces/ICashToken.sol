// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/**
 * @title ICashToken
 * @notice Interface for the mock settlement cash (MockUSD). Abstracting cash
 *         lets the settlement coordinator remain agnostic to the cash instrument.
 */
interface ICashToken {
    function balanceOf(address account) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    function approve(address spender, uint256 amount) external returns (bool);
}
