// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {RewardPoolFactory} from "../src/reward-pool/RewardPoolFactory.sol";
import {RewardPool} from "../src/reward-pool/RewardPool.sol";
import {IRewardPool} from "../src/reward-pool/interfaces/IRewardPool.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DeployRewardPool
/// @notice Script to deploy the XP-based reward pool factory to Base Sepolia
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

        console.log("=== DEPLOYING TO BASE SEPOLIA ===");
        console.log("Deployer/Admin:", deployer);

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
        console.log("Factory initialized with deployer:", deployer);

        // Create a test reward pool
        console.log("\n=== Creating Test Reward Pool ===");
        uint256 poolId = factory.createRewardPool(
            "Test Pool",
            "A test reward pool for demonstration"
        );

        console.log("Pool ID:", poolId);
        address poolAddress = factory.getPoolAddress(poolId);
        console.log("Pool Address:", poolAddress);
        console.log("Pool Admin:", deployer);

        // Grant signer role to specific addresses (like Incentive.sol pattern)
        address signerAddress = vm.envOr("SIGNER_ADDRESS", deployer); // Default to deployer if not set
        factory.grantSignerRole(poolId, signerAddress);
        console.log("Granted signer role to:", signerAddress);
        console.log(
            "Note: Additional signers can be added later via grantSignerRole()"
        );

        // Show pool information
        IRewardPool pool = IRewardPool(poolAddress);
        console.log("Pool active:", pool.s_active());
        console.log("Total XP in pool:", pool.s_totalXP());
        console.log("Total users in pool:", pool.getTotalUsers());

        vm.stopBroadcast();

        // Log deployment summary
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Network: Base Sepolia");
        console.log("RewardPoolFactory (Proxy):", address(factory));
        console.log(
            "RewardPoolFactory (Implementation):",
            address(implementation)
        );
        console.log("RewardPool (Implementation):", address(rewardPoolImpl));
        console.log("RewardPool implementation in factory:", factory.implementation());
        console.log("Example Pool ID:", poolId);
        console.log("Example Pool Address:", poolAddress);
        console.log("Pool Admin:", deployer);
        console.log("Initial Signer:", signerAddress);
        console.log("Pool Treasury:", poolAddress, "(pool itself)");
    }
}
