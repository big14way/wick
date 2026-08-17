// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Deploys two plain test ERC20s and mints supply to the deployer.
/// Run once per testnet, then paste the two addresses into BaseScript.
contract DeployTestTokensScript is Script {
    function run() external {
        vm.startBroadcast();

        MockERC20 tokenA = new MockERC20("Wick Test Token A", "WICKA", 18);
        MockERC20 tokenB = new MockERC20("Wick Test Token B", "WICKB", 18);

        tokenA.mint(msg.sender, 1_000_000e18);
        tokenB.mint(msg.sender, 1_000_000e18);

        vm.stopBroadcast();

        console2.log("WICKA:", address(tokenA));
        console2.log("WICKB:", address(tokenB));
    }
}
