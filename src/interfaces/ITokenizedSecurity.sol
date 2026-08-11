// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/**
 * @title ITokenizedSecurity
 * @notice Interface used by the CollateralManager to lock/unlock and enforce
 *         tokenized securities. Keeping this behind an interface means the
 *         collateral layer is not coupled to a specific token implementation
 *         and can be pointed at an external chain's representation later.
 */
interface ITokenizedSecurity {
    function assetId() external view returns (bytes32);

    function balanceOf(address account) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function frozen(address account) external view returns (bool);

    function mint(address to, uint256 amount) external;

    function burn(address from, uint256 amount) external;

    function forceTransfer(address from, address to, uint256 amount) external;

    function freeze(address account) external;

    function unfreeze(address account) external;
}
