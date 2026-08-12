// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Demo} from "../script/Demo.s.sol";

contract DemoTest is Test {
    /// @dev Runs the exact deploy + demo scripts against the in-memory test EVM.
    ///      Mirrors: anvil; forge script Deploy --broadcast; forge script Demo --broadcast
    function setUp() public {
        // Never touch an external RPC in tests; the in-memory warp is enough.
        vm.setEnv("ANVIL_FAST_TIME", "0");
    }

    function test_endToEndLifecycle() public {
        Deploy deploy = new Deploy();
        deploy.run();
        Demo demo = new Demo();
        demo.run();
    }
}
