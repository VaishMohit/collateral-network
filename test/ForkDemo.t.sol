// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

/// Temporary fork demo — safe to delete.
contract ForkDemo is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant BINANCE_14 = 0x28C6c06298d514Db089934071355E5743bf21d60;

    function testForkHydration() public {
        // Requires a live endpoint:
        // forge test --match-contract ForkDemo --fork-url $MAINNET_RPC_URL
        if (!isFork()) vm.skip(true);
        uint256 bal = IERC20(USDC).balanceOf(BINANCE_14);
        assertGt(bal, 0);
    }
}
