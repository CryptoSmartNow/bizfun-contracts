// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @notice Deploys MockUSDC on a testnet, then mints an initial supply to the deployer.
contract DeployMockUSDC is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        uint256 initialMint = 1_000_000e6; // 1 M USDC

        vm.startBroadcast(deployerPrivateKey);

        MockUSDC usdc = new MockUSDC();
        usdc.mint(deployer, initialMint);

        vm.stopBroadcast();

        console.log("=== MockUSDC Deployment ===");
        console.log("MockUSDC deployed at:", address(usdc));
        console.log("Owner:", deployer);
        console.log("Deployer balance:", usdc.balanceOf(deployer));
    }
}
