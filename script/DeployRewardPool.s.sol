// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {RewardPoolFactory} from "../src/reward-pool/RewardPoolFactory.sol";
import {RewardPool} from "../src/reward-pool/RewardPool.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DeployRewardPool
/// @notice Script to deploy the XP-based reward pool factory to production
contract DeployRewardPool is Script {
    uint256 public DEFAULT_ANVIL_PRIVATE_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    RewardPoolFactory public factory;
    uint256 public deployerKey;
    address public deployer;

    function setUp() public {
        if (block.chainid == 31337) {
            deployerKey = DEFAULT_ANVIL_PRIVATE_KEY;
            deployer = vm.addr(deployerKey);
        } else {
            string memory pkString = vm.envString("PRIVATE_KEY");
            deployerKey = vm.parseUint(pkString);
            deployer = vm.addr(deployerKey);
        }
    }

    function run() public {
        vm.startBroadcast(deployerKey);

        console.log("=== DEPLOYING REWARD POOL FACTORY ===");
        console.log("Deployer/Admin:", deployer);
        console.log("Chain ID:", block.chainid);

        // Deploy RewardPool implementation first
        RewardPool rewardPoolImpl = new RewardPool();
        console.log(
            "RewardPool implementation deployed at:",
            address(rewardPoolImpl)
        );

        // Deploy factory implementation
        RewardPoolFactory implementation = new RewardPoolFactory();
        console.log(
            "RewardPoolFactory implementation deployed at:",
            address(implementation)
        );

        // Deploy ERC1967Proxy for upgradeable pattern
        bytes memory initData = abi.encodeWithSelector(
            RewardPoolFactory.initialize.selector,
            deployer,
            address(rewardPoolImpl)
        );

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );
        factory = RewardPoolFactory(address(proxy));
        console.log("RewardPoolFactory proxy deployed at:", address(factory));
        console.log("Factory initialized with admin:", deployer);

        vm.stopBroadcast();

        // Log deployment summary
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Chain ID:", block.chainid);
        console.log("RewardPoolFactory (Proxy):", address(factory));
        console.log(
            "RewardPoolFactory (Implementation):",
            address(implementation)
        );
        console.log("RewardPool (Implementation):", address(rewardPoolImpl));
        console.log(
            "RewardPool implementation in factory:",
            factory.implementation()
        );
        console.log("Factory Admin:", deployer);
        console.log("Note: Create reward pools via SDK using factory address");
    }
}
