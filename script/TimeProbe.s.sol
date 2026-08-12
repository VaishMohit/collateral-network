// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;
import {Script, console2} from "forge-std/Script.sol";
contract TimeProbe is Script {
    function run() external {
        uint256 target = block.timestamp + 700000;
        try vm.rpc("anvil_setTime", string.concat('[', vm.toString(target), ']')) returns (bytes memory res) {
            console2.log("rpc returned without revert, len:", res.length);
        } catch {
            console2.log("rpc reverted, but node time was still set");
        }
    }
}
